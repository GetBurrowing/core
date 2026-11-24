defmodule Platform.Social.StudioBIndependentReviewTest do
  @moduledoc """
  Regressions for three races found in independent review of the approval
  and planning functions, adapted here after the fixes.
  Real connections and committed fixtures, which `cleanup_world!/1` removes.

  1. Replay authority race: the replayed post is locked `FOR UPDATE` from its
     destination decision to its return, so a concurrent B -> C retarget WAITS
     for the replay and the replay returns the very row it authorised. The
     handshake parks the actual replay after its destination decisions, at the
     render lookup; the retarget is then shown blocked BY THE REPLAY's backend
     (`pg_blocking_pids`), not by "any waiter".
  2. Agent writes need the profile's live project, on the locked profile.
  3. Retries and exhaustion never lock an account after the post.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Social
  alias Platform.Social.Studio

  alias Platform.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    known_admins = fixture_admin_ids()
    w = studio_world!()
    on_exit(fn -> cleanup_world!(w, fixture_admin_ids() -- known_admins) end)
    %{w: w}
  end

  # Ordinary fixture cleanup for rows these tests commit: every step is
  # attempted even if one raises, and the first error is re-raised at the end.
  # `org_id!/0` commits a root admin ("tenancy-fixtures-admin-N") per new org
  # when no sandbox transaction is open; N restarts with every BEAM, so leftovers
  # collide with later runs. The ones made by a test are removed with it.
  defp fixture_admin_ids do
    Repo.all(
      from(u in Platform.Accounts.User,
        where: like(u.email, "tenancy-fixtures-admin-%"),
        select: u.id
      )
    )
  end

  defp cleanup_world!(w, new_admin_ids) do
    Sandbox.mode(Repo, :auto)
    org_ids = [w.org_id, w.other_org_id]
    # Every member of the two orgs (the world's users and any user a test adds)
    extra_user_ids =
      Repo.all(
        from(m in Platform.Tenancy.OrgMembership, where: m.org_id in ^org_ids, select: m.user_id)
      )

    steps = [
      fn ->
        Repo.delete_all(
          from(r in Platform.Social.PostApproval,
            where: r.post_id in subquery(org_post_ids(org_ids))
          )
        )
      end,
      fn ->
        Repo.delete_all(
          from(po in Platform.Social.Post, where: po.id in subquery(org_post_ids(org_ids)))
        )
      end,
      fn ->
        Repo.delete_all(
          from(f in Platform.Files.File,
            where: f.project_id in subquery(org_project_ids(org_ids))
          )
        )
      end,
      fn ->
        Repo.delete_all(
          from(m in Platform.Tenancy.OrgMembership, where: m.user_id in ^new_admin_ids)
        )
      end,
      fn -> Repo.delete_all(from(p in Platform.Social.Profile, where: p.org_id in ^org_ids)) end,
      fn -> Repo.delete_all(from(p in Platform.Tasks.Project, where: p.org_id in ^org_ids)) end,
      fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id in ^org_ids)) end,
      fn ->
        Repo.delete_all(
          from(u in Platform.Accounts.User,
            where:
              u.id in ^Enum.uniq([w.approver.id, w.outsider.id | extra_user_ids ++ new_admin_ids])
          )
        )
      end,
      fn -> Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^w.agent.id)) end
    ]

    errors =
      Enum.flat_map(steps, fn step ->
        try do
          step.()
          []
        rescue
          e -> [e]
        end
      end)

    Sandbox.mode(Repo, :manual)

    case errors do
      [] -> :ok
      [first | _] -> raise first
    end
  end

  defp org_post_ids(org_ids) do
    from(po in Platform.Social.Post,
      join: ac in Platform.Social.Account,
      on: ac.id == po.account_id,
      join: pr in Platform.Social.Profile,
      on: pr.id == ac.profile_id,
      where: pr.org_id in ^org_ids,
      select: po.id
    )
  end

  defp org_project_ids(org_ids),
    do: from(p in Platform.Tasks.Project, where: p.org_id in ^org_ids, select: p.id)

  test "replay returns the post it authorised: a concurrent B to C retarget waits for it",
       %{w: w} do
    mover = user!() |> member!(w.org_id)

    {:ok, _} =
      Social.update_profile(w.org_id, w.profile, %{
        approver_user_ids: [w.approver.id, mover.id]
      })

    {:ok, third} =
      Social.create_account(w.org_id, w.profile, %{platform: "linkedin", handle: "@private"})

    {:ok, third} = Social.set_account_owner(w.org_id, third, mover.id)
    clip = w |> pending_clip!() |> make_studio_clip!()
    rid = render_id!(clip)
    attrs = %{render_id: rid, account_ids: [w.x.id]}

    {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, %{post: moved}} =
      Studio.save_version(
        w.org_id,
        post.id,
        w.approver.id,
        %{account_id: w.tiktok.id},
        expect(post)
      )

    profile = Social.get_profile(w.org_id, w.profile.id)
    assert :ok = Social.post_approver_check(w.org_id, profile, w.tiktok, w.approver.id)

    assert {:error, :not_the_owner} =
             Social.post_approver_check(w.org_id, profile, third, w.approver.id)

    parent = self()
    marker = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        marker,
        [:platform, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(marker) == :armed and
               String.contains?(metadata[:query] || "", ~s(FROM "social_clip_renders")) do
            Process.put(marker, :parked)
            # This process is inside the replay's transaction: its backend pid
            # is the one the retarget must be shown waiting on.
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:replay_decided, self(), backend})

            receive do
              :resume_replay -> :ok
            after
              10_000 -> raise "review replay handshake timed out"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(marker) end)

    replay =
      Task.async(fn ->
        Process.put(marker, :armed)
        Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)
      end)

    assert_receive {:replay_decided, replay_pid, replay_backend}, 5_000

    # A second real connection starts the supported retarget while replay is
    # between its destination decision and its return. The retarget must be
    # blocked on a lock the REPLAY's backend holds (the post row), proving the
    # replayed post is protected, not merely that something is waiting.
    retarget =
      Task.async(fn ->
        Studio.save_version(
          w.org_id,
          moved.id,
          mover.id,
          %{account_id: third.id},
          expect(moved)
        )
      end)

    assert wait_blocked_by?(replay_backend, "social_posts"),
           "the retarget is not waiting on the replay's lock on the post"

    # Neither another relation nor a different backend is this row wait.
    refute wait_blocked_by?(replay_backend, "social_profiles", 0)
    %{rows: [[observer_backend]]} = Repo.query!("SELECT pg_backend_pid()")
    refute wait_blocked_by?(observer_backend, "social_posts", 0)

    send(replay_pid, :resume_replay)

    # The replay returns the post it authorised (on B), never the retarget's C.
    assert {:ok, %{posts: [returned]}} = Task.await(replay, 5_000)
    assert returned.id == post.id
    assert returned.account_id == w.tiktok.id

    # Only afterwards does the retarget commit.
    assert {:ok, %{post: current}} = Task.await(retarget, 5_000)
    assert current.account_id == third.id
  end

  # True once some backend other than `holder` is waiting on a lock that
  # `holder` holds AND its current statement reads `table`. Bound to the
  # holder's pid, not to "any backend waiting on any lock". Use the actual
  # tuple relation: pg_stat_activity.query can truncate before FROM when
  # Ecto selects a post with many columns.
  defp wait_blocked_by?(holder, table, tries \\ 100) do
    %{rows: rows} =
      Repo.query!(
        "SELECT a.pid FROM pg_stat_activity a WHERE a.datname = current_database() " <>
          "AND a.wait_event_type = 'Lock' AND $1 = ANY(pg_blocking_pids(a.pid)) " <>
          "AND EXISTS (SELECT 1 FROM pg_locks l WHERE l.pid = a.pid " <>
          "AND l.locktype = 'tuple' AND l.granted AND l.relation = to_regclass($2))",
        [holder, table]
      )

    cond do
      rows != [] ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        wait_blocked_by?(holder, table, tries - 1)
    end
  end

  test "delegated agent edits require the profile's live project", %{w: w} do
    post = studio_post!(w, w.x, "draft")
    {:ok, profile} = Social.update_profile(w.org_id, w.profile, %{project_id: nil})
    assert {:error, :studio_needs_project} = Studio.require_studio_project(profile)

    assert {:error, :studio_needs_project} =
             Social.AgentDrafts.update_agent_draft(
               w.scope,
               post.id,
               %{body: "Agent edit after project removal"},
               agent_id: w.agent.id
             )
  end

  test "repeated retargets never take an account lock after the post lock", %{w: w} do
    post = studio_post!(w, w.x)

    more =
      for platform <- ["linkedin", "instagram"] do
        {:ok, account} =
          Social.create_account(w.org_id, w.profile, %{platform: platform, handle: "@retry"})

        account
      end

    parent = self()
    marker = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        marker,
        [:platform, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(marker) do
            query = metadata[:query] || ""

            cond do
              String.contains?(query, ~s(FROM "social_profiles")) and
                  String.contains?(query, "FOR SHARE") ->
                Process.put({marker, :post_locked}, false)

              String.contains?(query, ~s(FROM "social_posts")) and
                  String.contains?(query, "FOR UPDATE") ->
                Process.put({marker, :post_locked}, true)

              String.contains?(query, ~s(FROM "social_accounts")) and
                  String.contains?(query, "FOR SHARE") ->
                if Process.get({marker, :post_locked}, false) do
                  send(parent, :late_account_lock)
                else
                  send(parent, {:before_post_lock, self()})

                  receive do
                    :resume_writer -> :ok
                  after
                    10_000 -> raise "review retarget handshake timed out"
                  end
                end

              true ->
                :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(marker) end)

    writer =
      Task.async(fn ->
        Process.put(marker, true)
        Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))
      end)

    Enum.reduce([w.tiktok | more], post, fn destination, current ->
      assert_receive {:before_post_lock, writer_pid}, 5_000

      assert {:ok, %{post: moved}} =
               Studio.save_version(
                 w.org_id,
                 current.id,
                 w.approver.id,
                 %{account_id: destination.id},
                 expect(current)
               )

      send(writer_pid, :resume_writer)
      moved
    end)

    assert {:error, {:stale, _}} = Task.await(writer, 5_000)
    refute_receive :late_account_lock, 0
  end
end
