defmodule Platform.Goals.FlatRuleTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock
  setup do: setup_outcome()

  defp next_retro(c) do
    wake = fire(c.goal)

    if wake.kind == "retro" do
      wake
    else
      assert {:ok, _} =
               Goals.close_wake_up(c.coach, wake.id, "wait", %{
                 reason: "Wait for the next reading"
               })

      next_retro(c)
    end
  end

  test "goal change is required at three flat retros, never at two", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
    c = %{c | goal: goal}
    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 10, measured_at: Clock.now()})

    for count <- 1..2 do
      retro = next_retro(c)
      assert retro.briefing["retro"]["flat_retros"] == count
      refute retro.briefing["retro"]["goal_change_required"]

      assert {:ok, _} =
               Goals.close_retro(c.coach, retro.id, %{
                 title: "Still learning",
                 summary: "No movement"
               })
    end

    retro = next_retro(c)
    assert retro.briefing["retro"]["flat_retros"] == 3
    attrs = %{title: "Change the goal", summary: "The number stayed flat"}
    assert {:error, :goal_change_required} = Goals.close_retro(c.coach, retro.id, attrs)
    check_in = %{"summary" => "Less often", "set" => %{"rhythm" => "weekly"}}

    assert {:error, :goal_change_only} =
             Goals.close_retro(c.coach, retro.id, Map.put(attrs, :check_in_change, check_in))

    change = %{
      "kind" => "target",
      "summary" => "A reachable target",
      "set" => %{"target_value" => 20}
    }

    assert {:ok, result} =
             Goals.close_retro(c.coach, retro.id, Map.put(attrs, :goal_change, change))

    assert result.entry.details["stalled"] == true
    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 11, measured_at: Clock.now()})
    moved = next_retro(c)
    assert moved.briefing["retro"]["flat_retros"] == 0
    refute moved.briefing["retro"]["goal_change_required"]
  end

  test "unmeasurable retros do not count as flat", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2, source_key: nil})
    retro = next_retro(%{c | goal: goal})
    assert retro.briefing["retro"]["change"] == nil
    refute retro.briefing["retro"]["flat"]
    assert retro.briefing["retro"]["flat_retros"] == 0
  end
end

