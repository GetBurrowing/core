defmodule Platform.Tasks.ReviewRequestsReadTest do
  @moduledoc """
  Read-path coverage for `fetch_request_with_items/1` and
  `list_items_for_task/1` (task `01a00570` stage 1).

  These functions exist because an agent holding only a `task_id` could not
  read back a human's ruling. The load-bearing assertions are therefore: the
  feedback text round-trips, items from MORE THAN ONE request on the same task
  come back together, and a SUPERSEDED request's items are still present and
  labelled as such rather than filtered away.

  ## Mutations these tests are known to catch (task `01a00570` stage 3)

  Each assertion below was OBSERVED to fail against a deliberately broken
  `list_items_for_task/1`. Do not weaken one without re-running its mutation.

    * `list_items_for_task/1` returning `[]` unconditionally — caught by
      "returns items across TWO requests on one task" (`length(rows) == 3`
      → 0), "includes a superseded request's items and labels the parent
      status", and "orders ruled items ahead of undispositioned ones"
      (`right: []`). This is the vacuity mode the ticket names: a read-path
      test that passes whether or not real rows come back proves nothing.

  Known BLIND SPOT, recorded rather than papered over: adding a
  `status != "needs_revision"` filter to `list_items_for_task/1` leaves EVERY
  test in this module green. No test here builds a `needs_revision` item and
  then reads it back through the list path — the disposition used is
  `approve_item/2`. That mutation is caught one layer up, by
  `Platform.Federation.ReviewReadToolsTest`, whose fixture rejects its item and
  asserts the exact feedback string. If the tool-surface test is ever deleted,
  status-filtering regressions in this function become invisible.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequest, ReviewRequests}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Read Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Read Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    %{project: project, task: task, stage: stage, validation: validation}
  end

  defp create_request(ctx, labels) do
    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: ctx.validation.id,
        task_id: ctx.task.id,
        submitted_by: "test-agent",
        items: Enum.map(labels, &%{label: &1, content: "evidence for #{&1}"})
      })

    request
  end

  describe "fetch_request_with_items/1" do
    test "round-trips a mixed approved / needs_revision ruling", ctx do
      request = create_request(ctx, ["Desktop view", "Mobile nav"])

      [desktop, mobile] = Enum.sort_by(request.items, & &1.label)

      {:ok, _} = ReviewRequests.approve_item(desktop.id, "alex")
      {:ok, _} = ReviewRequests.reject_item(mobile.id, "alex", "FAB overlaps the bottom nav")

      assert {:ok, fetched} = ReviewRequests.fetch_request_with_items(request.id)

      by_label = Map.new(fetched.items, &{&1.label, &1})

      assert by_label["Desktop view"].status == "approved"
      assert by_label["Desktop view"].reviewed_by == "alex"
      assert by_label["Desktop view"].reviewed_at

      assert by_label["Mobile nav"].status == "needs_revision"
      assert by_label["Mobile nav"].feedback == "FAB overlaps the bottom nav"
      assert by_label["Mobile nav"].reviewed_by == "alex"
      assert by_label["Mobile nav"].reviewed_at
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = ReviewRequests.fetch_request_with_items(Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for a malformed id without raising" do
      assert {:error, :not_found} = ReviewRequests.fetch_request_with_items("not-a-uuid")
      assert {:error, :not_found} = ReviewRequests.fetch_request_with_items("")
    end
  end

  describe "list_items_for_task/1" do
    test "returns items across TWO requests on one task", ctx do
      first = create_request(ctx, ["Desktop view"])
      second = create_request(ctx, ["Mobile nav", "Tablet"])

      rows = ReviewRequests.list_items_for_task(ctx.task.id)

      assert length(rows) == 3
      assert Enum.sort(Enum.map(rows, & &1.label)) == ["Desktop view", "Mobile nav", "Tablet"]

      request_ids = rows |> Enum.map(& &1.review_request_id) |> Enum.uniq() |> Enum.sort()
      assert request_ids == Enum.sort([first.id, second.id])

      assert Enum.all?(rows, &(&1.validation_id == ctx.validation.id))
    end

    test "includes a superseded request's items and labels the parent status", ctx do
      superseded = create_request(ctx, ["Old evidence"])

      {:ok, _} =
        superseded
        |> ReviewRequest.changeset(%{status: "superseded", superseded_at: DateTime.utc_now()})
        |> Repo.update()

      _live = create_request(ctx, ["New evidence"])

      rows = ReviewRequests.list_items_for_task(ctx.task.id)
      by_label = Map.new(rows, &{&1.label, &1})

      assert by_label["Old evidence"].request_status == "superseded"
      assert by_label["Old evidence"].review_request_id == superseded.id
      assert by_label["New evidence"].request_status == "pending"
    end

    test "orders ruled items ahead of undispositioned ones", ctx do
      request = create_request(ctx, ["Ruled", "Untouched"])
      ruled = Enum.find(request.items, &(&1.label == "Ruled"))
      {:ok, _} = ReviewRequests.approve_item(ruled.id, "alex")

      assert ["Ruled", "Untouched"] =
               ctx.task.id |> ReviewRequests.list_items_for_task() |> Enum.map(& &1.label)
    end

    test "returns [] for a task with zero requests", ctx do
      assert ReviewRequests.list_items_for_task(ctx.task.id) == []
    end

    test "returns [] for unknown and malformed ids without raising" do
      assert ReviewRequests.list_items_for_task(Ecto.UUID.generate()) == []
      assert ReviewRequests.list_items_for_task("not-a-uuid") == []
      assert ReviewRequests.list_items_for_task(nil) == []
    end
  end
end
