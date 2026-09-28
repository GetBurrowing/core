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

  Task 01a0e8c1 stage 3 (`describe "refusal names ..."`): the refusal names
  each unsatisfied validation by id, kind and status, and returns them as
  `unsatisfied_validations`. Admission is unchanged. Mutations and the test
  that reddens:
    * drop the row list from the message   -> (1)
    * admit `failed`                       -> (2)
    * admit `skipped`                      -> (2b)
    * invert `validations == []`           -> "the stage's own executor still
                                              completes it" (zero validations)
  """

  use Platform.DataCase, async: true

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stage, Validation}

  import Ecto.Query

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

  describe "refusal names the unsatisfied validations (01a0e8c1)" do
    @payload %{
      "setup" => "a running stage with two behavioural cases",
      "actions" => "call stage_complete",
      "expected" => "refused, naming the unsatisfied case"
    }

    defp e2e_row!(stage) do
      {:ok, v} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "e2e_behavior",
          evaluation_payload: @payload
        })

      v
    end

    defp complete(stage),
      do: ToolSurface.execute("stage_complete", %{"stage_id" => stage.id}, %{agent_id: "exec"})

    test "(1) a pending row is refused and named by id, kind and status; the stage stays running",
         %{plan: plan} do
      s = stage!(plan, 1, "Review")
      {:ok, _} = Tasks.transition_stage(s, "running")
      a = e2e_row!(s)
      b = e2e_row!(s)
      {:ok, _} = Tasks.evaluate_validation(b.id, "passed", %{"summary" => "ok"})

      assert {:error, error} = complete(s)
      assert error.recoverable == true
      assert error.error =~ a.id
      assert error.error =~ "e2e_behavior"
      assert error.error =~ "(pending)"
      refute error.error =~ b.id

      assert error.unsatisfied_validations == [
               %{id: a.id, kind: "e2e_behavior", status: "pending"}
             ]

      assert status!(s.id) == "running"
    end

    test "(2) a failed row is refused and named", %{plan: plan} do
      s = stage!(plan, 1, "Review")
      {:ok, _} = Tasks.transition_stage(s, "running")
      a = e2e_row!(s)
      b = e2e_row!(s)
      {:ok, _} = Tasks.evaluate_validation(b.id, "passed", %{"summary" => "ok"})
      {:ok, _} = Tasks.evaluate_validation(a.id, "failed", %{"summary" => "broken"})

      assert {:error, error} = complete(s)
      assert error.error =~ a.id
      assert error.error =~ "(failed)"

      assert error.unsatisfied_validations == [
               %{id: a.id, kind: "e2e_behavior", status: "failed"}
             ]

      assert status!(s.id) == "running"
    end

    test "(2b) a skipped row is unsatisfied for stage_complete", %{plan: plan} do
      s = stage!(plan, 1, "Review")
      {:ok, _} = Tasks.transition_stage(s, "running")
      a = e2e_row!(s)
      b = e2e_row!(s)
      {:ok, _} = Tasks.evaluate_validation(b.id, "passed", %{"summary" => "ok"})

      {1, _} =
        Repo.update_all(from(v in Validation, where: v.id == ^a.id), set: [status: "skipped"])

      assert {:error, error} = complete(s)
      assert error.error =~ "(skipped)"

      assert error.unsatisfied_validations == [
               %{id: a.id, kind: "e2e_behavior", status: "skipped"}
             ]

      assert status!(s.id) == "running"
    end

    test "(3) every row passed completes the stage and starts the next", %{plan: plan} do
      one = stage!(plan, 1, "Review")
      two = stage!(plan, 2, "Ship")
      {:ok, _} = Tasks.transition_stage(one, "running")

      for v <- [e2e_row!(one), e2e_row!(one)] do
        {:ok, _} = Tasks.evaluate_validation(v.id, "passed", %{"summary" => "ok"})
      end

      assert status!(one.id) == "running", "the bare writer must not have advanced the stage"
      assert {:ok, %{stage_status: "passed"}} = complete(one)
      assert status!(one.id) == "passed"
      assert status!(two.id) == "running"
    end

    # The plan engine's pass guard (stage 2) is reached by injecting an unmet
    # row between admission and the `passed` write: a Repo query-telemetry
    # handler fires, in the caller's process and transaction, on the guard's
    # SAVEPOINT. The refused pass rolls the savepoint (and the injected row)
    # back.
    test "(4) when the plan engine refuses the pass, stage_complete reports stage_status running",
         %{plan: plan} do
      one = stage!(plan, 1, "Build")
      two = stage!(plan, 2, "Ship")
      {:ok, _} = Tasks.transition_stage(one, "running")
      {:ok, v} = Tasks.create_validation(%{stage_id: one.id, kind: "test_pass"})
      {:ok, _} = Tasks.evaluate_validation(v.id, "passed", %{})

      test_pid = self()
      handler_id = "inject-savepoint-#{System.unique_integer([:positive])}"
      flag = {:injected, handler_id}

      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, metadata, _ ->
          try do
            if self() == test_pid and not Process.get(flag, false) and
                 is_binary(metadata[:query]) and
                 String.starts_with?(metadata.query, "SAVEPOINT plan_engine_pass_guard") do
              Process.put(flag, true)
              row = Repo.insert!(%Validation{stage_id: one.id, kind: "lint_pass"})
              send(test_pid, {:injected, row.id})
            end
          rescue
            _ -> :ok
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, result} = complete(one)
      assert_received {:injected, _id}
      assert result.stage_status == "running"
      assert status!(one.id) == "running"
      assert status!(two.id) == "pending"
    end
  end
end
