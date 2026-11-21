defmodule Platform.Social.IdeaVoteConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social.{Idea, IdeaVote, IdeaVotes, Profile}
  alias Platform.Agents.Agent

  setup do
    Sandbox.mode(Repo, :auto)
    ids = Map.new(~w(org profile idea creator voter user account)a, &{&1, Ecto.UUID.generate()})

    on_exit(fn ->
      steps = [
        fn -> Repo.delete_all(from(v in IdeaVote, where: v.idea_id == ^ids.idea)) end,
        fn ->
          Repo.delete_all(from(p in Platform.Social.Post, where: p.account_id == ^ids.account))
        end,
        fn ->
          Repo.delete_all(from(a in Platform.Social.Account, where: a.id == ^ids.account))
        end,
        fn -> Repo.delete_all(from(i in Idea, where: i.id == ^ids.idea)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^ids.profile)) end,
        fn ->
          Repo.delete_all(
            from(m in Platform.Tenancy.OrgMembership,
              where: m.user_id == ^ids.user and m.org_id == ^ids.org
            )
          )
        end,
        fn -> Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^ids.user)) end,
        fn -> Repo.delete_all(from(a in Agent, where: a.id in ^[ids.creator, ids.voter])) end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^ids.org)) end
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

    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))

    Repo.insert!(%Platform.Tenancy.Org{
      id: ids.org,
      name: "Vote concurrency",
      slug: "votes-#{ids.org}",
      parent_org_id: root.id
    })

    Repo.insert!(%Profile{id: ids.profile, org_id: ids.org, name: "Vote concurrency"})

    Repo.insert!(%Platform.Social.Account{
      id: ids.account,
      profile_id: ids.profile,
      platform: "x",
      status: "connected"
    })

    for id <- [ids.creator, ids.voter],
        do:
          Repo.insert!(%Agent{
            id: id,
            slug: "votes-#{id}",
            name: "Vote agent",
            metadata: %{"org_id" => ids.org}
          })

    Repo.insert!(%Platform.Accounts.User{
      id: ids.user,
      name: "Vote reader",
      email: "#{ids.user}@example.com",
      oidc_sub: ids.user
    })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: ids.user,
      org_id: ids.org,
      role: "member"
    })

    Repo.insert!(%Idea{
      id: ids.idea,
      org_id: ids.org,
      profile_id: ids.profile,
      title: "Concurrent votes",
      source_kind: "agent",
      created_by_agent_id: ids.creator
    })

    ids
  end

  for kind <- [:agent] do
    @kind kind
    test "two real connections keep one #{@kind} vote", ctx do
      actor = {@kind, if(@kind == :agent, do: ctx.voter, else: ctx.user)}
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(i in Idea, where: i.id == ^ctx.idea, lock: "FOR UPDATE"))
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:held, pid})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:held, holder_pid}, 5_000

      worker = fn ->
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:worker, pid})
            IdeaVotes.vote(ctx.org, ctx.idea, actor)
          end)
        end)
      end

      a = worker.()
      b = worker.()
      assert_receive {:worker, a_pid}, 5_000
      assert_receive {:worker, b_pid}, 5_000
      assert a_pid != b_pid
      assert_blocked!(a_pid, holder_pid)
      assert_blocked!(b_pid, holder_pid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:ok, %{vote_count: 1, voted: true}} = Task.await(a, 10_000)
      assert {:ok, %{vote_count: 1, voted: true}} = Task.await(b, 10_000)
      assert Repo.aggregate(from(v in IdeaVote, where: v.idea_id == ^ctx.idea), :count) == 1
    end
  end

  test "two real connections refuse human vote and withdrawal while retaining history", ctx do
    old =
      Repo.insert!(%IdeaVote{
        idea_id: ctx.idea,
        org_id: ctx.org,
        profile_id: ctx.profile,
        voter_user_id: ctx.user
      })

    parent = self()

    workers =
      for operation <- [:vote, :unvote] do
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:human_worker, self(), pid})

            receive do
              :go -> apply(IdeaVotes, operation, [ctx.org, ctx.idea, {:user, ctx.user}])
            after
              5_000 -> flunk("human worker was not released")
            end
          end)
        end)
      end

    assert_receive {:human_worker, a, a_pid}, 5_000
    assert_receive {:human_worker, b, b_pid}, 5_000
    assert a_pid != b_pid
    send(a, :go)
    send(b, :go)
    for worker <- workers, do: assert({:error, :agent_only} = Task.await(worker, 5_000))
    assert Repo.all(from(v in IdeaVote, where: v.idea_id == ^ctx.idea)) == [old]
  end

  test "actor revoked while waiting for the profile lock cannot vote", ctx do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(p in Profile, where: p.id == ^ctx.profile, lock: "FOR UPDATE"))
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:held, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end

          Repo.update_all(from(a in Agent, where: a.id == ^ctx.voter), set: [status: "archived"])
        end)
      end)

    assert_receive {:held, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})
          IdeaVotes.vote(ctx.org, ctx.idea, {:agent, ctx.voter})
        end)
      end)

    assert_receive {:worker, pid}, 5_000
    assert_blocked!(pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:error, :not_found} = Task.await(worker, 10_000)
    assert Repo.aggregate(from(v in IdeaVote, where: v.idea_id == ^ctx.idea), :count) == 0
  end

  for writer <- [:agent, :composer] do
    @writer writer
    test "#{@writer} draft waits for archive and then refuses the archived idea", ctx do
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = IdeaVotes.archive(ctx.org, ctx.idea, {:agent, ctx.creator})
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:archived, pid})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:archived, holder_pid}, 5_000

      worker =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:writer, pid})
            draft(ctx, @writer)
          end)
        end)

      assert_receive {:writer, pid}, 5_000
      assert_blocked!(pid, holder_pid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:error, :idea_archived} = Task.await(worker, 10_000)

      assert Repo.aggregate(
               from(p in Platform.Social.Post, where: p.idea_id == ^ctx.idea),
               :count
             ) == 0
    end

    test "#{@writer} draft committed first makes agent archive refuse", ctx do
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = draft(ctx, @writer)
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:drafted, pid})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:drafted, holder_pid}, 5_000

      worker =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:archiver, pid})
            IdeaVotes.archive(ctx.org, ctx.idea, {:agent, ctx.creator})
          end)
        end)

      assert_receive {:archiver, pid}, 5_000
      assert_blocked!(pid, holder_pid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:error, :idea_has_posts} = Task.await(worker, 10_000)

      assert Repo.aggregate(
               from(p in Platform.Social.Post, where: p.idea_id == ^ctx.idea),
               :count
             ) == 1

      assert is_nil(Repo.get!(Idea, ctx.idea).archived_at)
    end
  end

  defp draft(ctx, :agent) do
    Platform.Social.AgentDrafts.create_agent_drafts(
      ctx.org,
      ctx.profile,
      %{
        "account_ids" => [ctx.account],
        "idea_id" => ctx.idea,
        "status" => "draft",
        "body" => "Concurrent draft"
      },
      agent_id: ctx.creator
    )
  end

  defp draft(ctx, :composer),
    do:
      Platform.Social.create_post(
        ctx.org,
        ctx.account,
        %{status: "draft", body: "Concurrent draft"},
        idea_id: ctx.idea
      )

  defp assert_blocked!(pid, holder, attempts \\ 200)
  defp assert_blocked!(_pid, _holder, 0), do: flunk("worker never blocked on this holder")

  defp assert_blocked!(pid, holder, attempts) do
    [[blockers]] =
      Repo.query!(
        """
        WITH RECURSIVE blockers(pid) AS (
          SELECT unnest(pg_blocking_pids($1))
          UNION
          SELECT unnest(pg_blocking_pids(pid)) FROM blockers
        ) SELECT coalesce(array_agg(pid), '{}') FROM blockers
        """,
        [pid]
      ).rows

    if holder in blockers,
      do: :ok,
      else:
        (
          Process.sleep(10)
          assert_blocked!(pid, holder, attempts - 1)
        )
  end
end
