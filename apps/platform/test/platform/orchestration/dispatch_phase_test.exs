defmodule Platform.Orchestration.DispatchPhaseTest do
  @moduledoc """
  Unit tests for the stage-contract dispatch resolver (task 019fa469 stage 1).

  Pure functions, no DB — `async: true`.

  The load-bearing case is `stale_status/*`: a task row still reading
  `"in_review"` while the running stage carries only implementation validations.
  Every other case exists to keep the table honest around it.
  """
  use ExUnit.Case, async: true

  alias Platform.Orchestration.DispatchPhase
  alias Platform.Tasks.Validation

  defp task(status, extra \\ %{}), do: Map.merge(%{id: "task-1", status: status}, extra)

  defp stage(kinds, extra \\ %{}) do
    Map.merge(
      %{
        id: "stage-1",
        position: 3,
        status: "running",
        validations:
          Enum.map(kinds, fn
            {kind, status} -> %{id: "v-#{kind}", kind: kind, status: status}
            kind -> %{id: "v-#{kind}", kind: kind, status: "pending"}
          end)
      },
      extra
    )
  end

  describe "compile-time exhaustiveness over Validation.kinds/0" do
    test "every declared validation kind is classified" do
      assert Validation.kinds() -- Map.keys(DispatchPhase.kind_phase_table()) == []
    end

    test "no table key is a kind Validation does not declare" do
      assert Map.keys(DispatchPhase.kind_phase_table()) -- Validation.kinds() == []
    end

    test "the table is non-empty and covers all nine shipped kinds" do
      # Anti-vacuity: both assertions above pass trivially against an empty
      # table paired with an empty kinds/0. Pin the actual arity.
      assert map_size(DispatchPhase.kind_phase_table()) == length(Validation.kinds())
      assert map_size(DispatchPhase.kind_phase_table()) == 9
    end

    test "every classified phase maps to a real dispatch.* slug shape" do
      for {kind, phase} <- DispatchPhase.kind_phase_table() do
        assert phase in [:in_progress, :in_review, :review_e2e, :deploying],
               "kind #{kind} classified to unexpected phase #{inspect(phase)}"
      end
    end
  end

  describe "planning (no stage)" do
    test "planning task with no plan and no stage resolves to dispatch.planning" do
      phase = DispatchPhase.resolve(task("planning"), nil, nil)

      assert phase.slug == "dispatch.planning"
      assert phase.stage_id == nil
      # ack_mode :none is load-bearing — ToolSurface rejects a stage-less ack.
      assert phase.ack_mode == :none
      refute phase.requires_stage?
    end
  end

  describe "stage contract wins over task.status" do
    test "stale in_review status with test_pass + lint_pass pending resolves to in_progress" do
      phase =
        DispatchPhase.resolve(task("in_review"), %{}, stage(["test_pass", "lint_pass"]))

      assert phase.slug == "dispatch.in_progress"
      assert phase.ack_mode == :stage
      assert phase.stage_id == "stage-1"
      assert phase.requires_stage?
    end

    test "stale in_review status on a pr_merged deploy stage resolves to deploying" do
      # The variant the ticket does not record — observed on task 019fa230.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage(["pr_merged"], %{name: "Deploy: PR merge"})
        )

      assert phase.slug == "dispatch.deploying"
      assert phase.ack_mode == :stage
    end

    test "stale in_progress status on a manual_approval-only stage resolves to in_review" do
      phase = DispatchPhase.resolve(task("in_progress"), %{}, stage(["manual_approval"]))

      assert phase.slug == "dispatch.in_review"
    end

    test "stale in_progress status on an e2e_behavior stage resolves to review_e2e" do
      phase = DispatchPhase.resolve(task("in_progress"), %{}, stage(["e2e_behavior"]))

      assert phase.slug == "dispatch.review_e2e"
    end
  end

  describe "kind -> phase table branches" do
    for {kind, expected_slug} <- [
          {"e2e_behavior", "dispatch.review_e2e"},
          {"manual_approval", "dispatch.in_review"},
          {"ci_check", "dispatch.deploying"},
          {"ci_passed", "dispatch.deploying"},
          {"pr_merged", "dispatch.deploying"},
          {"lint_pass", "dispatch.in_progress"},
          {"type_check", "dispatch.in_progress"},
          {"test_pass", "dispatch.in_progress"},
          {"code_review", "dispatch.in_progress"}
        ] do
      test "a lone pending #{kind} resolves to #{expected_slug}" do
        phase = DispatchPhase.resolve(task("todo"), %{}, stage([unquote(kind)]))

        assert phase.slug == unquote(expected_slug)
        assert phase.requires_stage?
        assert phase.ack_mode == :stage
      end
    end
  end

  describe "precedence" do
    test "e2e_behavior wins over manual_approval" do
      phase =
        DispatchPhase.resolve(task("in_review"), %{}, stage(["manual_approval", "e2e_behavior"]))

      assert phase.slug == "dispatch.review_e2e"
    end

    test "e2e_behavior wins over deploy gates" do
      phase = DispatchPhase.resolve(task("deploying"), %{}, stage(["pr_merged", "e2e_behavior"]))

      assert phase.slug == "dispatch.review_e2e"
    end

    test "deploy gates win over implementation kinds" do
      phase = DispatchPhase.resolve(task("in_progress"), %{}, stage(["test_pass", "ci_passed"]))

      assert phase.slug == "dispatch.deploying"
    end

    test "manual_approval mixed with test_pass resolves to in_progress, not in_review" do
      # in_review only wins when it is the ONLY pending phase — the work has to
      # land before a human can review it.
      phase =
        DispatchPhase.resolve(task("in_review"), %{}, stage(["manual_approval", "test_pass"]))

      assert phase.slug == "dispatch.in_progress"
    end

    test "manual_approval alone across several validations still resolves to in_review" do
      phase =
        DispatchPhase.resolve(
          task("in_progress"),
          %{},
          stage(["manual_approval", "manual_approval"])
        )

      assert phase.slug == "dispatch.in_review"
    end
  end

  describe "non-pending validations are ignored" do
    test "passed validations do not classify the stage" do
      phase =
        DispatchPhase.resolve(
          task("in_progress"),
          %{},
          stage([{"manual_approval", "passed"}, {"test_pass", "pending"}])
        )

      assert phase.slug == "dispatch.in_progress"
    end

    test "a stage whose validations all passed falls back to task.status" do
      phase =
        DispatchPhase.resolve(
          task("deploying"),
          %{},
          stage([{"test_pass", "passed"}, {"lint_pass", "passed"}])
        )

      assert phase.slug == "dispatch.deploying"
      assert phase.stage_id == "stage-1"
    end

    test "a stage with no validations and an unmapped status resolves to fallback" do
      phase = DispatchPhase.resolve(task("todo"), %{}, stage([]))

      assert phase.slug == "dispatch.fallback"
      # A stage DID resolve, so nothing is being fabricated — do not suppress.
      refute phase.requires_stage?
      assert phase.ack_mode == :stage
    end

    test "a validation with a missing status is treated as pending" do
      stage = %{id: "stage-1", validations: [%{id: "v", kind: "test_pass"}]}

      assert DispatchPhase.resolve(task("in_review"), %{}, stage).slug == "dispatch.in_progress"
    end
  end

  describe "no stage resolved (defect 4 classification half)" do
    for status <- ["in_progress", "in_review", "deploying"] do
      test "#{status} with no running stage flags requires_stage? so the caller can decline" do
        phase = DispatchPhase.resolve(task(unquote(status)), %{}, nil)

        assert phase.slug == "dispatch.fallback"
        assert phase.stage_id == nil
        assert phase.ack_mode == :none
        # The task claims to be mid-execution but no stage resolved. Rendering
        # a stage-scoped payload here is what fabricated "Stage 1/7".
        assert phase.requires_stage?
      end
    end

    test "a genuinely stage-less status falls back and must NOT be suppressed" do
      phase = DispatchPhase.resolve(task("todo"), %{}, nil)

      assert phase.slug == "dispatch.fallback"
      refute phase.requires_stage?
    end

    test "planning with no stage must NOT be suppressed" do
      phase = DispatchPhase.resolve(task("planning"), nil, nil)

      refute phase.requires_stage?
    end
  end

  describe "input shape tolerance" do
    test "string-keyed maps resolve identically to atom-keyed maps" do
      string_task = %{"id" => "task-1", "status" => "in_review"}

      string_stage = %{
        "id" => "stage-9",
        "validations" => [%{"kind" => "test_pass", "status" => "pending"}]
      }

      phase = DispatchPhase.resolve(string_task, %{}, string_stage)

      assert phase.slug == "dispatch.in_progress"
      assert phase.stage_id == "stage-9"
      assert phase.ack_mode == :stage
    end

    test "an unloaded validations association does not crash the resolver" do
      stage = %{id: "stage-1", validations: %Ecto.Association.NotLoaded{}}

      phase = DispatchPhase.resolve(task("in_progress"), %{}, stage)

      assert phase.slug == "dispatch.in_progress"
    end

    test "a nil task with no stage resolves to fallback rather than raising" do
      phase = DispatchPhase.resolve(nil, nil, nil)

      assert phase.slug == "dispatch.fallback"
      refute phase.requires_stage?
    end
  end

  describe "phase_for_pending/1 (stage 2's select_review_template delegate)" do
    test "returns nil for an empty pending list" do
      assert DispatchPhase.phase_for_pending([]) == nil
    end

    test "returns nil for a non-list" do
      assert DispatchPhase.phase_for_pending(nil) == nil
    end

    test "classifies e2e over manual_approval" do
      pending = [%{kind: "manual_approval"}, %{kind: "e2e_behavior"}]

      assert DispatchPhase.phase_for_pending(pending) == :review_e2e
    end

    test "returns nil when no kind classifies" do
      assert DispatchPhase.phase_for_pending([%{kind: "not_a_kind"}]) == nil
    end
  end
end
