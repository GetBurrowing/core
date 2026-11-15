defmodule Platform.Goals.ModesTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.WakeUp
  setup do: setup_outcome()

  test "mode and outreach refusal matrix is atomic and leaves wait available", c do
    for {mode, outreach, outcome, with_task, refusal} <- [
          {"advise", "pushy", "do", false, :mode_forbids_do},
          {"advise", "pushy", "do", true, :mode_forbids_do},
          {"coach", "pushy", "do", true, :mode_forbids_task},
          {"do", "off", "ask", false, :outreach_off},
          {"advise", "off", "ask", false, :outreach_off},
          {"coach", "off", "ask", false, :outreach_off}
        ] do
      assert {:ok, goal} =
               Goals.update_goal(c.owner, c.goal.id, %{agent_mode: mode, outreach: outreach})

      wake = fire(goal)
      attrs = if outcome == "ask", do: ask_attrs(), else: prediction()

      attrs =
        if with_task,
          do:
            Map.put(attrs, :task, %{
              "project_id" => Ecto.UUID.generate(),
              "title" => "Work",
              "description" => "Do it"
            }),
          else: attrs

      before = row_counts()
      assert Goals.close_wake_up(c.coach, wake.id, outcome, attrs) == {:error, refusal}
      assert row_counts() == before
      assert Repo.get!(WakeUp, wake.id).status == "open"

      assert {:ok, _} =
               Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Respect the mode"})
    end
  end

  test "coach records preparation without a task; every mode permits ask and wait", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach"})
    wake = fire(goal)

    assert {:ok, %{task: nil, entry: entry}} =
             Goals.close_wake_up(c.coach, wake.id, "do", prediction())

    assert entry.kind == "action"

    for mode <- ~w(do advise coach) do
      {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: mode})
      wake = fire(goal)
      assert {:ok, %{ask: ask}} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs())
      assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used")
      wake = fire(goal)
      assert {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Await result"})
    end
  end
end
