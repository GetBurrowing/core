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

  # ── PubSub broadcasts ───────────────────────────────────────────────────

  describe "PubSub broadcasts" do
    test "subscribe_for_task/1 receives :review_request_pending on create", ctx do
      :ok = ReviewRequests.subscribe_for_task(ctx.task.id)

      assert {:ok, request} = create_request(ctx, ["Desktop"])

      assert_receive {:review_request_pending,
                      %{
                        task_id: task_id,
                        validation_id: validation_id,
                        request_id: request_id
                      }},
                     500

      assert task_id == ctx.task.id
      assert validation_id == ctx.validation.id
      assert request_id == request.id
    end

    test ":review_request_resolved fires with outcome :passed when all items approved", ctx do
      {:ok, request} = create_request(ctx, ["A", "B"])
      :ok = ReviewRequests.subscribe_for_task(ctx.task.id)

      for item <- request.items do
        {:ok, _} = ReviewRequests.approve_item(item.id, "rowan")
      end

      assert_receive {:review_request_resolved, %{outcome: :passed, request_id: rid}}, 500
      assert rid == request.id
    end

    test ":review_request_resolved fires with outcome :failed when an item is rejected", ctx do
      {:ok, request} = create_request(ctx, ["Desktop", "Mobile"])
      :ok = ReviewRequests.subscribe_for_task(ctx.task.id)

      [item | _] = request.items
      {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", "Needs work")

      assert_receive {:review_request_resolved, %{outcome: :failed, request_id: rid}}, 500
      assert rid == request.id
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

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: review ids are phx-value- params" do
    @slug_16 "higginshigginsxx"

    test "get_review_request/1 returns nil for a malformed id" do
      assert ReviewRequests.get_review_request(@slug_16) == nil
      assert ReviewRequests.get_review_request("higgins") == nil
    end

    test "approving a malformed item id reports :not_found rather than raising" do
      assert {:error, :not_found} = ReviewRequests.approve_item(@slug_16, "someone")
    end
  end

  # ── Requester attribution (task 019fa129 stage 5) ────────────────────────
  #
  # `requester_display_name/1` is private; its only observable output is the
  # `"Requested by …"` body of the sponsor's `review_request_pending` inbox
  # row, so that is what these assert.
  #
  # Why this is a BEHAVIOUR suite and not a "does not raise" suite. Before this
  # stage the function ended in a bare `rescue _ -> submitted_by`, and both
  # lookups raised `Ecto.Query.CastError` on a non-UUID `submitted_by`. The
  # rescue therefore did not merely absorb a crash — it silently degraded the
  # OUTPUT: an agent-filed review rendered as the raw slug. The slug cases below
  # are red on `main` and green here, which is the evidence the rescue was
  # hiding a defect rather than guarding against one.
  #
  # The two arms are sequential arms of a `cond`, not nested calls, so the
  # stage-4 "inner guard absorbs the input" hazard does not apply:
  # `Accounts.get_user/1` is total and returns nil for a slug, which is exactly
  # what lets control REACH the Agent arm. Reverting the Agent-arm guard is
  # detectable here whether or not the rescue comes back with it.
  describe "requester attribution on the sponsor inbox row" do
    setup ctx do
      sponsor =
        Repo.insert!(%Platform.Accounts.User{
          name: "Sponsor Human",
          email: "sponsor-#{uniq()}@example.com",
          oidc_sub: "sub-sponsor-#{uniq()}"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: ctx.project.id,
          title: "Sponsored review task",
          sponsor_user_id: sponsor.id
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      %{sponsor: sponsor, sponsored_task: task, sponsored_plan: plan}
    end

    test "an agent SLUG renders the agent's display name, not the raw slug", ctx do
      agent = insert_agent("higgins-#{uniq()}", "Higgins Moon")

      assert requested_by(ctx, agent.slug) == "Higgins Moon"
      refute requested_by(ctx, agent.slug) == agent.slug
    end

    test "a 16-CHARACTER agent slug also renders the display name", ctx do
      # The discriminating case for the guard's PREDICATE, distinct from the
      # case above. `Ecto.UUID.cast/1` hex-encodes any 16-byte binary and
      # returns `{:ok, _}`, so a bare-cast guard routes a 16-character slug to
      # the UUID branch and `Repo` raises against Agent's strict UUIDv7 PK. A
      # suite built only from `"higgins"` is fully green against that
      # simplification; this one is not.
      slug = "higginshigginsxx"
      assert byte_size(slug) == 16
      assert {:ok, _} = Ecto.UUID.cast(slug)

      agent = insert_agent(slug, "Higgins Sixteen")
      assert requested_by(ctx, agent.slug) == "Higgins Sixteen"
    end

    # NOT covered, deliberately: `agent.name || agent.slug` and
    # `user.name || user.email`. Both `agents.name` and `users.name` carry a
    # NOT NULL constraint, so neither `||` fallback is reachable — an insert
    # with `name: nil` fails at the DB, not at the display function. Writing a
    # test that asserted the fallback would mean weakening the fixture until it
    # proved nothing. Recorded here rather than left as a silent gap.

    test "\"system:auto\" is returned unchanged, with no raise and no logged DB error", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert requested_by(ctx, "system:auto") == "system:auto"
        end)

      # The outer `rescue` in maybe_emit_reviewer_inbox/1 is the only thing that
      # logs here. If the Agent arm raised, the row would be missing AND this
      # warning would appear — so asserting both pins the mechanism, not just
      # the symptom.
      refute log =~ "failed to emit sponsor inbox row"
      refute log =~ "CastError"
    end

    test "an existing user's UUID still renders their name (no regression)", ctx do
      other =
        Repo.insert!(%Platform.Accounts.User{
          name: "Requesting Human",
          email: "requester-#{uniq()}@example.com",
          oidc_sub: "sub-requester-#{uniq()}"
        })

      assert requested_by(ctx, other.id) == "Requesting Human"
    end

    test "a valid-but-absent UUID returns the raw id", ctx do
      absent = Ecto.UUID.generate()
      assert requested_by(ctx, absent) == absent
    end
  end

  # Submit one review request as `submitted_by` and return the requester
  # substring of the sponsor's inbox row. Each call builds a fresh stage +
  # validation because `maybe_emit_reviewer_inbox/1` rolls up per
  # (sponsor, task) and emits at most one LIVE row — so the previous row is
  # dismissed before returning.
  defp requested_by(ctx, submitted_by) do
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: ctx.sponsored_plan.id,
        position: System.unique_integer([:positive, :monotonic]),
        name: "UI #{uniq()}"
      })

    {:ok, _} = PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, _request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: ctx.sponsored_task.id,
        submitted_by: submitted_by,
        items: [%{label: "Evidence"}]
      })

    case Platform.Inbox.list_unread_for_user(ctx.sponsor.id, kind: "review_request_pending") do
      [row | _] ->
        Platform.Inbox.mark_dismissed(row.id, ctx.sponsor.id)

        case row.body do
          "Requested by " <> requester -> requester
          other -> flunk("unexpected inbox body: #{inspect(other)}")
        end

      [] ->
        flunk("""
        no review_request_pending inbox row was emitted for submitted_by=#{inspect(submitted_by)}.

        The most likely cause is that requester_display_name/1 raised and the
        outer `rescue` in maybe_emit_reviewer_inbox/1 swallowed the whole
        emission — i.e. the Agent-arm guard is missing.
        """)
    end
  end

  defp insert_agent(slug, name) do
    Repo.insert!(%Platform.Agents.Agent{slug: slug, name: name, status: "active"})
  end

  defp uniq, do: System.unique_integer([:positive])
end
