defmodule Platform.Social.IdeaSelectionConcurrencyTest do
  @moduledoc """
  Two real database connections (the sandbox is `:auto`, as in
  `IdeaVoteConcurrencyTest`) for `Ideas.select_for_research/3` and
  `unselect_for_research/3`. Each test takes the IDEA row `FOR UPDATE` on a
  holder connection, starts the writers, and observes through
  `pg_blocking_pids` that they wait on that holder; a writer that does not
  wait fails the test, so removing the idea lock turns every test red.
  The world is committed and removed by hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social.{Idea, IdeaSelectionEvent, Ideas, Profile}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])
    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Select race #{n}",
        slug: "select-race-#{n}",
        parent_org_id: root.id
      })

    users =
      for label <- ~w(one two) do
        user =
          Repo.insert!(%Platform.Accounts.User{
            name: "Select #{label}",
            email: "select-race-#{label}-#{n}@example.com",
            oidc_sub: "select-race-#{label}-#{n}"
          })

        Repo.insert!(%Platform.Tenancy.OrgMembership{
          org_id: org.id,
          user_id: user.id,
          role: "member"
        })

        user
      end

    {:ok, project} = Platform.Tasks.create_project(%{name: "Select race #{n}", org_id: org.id})

    {:ok, profile} =
      Platform.Social.create_profile(org.id, %{name: "Select race", project_id: project.id})

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "select-race-#{n}",
        name: "Select race",
        metadata: %{"org_id" => org.id}
      })

    {:ok, idea} = Ideas.create(org.id, profile.id, %{title: "Race me"}, {:agent, agent.id})
    [u1, u2] = users

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      steps = [
        fn -> Repo.delete_all(from(i in Idea, where: i.profile_id == ^profile.id)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^profile.id)) end,
        fn -> Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id)) end,
        fn -> Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn ->
          Repo.delete_all(
            from(u in Platform.Accounts.User, where: u.id in ^Enum.map(users, & &1.id))
          )
        end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end
      ]

      Enum.each(steps, fn step ->
        try do
          step.()
        rescue
          _ -> :ok
        end
      end)

      Sandbox.mode(Repo, :manual)
    end)

    %{org: org, profile: profile, idea: idea, u1: u1, u2: u2, agent: agent}
  end

  # A holder connection that holds the idea row (after running `before`), then waits.
  defp hold(ctx, before \\ fn -> :ok end) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(i in Idea, where: i.id == ^ctx.idea.id, lock: "FOR UPDATE"))
          before.()
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:held, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:held, pid}, 5_000
    {task, pid}
  end

  defp worker(tag, fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, tag, pid})
          fun.()
        end)
      end)

    assert_receive {:worker, ^tag, pid}, 5_000
    {task, pid}
  end

  defp release(holder),
    do:
      (
        send(elem(holder, 0).pid, :release)
        assert {:ok, :ok} = Task.await(elem(holder, 0), 10_000)
      )

  defp events(ctx),
    do:
      Repo.all(
        from(e in IdeaSelectionEvent,
          where: e.idea_id == ^ctx.idea.id,
          order_by: [asc: e.inserted_at, asc: e.id]
        )
      )

  defp fresh(ctx), do: Repo.get!(Idea, ctx.idea.id)

  test "two concurrent selects: the first committed selector stands, one event", ctx do
    {_, holder_pid} = holder = hold(ctx)

    {a, a_pid} =
      worker(:a, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id}) end)

    {b, b_pid} =
      worker(:b, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u2.id}) end)

    assert a_pid != b_pid
    assert_blocked!(a_pid, holder_pid)
    assert_blocked!(b_pid, holder_pid)
    release(holder)

    results = [Task.await(a, 10_000), Task.await(b, 10_000)]

    assert [:changed, :unchanged] =
             results |> Enum.map(fn {:ok, _, how} -> how end) |> Enum.sort()

    [winner_event] = events(ctx)
    assert winner_event.action == "selected"
    row = fresh(ctx)
    assert row.selected_by_user_id == winner_event.actor_id
    assert row.selected_by_user_id in [ctx.u1.id, ctx.u2.id]

    # the :unchanged answer carries the winner, not the loser
    for {:ok, idea, _} <- results, do: assert(idea.selected_by_user_id == winner_event.actor_id)
  end

  test "select against unselect: the events strictly alternate", ctx do
    {:ok, _, :changed} = Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id})
    {_, holder_pid} = holder = hold(ctx)

    {a, a_pid} =
      worker(:a, fn ->
        Ideas.unselect_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u2.id})
      end)

    {b, b_pid} =
      worker(:b, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id}) end)

    assert_blocked!(a_pid, holder_pid)
    assert_blocked!(b_pid, holder_pid)
    release(holder)
    Task.await(a, 10_000)
    Task.await(b, 10_000)

    actions = Enum.map(events(ctx), & &1.action)
    assert hd(actions) == "selected"
    assert actions == Enum.take(Stream.cycle(~w(selected unselected)), length(actions))

    last = List.last(actions)
    assert is_nil(fresh(ctx).selected_at) == (last == "unselected")
  end

  test "archive committed first: select refuses :idea_archived and writes nothing", ctx do
    {_, holder_pid} =
      holder = hold(ctx, fn -> {:ok, _} = Ideas.archive(ctx.org.id, ctx.idea.id) end)

    {w, pid} =
      worker(:w, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id}) end)

    assert_blocked!(pid, holder_pid)
    release(holder)

    assert {:error, :idea_archived} = Task.await(w, 10_000)
    assert events(ctx) == []
    assert is_nil(fresh(ctx).selected_at)
  end

  test "select committed first: archive keeps the selection fields and events", ctx do
    {_, holder_pid} =
      holder =
      hold(ctx, fn ->
        assert {:ok, _, :changed} =
                 Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id})
      end)

    {w, pid} = worker(:w, fn -> Ideas.archive(ctx.org.id, ctx.idea.id) end)
    assert_blocked!(pid, holder_pid)
    release(holder)

    assert {:ok, _} = Task.await(w, 10_000)
    row = fresh(ctx)
    assert row.archived_at
    assert row.selected_by_user_id == ctx.u1.id
    assert row.selected_at
    assert [%{action: "selected"}] = events(ctx)
  end

  test "authority revoked while waiting for the lock is decided again under it", ctx do
    {_, holder_pid} =
      holder =
      hold(ctx, fn ->
        Repo.update_all(from(u in Platform.Accounts.User, where: u.id == ^ctx.u1.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end)

    {w, pid} =
      worker(:w, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id}) end)

    assert_blocked!(pid, holder_pid)
    release(holder)

    assert {:error, :not_authorized} = Task.await(w, 10_000)
    assert events(ctx) == []
    assert is_nil(fresh(ctx).selected_at)
  end

  test "an idea moved to another profile while waiting is refused, not selected under the old profile",
       ctx do
    {:ok, other} =
      Platform.Social.create_profile(ctx.org.id, %{
        name: "Other brand",
        project_id: ctx.profile.project_id
      })

    {_, holder_pid} =
      holder =
      hold(ctx, fn ->
        Repo.update_all(from(i in Idea, where: i.id == ^ctx.idea.id), set: [profile_id: other.id])
      end)

    {w, pid} =
      worker(:w, fn -> Ideas.select_for_research(ctx.org.id, ctx.idea.id, {:user, ctx.u1.id}) end)

    assert_blocked!(pid, holder_pid)
    release(holder)

    assert {:error, :not_found} = Task.await(w, 10_000)
    assert is_nil(fresh(ctx).selected_at)
    assert events(ctx) == []
    Repo.delete_all(from(i in Idea, where: i.id == ^ctx.idea.id))
    Repo.delete_all(from(p in Profile, where: p.id == ^other.id))
  end

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

    if holder in blockers do
      :ok
    else
      Process.sleep(10)
      assert_blocked!(pid, holder, attempts - 1)
    end
  end
end
