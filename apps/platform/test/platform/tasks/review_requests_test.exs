defmodule Platform.Tasks.ReviewRequestsTest do
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks

  alias Platform.Tasks.{
    PlanEngine,
    ReviewItem,
    ReviewRequest,
    ReviewRequests,
    Stage,
    Task,
    Validation
  }

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Review Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Review Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    %{project: project, task: task, plan: plan, stage: stage, validation: validation}
  end

  # ── create_review_request/1 ─────────────────────────────────────────────

  describe "create_review_request/1" do
    test "creates a request with multiple items in one transaction", ctx do
      assert {:ok, request} =
               ReviewRequests.create_review_request(%{
                 validation_id: ctx.validation.id,
                 task_id: ctx.task.id,
                 submitted_by: "test-agent",
                 items: [
                   %{label: "Desktop view", content: "Looks good on desktop"},
                   %{label: "Mobile nav", canvas_id: "canvas-123", content: "Mobile screenshot"}
                 ]
               })

      assert request.status == "pending"
      assert request.submitted_by == "test-agent"
      assert length(request.items) == 2

      labels = Enum.map(request.items, & &1.label) |> Enum.sort()
      assert labels == ["Desktop view", "Mobile nav"]
      assert Enum.all?(request.items, &(&1.status == "pending"))
    end

    test "rolls back if an item is invalid", ctx do
      # Missing required :label on the second item
      assert {:error, _changeset} =
               ReviewRequests.create_review_request(%{
                 validation_id: ctx.validation.id,
                 task_id: ctx.task.id,
                 items: [
                   %{label: "Good item"},
                   %{content: "Missing label"}
                 ]
               })

      # Nothing persisted
      assert ReviewRequests.list_pending_for_task(ctx.task.id) == []
    end

    test "creating a new review request reopens a failed manual approval gate", ctx do
      task =
        ctx.task
        |> Task.changeset(%{status: "in_review"})
        |> Repo.update!()

      {:ok, request} = create_request(%{ctx | task: task}, ["Desktop"])
      {:ok, _} = ReviewRequests.reject_item(hd(request.items).id, "rowan", "Needs work")

      assert Repo.get!(Task, task.id).status == "in_progress"
      assert Repo.get!(Validation, ctx.validation.id).status == "failed"
      assert Repo.get!(Stage, ctx.stage.id).status == "failed"

      assert {:ok, retried_request} =
               ReviewRequests.create_review_request(%{
                 validation_id: ctx.validation.id,
                 task_id: task.id,
                 items: [%{label: "Retried desktop"}]
               })

      assert retried_request.status == "pending"
      assert Repo.get!(Task, task.id).status == "in_review"

      retried_validation = Repo.get!(Validation, ctx.validation.id)
      assert retried_validation.status == "pending"
      assert retried_validation.evidence == %{}
      assert retried_validation.evaluated_by == nil
      assert retried_validation.evaluated_at == nil

      retried_stage = Repo.get!(Stage, ctx.stage.id)
      assert retried_stage.status == "running"
      assert retried_stage.completed_at == nil
    end
  end

  # ── get_review_request/1 ────────────────────────────────────────────────

  describe "get_review_request/1" do
    test "returns request with preloaded items", ctx do
      {:ok, created} = create_request(ctx, ["Item A", "Item B"])

      fetched = ReviewRequests.get_review_request(created.id)
      assert fetched.id == created.id
      assert length(fetched.items) == 2
    end

    test "returns nil for nonexistent ID" do
      assert ReviewRequests.get_review_request(Ecto.UUID.generate()) == nil
    end
  end

  # ── list_pending_for_task/1 ─────────────────────────────────────────────

  describe "list_pending_for_task/1" do
    test "returns only pending requests for the task", ctx do
      {:ok, pending} = create_request(ctx, ["A"])

      # Create another request and resolve it
      {:ok, validation2} =
        Tasks.create_validation(%{stage_id: ctx.stage.id, kind: "manual_approval"})

      {:ok, resolved} =
        ReviewRequests.create_review_request(%{
          validation_id: validation2.id,
          task_id: ctx.task.id,
          items: [%{label: "B"}]
        })

      # Manually resolve it
      resolved
      |> ReviewRequest.changeset(%{status: "resolved", resolved_at: DateTime.utc_now()})
      |> Repo.update!()

      pending_list = ReviewRequests.list_pending_for_task(ctx.task.id)
      assert length(pending_list) == 1
      assert hd(pending_list).id == pending.id
    end

    test "returns empty list when no pending requests exist", ctx do
      assert ReviewRequests.list_pending_for_task(ctx.task.id) == []
    end
  end

  # ── approve_item/2 ──────────────────────────────────────────────────────

  describe "approve_item/2" do
    test "sets item status to approved", ctx do
      {:ok, request} = create_request(ctx, ["Check A"])
      item = hd(request.items)

      assert {:ok, updated} = ReviewRequests.approve_item(item.id, "rowan")
      assert updated.status == "approved"
      assert updated.reviewed_by == "rowan"
      assert updated.reviewed_at != nil
    end

    test "approving all items resolves the request and passes the validation", ctx do
      {:ok, request} = create_request(ctx, ["A", "B"])

      for item <- request.items do
        {:ok, _} = ReviewRequests.approve_item(item.id, "rowan")
      end

      # Request should be resolved
      resolved = ReviewRequests.get_review_request(request.id)
      assert resolved.status == "resolved"
      assert resolved.resolved_at != nil

      # Validation should be passed
      validation = Repo.get!(Validation, ctx.validation.id)
      assert validation.status == "passed"
      assert validation.evaluated_by == "review_gate"
    end

    test "returns error for nonexistent item" do
      assert {:error, :not_found} = ReviewRequests.approve_item(Ecto.UUID.generate(), "rowan")
    end
  end

  # ── reject_item/3 ──────────────────────────────────────────────────────

  describe "reject_item/3" do
    test "sets item status to needs_revision with feedback", ctx do
      {:ok, request} = create_request(ctx, ["Check A"])
      item = hd(request.items)

      assert {:ok, updated} =
               ReviewRequests.reject_item(item.id, "rowan", "Button alignment is off")

      assert updated.status == "needs_revision"
      assert updated.feedback == "Button alignment is off"
      assert updated.reviewed_by == "rowan"
      assert updated.reviewed_at != nil
    end

    test "rejecting an item in a single-item request resolves it and fails validation", ctx do
      {:ok, request} = create_request(ctx, ["Solo check"])
      item = hd(request.items)

      {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", "Needs work")

      resolved = ReviewRequests.get_review_request(request.id)
      assert resolved.status == "resolved"

      validation = Repo.get!(Validation, ctx.validation.id)
      assert validation.status == "failed"
    end

    test "rejecting an item resolves sibling pending review requests for the same validation",
         ctx do
      {:ok, request_a} = create_request(ctx, ["Desktop"])
      {:ok, request_b} = create_request(ctx, ["Mobile"])

      item = hd(request_a.items)
      {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", "Needs work")

      assert ReviewRequests.list_pending_for_task(ctx.task.id) == []

      assert ReviewRequests.get_review_request(request_a.id).status == "resolved"
      assert ReviewRequests.get_review_request(request_b.id).status == "resolved"
    end

    test "rejecting review feedback returns an in-review task to in_progress", ctx do
      task =
        ctx.task
        |> Task.changeset(%{status: "in_review"})
        |> Repo.update!()

      {:ok, request} = create_request(%{ctx | task: task}, ["Desktop"])
      item = hd(request.items)

      {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", "Needs work")

      assert Repo.get!(Task, task.id).status == "in_progress"
    end
  end

  # ── Mixed approval/rejection ────────────────────────────────────────────

  describe "mixed approval and rejection" do
    test "partial approve + one reject = failed validation", ctx do
      {:ok, request} = create_request(ctx, ["Desktop", "Mobile", "Tablet"])
      [item_a, item_b, item_c] = request.items

      {:ok, _} = ReviewRequests.approve_item(item_a.id, "rowan")
      {:ok, _} = ReviewRequests.approve_item(item_b.id, "rowan")
      {:ok, _} = ReviewRequests.reject_item(item_c.id, "rowan", "Tablet layout broken")

      resolved = ReviewRequests.get_review_request(request.id)
      assert resolved.status == "resolved"

      validation = Repo.get!(Validation, ctx.validation.id)
      assert validation.status == "failed"
    end

    test "single rejection resolves immediately even when other items are still pending", ctx do
      {:ok, request} = create_request(ctx, ["Desktop", "Mobile", "Tablet"])
      [item_a | _rest] = request.items

      {:ok, _} = ReviewRequests.reject_item(item_a.id, "rowan", "Desktop state is incorrect")

      resolved = ReviewRequests.get_review_request(request.id)
      assert resolved.status == "resolved"

      validation = Repo.get!(Validation, ctx.validation.id)
      assert validation.status == "failed"
    end
  end

  # ── maybe_resolve_request/1 ─────────────────────────────────────────────

  describe "maybe_resolve_request/1" do
    test "returns :not_yet when only approvals exist and items are still pending", ctx do
      {:ok, request} = create_request(ctx, ["A", "B"])

      # Approve only one item
      {:ok, _} = ReviewRequests.approve_item(hd(request.items).id, "rowan")

      # Calling directly — second item is still pending and no rejection exists yet
      assert :not_yet == ReviewRequests.maybe_resolve_request(request.id)

      # Request still pending
      still_pending = ReviewRequests.get_review_request(request.id)
      assert still_pending.status == "pending"
    end

    test "returns :not_yet for nonexistent request" do
      assert :not_yet == ReviewRequests.maybe_resolve_request(Ecto.UUID.generate())
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp create_request(ctx, labels) do
    items = Enum.map(labels, fn label -> %{label: label} end)

    ReviewRequests.create_review_request(%{
      validation_id: ctx.validation.id,
      task_id: ctx.task.id,
      items: items
    })
  end
end
