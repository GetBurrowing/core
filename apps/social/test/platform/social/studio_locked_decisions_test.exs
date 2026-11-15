defmodule Platform.Social.StudioLockedDecisionsTest do
  @moduledoc """
  Slice B writers decide again on the rows they read UNDER the locks
  (the locked-row rule; slice A rule "authority under
  lock"). Two real database connections, for every writer and every change:

  1. a HOLDER opens a transaction and makes ONE change (owner transfer,
     account archive, approver removal, Studio switched off, project removed)
     and keeps it uncommitted;
  2. the writer is started; it passes its pre-lock reads (they still see the
     old rows) and must BLOCK on the profile or account row lock (shown by
     a 400 ms wait that is still pending, and a backend that `pg_blocking_pids`
     shows blocked by THIS holder's backend);
  3. the holder commits; the writer must answer the refusal the NEW rows
     call for and write nothing.

  The one exception per change is the escape route: cancelling a
  plan and retargeting away from an archived account still succeed.
  Accept replay is covered for both the requested and the current account.
  The world is committed and removed by hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, Post, PostApproval, PostEvent, Profile, Studio}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{
             name: "LD root #{n}",
             slug: "ld-root-#{Platform.TenancyFixtures.run_token()}-#{n}"
           }), true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "LD #{n}",
        slug: "ld-#{Platform.TenancyFixtures.run_token()}-#{n}",
        parent_org_id: root.id
      })

    user = fn tag ->
      u =
        Repo.insert!(%Platform.Accounts.User{
          email: "ld-#{tag}-#{Platform.TenancyFixtures.run_token()}-#{n}@example.com",
          oidc_sub: "ld-#{tag}-#{Platform.TenancyFixtures.run_token()}-#{n}",
          name: "LD #{tag} #{n}"
        })

      Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: u.id, org_id: org.id, role: "member"})
      u
    end

    [u1, u2] = Enum.map(~w(one two), user)
    {:ok, project} = Platform.Tasks.create_project(%{name: "LD #{n}", org_id: org.id})

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "ld-agent-#{Platform.TenancyFixtures.run_token()}-#{n}",
        name: "LD agent #{n}",
        metadata: %{"org_id" => org.id}
      })

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

      Repo.delete_all(from(r in PostApproval, where: r.post_id in ^post_ids))
      Repo.delete_all(from(po in Post, where: po.id in ^post_ids))
      Repo.delete_all(from(c in Clip, where: c.profile_id in ^profile_ids))
      Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids))
      Repo.delete_all(from(f in Platform.Files.File, where: f.project_id == ^project.id))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^[u1.id, u2.id]))
      Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id))
      if own_root?, do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{org: org, u1: u1, u2: u2, project: project, agent: agent}
  end

  # A fresh profile with accounts a and b. `owned?`: both owned by u1, else
  # unowned and u1 acts as a listed approver (u2 is listed too).
  defp scenario!(ctx, owned?) do
    n = System.unique_integer([:positive])

    {:ok, profile} =
      Social.create_profile(ctx.org.id, %{
        name: "LD show #{n}",
        project_id: ctx.project.id,
        home_url: "https://www.youtube.com/@ldshow",
        approver_user_ids: [ctx.u1.id, ctx.u2.id]
      })

    {:ok, a} = Social.create_account(ctx.org.id, profile, %{platform: "x", handle: "@a#{n}"})
    {:ok, b} = Social.create_account(ctx.org.id, profile, %{platform: "tiktok", handle: "@b#{n}"})

    {a, b} =
      if owned? do
        {:ok, a} = Social.set_account_owner(ctx.org.id, a, ctx.u1.id)
        {:ok, b} = Social.set_account_owner(ctx.org.id, b, ctx.u1.id)
        {a, b}
      else
        {a, b}
      end

    {:ok, profile} = Studio.set_enabled(ctx.org.id, profile.id, ctx.u1.id, true)
    %{profile: profile, a: a, b: b}
  end

  defp exp(p, extra \\ %{}), do: Map.merge(%{state_rev: p.state_rev, version: p.version}, extra)
  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp post!(ctx, account, status) do
    {:ok, post} =
      Studio.create_post(ctx.org.id, account.id, ctx.u1.id, %{
        body: "ld #{System.unique_integer([:positive])}",
        status: status
      })

    post
  end

  defp approved!(ctx, account) do
    post = post!(ctx, account, "needs_approval")

    {:ok, %{post: p, approval: r}} =
      Studio.approve_version(ctx.org.id, post.id, ctx.u1.id, exp(post))

    {p, r}
  end

  defp clip!(ctx, s) do
    {:ok, file, _} =
      Platform.Files.add_bytes(
        ctx.project,
        "ld clip #{System.unique_integer([:positive])}",
        "clip.mp4",
        "video/mp4",
        ingest: false
      )

    {:ok, clip} =
      AgentDrafts.submit_clip(
        {:tenant, ctx.org.id},
        s.profile.id,
        %{
          "file_id" => file.id,
          "title" => "T",
          "caption" => "C",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        ctx.agent.id
      )

    Repo.update_all(from(c in Clip, where: c.id == ^clip.id), set: [flow: "studio"])

    rid =
      Repo.one!(from(r in Platform.Social.ClipRender, where: r.clip_id == ^clip.id, select: r.id))

    {clip, rid}
  end

  defp accept(ctx, clip, rid, accounts),
    do:
      Studio.accept_render(ctx.org.id, clip.id, ctx.u1.id, %{
        render_id: rid,
        account_ids: Enum.map(accounts, & &1.id)
      })

  # ── writers: name => fn ctx, s -> {call, target} ─────────────────────
  # `target` is the account (:a or :b) the change is made on.

  defp writers do
    %{
      approve: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")
        {fn -> Studio.approve_version(ctx.org.id, p.id, ctx.u1.id, exp(p)) end, :a}
      end,
      reapprove: fn ctx, s ->
        # an approved post whose receipt authority is still intact when the
        # call starts; the change that commits while it waits is what ends it
        {p, _} = approved!(ctx, s.a)
        {fn -> Studio.approve_version(ctx.org.id, p.id, ctx.u1.id, exp(p)) end, :a}
      end,
      plan_post: fn ctx, s ->
        {p, _} = approved!(ctx, s.a)
        {fn -> Studio.plan_post(ctx.org.id, p.id, ctx.u1.id, exp(p), future()) end, :a}
      end,
      cancel_plan: fn ctx, s ->
        {p, _} = approved!(ctx, s.a)
        {:ok, %{post: planned}} = Studio.plan_post(ctx.org.id, p.id, ctx.u1.id, exp(p), future())
        {fn -> Studio.cancel_plan(ctx.org.id, planned.id, ctx.u1.id, exp(planned)) end, :a}
      end,
      revoke_approval: fn ctx, s ->
        {p, r} = approved!(ctx, s.a)

        {fn ->
           Studio.revoke_approval(ctx.org.id, p.id, ctx.u1.id, exp(p, %{approval_id: r.id}), "x")
         end, :a}
      end,
      request_changes: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")
        {fn -> Studio.request_changes(ctx.org.id, p.id, ctx.u1.id, exp(p), "fix") end, :a}
      end,
      resubmit: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")
        {:ok, rejected} = Studio.request_changes(ctx.org.id, p.id, ctx.u1.id, exp(p), "fix")
        {fn -> Studio.resubmit(ctx.org.id, rejected.id, ctx.u1.id, exp(rejected), "ok") end, :a}
      end,
      save_version_edit: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")

        {fn ->
           Studio.save_version(ctx.org.id, p.id, {:human, ctx.u1.id}, %{body: "edited"}, exp(p))
         end, :a}
      end,
      retarget_old: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")

        {fn ->
           Studio.save_version(
             ctx.org.id,
             p.id,
             {:human, ctx.u1.id},
             %{account_id: s.b.id},
             exp(p)
           )
         end, :a}
      end,
      retarget_new: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")

        {fn ->
           Studio.save_version(
             ctx.org.id,
             p.id,
             {:human, ctx.u1.id},
             %{account_id: s.b.id},
             exp(p)
           )
         end, :b}
      end,
      agent_draft: fn ctx, s ->
        p = post!(ctx, s.a, "needs_approval")

        {fn ->
           AgentDrafts.update_agent_draft({:tenant, ctx.org.id}, p.id, %{"body" => "agent"},
             agent_id: ctx.agent.id
           )
         end, :a}
      end,
      accept_new: fn ctx, s ->
        {clip, rid} = clip!(ctx, s)
        {fn -> accept(ctx, clip, rid, [s.a]) end, :a}
      end,
      accept_replay_requested: fn ctx, s ->
        {clip, rid} = clip!(ctx, s)
        {:ok, _} = accept(ctx, clip, rid, [s.a])
        {fn -> accept(ctx, clip, rid, [s.a]) end, :a}
      end,
      accept_replay_current: fn ctx, s ->
        {clip, rid} = clip!(ctx, s)
        {:ok, %{posts: [p]}} = accept(ctx, clip, rid, [s.a])

        {:ok, _} =
          Studio.save_version(
            ctx.org.id,
            p.id,
            {:human, ctx.u1.id},
            %{account_id: s.b.id},
            exp(p)
          )

        {fn -> accept(ctx, clip, rid, [s.a]) end, :b}
      end
    }
  end

  # change => {needs an owned account?, holder fn, refusal}
  defp changes do
    %{
      owner_transferred:
        {true, fn ctx, s, t -> Social.set_account_owner(ctx.org.id, s[t], ctx.u2.id) end,
         :not_the_owner},
      account_archived:
        {true, fn ctx, s, t -> Social.archive_account(ctx.org.id, s[t]) end, :account_archived},
      approver_removed:
        {false,
         fn ctx, s, _t ->
           Social.update_profile(ctx.org.id, s.profile, %{approver_user_ids: [ctx.u2.id]})
         end, :not_an_approver},
      studio_disabled:
        {true,
         fn ctx, s, _t -> Studio.set_enabled(ctx.org.id, s.profile.id, ctx.u2.id, false) end,
         :studio_disabled},
      project_removed:
        {true,
         fn ctx, s, _t -> Social.update_profile(ctx.org.id, s.profile, %{project_id: nil}) end,
         :studio_needs_project}
    }
  end

  # The escape routes: these writers still succeed on an
  # archived OLD account.
  @archive_ok ~w(cancel_plan retarget_old)a
  # An agent has no approver or owner check (those are human-only), but it needs
  # Studio enabled, a live account and a live same-org project (every Studio
  # write), each decided on the locked rows.
  @agent_changes ~w(account_archived studio_disabled project_removed)a

  defp reason({:error, {:destinations, [%{reason: r}]}}), do: r
  defp reason({:error, r}), do: r
  defp reason({:error, r, _}), do: r
  defp reason({:ok, _}), do: :ok

  defp snapshot(s) do
    account_ids = [s.a.id, s.b.id]

    posts =
      Repo.all(from(p in Post, where: p.account_id in ^account_ids, order_by: p.id))

    ids = Enum.map(posts, & &1.id)

    {posts, Repo.aggregate(from(e in PostEvent, where: e.post_id in ^ids), :count),
     Repo.aggregate(from(r in PostApproval, where: r.post_id in ^ids), :count)}
  end

  # The backend pid of the connection this process holds (call it inside the
  # holder's transaction, so it names the holder's own backend).
  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # True once a DIFFERENT backend is waiting on a lock that the holder's
  # backend holds, in a Studio lock statement (`FOR SHARE`/`FOR UPDATE`). It is
  # bound to this test's holder (`pg_blocking_pids`), so unrelated database
  # traffic waiting on something else cannot satisfy it. The 400 ms
  # `Task.yield` before it shows only that the call is still pending.
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

  for {writer, change} <-
        for(
          w <- ~w(approve reapprove plan_post cancel_plan revoke_approval request_changes resubmit
                    save_version_edit retarget_old retarget_new agent_draft accept_new
                    accept_replay_requested accept_replay_current)a,
          c <-
            ~w(owner_transferred account_archived approver_removed studio_disabled project_removed)a,
          do: {w, c}
        ),
      not (writer == :agent_draft and change not in @agent_changes),
      # the new account of a retarget has no profile-level change of its own
      not (writer == :retarget_new and
             change in ~w(approver_removed studio_disabled project_removed)a) do
    archive_escape? = writer in @archive_ok and change == :account_archived

    test "#{writer} is re-decided under the lock when #{change} commits while it waits", ctx do
      writer = unquote(writer)
      change = unquote(change)
      {owned?, hold, refusal} = Map.fetch!(changes(), change)
      s = scenario!(ctx, owned?)
      {call, target} = Map.fetch!(writers(), writer).(ctx, s)

      before = snapshot(s)
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            {:ok, _} = hold.(ctx, s, target)
            send(parent, {:changed, backend_pid()})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:changed, holder_backend}, 5_000
      caller = Task.async(call)
      assert Task.yield(caller, 400) == nil, "the writer must block on the row lock"
      assert blocked_by?(holder_backend), "no backend is blocked by this test's holder"

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 10_000)
      result = Task.await(caller, 10_000)

      if unquote(archive_escape?) and target == :a do
        assert {:ok, _} = result
      else
        assert reason(result) == refusal, "#{writer}/#{change}: #{inspect(result)}"
        assert snapshot(s) == before, "a refused #{writer} wrote something"
      end
    end
  end

  test "re-approval is decided under the lock: the owner change that commits while it waits makes it succeed",
       ctx do
    s = scenario!(ctx, true)
    {approved, old} = approved!(ctx, s.a)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Social.set_account_owner(ctx.org.id, s.a, ctx.u2.id)
          send(parent, {:changed, backend_pid()})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:changed, holder_backend}, 5_000

    # u2 is NOT the owner in any row the writer can read before the lock; only
    # the committed transfer makes u2 an approver, and it also ends u1's receipt.
    caller =
      Task.async(fn ->
        Studio.approve_version(ctx.org.id, approved.id, ctx.u2.id, exp(approved))
      end)

    assert Task.yield(caller, 400) == nil, "the re-approval must block on the row lock"
    assert blocked_by?(holder_backend), "no backend is blocked by this test's holder"

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)

    assert {:ok, %{post: post, approval: receipt}} = Task.await(caller, 10_000)
    assert post.status == "approved"
    assert post.approved_by_user_id == ctx.u2.id
    assert receipt.approved_by_user_id == ctx.u2.id
    assert Repo.get!(PostApproval, old.id).state == "superseded"
  end

  test "two acceptances naming overlapping accounts in opposite order do not deadlock", ctx do
    s = scenario!(ctx, true)
    {clip, rid} = clip!(ctx, s)
    [low, high] = Enum.sort_by([s.a, s.b], & &1.id)
    parent = self()

    # an owner transfer of the HIGH account in flight: both acceptances take
    # the low account, then wait for the high one, in the same order.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Social.set_account_owner(ctx.org.id, high, ctx.u2.id)
          send(parent, :changed)

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :changed, 5_000
    first = Task.async(fn -> accept(ctx, clip, rid, [low, high]) end)
    second = Task.async(fn -> accept(ctx, clip, rid, [high, low]) end)
    assert Task.yield(first, 400) == nil
    assert Task.yield(second, 400) == nil

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)

    for task <- [first, second] do
      # the owner moved while they waited: both are refused on the high
      # account, in the envelope, and neither died on a deadlock
      assert {:error, {:destinations, [%{account_id: id, reason: :not_the_owner}]}} =
               Task.await(task, 10_000)

      assert id == high.id
    end

    assert Repo.aggregate(from(p in Post, where: p.account_id in ^[low.id, high.id]), :count) == 0
  end
end
