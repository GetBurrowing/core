defmodule Platform.Goals.DisabledTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Goal, Stop, Entry, Grant, Reading, WakeUp, Ask, AskAnswer, TaskLink}

  test "every public context function refuses before writes" do
    enable_goals!()
    Application.put_env(:goals, :enabled, false)
    before = counts()
    functions = Goals.__info__(:functions) |> Enum.reject(fn {name, _} -> name == :enabled? end)
    assert length(functions) >= 57

    # Goals 4/8: the page reads are in the iterated set.
    for f <- [describe_goals: 1, describe_goal: 2, list_audience_options: 2],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    for f <- [
          expected_pace: 2,
          expected_pace: 3,
          prepare_brief: 2,
          brief_items: 2,
          brief_summary: 2,
          ask_brief_date: 2,
          set_report_noted: 3,
          request_undo: 3,
          request_undo: 4,
          ask_coach: 3,
          ask_coach: 4,
          withdraw_answer: 2,
          record_practice: 3,
          practice_streak: 2,
          practice_streak: 3,
          get_ask: 2,
          refresh_brief: 2
        ],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    refute Goals.enabled?()

    for {name, arity} <- functions do
      args = [nil | List.duplicate(%{}, arity - 1)] |> Enum.take(arity)

      assert apply(Goals, name, args) == {:error, :goals_disabled},
             "#{name}/#{arity} did not refuse"
    end

    assert counts() == before
  end

  defp counts,
    do:
      Enum.map(
        [
          Goal,
          Stop,
          Entry,
          Grant,
          Reading,
          WakeUp,
          Ask,
          AskAnswer,
          TaskLink,
          Platform.Goals.BriefItem,
          Platform.Tasks.Task
        ],
        &Repo.aggregate(&1, :count)
      )
end
