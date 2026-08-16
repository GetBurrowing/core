defmodule Platform.Tasks.PlanEngineDirectEvidenceWriteTest do
  @moduledoc """
  Task `01a006f6` stage 1 — `prior_rulings` survives only because every caller
  re-attaches it.

  `ReviewRequests` used to copy the archive forward before calling into the plan
  engine, so only writes going through the review-request path preserved
  history. A DIRECT `PlanEngine.evaluate_validation/2` — which is what the MCP
  validation tools reach — replaced `evidence` wholesale and dropped the archive
  on the floor. Stage 2 moved the merge into the engine write and stage 3
  removed the caller-side duplicate, so the engine is now the sole owner.

  Case 1 was EXPECTED TO FAIL on unmodified main. Its red output was the
  deliverable of stage 1; the fix landed in stage 2. Cases 2 and 3 pin the
  shape that fix must NOT break: no `prior_rulings` key invented where there was
  none, and non-manual kinds untouched.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests, Task, Validation}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Direct Write Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Direct Write Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    task = task |> Task.changeset(%{status: "in_review"}) |> Repo.update!()

    %{task: task, stage: stage, validation: validation}
  end

  test "a direct evaluate_validation/2 keeps an existing prior_rulings archive", ctx do
    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: ctx.validation.id,
        task_id: ctx.task.id,
        items: [%{label: "Desktop view"}]
      })

    {:ok, _item} = ReviewRequests.reject_item(hd(request.items).id, "rowan", "Needs work")
    assert {:ok, _} = PlanEngine.reopen_manual_approval(ctx.validation.id)

    # Precondition: the archive really is on the row before the write under test,
    # otherwise the assertion below could pass on an empty list.
    seeded = Repo.get!(Validation, ctx.validation.id)

    assert [entry] = seeded.evidence["prior_rulings"],
           "precondition failed: no archive to lose; evidence is #{inspect(seeded.evidence)}"

    assert {:ok, _} =
             PlanEngine.evaluate_validation(ctx.validation.id, %{
               status: "passed",
               evidence: %{"note" => "direct call"},
               evaluated_by: "some_agent"
             })

    reloaded = Repo.get!(Validation, ctx.validation.id)

    # THE DEFECT: nothing in the engine carries the archive, so a caller that
    # does not know to re-attach it silently destroys the human's ruling.
    assert reloaded.evidence["prior_rulings"] == [entry],
           "a direct evaluate_validation/2 dropped the prior_rulings archive; " <>
             "evidence is now #{inspect(reloaded.evidence)}"

    assert hd(reloaded.evidence["prior_rulings"])["evidence"]["feedback"] =~ "Needs work"
    assert reloaded.evidence["note"] == "direct call"
  end

  test "a direct evaluate_validation/2 does not invent a prior_rulings key", ctx do
    assert {:ok, _} =
             PlanEngine.evaluate_validation(ctx.validation.id, %{
               status: "passed",
               evidence: %{"note" => "x"},
               evaluated_by: "some_agent"
             })

    reloaded = Repo.get!(Validation, ctx.validation.id)

    refute Map.has_key?(reloaded.evidence, "prior_rulings")
    assert reloaded.evidence == %{"note" => "x"}
  end

  test "a non-manual validation's evidence is replaced wholesale", ctx do
    {:ok, other} = Tasks.create_validation(%{stage_id: ctx.stage.id, kind: "test_pass"})

    assert {:ok, _} =
             PlanEngine.evaluate_validation(other.id, %{
               status: "passed",
               evidence: %{"note" => "x"},
               evaluated_by: "some_agent"
             })

    reloaded = Repo.get!(Validation, other.id)

    refute Map.has_key?(reloaded.evidence, "prior_rulings")
    assert reloaded.evidence == %{"note" => "x"}
  end
end
