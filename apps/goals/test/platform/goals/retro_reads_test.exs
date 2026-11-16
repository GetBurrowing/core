defmodule Platform.Goals.RetroReadsTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock
  setup do: setup_outcome()

  defp entry(c, attrs) do
    {:ok, entry} =
      Goals.add_entry(
        c.owner,
        c.goal.id,
        Map.merge(%{kind: "retro", title: "Looking back", occurred_at: Clock.now()}, attrs)
      )

    entry
  end

  test "reads derive six action states exclusively from the notebook", c do
    actions = for _ <- 1..6, do: entry(c, %{kind: "action"})
    [working, failed, early, none, stopped, started] = actions

    retro =
      entry(c, %{
        details: %{
          "dropped" => [%{"entry_id" => stopped.id}],
          "verdicts" => [
            %{"entry_id" => working.id, "verdict" => "came_true"},
            %{"entry_id" => failed.id, "verdict" => "did_not"},
            %{"entry_id" => early.id, "verdict" => "too_early"},
            %{"entry_id" => none.id, "verdict" => "cannot_measure"}
          ]
        }
      })

    assert {:ok, states} = Goals.prediction_states(c.owner, c.goal.id)

    assert states == %{
             working.id => :working,
             failed.id => :not_working,
             early.id => :too_early,
             none.id => :none,
             stopped.id => {:stopped, DateTime.to_date(retro.occurred_at)},
             started.id => :just_started
           }

    assert {:ok, [%{entry_id: id}]} = Goals.list_retros(c.owner, c.goal.id)
    assert id == retro.id
    assert {:ok, view} = Goals.get_retro(c.coach, c.goal.id, retro.id)
    assert view.coach_name == c.coach.name
    refute view.can_decide?
  end

  test "change lines cover the settings and owner alone can decide an open proposal", c do
    sets = [
      {%{"rhythm" => "weekdays"}, "Check-ins:"},
      {%{"rhythm_weekday" => 3}, "Check-in weekday:"},
      {%{"outreach" => "gentle"}, "Nudges:"},
      {%{"retro_every" => 4}, "Retro every:"},
      {%{"target_value" => 600}, "Target:"},
      {%{"title" => "New scope", "why" => "More focused"}, "Title:"},
      {%{"status" => "finished"}, "Finish this goal"}
    ]

    for {set, expected} <- sets do
      retro =
        entry(c, %{
          details: %{
            "goal_change" => %{"summary" => "Change direction", "kind" => "scope", "set" => set}
          }
        })

      assert {:ok, view} = Goals.get_retro(c.owner, c.goal.id, retro.id)
      assert view.can_decide?
      assert view.change.state == :open
      assert Enum.any?(view.change.lines, &String.starts_with?(&1, expected))
      assert {:ok, _} = Goals.decide_retro_change(c.owner, c.goal.id, retro.id, "keep")
      assert {:ok, kept} = Goals.get_retro(c.owner, c.goal.id, retro.id)
      assert kept.change.state == :kept
      refute kept.can_decide?
    end
  end

  test "end switches through the settings writer and all reads hide personal goals", c do
    retro =
      entry(c, %{
        details: %{
          "goal_change" => %{
            "summary" => "We are done",
            "kind" => "end",
            "set" => %{"status" => "finished"}
          }
        }
      })

    assert {:ok, %{goal: %{status: "finished"}}} =
             Goals.decide_retro_change(c.owner, c.goal.id, retro.id, "switch")

    assert {:ok, %{change: %{state: :switched}, can_decide?: false}} =
             Goals.get_retro(c.owner, c.goal.id, retro.id)

    for stranger <- [user!(), root_admin!()] do
      assert {:error, :not_found} = Goals.get_retro(stranger, c.goal.id, retro.id)
      assert {:error, :not_found} = Goals.list_retros(stranger, c.goal.id)
      assert {:error, :not_found} = Goals.prediction_states(stranger, c.goal.id)
    end
  end
end
