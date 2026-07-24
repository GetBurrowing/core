defmodule Platform.Orchestration.ReviewRequestInboxTest do
  @moduledoc """
  Producer coverage for the review_request → reviewer inbox seam (M4).

  Creating a review request for a *human* reviewer inserts exactly one durable
  `Inbox.Item` addressed to that reviewer; resolving the request (approve-all or
  reject) dismisses it. Agent reviewers, self-reviews, and already-resolved
  requests emit nothing — the inbox is a human, pending-decision surface.
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

  # Build a task whose review-phase assignee is `{type, id}`, with a
  # manual_approval validation on a stage at `position`.
  defp setup_task(assignee_type, assignee_id, position) do
    {:ok, project} = Tasks.create_project(%{name: "Inbox Review Project"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Ship the thing",
        phase_assignees: %{
          "review" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    %{task: task, stage: stage, validation: validation}
  end

  defp create_request(ctx, opts) do
    labels = Keyword.get(opts, :labels, ["Desktop", "Mobile"])
    extra = Keyword.get(opts, :attrs, %{})

    attrs =
      Map.merge(
        %{
          validation_id: ctx.validation.id,
          task_id: ctx.task.id,
          items: Enum.map(labels, &%{label: &1})
        },
        extra
      )

    ReviewRequests.create_review_request(attrs)
  end

  defp inbox_rows(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id))
  end

  # ── Stage 1: emit on create ──────────────────────────────────────────────

  describe "create_review_request/1 — human reviewer" do
    test "inserts exactly one inbox row with the correct fields and broadcasts it" do
      reviewer = insert_user()
      ctx = setup_task("user", reviewer.id, 2)
      :ok = Inbox.subscribe(reviewer.id)

      assert {:ok, request} =
               create_request(ctx,
                 labels: ["Desktop", "Mobile"],
                 attrs: %{submitted_by: "some-agent"}
               )

      rows = inbox_rows(reviewer.id)
      assert length(rows) == 1
      [item] = rows

      assert item.kind == "review_request_pending"
      assert item.source_type == "review_request"
      assert item.source_id == request.id
      assert item.title == "Review request: Ship the thing · Stage 2"
      assert item.body =~ "Items: 2"
      assert item.url == "/tasks/#{ctx.task.id}#review-#{request.id}"

      assert_receive {:inbox_item_added, %Item{source_id: sid}}, 500
      assert sid == request.id
    end

    test "body carries the requester display name (user name)" do
      reviewer = insert_user()
      requester = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      {:ok, _request} = create_request(ctx, attrs: %{submitted_by: requester.id})

      [item] = inbox_rows(reviewer.id)
      assert item.body =~ requester.name
    end

    test "no inbox row is created for any other user" do
      reviewer = insert_user()
      bystander = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      {:ok, _} = create_request(ctx, attrs: %{submitted_by: "some-agent"})

      assert inbox_rows(bystander.id) == []
    end
  end

  describe "create_review_request/1 — skip conditions" do
    test "agent reviewer inserts no inbox row" do
      agent_id = Ecto.UUID.generate()
      ctx = setup_task("agent", agent_id, 2)

      assert {:ok, _request} = create_request(ctx, attrs: %{submitted_by: "executor-agent"})

      # No inbox rows exist at all for the (non-user) agent id.
      assert Repo.aggregate(from(i in Item), :count) == 0
    end

    test "self-review (reviewer == submitted_by) inserts no inbox row" do
      reviewer = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      assert {:ok, _request} = create_request(ctx, attrs: %{submitted_by: reviewer.id})

      assert inbox_rows(reviewer.id) == []
    end

    test "non-pending (already-resolved) request inserts no inbox row" do
      reviewer = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      assert {:ok, request} =
               create_request(ctx, attrs: %{submitted_by: "some-agent", status: "resolved"})

      assert request.status == "resolved"
      assert inbox_rows(reviewer.id) == []
    end
  end

  # ── Stage 2: dismiss on resolve ──────────────────────────────────────────

  describe "resolve dismisses the reviewer inbox row" do
    test "approving all items dismisses the reviewer's inbox row" do
      reviewer = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      {:ok, request} =
        create_request(ctx, labels: ["A", "B"], attrs: %{submitted_by: "some-agent"})

      assert [item] = inbox_rows(reviewer.id)
      assert is_nil(item.dismissed_at)

      for it <- request.items do
        {:ok, _} = ReviewRequests.approve_item(it.id, reviewer.id)
      end

      [dismissed] = inbox_rows(reviewer.id)
      assert %DateTime{} = dismissed.dismissed_at
      assert Inbox.list_unread_for_user(reviewer.id) == []
    end

    test "rejecting an item dismisses the reviewer's inbox row" do
      reviewer = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      {:ok, request} =
        create_request(ctx, labels: ["A", "B"], attrs: %{submitted_by: "some-agent"})

      assert [_pending] = Inbox.list_unread_for_user(reviewer.id)

      {:ok, _} = ReviewRequests.reject_item(hd(request.items).id, reviewer.id, "Needs work")

      [dismissed] = inbox_rows(reviewer.id)
      assert %DateTime{} = dismissed.dismissed_at
      assert Inbox.list_unread_for_user(reviewer.id) == []
    end

    test "resolving does not touch another user's or another source's rows" do
      reviewer = insert_user()
      other = insert_user()
      ctx = setup_task("user", reviewer.id, 2)

      # An unrelated inbox row for the reviewer (different source) and one for
      # another user must survive dismissal.
      {:ok, keep_reviewer} =
        Inbox.emit(%{
          user_id: reviewer.id,
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

      {:ok, request} = create_request(ctx, labels: ["A"], attrs: %{submitted_by: "some-agent"})
      {:ok, _} = ReviewRequests.approve_item(hd(request.items).id, reviewer.id)

      assert is_nil(Repo.get!(Item, keep_reviewer.id).dismissed_at)
      assert is_nil(Repo.get!(Item, keep_other.id).dismissed_at)
    end
  end

  describe "Inbox.dismiss_by_source/3" do
    test "is a no-op returning {:ok, 0} when no matching row exists" do
      user = insert_user()
      assert {:ok, 0} = Inbox.dismiss_by_source(user.id, "review_request", Ecto.UUID.generate())
    end

    test "dismisses every matching non-dismissed row exactly once" do
      user = insert_user()
      source_id = Ecto.UUID.generate()

      {:ok, item} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "review_request_pending",
          source_type: "review_request",
          source_id: source_id,
          title: "pending review"
        })

      assert {:ok, 1} = Inbox.dismiss_by_source(user.id, "review_request", source_id)
      assert %DateTime{} = Repo.get!(Item, item.id).dismissed_at

      # Idempotent — a second call matches nothing.
      assert {:ok, 0} = Inbox.dismiss_by_source(user.id, "review_request", source_id)
    end
  end
end
