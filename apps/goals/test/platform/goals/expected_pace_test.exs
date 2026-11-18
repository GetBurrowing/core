defmodule Platform.Goals.ExpectedPaceTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    goal = goal!(owner, org, %{source_key: "self_reported", unit: "steps"})
    %{owner: owner, org: org, goal: goal}
  end

  defp seed(c, start, target, value) do
    {:ok, _} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "Finish", target_value: target, due_on: ~D[2026-04-11]}
      ])

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: start, measured_at: ~U[2026-01-01 12:00:00Z]})

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: value, measured_at: ~U[2026-02-10 12:00:00Z]})
  end

  test "rising line hopes for 700 on day 40, with exact boundary", c do
    seed(c, 500, 1000, 700)
    assert {:ok, pace} = Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-02-10])
    assert Decimal.equal?(pace.hoped, 700) and pace.state == :on_track

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 699, measured_at: ~U[2026-02-10 13:00:00Z]})

    assert {:ok, %{state: :behind}} =
             Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-02-10])
  end

  test "falling line mirrors the boundary and clamps elapsed days", c do
    seed(c, 1000, 500, 800)
    assert {:ok, pace} = Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-02-10])
    assert Decimal.equal?(pace.hoped, 800) and pace.state == :on_track

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 801, measured_at: ~U[2026-02-10 13:00:00Z]})

    assert {:ok, %{state: :behind}} =
             Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-02-10])

    {:ok, early} = Goals.expected_pace(c.owner, c.goal.id, today: ~D[2025-12-01])
    {:ok, late} = Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-05-01])
    assert Decimal.equal?(early.hoped, 1000) and Decimal.equal?(late.hoped, 500)
  end

  test "missing target, due date, source or valid start interval yields nil", c do
    seed(c, 500, 1000, 700)

    for attrs <- [
          %{target_value: nil, due_on: ~D[2026-04-11]},
          %{target_value: 1000},
          %{target_value: 1000, due_on: ~D[2025-12-31]}
        ] do
      {:ok, _} = Goals.put_stops(c.owner, c.goal.id, [Map.put(attrs, :label, "Finish")])
      assert {:ok, nil} = Goals.expected_pace(c.owner, c.goal.id)
    end

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{source_key: nil})
    assert {:ok, nil} = Goals.expected_pace(c.owner, c.goal.id)
    assert {:error, :not_found} = Goals.expected_pace(member!(c.org), c.goal.id)
  end

  test "newest reached stop supplies the start instead of first reading", c do
    seed(c, 0, 1000, 700)

    {:ok, _} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "Reached", target_value: 500, reached_on: ~D[2026-01-01]},
        %{label: "Finish", target_value: 1000, due_on: ~D[2026-04-11]}
      ])

    assert {:ok, pace} = Goals.expected_pace(c.owner, c.goal.id, today: ~D[2026-02-10])
    assert Decimal.equal?(pace.hoped, 700)
  end
end
