defmodule Platform.Federation.ToolSurfacePriorRulingsTest do
  @moduledoc """
  Task `01a00575` stage 3 — a reopened manual-approval gate's history must
  reach an MCP reader.

  Stage 2 made `PlanEngine.reopen_manual_approval/1` archive the ruling it
  clears into `evidence["prior_rulings"]`. `serialize_validation/1` passes
  `evidence` through verbatim, so nothing in the tool surface had to change —
  but "passes through verbatim" is a claim about behaviour, and these tests
  pin it rather than leaving it to inspection. If a future serializer prunes,
  whitelists, or flattens `evidence`, the agent-visible consequence is that a
  `pending` gate silently loses the only record of why it was reopened, and
  that must fail here.
  """

  use Platform.DataCase, async: true

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests, Task, Validation}

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Prior rulings project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Prior rulings task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    task = task |> Task.changeset(%{status: "in_review"}) |> Repo.update!()

    %{task: task, plan: plan, stage: stage, validation: validation}
  end

  # Reject the gate with `feedback`, then reopen it for another attempt.
  defp reject_then_reopen!(ctx, feedback) do
    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: ctx.validation.id,
        task_id: ctx.task.id,
        items: [%{label: "Desktop view"}]
      })

    {:ok, _} = ReviewRequests.reject_item(hd(request.items).id, "rowan", feedback)
    {:ok, _} = PlanEngine.reopen_manual_approval(ctx.validation.id)
    :ok
  end

  describe "validation_list after a reject-then-reopen" do
    test "reports the gate as pending AND carries the human's words under prior_rulings", ctx do
      :ok = reject_then_reopen!(ctx, "Contrast on the FAB is unreadable")

      assert {:ok, %{validations: [serialized]}} =
               ToolSurface.execute(
                 "validation_list",
                 %{"stage_id" => ctx.stage.id},
                 %{agent_id: "reader"}
               )

      assert serialized.id == ctx.validation.id
      assert serialized.kind == "manual_approval"

      # Gate state: un-evaluated, awaiting another attempt.
      assert serialized.status == "pending"
      assert serialized.evaluated_by == nil
      assert serialized.evaluated_at == nil

      # History: the ruling the reopen cleared, reachable by name. Asserting
      # the nested feedback string means a serializer that dropped
      # `prior_rulings` — or kept the key but emptied it — fails here.
      assert [ruling] = serialized.evidence["prior_rulings"]
      assert ruling["status"] == "failed"
      assert ruling["evaluated_by"] == "review_gate"
      assert ruling["evidence"]["feedback"] =~ "Contrast on the FAB is unreadable"
      assert is_binary(ruling["reopened_at"])
    end

    test "two cycles serialize both rulings, oldest first", ctx do
      :ok = reject_then_reopen!(ctx, "First round problem")
      :ok = reject_then_reopen!(ctx, "Second round problem")

      assert {:ok, %{validations: [serialized]}} =
               ToolSurface.execute(
                 "validation_list",
                 %{"stage_id" => ctx.stage.id},
                 %{agent_id: "reader"}
               )

      assert serialized.status == "pending"
      rulings = serialized.evidence["prior_rulings"]

      assert length(rulings) == 2, "expected two serialized rulings, got #{inspect(rulings)}"
      assert Enum.at(rulings, 0)["evidence"]["feedback"] =~ "First round problem"
      assert Enum.at(rulings, 1)["evidence"]["feedback"] =~ "Second round problem"
    end

    test "a gate nobody has ruled on carries no prior_rulings key", ctx do
      assert {:ok, %{validations: [serialized]}} =
               ToolSurface.execute(
                 "validation_list",
                 %{"stage_id" => ctx.stage.id},
                 %{agent_id: "reader"}
               )

      assert serialized.status == "pending"

      # Anti-vacuity for the tests above: absent history is distinguishable
      # from present history, so the assertions there are not satisfied by an
      # empty map that happens to compare loosely.
      refute Map.has_key?(serialized.evidence || %{}, "prior_rulings")
    end
  end

  describe "plan_get" do
    test "surfaces prior_rulings on the reopened gate in the stage/validation tree", ctx do
      :ok = reject_then_reopen!(ctx, "Tap target too small at 375px")

      assert {:ok, plan} =
               ToolSurface.execute("plan_get", %{"task_id" => ctx.task.id}, %{agent_id: "reader"})

      stage = Enum.find(plan.stages, &(&1.id == ctx.stage.id))
      assert stage, "stage missing from plan_get payload: #{inspect(plan)}"

      validation = Enum.find(stage.validations, &(&1.id == ctx.validation.id))
      assert validation, "validation missing from plan_get payload: #{inspect(stage)}"

      assert validation.status == "pending"
      assert [ruling] = validation.evidence["prior_rulings"]
      assert ruling["evidence"]["feedback"] =~ "Tap target too small at 375px"
    end
  end

  describe "the validation row is still readable straight from the database" do
    test "serializer output matches the persisted evidence map", ctx do
      :ok = reject_then_reopen!(ctx, "Copy is wrong")

      assert {:ok, %{validations: [serialized]}} =
               ToolSurface.execute(
                 "validation_list",
                 %{"stage_id" => ctx.stage.id},
                 %{agent_id: "reader"}
               )

      persisted = Repo.get!(Validation, ctx.validation.id)
      assert serialized.evidence == persisted.evidence
    end
  end
end
