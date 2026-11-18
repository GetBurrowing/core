defmodule Platform.Goals.UnansweredTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Ask, Clock, Entry, GoalClock, WakeUp}
  @now ~U[2026-02-04 07:00:00.000000Z]

  setup do
    enable_goals!()
    dispatch_previous = Application.fetch_env(:goals, :wake_up_dispatcher)
    previous = Application.fetch_env(:goals, :clock_now)
    Application.put_env(:goals, :clock_now, fn -> @now end)

    on_exit(fn ->
      case dispatch_previous do
        {:ok, value} -> Application.put_env(:goals, :wake_up_dispatcher, value)
        :error -> Application.delete_env(:goals, :wake_up_dispatcher)
      end

      case previous do
        {:ok, value} -> Application.put_env(:goals, :clock_now, value)
        :error -> Application.delete_env(:goals, :clock_now)
      end
    end)

    org = org_id!()
    owner = member!(org)

    goal =
      goal!(owner, org, %{
        coach_agent_id: agent!().id,
        rhythm: "daily",
        source_key: "self_reported",
        unit: "steps"
      })

    {:ok, _} = Goals.log_reading(owner, goal.id, %{value: "12", measured_at: @now})
    %{goal: goal, owner: owner}
  end

  defp clock(goal), do: Repo.one!(from(c in GoalClock, where: c.goal_id == ^goal.id))

  defp wakes(goal),
    do: Repo.all(from(w in WakeUp, where: w.goal_id == ^goal.id, order_by: w.due_at))

  test "deadline sweep writes one notebook entry and preserves the wake-up reading", c do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: c.owner.id,
        runtime_id: "unanswered-#{unique()}",
        display_name: "Unanswered test",
        status: "active"
      })

    Repo.get!(Platform.Agents.Agent, c.goal.coach_agent_id)
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()

    parent = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:dispatch, signal})
      :ok
    end)

    Clock.tick(@now)
    Clock.tick(clock(c.goal).next_wake_at)
    assert_received {:dispatch, _}

    [wake] = wakes(c.goal)
    Clock.tick(wake.respond_by)
    [unanswered] = wakes(c.goal)
    refute_received {:dispatch, _}
    assert unanswered.status == "unanswered"
    assert unanswered.delivery == wake.delivery
    entry = Repo.get!(Entry, unanswered.entry_id)
    assert entry.kind == "wake_up"
    assert entry.title == "Check-in not answered"
    assert is_binary(wake.reading_id)
    assert entry.reading_id == wake.reading_id
    assert entry.details == %{"wake_up_id" => wake.id, "status" => "unanswered"}
    Clock.tick(wake.respond_by)
    assert Repo.aggregate(from(e in Entry, where: e.goal_id == ^c.goal.id), :count) == 1
  end

  test "three unanswered check-ins stall and restart clears the stall", c do
    Clock.tick(@now)

    for _ <- 1..3 do
      Clock.tick(clock(c.goal).next_wake_at)
      latest = List.last(wakes(c.goal))
      Clock.tick(latest.respond_by)
    end

    assert length(wakes(c.goal)) == 3
    assert Enum.all?(wakes(c.goal), &(&1.status == "unanswered"))
    assert clock(c.goal).stalled_at
    next = clock(c.goal).next_wake_at
    Clock.tick(next)
    assert length(wakes(c.goal)) == 3
    Application.put_env(:goals, :clock_now, fn -> next end)
    assert {:ok, _} = Goals.restart_clock(c.owner, c.goal.id)
    refute clock(c.goal).stalled_at
    assert DateTime.compare(clock(c.goal).next_wake_at, next) == :gt
  end

  test "an expired ask stops being open at its exact deadline", c do
    ask =
      %Ask{goal_id: c.goal.id}
      |> Ask.changeset(%{kind: "question", title: "Still useful?", expires_at: @now})
      |> Repo.insert!()

    Clock.tick(@now)
    expired = Repo.get!(Ask, ask.id)
    assert expired.status == "expired"
    assert expired.closed_at == @now
  end
end
