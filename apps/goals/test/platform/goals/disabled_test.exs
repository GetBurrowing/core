defmodule Platform.Goals.DisabledTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Goal, Stop, Entry, Grant, Reading}

  test "every public context function refuses before writes" do
    enable_goals!()
    Application.put_env(:goals, :enabled, false)
    before = counts()
    functions = Goals.__info__(:functions) |> Enum.reject(fn {name, _} -> name == :enabled? end)
    assert length(functions) >= 23
    refute Goals.enabled?()

    for {name, arity} <- functions do
      args = [nil | List.duplicate(%{}, arity - 1)] |> Enum.take(arity)

      assert apply(Goals, name, args) == {:error, :goals_disabled},
             "#{name}/#{arity} did not refuse"
    end

    assert counts() == before
  end

  defp counts, do: Enum.map([Goal, Stop, Entry, Grant, Reading], &Repo.aggregate(&1, :count))
end
