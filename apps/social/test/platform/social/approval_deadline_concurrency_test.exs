defmodule Platform.Social.ApprovalDeadlineConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, AgentDrafts, Post, Profile}

  setup do
    Sandbox.mode(Repo, :auto)
    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))
    id = Ecto.UUID.generate()

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Deadline race",
        slug: "deadline-#{id}",
        parent_org_id: root.id
      })

    user = user!()
    member!(user, org.id)
    space = channel!(org.id)

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Deadline race",
        space_id: space.id,
        approver_user_ids: [user.id]
      })

    {:ok, account} =
      Social.create_account(org.id, profile, %{platform: "linkedin", status: "connected"})

    {:ok, post} =
      Social.create_post(org.id, account, %{
        body: "Race caption",
        status: "needs_approval",
        scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    on_exit(fn ->
      steps = [
        fn -> Repo.delete_all(from(p in Post, where: p.account_id == ^account.id)) end,
        fn -> Repo.delete_all(from(a in Account, where: a.id == ^account.id)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^profile.id)) end,
        fn -> Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^space.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn -> Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user.id)) end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end
      ]

      errors =
        try do
          Enum.flat_map(steps, fn step ->
            try do
              step.()
              []
            catch
              kind, reason -> [{kind, reason, __STACKTRACE__}]
            end
          end)
        after
          Sandbox.mode(Repo, :manual)
        end

      case errors do
        [{kind, reason, stack} | _] -> :erlang.raise(kind, reason, stack)
        [] -> :ok
      end
    end)

    %{org: org, user: user, post: post}
  end

  test "approval rechecks completeness after its post-lock wait", ctx do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          locked = Social.lock_post(ctx.org.id, ctx.post.id)
          Repo.update!(Ecto.Changeset.change(locked, body: "   "))
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:incomplete_held, pid})

          receive do
            :release -> :ok
          after
            5000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:incomplete_held, holder_pid}, 5000

    caller =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:incomplete_caller, pid})
          Social.approve_post(ctx.org.id, ctx.post, ctx.user.id)
        end)
      end)

    try do
      assert_receive {:incomplete_caller, caller_pid}, 5000
      assert caller_pid != holder_pid
      blocked!(caller_pid, holder_pid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5000)
      assert {:error, {:incomplete_post, ["Add the post text."]}} = Task.await(caller, 5000)

      assert %{status: "needs_approval", approved_at: nil, body: "   "} =
               Repo.get!(Post, ctx.post.id)
    after
      send(holder.pid, :release)
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  test "new-job confirmation refuses a job id appearing during the lock wait", ctx do
    alias Platform.Social.{Publishing, Publisher.Fake}
    Fake.reset()
    {:ok, approved} = Social.approve_post(ctx.org.id, ctx.post, ctx.user.id)
    post = Repo.update!(Post.refusal_changeset(approved, "media_rejected", "Fix media", nil))
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          locked = Social.lock_post(ctx.org.id, post.id)
          Repo.update!(Ecto.Changeset.change(locked, external_id: "concurrent-job"))
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:job_held, pid})

          receive do
            :release -> :ok
          after
            5000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:job_held, holder_pid}, 5000

    caller =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:job_caller, pid})

          Publishing.retry_publish(ctx.org.id, post.id, ctx.user.id,
            scheduled_at: DateTime.add(DateTime.utc_now(), 7200)
          )
        end)
      end)

    try do
      assert_receive {:job_caller, caller_pid}, 5000
      assert caller_pid != holder_pid
      blocked!(caller_pid, holder_pid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5000)
      assert {:error, :publish_job_changed} = Task.await(caller, 5000)
      assert Fake.calls(:publish) == []
      assert Fake.calls(:retry) == []
      assert %{status: "approved", external_id: "concurrent-job"} = Repo.get!(Post, post.id)
    after
      send(holder.pid, :release)
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  for {operation, change} <- [
        failed: :replace,
        failed: :remove,
        failed: :revoke,
        approved: :replace,
        approved: :remove
      ] do
    @retry_operation operation
    @retry_change change
    test "#{operation} same-job retry refuses #{change} after its lock wait", ctx do
      alias Platform.Social.{Clip, Publishing, Publisher.Fake}
      Fake.reset()
      {:ok, approved} = Social.approve_post(ctx.org.id, ctx.post, ctx.user.id)
      {:ok, profile} = Social.profile_of_post(approved)
      clip = Repo.insert!(%Clip{profile_id: profile.id, origin: "external"})
      status = if @retry_operation == :failed, do: "failed", else: "approved"

      post =
        Repo.update!(
          Ecto.Changeset.change(approved,
            clip_id: clip.id,
            status: status,
            external_id: "original-job",
            error: "Earlier refusal",
            refused_reason: "media_rejected"
          )
        )

      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            locked = Social.lock_post(ctx.org.id, post.id)

            case @retry_change do
              :replace ->
                Repo.update!(Ecto.Changeset.change(locked, external_id: "different-job"))

              :remove ->
                Repo.update!(Ecto.Changeset.change(locked, external_id: nil))

              :revoke ->
                Repo.update!(Ecto.Changeset.change(ctx.user, archived_at: DateTime.utc_now()))
            end

            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:same_job_held, pid})

            receive do
              :release -> :ok
            after
              5000 -> Repo.rollback(:holder_timeout)
            end
          end)
        end)

      assert_receive {:same_job_held, holder_pid}, 5000

      caller =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:same_job_caller, pid})

            case @retry_operation do
              :failed -> Social.retry_post(ctx.org.id, post.id, ctx.user.id)
              :approved -> Publishing.retry_publish(ctx.org.id, post.id, ctx.user.id)
            end
          end)
        end)

      try do
        assert_receive {:same_job_caller, caller_pid}, 5000
        assert caller_pid != holder_pid
        blocked!(caller_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5000)
        reason = if @retry_change == :revoke, do: :approver_archived, else: :publish_job_changed
        assert {:error, ^reason} = Task.await(caller, 5000)
        row = Repo.get!(Post, post.id)
        assert row.status == post.status
        assert row.approved_at == post.approved_at
        assert row.error == post.error
        assert Fake.calls(:publish) == []
        assert Fake.calls(:retry) == []
      after
        send(holder.pid, :release)
        Task.shutdown(holder, :brutal_kill)
        Task.shutdown(caller, :brutal_kill)
      end
    end
  end

  for operation <- [:approve, :agent_retime] do
    @operation operation
    test "#{operation} that starts before the deadline rechecks after its row-lock wait", ctx do
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(p in Post, where: p.id == ^ctx.post.id, lock: "FOR UPDATE"))
            deadline = DateTime.add(DateTime.utc_now(), 3)

            Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
              set: [scheduled_at: deadline]
            )

            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:held, pid, deadline})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:holder_timeout)
            end
          end)
        end)

      assert_receive {:held, holder_pid, deadline}, 5_000

      caller =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:caller, pid})

            case @operation do
              :approve ->
                Social.approve_post(ctx.org.id, ctx.post, ctx.user.id)

              :agent_retime ->
                AgentDrafts.update_agent_draft({:tenant, ctx.org.id}, ctx.post.id, %{
                  "scheduled_at" => DateTime.add(DateTime.utc_now(), 7200)
                })
            end
          end)
        end)

      try do
        assert_receive {:caller, caller_pid}, 5_000
        assert caller_pid != holder_pid
        blocked!(caller_pid, holder_pid)
        assert DateTime.compare(DateTime.utc_now(), deadline) == :lt
        await_deadline!(deadline, 500)
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5_000)
        expected = if @operation == :approve, do: :slot_passed, else: :human_retime_required
        assert {:error, ^expected} = Task.await(caller, 5_000)
        row = Repo.get!(Post, ctx.post.id)
        assert row.status == "needs_approval"
        assert row.approved_at == nil
        assert row.approved_by_user_id == nil
        assert DateTime.compare(row.scheduled_at, deadline) == :eq
      after
        send(holder.pid, :release)
        Task.shutdown(holder, :brutal_kill)
        Task.shutdown(caller, :brutal_kill)
      end
    end
  end

  for operation <- [:approve, :agent_edit] do
    @operation operation
    test "#{operation} cannot overwrite a concurrent completed approval", ctx do
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            locked = Repo.one!(from(p in Post, where: p.id == ^ctx.post.id, lock: "FOR UPDATE"))
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:status_held, pid})

            receive do
              :release -> locked |> Post.approval_changeset(ctx.user.id) |> Repo.update!()
            after
              5_000 -> Repo.rollback(:holder_timeout)
            end
          end)
        end)

      assert_receive {:status_held, holder_pid}, 5_000

      caller =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:status_caller, pid})

            case @operation do
              :approve ->
                Social.approve_post(ctx.org.id, ctx.post, ctx.user.id)

              :agent_edit ->
                AgentDrafts.update_agent_draft({:tenant, ctx.org.id}, ctx.post.id, %{
                  "body" => "Unseen edit"
                })
            end
          end)
        end)

      try do
        assert_receive {:status_caller, caller_pid}, 5_000
        assert caller_pid != holder_pid
        blocked!(caller_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, %Post{status: "approved"}} = Task.await(holder, 5_000)
        expected = if @operation == :approve, do: :not_approvable, else: :post_locked
        assert {:error, ^expected} = Task.await(caller, 5_000)
        assert %Post{status: "approved", body: "Race caption"} = Repo.get!(Post, ctx.post.id)
      after
        send(holder.pid, :release)
        Task.shutdown(holder, :brutal_kill)
        Task.shutdown(caller, :brutal_kill)
      end
    end
  end

  test "a replacement time expiring during the lock wait refuses before claim or time writes",
       ctx do
    alias Platform.Social.{ApprovalCard, Approvals, PostEvents}
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    card = Approvals.live_card(ctx.post.id)
    before_events = PostEvents.list_for_post(ctx.post.id)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(p in Post, where: p.id == ^ctx.post.id, lock: "FOR UPDATE"))
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:replacement_held, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:replacement_held, holder_pid}, 5_000
    at = DateTime.add(DateTime.utc_now(), 3)

    caller =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:replacement_caller, pid})

          Platform.SocialApprovalWriteProbe.capture(fn ->
            Approvals.decide_approve_at(
              card.canvas_id,
              ctx.user,
              Approvals.fingerprint(ctx.post),
              at
            )
          end)
        end)
      end)

    try do
      assert_receive {:replacement_caller, caller_pid}, 5_000
      assert caller_pid != holder_pid
      blocked!(caller_pid, holder_pid)
      assert DateTime.compare(DateTime.utc_now(), at) == :lt
      await_deadline!(at, 500)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {{:error, :slot_passed}, queries} = Task.await(caller, 5_000)
      assert queries == []
      assert Repo.get!(Post, ctx.post.id) == ctx.post
      assert Repo.get!(ApprovalCard, card.id) == card
      assert PostEvents.list_for_post(ctx.post.id) == before_events
      assert Fake.calls(:publish) == []
    after
      send(holder.pid, :release)
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  test "a deadline crossing after the pre-claim check rolls attempted writes back", ctx do
    alias Platform.Social.{ApprovalCard, Approvals, PostEvents}
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    card = Approvals.live_card(ctx.post.id)
    before_events = PostEvents.list_for_post(ctx.post.id)
    parent = self()
    at = DateTime.add(DateTime.utc_now(), 3)

    caller =
      Task.async(fn ->
        handler = {__MODULE__, make_ref()}

        :ok =
          :telemetry.attach(
            handler,
            [:platform, :repo, :query],
            &__MODULE__.pause_claim/4,
            {parent, self()}
          )

        try do
          Platform.SocialApprovalWriteProbe.capture(fn ->
            Approvals.decide_approve_at(
              card.canvas_id,
              ctx.user,
              Approvals.fingerprint(ctx.post),
              at
            )
          end)
        after
          :telemetry.detach(handler)
        end
      end)

    try do
      assert_receive {:claimed, pid}, 5_000
      assert pid == caller.pid
      assert DateTime.compare(DateTime.utc_now(), at) == :lt
      await_deadline!(at, 500)
      send(caller.pid, :continue_claim)
      assert {{:error, :slot_passed}, queries} = Task.await(caller, 5_000)
      assert Enum.any?(queries, &String.starts_with?(&1, ~s(UPDATE "social_approval_cards")))
      assert Enum.any?(queries, &String.starts_with?(&1, ~s(UPDATE "social_posts")))
      assert Repo.get!(Post, ctx.post.id) == ctx.post
      assert Repo.get!(ApprovalCard, card.id) == card
      assert PostEvents.list_for_post(ctx.post.id) == before_events
      assert Fake.calls(:publish) == []
    after
      send(caller.pid, :continue_claim)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  def pause_claim(_event, _measurements, %{query: query}, {parent, caller}) do
    if self() == caller and String.starts_with?(query, ~s(UPDATE "social_approval_cards")) do
      send(parent, {:claimed, self()})

      receive do
        :continue_claim -> :ok
      after
        8_000 -> raise "claim probe was not released"
      end
    end
  end

  defp blocked!(pid, holder, attempts \\ 200)
  defp blocked!(_pid, _holder, 0), do: flunk("caller never waited on its own holder")

  defp blocked!(pid, holder, attempts) do
    [[blockers]] = Repo.query!("SELECT pg_blocking_pids($1)", [pid]).rows

    if holder in blockers do
      :ok
    else
      Process.sleep(10)
      blocked!(pid, holder, attempts - 1)
    end
  end

  # Poll the actual deadline only after observing this caller blocked on this holder.
  defp await_deadline!(_at, 0), do: flunk("deadline did not pass within the bounded wait")

  defp await_deadline!(at, attempts) do
    if DateTime.compare(DateTime.utc_now(), at) == :lt do
      Process.sleep(10)
      await_deadline!(at, attempts - 1)
    else
      :ok
    end
  end
end
