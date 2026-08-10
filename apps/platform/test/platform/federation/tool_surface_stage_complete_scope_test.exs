defmodule Platform.Federation.ToolSurfaceStageCompleteScopeTest do
  @moduledoc """
  Coverage for `stage_complete` stage-scoping (task 019fec3a).

  `stage_complete` admits a call naming a stage whose status is already
  `passed` so genuine idempotent re-calls succeed. Before this task it then
  called the PLAN-scoped `PlanEngine.advance/1`, which picks its subject via
  "first running, else first pending" — NOT the stage the caller named. A
  late or duplicate `stage_complete` therefore advanced whatever stage
  happened to be running, and a stage with zero validation rows has verdict
  `:all_passed`, so it was marked `passed` with no executor involvement.

  These tests pin both halves: a re-call naming an already-passed stage must
  not touch the running stage, and a stage whose own executor names it must
  still complete and still start the next stage.
  """

  use Platform.DataCase, async: true

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stage

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stage-scope project #{System.unique_integer([:positive])}"
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Stage-scope task"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    %{project: project, task: task, plan: plan}
  end

  defp stage!(plan, position, name) do
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
    stage
  end

  defp status!(stage_id), do: Repo.get!(Stage, stage_id).status

  describe "stage_complete scoping" do
    test "a re-call naming an already-passed stage does not pass the running zero-validation stage",
         %{plan: plan} do
      one = stage!(plan, 1, "Setup")
      two = stage!(plan, 2, "Build")
      three = stage!(plan, 3, "Ship")

      # Stages 1 and 2 are done; stage 3 is running and carries NO validations.
      {:ok, _} = Tasks.transition_stage(one, "running")
      {:ok, one} = Tasks.transition_stage(Repo.get!(Stage, one.id), "passed")
      {:ok, _} = Tasks.transition_stage(two, "running")
      {:ok, _two} = Tasks.transition_stage(Repo.get!(Stage, two.id), "passed")
      {:ok, _} = Tasks.transition_stage(three, "running")

      assert status!(three.id) == "running"
      assert Tasks.list_validations(three.id) == []

      # A late / duplicate completion naming stage 2 — which is already passed.
      assert {:ok, result} =
               ToolSurface.execute(
                 "stage_complete",
                 %{"stage_id" => two.id},
                 %{agent_id: "executor-stage-two"}
               )

      # Idempotent success for the named stage...
      assert result.stage_id == two.id

      # ...but the stage it did NOT name must be untouched.
      assert status!(three.id) == "running",
             "stage 3 was advanced by a stage_complete that named stage 2"

      assert status!(one.id) == "passed"
    end

    test "the stage's own executor still completes it and still starts the next stage",
         %{plan: plan} do
      one = stage!(plan, 1, "Build")
      two = stage!(plan, 2, "Ship")

      {:ok, _} = Tasks.transition_stage(one, "running")

      assert {:ok, result} =
               ToolSurface.execute(
                 "stage_complete",
                 %{"stage_id" => one.id},
                 %{agent_id: "executor-stage-one"}
               )

      assert result.stage_id == one.id
      assert status!(one.id) == "passed"

      assert status!(two.id) == "running",
             "completing stage 1 must still auto-start stage 2"
    end

    test "an executor completing a stage whose validations all passed still advances",
         %{plan: plan} do
      one = stage!(plan, 1, "Build")
      two = stage!(plan, 2, "Ship")

      {:ok, _} = Tasks.transition_stage(one, "running")
      {:ok, v} = Tasks.create_validation(%{stage_id: one.id, kind: "test_pass"})

      {:ok, _} =
        Platform.Tasks.PlanEngine.evaluate_validation(v.id, %{
          status: "passed",
          evidence: %{},
          evaluated_by: "system"
        })

      # The validation pass path already advanced stage 1 (it is stage-scoped
      # and must stay behaviourally unchanged), so stage 2 is running.
      assert status!(one.id) == "passed"
      assert status!(two.id) == "running"

      # The executor's own stage_complete arrives afterwards — idempotent,
      # and must not sweep stage 2.
      assert {:ok, _} =
               ToolSurface.execute(
                 "stage_complete",
                 %{"stage_id" => one.id},
                 %{agent_id: "executor-stage-one"}
               )

      assert status!(two.id) == "running"
    end
  end
end
