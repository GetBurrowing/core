defmodule Platform.Lifecycle.EdgesTest do
  use ExUnit.Case, async: true

  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.StepRegistry
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

  describe "default_steps/1" do
    test "the designer edge ships an awaited, divert-capable step" do
      assert [step] = Edges.default_steps(Edges.designer_edge())

      assert step["step"] == Edges.designer_step_name()

      # `await` is the whole point of the designer edge: "design runs BEFORE
      # planning" is only true if the planner actually waits. `can_divert` is
      # authority, read from the DECLARATION and never from position.
      assert step["await"] == true
      assert step["can_divert"] == true
    end

    test "the declaration is string-keyed, exactly as a configured one would be" do
      [step] = Edges.default_steps(Edges.designer_edge())

      # A shipped default that a project pipeline could not have expressed
      # would be a second, hidden step language — and the executor reads
      # `Map.get(step, "await")`, so an atom-keyed default would silently
      # resolve to `false` and stop awaiting.
      assert Enum.all?(Map.keys(step), &is_binary/1)
    end

    test "the architect edge ships none, and an unknown edge ships none" do
      # Not an oversight: the architect gate is a single function with a
      # resolution argument, so there is no bespoke machinery to declare. See
      # the premise correction in the moduledoc.
      assert Edges.default_steps(Edges.architect_edge()) == []
      assert Edges.default_steps("no.such.edge") == []
    end

    test "the shipped designer step is a name the registry resolves" do
      # The declaration and the allowlist are separate sources and can drift.
      # If they do, the edge resolves `{:error, :unknown_step}`, the step is
      # recorded `failed`, and the planner is released anyway — indistinguishable
      # from success to anything watching only the planner.
      registry = :"edges_registry_#{System.unique_integer([:positive])}"
      start_supervised!({StepRegistry, name: registry})

      assert {:ok, entry} = StepRegistry.fetch(Edges.designer_step_name(), registry)
      assert entry.kind == :agent
    end
  end

  test "mapped_run_statuses/0 is the StepRun status list, not a copy" do
    assert Edges.mapped_run_statuses() == StepRun.statuses()
  end
end
