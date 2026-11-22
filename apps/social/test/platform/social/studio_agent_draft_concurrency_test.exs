defmodule Platform.Social.StudioAgentDraftConcurrencyTest do
  @moduledoc """
  Two real database connections (the sandbox is switched to `:auto`, as in
  `StudioProfileLockConcurrencyTest`) for `Studio.create_agent_draft/4`.

  The guards under test, each shown to matter by removing it:

    * the unique index on `social_agent_draft_requests (agent, account,
      request id)`: duplicate request ids, concurrently, make ONE draft;
    * the profile and account `FOR SHARE` locks plus the decisions made again
      on the locked rows (Studio on, account live, project, the agent and its
      home org), for a first call and for a retry.

  Waiting is observed, not slept: `blocked_by?/1` polls `pg_blocking_pids` for
  a backend blocked by THIS test's holder connection. The only fixed wait is
  the negative claim in the free race. The world is committed, and removed by
  hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDraftRequest, Account, Post, Profile, Studio}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{name: "Draft root #{n}", slug: "draft-root-#{n}"}),
           true}

        root ->
          {root, false}
      end

    org = tenant!(root, "Draft race #{n}", "draft-race-#{n}")
    other_org = tenant!(root, "Draft other #{n}", "draft-other-#{n}")

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "draft-race-#{n}@example.com",
        oidc_sub: "draft-race-#{n}",
        name: "Draft Race #{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org.id,
      role: "member"
    })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Draft race #{n}", org_id: org.id})

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "draft-race-agent-#{n}",
        name: "Draft Race Agent #{n}",
        metadata: %{"org_id" => org.id}
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      steps = [
        fn -> Repo.delete_all(from(r in AgentDraftRequest, where: r.agent_id == ^agent.id)) end,
        fn ->
          Repo.delete_all(
            from(po in Post,
              join: a in Account,
              on: a.id == po.account_id,
              where: a.profile_id in ^profile_ids
            )
            |> select([po], po)
          )
        end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids)) end,
        fn -> Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id)) end,
        fn -> Repo.delete_all(from(p in Platform.Tasks.Project, where: p.org_id == ^org.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn -> Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user.id)) end,
        fn ->
          Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id in ^[org.id, other_org.id]))
        end,
        fn ->
          if own_root?,
            do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
        end
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
      if errors != [], do: raise(hd(errors))
    end)

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Draft show #{n}",
        project_id: project.id,
        home_url: "https://www.youtube.com/@raceshow",
        approver_user_ids: [user.id]
      })

    {:ok, account} =
      Social.create_account(org.id, profile, %{platform: "x", handle: "@draft#{n}"})

    {:ok, profile} = Studio.set_enabled(org.id, profile.id, user.id, true)

    %{
      org: org,
      other_org: other_org,
      user: user,
      project: project,
      agent: agent,
      profile: profile,
      account: account,
      scope: {:tenant, org.id}
    }
  end

  defp tenant!(root, name, slug),
    do: Repo.insert!(%Platform.Tenancy.Org{name: name, slug: slug, parent_org_id: root.id})

  defp draft(ctx, attrs \\ %{}) do
    Studio.create_agent_draft(
      ctx.scope,
      ctx.account.id,
      ctx.agent.id,
      Map.merge(%{"request_id" => "req-1", "body" => "Race copy"}, attrs)
    )
  end

  defp studio_posts(ctx),
    do:
      Repo.aggregate(
        from(po in Post,
          join: a in Account,
          on: a.id == po.account_id,
          where: a.profile_id == ^ctx.profile.id and po.flow == "studio"
        ),
        :count
      )

  defp requests(ctx),
    do: Repo.aggregate(from(r in AgentDraftRequest, where: r.agent_id == ^ctx.agent.id), :count)

  defp created_events(ctx),
    do:
      Repo.aggregate(
        from(e in Platform.Social.PostEvent,
          join: po in Post,
          on: po.id == e.post_id,
          join: a in Account,
          on: a.id == po.account_id,
          where: a.profile_id == ^ctx.profile.id and e.action == "created"
        ),
        :count
      )

  # A process that runs `work` in an open transaction, tells the test its
  # backend pid, and holds the transaction until told to `:release`.
  defp holder(work, after_release \\ fn -> :ok end) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        %{rows: [[pid]]} = Repo.query!("select pg_backend_pid()")
        result = work.()
        send(parent, {:held, pid, result})

        receive do
          :release -> after_release.()
        after
          10_000 -> Repo.rollback(:timeout)
        end

        result
      end)
    end)
  end

  defp held! do
    assert_receive {:held, pid, result}, 5_000
    {pid, result}
  end

  # Observes (never sleeps for) a backend blocked by `holder_pid`.
  defp blocked_by?(holder_pid, tries \\ 100) do
    %{rows: [[n]]} =
      Repo.query!(
        "select count(*) from pg_stat_activity where $1 = ANY(pg_blocking_pids(pid))",
        [holder_pid]
      )

    cond do
      n > 0 -> true
      tries == 0 -> false
      true -> Process.sleep(50) && blocked_by?(holder_pid, tries - 1)
    end
  end

  defp release(holder) do
    send(holder.pid, :release)
    Task.await(holder, 10_000)
  end

  describe "duplicate request ids (the unique index)" do
    test "lost-race replay waits for a concurrent discard and sees the committed marker", ctx do
      parent = self()

      loser =
        Task.async(fn ->
          me = self()
          handler = {__MODULE__, make_ref()}
          Process.put(:pause_first_request_lookup, true)

          :ok =
            :telemetry.attach(
              handler,
              [:platform, :repo, :query],
              fn _, _, %{query: query}, _ ->
                if self() == me and String.starts_with?(query, "INSERT") and
                     String.contains?(query, "social_agent_draft_requests") do
                  send(parent, {:loser_request_insert_attempted, self()})
                end

                if self() == me and Process.get(:pause_first_request_lookup) and
                     String.starts_with?(query, "SELECT") and
                     String.contains?(query, "social_agent_draft_requests") do
                  Process.put(:pause_first_request_lookup, false)
                  send(parent, {:first_lookup_complete, self()})

                  receive do
                    :continue_after_lookup -> :ok
                  after
                    10_000 -> raise "lookup barrier timed out"
                  end
                end
              end,
              nil
            )

          try do
            draft(ctx)
          after
            :telemetry.detach(handler)
          end
        end)

      try do
        assert_receive {:first_lookup_complete, loser_pid}, 5_000
        assert loser_pid == loser.pid
        # The loser has already read an absent request. Commit the winning
        # request, then hold a discard on its post while the loser resumes.
        {:ok, post, :created} = draft(ctx)

        discarder =
          holder(fn ->
            Studio.discard_draft(ctx.org.id, post.id, ctx.user.id, %{
              state_rev: post.state_rev,
              version: post.version
            })
          end)

        Process.put(:discard_holder, discarder)
        {discarder_pid, {:ok, discarded}} = held!()
        send(loser.pid, :continue_after_lookup)
        assert_receive {:loser_request_insert_attempted, loser_pid}, 5_000
        assert loser_pid == loser.pid

        assert blocked_by?(discarder_pid),
               "lost-race replay must wait for the discarder post lock"

        assert {:ok, _} = release(discarder)
        assert {:error, :post_discarded} = Task.await(loser, 10_000)
        assert Repo.get!(Post, post.id).state_rev == discarded.state_rev
        assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {1, 1, 1}
      after
        send(loser.pid, :continue_after_lookup)
        Task.shutdown(loser, :brutal_kill)

        if task = Process.delete(:discard_holder) do
          send(task.pid, :release)
          Task.shutdown(task, :brutal_kill)
        end
      end
    end

    test "a create replay holds the post share lock until its transaction ends", ctx do
      {:ok, post, :created} = draft(ctx)
      replay = holder(fn -> draft(ctx) end)
      {replay_pid, {:ok, replayed, :replayed}} = held!()
      assert replayed.id == post.id

      discard =
        Task.async(fn ->
          Studio.discard_draft(ctx.org.id, post.id, ctx.user.id, %{
            state_rev: post.state_rev,
            version: post.version
          })
        end)

      assert blocked_by?(replay_pid), "discard must wait until the replay releases the post"
      assert {:ok, _} = release(replay)
      assert {:ok, discarded} = Task.await(discard, 10_000)
      assert discarded.discarded_at != nil
    end

    test "a create loser refuses a winner discarded before its transaction commits", ctx do
      winner =
        holder(fn ->
          {:ok, post, :created} = draft(ctx)

          {:ok, discarded} =
            Studio.discard_draft(ctx.org.id, post.id, ctx.user.id, %{
              state_rev: post.state_rev,
              version: post.version
            })

          discarded
        end)

      {winner_pid, discarded} = held!()
      loser = Task.async(fn -> draft(ctx) end)

      assert blocked_by?(winner_pid),
             "the second request must wait for the winner's unique index entry"

      assert {:ok, _} = release(winner)
      assert {:error, :post_discarded} = Task.await(loser, 10_000)
      assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {1, 1, 1}
      assert Repo.get!(Post, discarded.id).discarded_at == discarded.discarded_at
    end

    test "a call that races a first call still in flight returns that one draft", ctx do
      winner = holder(fn -> draft(ctx) end)
      {winner_pid, {:ok, won, :created}} = held!()

      loser = Task.async(fn -> draft(ctx) end)

      assert blocked_by?(winner_pid),
             "the second insert must wait on the first's unique index entry"

      assert {:ok, _} = release(winner)
      assert {:ok, same, :replayed} = Task.await(loser, 10_000)
      assert same.id == won.id
      assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {1, 1, 1}
    end

    test "a different body under the same request id, in flight, is a conflict and writes nothing",
         ctx do
      winner = holder(fn -> draft(ctx) end)
      {winner_pid, {:ok, won, :created}} = held!()

      loser = Task.async(fn -> draft(ctx, %{"body" => "Another body"}) end)
      assert blocked_by?(winner_pid)

      assert {:ok, _} = release(winner)
      assert {:error, :request_id_conflict} = Task.await(loser, 10_000)
      assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {1, 1, 1}
      assert Repo.get!(Post, won.id).body == "Race copy"
    end

    test "free race, repeated: every round makes exactly one draft and both callers get it",
         ctx do
      for round <- 1..15 do
        parent = self()

        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> draft(ctx, %{"request_id" => "round-#{round}"})
              end
            end)
          end

        for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
        Enum.each(tasks, &send(&1.pid, :go))
        results = Enum.map(tasks, &Task.await(&1, 15_000))

        assert [{:ok, a, _}, {:ok, b, _}] = results
        assert a.id == b.id
        assert results |> Enum.map(&elem(&1, 2)) |> Enum.sort() == [:created, :replayed]
      end

      assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {15, 15, 15}
    end
  end

  # The caller passes its early checks, then waits on a lock a holder owns; the
  # holder changes ONE thing and commits; the caller must decide again.
  describe "authority is decided again under the lock" do
    defp profile_holder(ctx, change) do
      holder(
        fn -> Social.lock_profile(ctx.scope, ctx.profile, :update) || Repo.rollback(:gone) end,
        change
      )
    end

    defp account_holder(ctx, change) do
      holder(
        fn ->
          # Takes the account row lock by writing it, as `archive_account/2` does.
          Repo.one!(from(a in Account, where: a.id == ^ctx.account.id, lock: "FOR UPDATE"))
        end,
        change
      )
    end

    defp refused_after(ctx, holder_fun, change, expected, attrs) do
      h = holder_fun.(ctx, change)
      {pid, _} = held!()
      before = {studio_posts(ctx), requests(ctx), created_events(ctx)}

      caller = Task.async(fn -> draft(ctx, attrs) end)
      assert blocked_by?(pid), "the call must wait on the lock the holder owns"

      assert {:ok, _} = release(h)
      assert Task.await(caller, 10_000) == expected
      assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == before
    end

    defp switch_off(ctx) do
      fn ->
        Repo.update_all(from(p in Profile, where: p.id == ^ctx.profile.id),
          set: [studio_enabled: false]
        )
      end
    end

    defp archive_project(ctx) do
      fn ->
        Repo.update_all(from(p in Platform.Tasks.Project, where: p.id == ^ctx.project.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end
    end

    defp archive_account(ctx) do
      fn ->
        Repo.update_all(from(a in Account, where: a.id == ^ctx.account.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end
    end

    defp move_agent(ctx) do
      fn ->
        Repo.update_all(from(a in Platform.Agents.Agent, where: a.id == ^ctx.agent.id),
          set: [metadata: %{"org_id" => ctx.other_org.id}]
        )
      end
    end

    # {who holds the lock the caller waits on, the one change made, the answer}
    defp scenario(:studio_off, ctx),
      do: {&profile_holder/2, switch_off(ctx), {:error, :studio_disabled}}

    defp scenario(:project_archived, ctx),
      do: {&profile_holder/2, archive_project(ctx), {:error, :studio_needs_project}}

    defp scenario(:agent_moved, ctx),
      do: {&profile_holder/2, move_agent(ctx), {:error, :not_found}}

    defp scenario(:account_archived, ctx),
      do: {&account_holder/2, archive_account(ctx), {:error, :account_archived}}

    for name <- [:studio_off, :project_archived, :agent_moved, :account_archived] do
      test "first call: #{name} between the early checks and the lock refuses, writes nothing",
           ctx do
        {holder_fun, change, expected} = scenario(unquote(name), ctx)
        refused_after(ctx, holder_fun, change, expected, %{})
      end

      test "retry: #{name} after the first call refuses and reveals no draft", ctx do
        assert {:ok, first, :created} = draft(ctx)
        {holder_fun, change, expected} = scenario(unquote(name), ctx)
        refused_after(ctx, holder_fun, change, expected, %{})
        assert {studio_posts(ctx), requests(ctx), created_events(ctx)} == {1, 1, 1}
        assert Repo.get!(Post, first.id).status == "draft"
      end
    end
  end
end
