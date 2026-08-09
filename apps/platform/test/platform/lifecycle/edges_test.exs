defmodule Platform.Lifecycle.EdgesTest do
  use ExUnit.Case, async: true

  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.StepRun
  alias Platform.Tasks.Task, as: TaskSchema

  describe "edge names" do
    test "the designer and architect edges are distinct and both listed" do
      assert Edges.designer_edge() != Edges.architect_edge()
      assert Enum.sort(Edges.all()) == Enum.sort([Edges.designer_edge(), Edges.architect_edge()])
    end

    test "edge names are dotted strings, matching the shipped pipeline config vocabulary" do
      for edge <- Edges.all() do
        assert is_binary(edge)
        assert String.contains?(edge, "."), "edge #{inspect(edge)} must be dotted"
      end
    end
  end

  describe "run_outcome/1 totality" do
    # Asserted against StepRun.statuses/0, not a list written in this test.
    # A hand-written list agrees with itself after someone adds a sixth
    # status and forgets the mapping, which is the failure this guards.
    test "every StepRun status maps to a planning-step outcome" do
      statuses = StepRun.statuses()

      # Anti-vacuity: the source list must be non-trivial, or "all of them
      # map" is true of an empty set.
      assert length(statuses) >= 5

      for status <- statuses do
        outcome = Edges.run_outcome(status)

        assert outcome in TaskSchema.planning_step_outcomes(),
               "status #{inspect(status)} mapped to #{inspect(outcome)}, " <>
                 "which is outside the planning-step outcome trio"
      end
    end

    test "the mapping is not constant — it discriminates working from broken" do
      # A constant implementation (always "complete", or always "failed")
      # would satisfy the totality test above. This is the test that
      # distinguishes it from a real mapping.
      outcomes = Enum.map(StepRun.statuses(), &Edges.run_outcome/1)
      assert Enum.uniq(outcomes) |> length() >= 2
    end
  end

  describe "run_outcome/1 decisions worth arguing about" do
    test "a divert is a SUCCESSFUL gate result, not a failure" do
      assert Edges.run_outcome(:diverted) == "complete"
      assert Edges.run_outcome("diverted") == "complete"
    end

    test "a suppressed firing is not_applicable — a refusal is not a malfunction" do
      assert Edges.run_outcome(:suppressed) == "not_applicable"
    end

    test "an edge that ran with no steps configured is not_applicable, not complete" do
      assert Edges.run_outcome(:not_applicable) == "not_applicable"
    end

    test "a timeout and a run left non-terminal both read as failed" do
      assert Edges.run_outcome(:timed_out) == "failed"
      assert Edges.run_outcome(:started) == "failed"
    end

    test "the executor's :complete outcome and a StepRun's completed status agree" do
      assert Edges.run_outcome(:complete) == Edges.run_outcome(:completed)
    end
  end

  test "mapped_run_statuses/0 is the StepRun status list, not a copy" do
    assert Edges.mapped_run_statuses() == StepRun.statuses()
  end
end
