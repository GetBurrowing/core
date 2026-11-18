defmodule Platform.Social.StudioIntakeAcceptLocksTest do
  @moduledoc """
  Integration test (slice C joined to slice B): a clip imported through
  `Intake.import_manifest/4` is accepted by `Studio.accept_render/4` under B's
  lock order, and the decisions are made again on the rows read under the lock.

  Two real connections. The import commits. A HOLDER then changes the
  destination account (archive, or an owner transfer) and keeps its transaction
  open. `accept_render` is started, must BLOCK on the account row lock (shown
  by `pg_blocking_pids` bound to this holder's backend), and after the holder
  commits it must be refused with the reason the NEW row calls for and write
  nothing. A control with no change is accepted.

  Mutation checks (each fails the named tests):
    * lock the accounts without `FOR SHARE` in `Studio.lock_accounts_in_order/2`:
      "must block" fails in both change tests;
    * drop `require_live(account)` in `Studio.decide_destination/6`: the archive test;
    * drop `accept_actor/4` in `Studio.decide_destination/6`: the owner test.

  The world is committed and removed by hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, ClipRender, Intake, Post, Profile, Studio}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{name: "IA root #{n}", slug: "ia-root-#{n}"}), true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "IA #{n}",
        slug: "ia-#{n}",
        parent_org_id: root.id
      })

    user = fn tag ->
      u =
        Repo.insert!(%Platform.Accounts.User{
          email: "ia-#{tag}-#{n}@example.com",
          oidc_sub: "ia-#{tag}-#{n}",
          name: "IA #{tag} #{n}"
        })

      Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: u.id, org_id: org.id, role: "member"})
      u
    end

    [u1, u2] = Enum.map(~w(one two), user)
    {:ok, project} = Platform.Tasks.create_project(%{name: "IA #{n}", org_id: org.id})

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "IA show #{n}",
        project_id: project.id,
        home_url: "https://www.youtube.com/@iashow",
        approver_user_ids: [u1.id, u2.id]
      })

    {:ok, account} =
      Social.create_account(org.id, profile, %{platform: "tiktok", handle: "@ia#{n}"})

    {:ok, account} = Social.set_account_owner(org.id, account, u1.id)
    {:ok, profile} = Studio.set_enabled(org.id, profile.id, u1.id, true)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      post_ids =
        Repo.all(
          from(po in Post,
            join: ac in Platform.Social.Account,
            on: ac.id == po.account_id,
            where: ac.profile_id in ^profile_ids,
            select: po.id
          )
        )

      Repo.delete_all(from(r in Platform.Social.PostApproval, where: r.post_id in ^post_ids))
      Repo.delete_all(from(e in Platform.Social.PostEvent, where: e.post_id in ^post_ids))
      Repo.delete_all(from(po in Post, where: po.id in ^post_ids))
      # Clips (and their renders and versions) and accounts go with the profile by FK.
      Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids))
      Repo.delete_all(from(f in Platform.Files.File, where: f.project_id == ^project.id))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^[u1.id, u2.id]))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id))
      if own_root?, do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{org: org, u1: u1, u2: u2, project: project, profile: profile, account: account}
  end

  # Imports one clip through slice C and returns it with its render id.
  defp imported!(ctx) do
    {:ok, file, _} =
      Platform.Files.add_bytes(
        ctx.project,
        "ia clip #{System.unique_integer([:positive])}",
        "ia.mp4",
        "video/mp4",
        ingest: false
      )

    manifest = %{
      "clips" => [
        %{
          "external_ref" => "ia/#{System.unique_integer([:positive])}",
          "file_id" => file.id,
          "title" => "T",
          "caption" => "C",
          "platforms" => ["tiktok"]
        }
      ]
    }

    assert {:ok, %{clips: [%{status: :created, clip_id: clip_id}]}} =
             Intake.import_manifest({:tenant, ctx.org.id}, ctx.profile.id, manifest, ctx.u1.id)

    clip = Repo.get!(Clip, clip_id)
    assert clip.origin == "external" and clip.flow == "studio"
    rid = Repo.one!(from(r in ClipRender, where: r.clip_id == ^clip.id, select: r.id))
    {clip, rid}
  end

  defp accept(ctx, clip, rid),
    do:
      Studio.accept_render(ctx.org.id, clip.id, ctx.u1.id, %{
        render_id: rid,
        account_ids: [ctx.account.id]
      })

  defp post_count(ctx),
    do: Repo.aggregate(from(p in Post, where: p.account_id == ^ctx.account.id), :count)

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp blocked_by?(holder_backend, tries \\ 100) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND pid <> $1 AND wait_event_type = 'Lock' " <>
          "AND $1 = ANY(pg_blocking_pids(pid)) AND query ~ 'FOR (SHARE|UPDATE)'",
        [holder_backend]
      )

    cond do
      n > 0 ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        blocked_by?(holder_backend, tries - 1)
    end
  end

  # The holder changes the account and keeps the transaction open; accept_render
  # must block on the account lock and then be refused on the committed change.
  defp refused_under_lock(ctx, change) do
    {clip, rid} = imported!(ctx)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = change.()
          send(parent, {:changed, backend_pid()})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:changed, holder_backend}, 5_000
    caller = Task.async(fn -> accept(ctx, clip, rid) end)
    assert Task.yield(caller, 400) == nil, "accept_render must block on the account row lock"
    assert blocked_by?(holder_backend), "no backend is blocked by this test's holder"

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)
    {clip, Task.await(caller, 10_000)}
  end

  test "control: an imported clip is accepted when nothing changed", ctx do
    {clip, rid} = imported!(ctx)

    assert {:ok, %{posts: [%Post{} = post]}} = accept(ctx, clip, rid)
    assert post.account_id == ctx.account.id
    assert post_count(ctx) == 1
  end

  test "imported clip, destination archived while accept_render waits: refused under the lock",
       ctx do
    {clip, result} =
      refused_under_lock(ctx, fn -> Social.archive_account(ctx.org.id, ctx.account) end)

    assert {:error, {:destinations, [%{reason: :account_archived}]}} = result
    assert post_count(ctx) == 0
    assert Repo.get!(Clip, clip.id).review_status == "pending"
  end

  test "imported clip, destination owner changed while accept_render waits: refused under the lock",
       ctx do
    {clip, result} =
      refused_under_lock(ctx, fn ->
        Social.set_account_owner(ctx.org.id, ctx.account, ctx.u2.id)
      end)

    assert {:error, {:destinations, [%{reason: :not_the_owner}]}} = result
    assert post_count(ctx) == 0
    assert Repo.get!(Clip, clip.id).review_status == "pending"
  end
end
