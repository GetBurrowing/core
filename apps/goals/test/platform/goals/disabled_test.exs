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
    assert length(functions) >= 37

    # Goals 4/8: the page reads are in the iterated set.
    for f <- [describe_goals: 1, describe_goal: 2, list_audience_options: 2],
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
          Platform.Tasks.Task
        ],
        &Repo.aggregate(&1, :count)
      )
end
