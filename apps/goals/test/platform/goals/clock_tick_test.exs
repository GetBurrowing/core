defmodule Platform.Goals.ClockTickTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, GoalClock, WakeUp}

  @now ~U[2026-02-04 07:00:00.000000Z]
  setup do
    enable_goals!()
    keys = [:clock_now, :wake_up_dispatcher, :default_time_zone]
    old = Map.new(keys, &{&1, Application.fetch_env(:goals, &1)})
    Application.put_env(:goals, :clock_now, fn -> @now end)
    Application.put_env(:goals, :default_time_zone, "Etc/UTC")
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> :ok end)

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, v} -> Application.put_env(:goals, key, v)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    owner = member!(org)
    coach = agent!()
    goal = goal!(owner, org, %{coach_agent_id: coach.id, rhythm: "daily"})
    %{goal: goal, owner: owner, coach: coach, org: org}
  end

  defp clock(goal), do: Repo.one!(from(c in GoalClock, where: c.goal_id == ^goal.id))
  defp wakes(goal), do: Repo.all(from(w in WakeUp, where: w.goal_id == ^goal.id))

  test "initialises without firing, then fires only at the exact slot once", c do
    assert :ok = Clock.tick(@now)
    scheduled = clock(c.goal)
    assert scheduled.next_wake_at == ~U[2026-02-05 06:00:00.000000Z]
    assert wakes(c.goal) == []
    assert :ok = Clock.tick(DateTime.add(scheduled.next_wake_at, -60))
    assert wakes(c.goal) == []
    assert :ok = Clock.tick(scheduled.next_wake_at)
    assert [wake] = wakes(c.goal)
    assert wake.due_at == scheduled.next_wake_at
    assert wake.respond_by == DateTime.add(wake.fired_at, 12 * 3600)
    refute wake.catch_up
    assert :ok = Clock.tick(scheduled.next_wake_at)
    assert length(wakes(c.goal)) == 1
  end

  test "ten days offline produce one catch-up with the next slot in the future", c do
    Clock.tick(@now)
    slot = clock(c.goal).next_wake_at
    late = DateTime.add(slot, 10 * 86400)
    Clock.tick(late)
    assert [%{catch_up: true, due_at: ^slot}] = wakes(c.goal)
    assert DateTime.compare(clock(c.goal).next_wake_at, late) == :gt
  end

  test "paused, finished and uncoached goals have no clock", c do
    for attrs <- [%{status: "paused"}, %{status: "finished"}, %{coach_agent_id: nil}] do
      goal = goal!(c.owner, c.org, Map.merge(%{coach_agent_id: c.coach.id}, attrs))
      Clock.tick(@now)
      refute Repo.exists?(from(cl in GoalClock, where: cl.goal_id == ^goal.id))
      assert wakes(goal) == []
    end
  end

  test "disabled tick performs no query and telemetry has a positive control", _c do
    parent = self()
    handler = "goals-clock-query-#{unique()}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _, _, _, _ -> send(parent, :repo_query) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    Application.put_env(:goals, :enabled, false)
    assert :ok = Clock.tick(@now)
    refute_receive :repo_query, 0
    Application.put_env(:goals, :enabled, true)
    Clock.tick(@now)
    assert_received :repo_query
  end

  test "resume and schedule changes reanchor but a title edit preserves the anchor", c do
    Clock.tick(@now)
    original = clock(c.goal)
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{title: "A new title"})
    assert clock(c.goal).next_wake_at == original.next_wake_at
    assert clock(c.goal).anchor_on == original.anchor_on
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{status: "paused"})
    resumed_at = DateTime.add(@now, 10 * 86400)
    Application.put_env(:goals, :clock_now, fn -> resumed_at end)
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{status: "active"})
    Clock.tick(resumed_at)
    assert wakes(c.goal) == []
    assert DateTime.compare(clock(c.goal).next_wake_at, resumed_at) == :gt
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{rhythm: "weekly", rhythm_weekday: 3})
    weekly = clock(c.goal).next_wake_at
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{rhythm: "daily"})
    assert clock(c.goal).next_wake_at == ~U[2026-02-15 06:00:00.000000Z]
    refute clock(c.goal).next_wake_at == weekly
  end

  test "compare-and-swap rejects the same observed slot twice", c do
    Clock.tick(@now)
    seen = clock(c.goal)
    assert {:ok, _} = Clock.claim(c.coach, c.goal, seen, seen.next_wake_at)
    assert :already_claimed = Clock.claim(c.coach, c.goal, seen, seen.next_wake_at)
    assert length(wakes(c.goal)) == 1
    advanced = clock(c.goal)
    assert :already_claimed = Clock.claim(c.coach, c.goal, advanced, seen.next_wake_at)
    assert length(wakes(c.goal)) == 1
  end

  test "two concurrent ticks sharing the sandbox produce one wake-up", c do
    Clock.tick(@now)
    slot = clock(c.goal).next_wake_at
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          Clock.tick(slot)
        end)
      end

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    assert length(wakes(c.goal)) == 1
  end

  test "personal wake-up access is hidden from outsiders and briefing from viewers", c do
    Clock.tick(@now)
    Clock.tick(clock(c.goal).next_wake_at)
    [wake] = wakes(c.goal)

    for actor <- [member!(c.org), root_admin!(), agent!()] do
      for id <- [c.goal.id, Ecto.UUID.generate()] do
        assert Goals.list_wake_ups(actor, id) == {:error, :not_found}
        assert Goals.clock_status(actor, id) == {:error, :not_found}
        assert Goals.restart_clock(actor, id) == {:error, :not_found}
      end

      assert Goals.get_wake_up(actor, wake.id) == {:error, :not_found}
      assert Goals.get_wake_up(actor, Ecto.UUID.generate()) == {:error, :not_found}
    end

    assert Goals.get_wake_up(c.owner, "not-a-uuid") == {:error, :not_found}
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})
    assert {:ok, [listed]} = Goals.list_wake_ups(viewer, c.goal.id)
    assert Map.get(listed, :briefing) in [nil, %{}]
    assert Goals.get_wake_up(viewer, wake.id) == {:error, :forbidden}
    assert Goals.restart_clock(viewer, c.goal.id) == {:error, :forbidden}
    assert {:ok, %{wake_up: _, briefing: _, text: text}} = Goals.get_wake_up(c.coach, wake.id)
    assert is_binary(text)
  end
end
