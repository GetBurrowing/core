defmodule Platform.Goals.RetroCloseTest do
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures

  alias Platform.Goals
  alias Platform.Goals.{Clock, Entry, Tools, WakeUp}

  setup do: setup_outcome()

  defp call(tool, args, agent), do: Tools.execute(tool, args, %{agent_id: agent.id})

  defp retro_args(wake, extra \\ %{}),
    do:
      Map.merge(
        %{"wake_up_id" => wake.id, "title" => "Looking back", "summary" => "What happened"},
        extra
      )

  defp open_retro(c) do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
    check_in = fire(c.goal)
    {:ok, _} = Goals.close_wake_up(c.coach, check_in.id, "wait", %{reason: "Wait"})
    retro = fire(c.goal)
    assert retro.kind == "retro"
    retro
  end

  defp counts, do: {Repo.aggregate(Entry, :count), Repo.aggregate(WakeUp, :count)}

  test "tool closes once with the module's frozen verdicts, ignoring supplied verdicts", c do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 0, measured_at: Clock.now()})
    first = fire(c.goal)
    deadline = Date.add(DateTime.to_date(Clock.now()), 4)

    {:ok, a} =
      Goals.close_wake_up(
        c.coach,
        first.id,
        "do",
        prediction(%{predicted_change: 40, predicted_by: deadline})
      )

    early = fire(c.goal)

    {:ok, _} =
      Goals.close_retro(c.coach, early.id, %{title: "Early", summary: "Wait for the deadline"})

    second = fire(c.goal)

    {:ok, b} =
      Goals.close_wake_up(
        c.coach,
        second.id,
        "do",
        prediction(%{predicted_change: 100, predicted_by: deadline})
      )

    early = fire(c.goal)

    {:ok, _} =
      Goals.close_retro(c.coach, early.id, %{
        title: "Still early",
        summary: "Wait for the deadline"
      })

    check_in = fire(c.goal)
    {:ok, _} = Goals.close_wake_up(c.coach, check_in.id, "wait", %{reason: "Let it finish"})
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 55, measured_at: Clock.now()})
    retro = fire(c.goal)
    expected = retro.briefing["retro"]["predictions"]
    assert Enum.map(expected, & &1["entry_id"]) == [a.entry.id, b.entry.id]
    assert Enum.map(expected, & &1["verdict"]) == ["came_true", "did_not"]
    assert Enum.map(expected, & &1["actual_change"]) == ["55", "55"]
    before = Repo.aggregate(Entry, :count)

    assert {:ok, result} =
             call(
               "goal_retro",
               retro_args(retro, %{"verdicts" => [%{"verdict" => "invented"}], "stalled" => true}),
               c.coach
             )

    assert result.wake_up.outcome == "retro" and result.wake_up.status == "closed"
    assert result.entry.kind == "retro"
    assert result.entry.details["verdicts"] == expected
    assert result.entry.details["wake_up_id"] == retro.id
    assert result.entry.details["stalled"] == retro.briefing["retro"]["goal_change_required"]
    assert Repo.aggregate(Entry, :count) == before + 1

    assert {:error, %{code: :wake_up_closed, recoverable: false}} =
             call("goal_retro", retro_args(retro), c.coach)

    assert Repo.aggregate(Entry, :count) == before + 1
  end

  test "kind guards and allowed outcomes agree for each kind", c do
    retro = open_retro(c)

    assert {:ok, %{wake_up: %{kind: "retro"}, allowed: allowed}} =
             call("goal_wake_up_get", %{"wake_up_id" => retro.id}, c.coach)

    assert allowed["retro"] == true
    for key <- ~w(do do_with_task ask wait), do: assert(allowed[key] == :retro_wake_up)
    before = counts()

    assert {:error, %{code: :retro_wake_up, recoverable: true}} =
             call("goal_do", %{"wake_up_id" => retro.id}, c.coach)

    assert counts() == before
    {:ok, _} = Goals.close_retro(c.coach, retro.id, %{title: "Review", summary: "Done"})
    check_in = fire(c.goal)

    assert {:ok, %{allowed: %{"retro" => :not_a_retro}}} =
             call("goal_wake_up_get", %{"wake_up_id" => check_in.id}, c.coach)

    assert {:error, %{code: :not_a_retro, recoverable: true}} =
             call("goal_retro", retro_args(check_in), c.coach)

    assert {:ok, %{goals: [row]}} = call("goal_list", %{}, c.coach)
    assert row.open_wake_up_kind == "check_in"
  end

  test "invalid shapes leave the retro open and write nothing", c do
    retro = open_retro(c)
    other = goal!(c.owner, c.org, %{coach_agent_id: c.coach.id})
    {:ok, foreign} = Goals.add_entry(c.coach, other.id, %{kind: "action", title: "Other goal"})

    for {extra, code} <- [
          {%{"dropped" => [%{"entry_id" => foreign.id}]}, :invalid},
          {%{"learned" => List.duplicate("A lesson", 11)}, :invalid},
          {%{"summary" => " "}, :summary_required},
          {%{
             "check_in_change" => %{"summary" => "Less often", "set" => %{"rhythm" => "weekly"}},
             "goal_change" => %{
               "summary" => "End",
               "kind" => "end",
               "set" => %{"status" => "finished"}
             }
           }, :one_change_only}
        ] do
      before = counts()

      assert {:error, %{code: ^code, recoverable: true}} =
               call("goal_retro", retro_args(retro, extra), c.coach)

      assert counts() == before
      assert Repo.one!(from(w in WakeUp, where: w.id == ^retro.id)).status == "open"
    end
  end

  test "only the coach may close; tools hide a visible goal from a non-coach", c do
    retro = open_retro(c)
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})
    viewer = agent!()
    join_space!(space.id, :agent, viewer.id)
    assert {:ok, _} = Goals.get_goal(viewer, c.goal.id)

    assert {:error, :forbidden} =
             Goals.close_retro(c.owner, retro.id, %{title: "Review", summary: "Done"})

    assert {:error, :forbidden} =
             Goals.close_retro(viewer, retro.id, %{title: "Review", summary: "Done"})

    before = counts()

    for actor <- [viewer, agent!()] do
      assert {:error, real} = call("goal_retro", retro_args(retro), actor)
      assert {:error, random} = call("goal_retro", retro_args(%{id: Ecto.UUID.generate()}), actor)
      assert real == random
      assert real.code == :not_found and not real.recoverable
    end

    assert counts() == before
  end
end
