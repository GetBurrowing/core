defmodule Platform.Orchestration.ReviewRequestInboxTest do
  @moduledoc """
  Producer coverage for the review-gate → task-SPONSOR inbox seam.

  Rowan's directives (inbox hardening):

    * review items route to the task's **sponsor** (the human who owns the
      task), NOT the review-phase technical assignee (an agent on agent-run
      tasks — the old routing emitted nothing);
    * they **roll up per task**: at most ONE `review_request_pending` inbox row
      per `(sponsor, task)`, keyed `source_type: "task_review"` /
      `source_id: task.id`, no matter how many review gates the task fans out;
    * the row is dismissed only when the task has NO remaining pending review
      requests — resolving a non-last gate leaves it.

  Agent-only / sponsor-less tasks, self-reviews (sponsor == submitter) and
  already-resolved requests emit nothing — the inbox is a human,
  pending-decision surface.
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  # Build a task with `sponsor` as its ADR-0042 sponsor and a manual_approval
  # validation on a started stage. The sponsor is stamped via a direct
  # Repo.update so the `task_sponsor_assigned` producer (which fires on
  # Tasks.create_task/update_task) never pollutes the reviewer's inbox — this
  # test isolates the review-gate producer.
  defp setup_task(sponsor, opts \\ []) do
    position = Keyword.get(opts, :position, 2)
    {:ok, project} = Tasks.create_project(%{name: "Inbox Review Project"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ship the thing"})

    task =
      task
      |> Ecto.Changeset.change(sponsor_user_id: sponsor && sponsor.id)
      |> Repo.update!()

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    validation = add_validation(plan, position)

    %{task: task, plan: plan, validation: validation}
  end

  # Add another started stage + manual_approval validation to an existing plan,
  # so a task can carry several independent review gates (rollup coverage).
  defp add_validation(plan, position) do
    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: position, name: "Stage #{position}"})

    {:ok, _} = PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})
    validation
  end

  defp create_request(validation, task, opts) do
    labels = Keyword.get(opts, :labels, ["Desktop", "Mobile"])
    extra = Keyword.get(opts, :attrs, %{})

    attrs =
      Map.merge(
        %{
          validation_id: validation.id,
          task_id: task.id,
          items: Enum.map(labels, &%{label: &1})
        },
        extra
      )

    ReviewRequests.create_review_request(attrs)
  end

  defp inbox_rows(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id))
  end

  # ── Emit → sponsor ───────────────────────────────────────────────────────

  describe "create_review_request/1 — routes to the task sponsor" do
    test "inserts exactly one rolled-up inbox row addressed to the sponsor and broadcasts it" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)
      :ok = Inbox.subscribe(sponsor.id)

      assert {:ok, _request} =
               create_request(ctx.validation, ctx.task, attrs: %{submitted_by: "some-agent"})

      rows = inbox_rows(sponsor.id)
      assert length(rows) == 1
      [item] = rows

      assert item.kind == "review_request_pending"
      # Per-task rollup — keyed on the TASK, not the review request.
      assert item.source_type == "task_review"
      assert item.source_id == ctx.task.id
      assert item.title == "Review awaiting you: Ship the thing"
      assert item.body =~ "Requested by"
      # Deep-links to the task detail (where all its reviews live), not a
      # per-request anchor.
      assert item.url == "/tasks/#{ctx.task.id}"

      assert_receive {:inbox_item_added, %Item{source_type: "task_review", source_id: sid}}, 500
      assert sid == ctx.task.id
    end

    test "no inbox row is created for any other user (e.g. the review-phase assignee)" do
      sponsor = insert_user()
      bystander = insert_user()
      ctx = setup_task(sponsor)

      {:ok, _} = create_request(ctx.validation, ctx.task, attrs: %{submitted_by: "some-agent"})

      assert inbox_rows(bystander.id) == []
    end
  end

  describe "create_review_request/1 — per-task rollup" do
    test "a second review request on the SAME task emits NO new row (one row total)" do
      sponsor = insert_user()
      ctx = setup_task(sponsor, position: 1)
      second_validation = add_validation(ctx.plan, 2)

      {:ok, _r1} = create_request(ctx.validation, ctx.task, attrs: %{submitted_by: "agent-a"})
      assert length(inbox_rows(sponsor.id)) == 1

      {:ok, _r2} = create_request(second_validation, ctx.task, attrs: %{submitted_by: "agent-b"})

      # Still exactly one row — the second gate folded into the rollup.
      assert length(inbox_rows(sponsor.id)) == 1
    end
  end

  describe "create_review_request/1 — skip conditions" do
    test "sponsor-less task inserts no inbox row" do
      ctx = setup_task(nil)

      assert {:ok, _} =
               create_request(ctx.validation, ctx.task, attrs: %{submitted_by: "executor-agent"})

      assert Repo.aggregate(from(i in Item), :count) == 0
    end

    test "self-review (sponsor == submitted_by) inserts no inbox row" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)

      assert {:ok, _} =
               create_request(ctx.validation, ctx.task, attrs: %{submitted_by: sponsor.id})

      assert inbox_rows(sponsor.id) == []
    end

    test "non-pending (already-resolved) request inserts no inbox row" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)

      assert {:ok, request} =
               create_request(ctx.validation, ctx.task,
                 attrs: %{submitted_by: "some-agent", status: "resolved"}
               )

      assert request.status == "resolved"
      assert inbox_rows(sponsor.id) == []
    end
  end

  # ── Dismiss on task-review completion ────────────────────────────────────

  describe "resolve dismisses the rolled-up sponsor row" do
    test "resolving the LAST pending review request dismisses the row" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)

      {:ok, request} =
        create_request(ctx.validation, ctx.task,
          labels: ["A", "B"],
          attrs: %{submitted_by: "some-agent"}
        )

      assert [item] = inbox_rows(sponsor.id)
      assert is_nil(item.dismissed_at)

      for it <- request.items, do: {:ok, _} = ReviewRequests.approve_item(it.id, sponsor.id)

      [dismissed] = inbox_rows(sponsor.id)
      assert %DateTime{} = dismissed.dismissed_at
      assert Inbox.list_unread_for_user(sponsor.id) == []
    end

    test "resolving a NON-last gate leaves the row; resolving the last then dismisses it" do
      sponsor = insert_user()
      ctx = setup_task(sponsor, position: 1)
      second_validation = add_validation(ctx.plan, 2)

      {:ok, r1} =
        create_request(ctx.validation, ctx.task, labels: ["A"], attrs: %{submitted_by: "agent-a"})

      {:ok, r2} =
        create_request(second_validation, ctx.task,
          labels: ["B"],
          attrs: %{submitted_by: "agent-b"}
        )

      assert [row] = inbox_rows(sponsor.id)
      assert is_nil(row.dismissed_at)

      # Resolve the first gate — a second gate is still pending, so the
      # rolled-up row must SURVIVE.
      {:ok, _} = ReviewRequests.approve_item(hd(r1.items).id, sponsor.id)
      assert [still_live] = inbox_rows(sponsor.id)
      assert is_nil(still_live.dismissed_at)

      # Resolve the last gate — now no pending reviews remain, so the row is
      # dismissed.
      {:ok, _} = ReviewRequests.approve_item(hd(r2.items).id, sponsor.id)
      assert [dismissed] = inbox_rows(sponsor.id)
      assert %DateTime{} = dismissed.dismissed_at
      assert Inbox.list_unread_for_user(sponsor.id) == []
    end

    test "rejecting the last gate's item also dismisses the row" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)

      {:ok, request} =
        create_request(ctx.validation, ctx.task,
          labels: ["A", "B"],
          attrs: %{submitted_by: "some-agent"}
        )

      assert [_pending] = Inbox.list_unread_for_user(sponsor.id)

      {:ok, _} = ReviewRequests.reject_item(hd(request.items).id, sponsor.id, "Needs work")

      [dismissed] = inbox_rows(sponsor.id)
      assert %DateTime{} = dismissed.dismissed_at
      assert Inbox.list_unread_for_user(sponsor.id) == []
    end

    test "resolving does not touch another user's or another source's rows" do
      sponsor = insert_user()
      other = insert_user()
      ctx = setup_task(sponsor)

      {:ok, keep_sponsor} =
        Inbox.emit(%{
          user_id: sponsor.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "unrelated"
        })

      {:ok, keep_other} =
        Inbox.emit(%{
          user_id: other.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "unrelated"
        })

      {:ok, request} =
        create_request(ctx.validation, ctx.task,
          labels: ["A"],
          attrs: %{submitted_by: "some-agent"}
        )

      {:ok, _} = ReviewRequests.approve_item(hd(request.items).id, sponsor.id)

      assert is_nil(Repo.get!(Item, keep_sponsor.id).dismissed_at)
      assert is_nil(Repo.get!(Item, keep_other.id).dismissed_at)
    end
  end

  # ── Helper predicates ────────────────────────────────────────────────────

  describe "task_has_pending_reviews?/1" do
    test "reflects pending → resolved transitions" do
      sponsor = insert_user()
      ctx = setup_task(sponsor)

      refute ReviewRequests.task_has_pending_reviews?(ctx.task.id)

      {:ok, request} =
        create_request(ctx.validation, ctx.task,
          labels: ["A"],
          attrs: %{submitted_by: "some-agent"}
        )

      assert ReviewRequests.task_has_pending_reviews?(ctx.task.id)

      {:ok, _} = ReviewRequests.approve_item(hd(request.items).id, sponsor.id)
      refute ReviewRequests.task_has_pending_reviews?(ctx.task.id)
    end
  end

  describe "Inbox.dismiss_by_source/3" do
    test "is a no-op returning {:ok, 0} when no matching row exists" do
      user = insert_user()
      assert {:ok, 0} = Inbox.dismiss_by_source(user.id, "task_review", Ecto.UUID.generate())
    end

    test "dismisses every matching non-dismissed row exactly once" do
      user = insert_user()
      source_id = Ecto.UUID.generate()

      {:ok, item} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "review_request_pending",
          source_type: "task_review",
          source_id: source_id,
          title: "pending review"
        })

      assert {:ok, 1} = Inbox.dismiss_by_source(user.id, "task_review", source_id)
      assert %DateTime{} = Repo.get!(Item, item.id).dismissed_at

      assert {:ok, 0} = Inbox.dismiss_by_source(user.id, "task_review", source_id)
    end
  end
end
