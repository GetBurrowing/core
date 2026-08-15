defmodule Platform.Tasks.PlanEngineManualGateRulingTest do
  @moduledoc """
  Task `01a00575` stage 1 — the human's ruling on a manual-approval gate must
  survive a reopen.

  `ReviewRequests.resolve_request/1` writes the rejection onto the validation
  row as `evidence: %{review_request_id: _, feedback: consolidated}` with
  `evaluated_by: "review_gate"`. `PlanEngine.reopen_manual_approval/1` then
  blanks that row (`evidence: %{}, evaluated_by: nil`), so a reader of the
  validation cannot tell a task nobody has judged from one a human rejected
  seconds earlier.

  This test is EXPECTED TO FAIL on unmodified main. Its red output is the
  deliverable of stage 1.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests, Task, Validation}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Ruling Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ruling Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    task = task |> Task.changeset(%{status: "in_review"}) |> Repo.update!()

    %{task: task, stage: stage, validation: validation}
  end

  test "reopening a rejected manual gate keeps the human's feedback and evaluator readable",
       ctx do
    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: ctx.validation.id,
        task_id: ctx.task.id,
        items: [%{label: "Desktop view"}]
      })

    {:ok, _item} = ReviewRequests.reject_item(hd(request.items).id, "rowan", "Needs work")

    # Precondition: the ruling really is on the validation row before the reopen.
    rejected = Repo.get!(Validation, ctx.validation.id)
    assert rejected.status == "failed"
    assert rejected.evaluated_by == "review_gate"
    assert rejected.evidence["feedback"] =~ "Needs work"

    assert {:ok, _reopened} = PlanEngine.reopen_manual_approval(ctx.validation.id)

    reloaded = Repo.get!(Validation, ctx.validation.id)

    # The gate must still read as un-evaluated — a populated `evaluated_by` on
    # a `pending` row is exactly the ambiguity this ticket removes.
    assert reloaded.status == "pending"
    assert reloaded.evaluated_by == nil
    assert reloaded.evaluated_at == nil

    # THE DEFECT: the human said "Needs work" and that must remain readable
    # from the validation row after the gate is reopened for another attempt —
    # as history, not as the current ruling.
    assert [entry] = reloaded.evidence["prior_rulings"],
           "reopen_manual_approval/1 erased the human's rejection feedback; " <>
             "evidence is now #{inspect(reloaded.evidence)}"

    assert entry["status"] == "failed"
    assert entry["evaluated_by"] == "review_gate"
    assert entry["evidence"]["feedback"] =~ "Needs work"
    assert is_binary(entry["reopened_at"])
    refute Map.has_key?(entry["evidence"], "prior_rulings")
  end

  test "successive reject-then-reopen cycles append ordered history entries", ctx do
    for feedback <- ["First round", "Second round"] do
      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: ctx.validation.id,
          task_id: ctx.task.id,
          items: [%{label: "Desktop view"}]
        })

      {:ok, _} = ReviewRequests.reject_item(hd(request.items).id, "rowan", feedback)
      assert {:ok, _} = PlanEngine.reopen_manual_approval(ctx.validation.id)
    end

    reloaded = Repo.get!(Validation, ctx.validation.id)
    rulings = reloaded.evidence["prior_rulings"]

    assert length(rulings) == 2, "expected two rulings, got #{inspect(rulings)}"
    assert Enum.at(rulings, 0)["evidence"]["feedback"] =~ "First round"
    assert Enum.at(rulings, 1)["evidence"]["feedback"] =~ "Second round"

    # The oldest entry is not re-nested inside the newest one.
    refute Map.has_key?(Enum.at(rulings, 1)["evidence"], "prior_rulings")
  end

  test "reopening a validation with no ruling on it adds no history entry", ctx do
    # Fail the gate without ever writing evidence or an evaluator, so the
    # reopen has nothing worth preserving.
    ctx.validation
    |> Validation.changeset(%{status: "failed"})
    |> Repo.update!()

    assert {:ok, _} = PlanEngine.reopen_manual_approval(ctx.validation.id)

    reloaded = Repo.get!(Validation, ctx.validation.id)
    assert reloaded.status == "pending"
    assert reloaded.evidence == %{}

    # And a second reopen still adds nothing.
    ctx.validation.id |> PlanEngine.reopen_manual_approval()
    assert Repo.get!(Validation, ctx.validation.id).evidence == %{}
  end

  test "a nil evaluated_at persists as JSON null, not the string \"nil\"", ctx do
    ctx.validation
    |> Validation.changeset(%{
      status: "failed",
      evidence: %{"feedback" => "No evaluator recorded"},
      evaluated_by: nil,
      evaluated_at: nil
    })
    |> Repo.update!()

    assert {:ok, _} = PlanEngine.reopen_manual_approval(ctx.validation.id)

    [entry] = Repo.get!(Validation, ctx.validation.id).evidence["prior_rulings"]

    assert entry["evaluated_at"] == nil
    assert entry["evaluated_by"] == nil
    refute entry["evaluated_at"] == "nil"
    refute entry["evaluated_by"] == "nil"
  end
end
