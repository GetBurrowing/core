defmodule Platform.Goals.BriefingTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.NumberAssertions
  alias Platform.Goals
  alias Platform.Goals.WakeUp
  alias Platform.Goals.WakeUps.Briefing

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    coach = agent!()

    goal =
      goal!(owner, org, %{
        coach_agent_id: coach.id,
        title: "ZEBRA-QUARTZ",
        why: "VIOLET-ANVIL",
        unit: "florps",
        source_key: "self_reported"
      })

    %{owner: owner, coach: coach, goal: goal}
  end

  test "every refusal stays number-free, with a reading positive control", c do
    wake = wake!(c, ~U[2025-01-01 06:00:00.000000Z])

    for reason <- [
          :no_source,
          :unknown_source,
          :unknown_project,
          :bad_settings,
          :no_reading_yet,
          :source_failed
        ] do
      snapshot = Briefing.snapshot(c.coach, c.goal, wake, {:cannot_measure, %{reason: reason}})
      assert Enum.sort(Map.keys(snapshot["number"])) == ~w(reason state wording)
      assert number_free?(snapshot["number"])

      block =
        Briefing.text(snapshot)
        |> String.split("## The number\n")
        |> List.last()
        |> String.split("## Since the last check-in")
        |> hd()

      refute Regex.match?(~r/\d/, block)
    end

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 4242,
        measured_at: ~U[2024-12-31 06:00:00.000000Z]
      })

    {:ok, result} = Goals.goal_number(c.coach, c.goal.id)
    snapshot = Briefing.snapshot(c.coach, c.goal, wake, result)
    refute number_free?(snapshot["number"])
    text = Briefing.text(snapshot)

    for secret <- ["ZEBRA-QUARTZ", "VIOLET-ANVIL", "florps", "4242"] do
      assert text =~ secret
      refute Briefing.wire_prompt(wake) =~ secret
    end

    assert Briefing.wire_prompt(wake) ==
             "A goal you coach is due for a check-in. Wake-up id: #{wake.id}. Read it with goal_wake_up_get, then close it with exactly one of goal_do, goal_ask or goal_wait before 2025-01-01T18:00:00.000000Z. " <>
               Briefing.read_conversation_prompt()
  end

  test "comparison uses the earlier reading timestamp and current population", c do
    {:ok, first_reading} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 10,
        measured_at: ~U[2025-01-01 06:00:01.000000Z]
      })

    first = wake!(c, ~U[2025-01-01 06:00:00.000000Z])
    first = first |> Ecto.Changeset.change(reading_id: first_reading.id) |> Repo.update!()
    {:ok, result} = Goals.goal_number(c.coach, c.goal.id)
    assert Briefing.snapshot(c.coach, c.goal, first, result)["number"]["change"] == nil
    first |> Ecto.Changeset.change(status: "closed", outcome: "wait") |> Repo.update!()

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 17,
        measured_at: ~U[2025-01-02 06:00:01.000000Z]
      })

    second = wake!(c, ~U[2025-01-02 06:00:00.000000Z])
    {:ok, result} = Goals.goal_number(c.coach, c.goal.id)
    number = Briefing.snapshot(c.coach, c.goal, second, result)["number"]
    assert number["change"] == "7"
    assert number["change_since"] == DateTime.to_iso8601(first_reading.measured_at)
  end

  test "a committed wake-up remains readable if snapshot construction was interrupted" do
    assert is_binary(Briefing.text(%{}))
  end

  defp wake!(c, time) do
    %WakeUp{goal_id: c.goal.id, coach_agent_id: c.coach.id}
    |> WakeUp.changeset(%{due_at: time, fired_at: time, respond_by: DateTime.add(time, 43_200)})
    |> Repo.insert!()
  end
end
