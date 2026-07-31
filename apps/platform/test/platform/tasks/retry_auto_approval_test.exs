defmodule Platform.Tasks.RetryAutoApprovalTest do
  @moduledoc """
  Task 019fa605 stage 3 — healing a lost deferred approval tail, and the
  refusal set that keeps that from becoming a governance failure.

  ## The two shapes, and why only one of them is this file's business

  Stage 1 heals a plan whose verdict ROW still reads `"pending"` while
  `architecture_gate/1` already projects it expired. This file covers the
  shape one step further down: a verdict already COMMITTED terminal on a plan
  still sitting at `pending_review` with the auto flag armed, because the
  deferred `settle_plan_submission/1` tail was lost between the verdict write
  and the approval.

  That the tail can be lost is a property of this repo, not a hypothetical:
  `write_architecture_verdict/4`'s `Repo.update_all` commits BEFORE
  `resolve_architecture_gate/3` calls `settle_resolved_architecture_gate/2`,
  and both writers of `:expired` sit where a raise in the tail is swallowed
  and never retried (the reconcile tick's `rescue` envelope around
  `sweep_expired_architecture_gates/0`, and `TaskRouter`'s `handle_info`).

  ## THE REFUSAL SET IS THE DELIVERABLE

  `ArchitectureRejection.handle/1` leaves an architect-REJECTED,
  human-escalated plan UNTOUCHED at `pending_review` — byte-identical in
  `plans.status` to the stall. An arm keyed on "pending_review + terminal
  verdict" would auto-approve a plan an architect explicitly rejected. That
  case is built here with REAL machinery (two rounds through
  `Tasks.resolve_architecture_gate(_, :reject, _)` until
  `ArchitectureRejection.escalation_due?/1` fires) rather than a fabricated
  verdict row, because a hand-built row is the exact failure mode where
  careful tests pass against a shape production never sends.

  ## `"passed"` is REFUSED, and this stage was specified to retry it

  See `Tasks.retry_auto_approval/1`'s @doc for the full argument. The short
  form: no writer of `:pass` can lose the tail (the MCP verdict tool is a
  synchronous request, not a swallowed timer), and a `passed` plan has no
  `planning_gate_failed?/1` record to contain a mistaken retry — it would run
  unattended to merge. `"passed"` is pinned refused BELOW, paired with an
  otherwise-identical `"expired"` fixture that DOES approve, so the
  assertion is measuring the verdict state and not a constant.

  ## The invariant that must survive

  Approving must not erase the record that nobody reviewed it. Every
  approval assertion here is a CONJUNCTION with the verdict being
  byte-identical afterwards and `planning_gate_failed?/1` still true. Stage 2
  proved why: pointing the settler at `:pass` instead of `:expired` left
  `status == "approved"` and `auto_approved_at` both green, and only the
  verdict assertions caught it.

  ## Fixture arming is part of the test, not of the setup

  `maybe_auto_approve/1` no-ops SILENTLY unless armed, so `assert_armed!/2`
  runs inline in every test whose outcome depends on the auto path, and every
  outcome is keyed on `auto_approved_at` — never on `approved_by` alone.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Inbox
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ArchitectureRejection, Plan, Stacks, Stage, Task}

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Retry Auto Approval #{u()}"})
    %{project: project}
  end

  # ── fixtures (same discipline as stages 1 and 2) ───────────────────────

  defp sponsor_fixture do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "retry-sponsor-#{n}@example.com",
      oidc_sub: "retry-sub-#{n}"
    })
  end

  # THE LOAD-BEARING FIXTURE DETAIL: `assignee_type: "user"` on the PLANNING
  # phase. Against an agent-assigned task a router exists and settles the row
  # itself, and this file would exercise a path the defect does not live on.
  defp task_fixture(project, opts) do
    assignee_type = Keyword.get(opts, :assignee_type, "user")
    assignee_id = Keyword.get(opts, :assignee_id, Ecto.UUID.generate())

    attrs = %{
      project_id: project.id,
      title: "Retry auto approval fixture #{u()}",
      status: "planning",
      auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
      assignee_type: assignee_type,
      assignee_id: assignee_id,
      phase_assignees: %{
        "planning" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type},
        "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
        "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      }
    }

    attrs =
      attrs
      |> maybe_put(:sponsor_user_id, Keyword.get(opts, :sponsor_user_id))

    {:ok, task} = Tasks.create_task(attrs)
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    unless Keyword.get(opts, :empty_plan, false) do
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
    end

    {task, plan}
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    {:ok, _task} = Tasks.record_planning_step(task.id, :architecture, {:ok, :dispatched})
    gated
  end

  # THE CRASH SHAPE. A verdict committed terminal with the tail never run —
  # what `write_architecture_verdict/4` leaves behind when the settlement
  # raises after its `Repo.update_all` commits. Written through
  # `Repo.update_all` for exactly that reason: routing it through
  # `resolve_architecture_gate/3` would RUN the tail, which is the thing this
  # fixture must not do.
  #
  # `record_planning_step(:architecture, {:error, :expired})` is included
  # because the real `:expired` clause records it BEFORE settling, so a
  # fixture without it would let the `planning_gate_failed?/1` half of every
  # invariant assertion pass for the wrong reason.
  defp lose_the_tail!(task, %Plan{} = plan, opts \\ []) do
    state = Keyword.get(opts, :state, "expired")

    verdict =
      Repo.get!(Plan, plan.id).architecture_verdict
      |> Map.merge(%{
        "state" => state,
        "source" => Keyword.get(opts, :source, "deadline"),
        "resolved_at" =>
          DateTime.utc_now()
          |> DateTime.add(-Keyword.get(opts, :resolved_seconds_ago, 3600), :second)
          |> DateTime.to_iso8601()
      })

    {1, _} =
      Plan
      |> where([p], p.id == ^plan.id)
      |> Repo.update_all(set: [architecture_verdict: verdict])

    if state in ["expired", "dispatch_failed"] do
      {:ok, _} =
        Tasks.record_planning_step(task.id, :architecture, {:error, String.to_atom(state)})
    end

    Repo.get!(Plan, plan.id)
  end

  # An armed, router-less plan whose gate resolved terminally and whose tail
  # was lost. The default shape this file heals.
  defp armed_lost_tail!(project, opts \\ []) do
    {task, plan} = task_fixture(project, Keyword.put_new(opts, :auto_approve_plan, true))
    gated = open_gate!(task, plan)
    _ = lose_the_tail!(task, gated, opts)
    {task, plan}
  end

  # Push `plans.updated_at` back so the sweep's 15-minute debounce admits the
  # row. Separate from the verdict write because the debounce and the verdict
  # are independent facts, and a test that needs one rarely needs the other.
  defp backdate_plan!(%Plan{} = plan, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

    {1, _} =
      Plan
      |> where([p], p.id == ^plan.id)
      |> Repo.update_all(set: [updated_at: at])

    Repo.get!(Plan, plan.id)
  end

  defp reload(%Plan{id: id}), do: Repo.get!(Plan, id)
  defp reload(%Task{id: id}), do: Repo.get!(Task, id)

  # Arming is asserted, never assumed. See the moduledoc.
  defp assert_armed!(%Task{} = task, %Plan{} = plan) do
    task = reload(task)
    assert task.auto_approve_plan
    assert task.phase_assignees["execution"]["assignee_id"]
    assert task.phase_assignees["review"]["assignee_id"]
    assert [_stage] = Repo.all(from(s in Stage, where: s.plan_id == ^plan.id))
    :ok
  end

  # THE INVARIANT. An approval that erased the record of the missing review
  # would satisfy the liveness half alone; both halves are required.
  defp assert_approved_without_erasing_the_record!(task, plan, verdict_before) do
    settled = reload(plan)

    assert settled.status == "approved"
    assert settled.auto_approved_at
    assert settled.approved_by == "system:auto"

    # BYTE-IDENTICAL. The retry re-runs the tail; it must not re-enter the
    # gate exit. A changed `resolved_at` would mean it did.
    assert settled.architecture_verdict == verdict_before

    assert Tasks.planning_gate_failed?(reload(task))

    assert [%{step: "architecture", detail: detail}] = Tasks.failed_planning_steps(reload(task))
    assert detail =~ "expired" or detail =~ "dispatch_failed"
  end

  # ── the happy path, conjoined with the invariant ───────────────────────

  describe "retry_auto_approval/1 re-runs a lost tail" do
    test "armed + expired + pending_review approves without touching the gate", %{
      project: project
    } do
      {task, plan} = armed_lost_tail!(project)
      assert_armed!(task, plan)

      # Pre-state: terminal verdict, plan still waiting, nobody approved it.
      before = reload(plan)
      assert before.status == "pending_review"
      assert before.architecture_verdict["state"] == "expired"
      assert before.architecture_verdict["source"] == "deadline"
      assert is_binary(before.architecture_verdict["resolved_at"])
      refute before.auto_approved_at
      refute TaskRouterWatcher.should_run?(reload(task))

      assert {:ok, :approved} = Tasks.retry_auto_approval(plan.id)

      assert_approved_without_erasing_the_record!(task, plan, before.architecture_verdict)
    end

    test "a dispatch_failed verdict is healed on the same terms", %{project: project} do
      {task, plan} =
        armed_lost_tail!(project, state: "dispatch_failed", source: "handle_output")

      assert_armed!(task, plan)
      before = reload(plan)
      assert before.architecture_verdict["state"] == "dispatch_failed"

      assert {:ok, :approved} = Tasks.retry_auto_approval(plan.id)
      assert_approved_without_erasing_the_record!(task, plan, before.architecture_verdict)
    end

    test "accepts a %Plan{} and re-reads it, so a stale struct cannot decide", %{
      project: project
    } do
      {task, plan} = armed_lost_tail!(project)
      assert_armed!(task, plan)

      # A struct loaded BEFORE the gate resolved: its verdict still reads
      # `"pending"`. Deciding off this struct would refuse (`:gate_open`).
      stale = %Plan{plan | architecture_verdict: %{"state" => "pending"}, status: "draft"}

      assert {:ok, :approved} = Tasks.retry_auto_approval(stale)
      assert reload(plan).status == "approved"
    end

    test "does NOT emit a second sponsor Inbox row (it must not re-enter settle_plan_submission/1)",
         %{project: project} do
      sponsor = sponsor_fixture()

      # Built through REAL machinery: an UNARMED task whose gate expires
      # emits the sponsor's plan-review row at settle time (stage 2 case c).
      # Arming the task afterwards is what a human flipping the flag does.
      {task, plan} = task_fixture(project, sponsor_user_id: sponsor.id)
      gated = open_gate!(task, plan)
      {:ok, _} = Tasks.resolve_architecture_gate(gated, :expired)

      rows_before = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")
      assert length(rows_before) == 1
      assert reload(plan).status == "pending_review"

      {:ok, _task} = Tasks.update_task(task, %{auto_approve_plan: true})
      assert_armed!(task, plan)

      assert {:ok, :approved} = Tasks.retry_auto_approval(plan.id)

      assert reload(plan).auto_approved_at

      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == rows_before
    end

    test "the stack auto_accept_plan twin is healed by the same arm", %{project: project} do
      slug = "retry-stack-#{u()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Retry stack #{slug}",
          base_branch: "main",
          rollup_branch: Stacks.rollup_branch_name(slug),
          auto_accept_plan: true
        })

      {task, plan} = task_fixture(project, auto_approve_plan: false)
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      gated = open_gate!(task, plan)
      _ = lose_the_tail!(task, gated)

      # POSITIVE CONTROL that the STACK arm fires and not the task arm.
      assert reload(task).auto_approve_plan == false
      assert Repo.preload(reload(task), :stack).stack.auto_accept_plan == true

      handler = "retry-stack-#{u()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :plan, :auto_approved],
        fn _e, _m, meta, _c -> send(test_pid, {:auto_approved, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      before = reload(plan)
      assert {:ok, :approved} = Tasks.retry_auto_approval(plan.id)

      assert_receive {:auto_approved, %{via: :stack}}
      assert_approved_without_erasing_the_record!(task, plan, before.architecture_verdict)
    end
  end

  # ── THE REFUSAL SET ────────────────────────────────────────────────────

  describe "retry_auto_approval/1 refuses" do
    # THE LOAD-BEARING CASE. Built with real machinery: two rounds through
    # the gate until `escalation_due?/1` fires and `escalate/2` leaves the
    # plan untouched at `pending_review`.
    test "an architect-rejected, human-escalated plan — never auto-approved", %{
      project: project
    } do
      {task, v1} =
        task_fixture(project, auto_approve_plan: true, sponsor_user_id: sponsor_fixture().id)

      g1 = open_gate!(task, v1)

      {:ok, _} =
        Tasks.resolve_architecture_gate(g1, :reject,
          source: "mcp",
          findings: [%{"constraint" => "module_boundary", "detail" => "round one"}]
        )

      # Round one is BELOW the bound: feedback, and the plan is rejected.
      assert reload(v1).architecture_verdict["state"] == "rejected"
      assert ArchitectureRejection.streak(task.id) == 1

      {:ok, v2} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: v2.id, position: 1, name: "S1"})
      g2 = open_gate!(task, v2)

      {:ok, _} =
        Tasks.resolve_architecture_gate(g2, :reject,
          source: "mcp",
          findings: [%{"constraint" => "module_boundary", "detail" => "round two"}]
        )

      # AT the bound. `escalate/2` returned the plan UNTOUCHED — this row is
      # byte-identical in `plans.status` to the stall being healed.
      assert ArchitectureRejection.streak(task.id) >= ArchitectureRejection.reject_limit()
      assert ArchitectureRejection.escalation_due?(task.id)

      escalated = reload(v2)
      assert escalated.status == "pending_review"
      assert escalated.architecture_verdict["state"] == "rejected"
      refute escalated.auto_approved_at

      # The task IS armed — so nothing but the refusal set is standing
      # between this plan and an auto-approval.
      assert_armed!(task, v2)

      assert {:ok, :noop, :architect_rejected} = Tasks.retry_auto_approval(v2.id)

      after_retry = reload(v2)
      assert after_retry.status == "pending_review"
      assert after_retry.architecture_verdict["state"] == "rejected"
      assert after_retry.architecture_verdict == escalated.architecture_verdict
      refute after_retry.auto_approved_at
      refute after_retry.approved_by
    end

    test "a passed gate — and an otherwise-identical expired one is approved", %{
      project: project
    } do
      # PAIRED, in one test, so the assertion measures the verdict state and
      # not a constant. Everything else about these two fixtures is equal.
      {passed_task, passed_plan} =
        armed_lost_tail!(project, state: "passed", source: "mcp")

      {expired_task, expired_plan} = armed_lost_tail!(project)

      assert_armed!(passed_task, passed_plan)
      assert_armed!(expired_task, expired_plan)

      assert {:ok, :noop, :gate_passed} = Tasks.retry_auto_approval(passed_plan.id)
      assert reload(passed_plan).status == "pending_review"
      refute reload(passed_plan).auto_approved_at

      assert {:ok, :approved} = Tasks.retry_auto_approval(expired_plan.id)
      assert reload(expired_plan).status == "approved"
      assert reload(expired_plan).auto_approved_at
    end

    test "a human_override verdict", %{project: project} do
      {task, plan} = armed_lost_tail!(project, state: "human_override", source: "human")
      assert_armed!(task, plan)

      assert {:ok, :noop, :human_override} = Tasks.retry_auto_approval(plan.id)
      assert reload(plan).status == "pending_review"
      refute reload(plan).auto_approved_at
    end

    test "a plan whose gate never opened — its tail ran INLINE at submit", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      assert Tasks.architecture_gate(submitted.id) == :none
      assert_armed!(task, plan)

      assert {:ok, :noop, :no_gate} = Tasks.retry_auto_approval(plan.id)
      assert reload(plan).status == "pending_review"
    end

    test "a gate that is still genuinely open — that is stage 1's business", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      assert {:open, _} = Tasks.architecture_gate(gated.id)
      assert_armed!(task, plan)

      assert {:ok, :noop, :gate_open} = Tasks.retry_auto_approval(plan.id)
      assert reload(plan).status == "pending_review"
    end

    test "a non-armed task, and no Inbox row is created", %{project: project} do
      sponsor = sponsor_fixture()

      {task, plan} =
        armed_lost_tail!(project, auto_approve_plan: false, sponsor_user_id: sponsor.id)

      refute reload(task).auto_approve_plan

      rows_before = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")

      assert {:ok, :noop, :not_armed} = Tasks.retry_auto_approval(plan.id)

      assert reload(plan).status == "pending_review"
      refute reload(plan).auto_approved_at

      # The count, not just the return value: a refusal that had gone
      # through `settle_plan_submission/1` would show up here.
      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == rows_before
    end

    test "an already-approved plan", %{project: project} do
      {task, plan} = armed_lost_tail!(project)
      assert_armed!(task, plan)

      assert {:ok, :approved} = Tasks.retry_auto_approval(plan.id)
      approved_at = reload(plan).auto_approved_at

      assert {:ok, :noop, :not_pending_review} = Tasks.retry_auto_approval(plan.id)
      assert reload(plan).auto_approved_at == approved_at
    end

    test "a missing plan", %{project: _project} do
      assert {:error, :plan_not_found} = Tasks.retry_auto_approval(Ecto.UUID.generate())
    end

    # THE FOREVER-LOOP GUARD. A precondition failure can never be healed by
    # a retry, so it is refused HERE rather than being discovered inside
    # `maybe_auto_approve/1` — which would log a warning and emit
    # `auto_approve_skipped` on every five-minute tick for the life of the
    # row. Asserted as the ABSENCE of that telemetry, paired below with a
    # case that does emit it, so the absence is evidence.
    test "a plan with no stages, terminally and without the skip telemetry", %{project: project} do
      {task, plan} =
        task_fixture(project, auto_approve_plan: true, empty_plan: true)

      gated = open_gate!(task, plan)
      _ = lose_the_tail!(task, gated)

      assert Repo.all(from(s in Stage, where: s.plan_id == ^plan.id)) == []
      assert reload(task).auto_approve_plan

      handler = "retry-skip-#{u()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :plan, :auto_approve_skipped],
        fn _e, _m, meta, _c -> send(test_pid, {:skipped, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, :noop, :empty_plan} = Tasks.retry_auto_approval(plan.id)
      refute_receive {:skipped, _}, 100

      assert reload(plan).status == "pending_review"

      # POSITIVE CONTROL that the same handler CAN hear that event, so the
      # `refute_receive` above is not passing because nothing is attached.
      # A SECOND armed task with an equally empty plan, submitted through the
      # ordinary ungated path — `maybe_auto_approve/1` reaches the identical
      # `{:skip, :empty_plan}` and says so. That is the noise this refusal
      # keeps off the five-minute tick.
      {_control_task, control_plan} =
        task_fixture(project, auto_approve_plan: true, empty_plan: true)

      {:ok, _} = Tasks.submit_plan_for_review(control_plan)
      assert_receive {:skipped, %{reason: :empty_plan}}
    end
  end

  # ── the sweep arm ──────────────────────────────────────────────────────

  describe "sweep_unsettled_auto_approvals/0" do
    test "re-approves a debounced candidate and reports it", %{project: project} do
      {task, plan} = armed_lost_tail!(project)
      assert_armed!(task, plan)
      _ = backdate_plan!(plan, 3600)

      before = reload(plan)

      assert %{scanned: 1, reapproved: 1, observed: 0} =
               TaskRouterWatcher.sweep_unsettled_auto_approvals()

      assert_approved_without_erasing_the_record!(task, plan, before.architecture_verdict)
    end

    test "observes an architect-rejected plan instead of re-approving it", %{project: project} do
      {task, v1} = task_fixture(project, auto_approve_plan: true)
      g1 = open_gate!(task, v1)

      {:ok, _} =
        Tasks.resolve_architecture_gate(g1, :reject, source: "mcp", findings: [])

      {:ok, v2} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _} = Tasks.create_stage(%{plan_id: v2.id, position: 1, name: "S1"})
      g2 = open_gate!(task, v2)

      {:ok, _} =
        Tasks.resolve_architecture_gate(g2, :reject, source: "mcp", findings: [])

      assert ArchitectureRejection.escalation_due?(task.id)
      assert reload(v2).status == "pending_review"
      _ = backdate_plan!(v2, 3600)

      # A `"rejected"` verdict is not even a CANDIDATE — the query is built
      # from `Tasks.retryable_auto_approval_states/0`, which excludes it.
      assert %{scanned: 0, reapproved: 0, observed: 0} =
               TaskRouterWatcher.sweep_unsettled_auto_approvals()

      assert reload(v2).status == "pending_review"
      refute reload(v2).auto_approved_at
    end

    test "the debounce and the max-age bound both exclude, while a middling row is swept", %{
      project: project
    } do
      # PAIRED exclusions: all three fixtures are armed and identical apart
      # from `updated_at`, so the bounds are what is being measured.
      {fresh_task, fresh} = armed_lost_tail!(project)
      _ = backdate_plan!(fresh, 60)

      {ancient_task, ancient} = armed_lost_tail!(project)
      _ = backdate_plan!(ancient, 9 * 24 * 60 * 60)

      {ok_task, sweepable} = armed_lost_tail!(project)
      _ = backdate_plan!(sweepable, 3600)

      assert_armed!(fresh_task, fresh)
      assert_armed!(ancient_task, ancient)
      assert_armed!(ok_task, sweepable)

      assert %{scanned: 1, reapproved: 1, observed: 0} =
               TaskRouterWatcher.sweep_unsettled_auto_approvals()

      assert reload(sweepable).status == "approved"
      assert reload(fresh).status == "pending_review"
      assert reload(ancient).status == "pending_review"
    end

    test "a non-armed candidate is scanned, observed and left alone", %{project: project} do
      {task, plan} = armed_lost_tail!(project, auto_approve_plan: false)
      refute reload(task).auto_approve_plan
      _ = backdate_plan!(plan, 3600)

      handler = "retry-sweep-telemetry-#{u()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :orchestration, :architecture_gate_swept],
        fn _e, _m, meta, _c -> send(test_pid, {:swept, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert %{scanned: 1, reapproved: 0, observed: 1} =
               TaskRouterWatcher.sweep_unsettled_auto_approvals()

      assert_receive {:swept, %{action: :observed_only, reason: :not_armed}}
      assert reload(plan).status == "pending_review"
    end

    test "is idempotent — a second pass re-approves nothing", %{project: project} do
      sponsor = sponsor_fixture()
      {task, plan} = armed_lost_tail!(project, sponsor_user_id: sponsor.id)
      assert_armed!(task, plan)
      _ = backdate_plan!(plan, 3600)

      assert %{reapproved: 1} = TaskRouterWatcher.sweep_unsettled_auto_approvals()

      settled = reload(plan)
      rows = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")

      assert %{scanned: 0, reapproved: 0, observed: 0} =
               TaskRouterWatcher.sweep_unsettled_auto_approvals()

      assert reload(plan).auto_approved_at == settled.auto_approved_at
      assert reload(plan).architecture_verdict == settled.architecture_verdict
      assert Repo.all(from(p in Plan, where: p.task_id == ^task.id)) |> length() == 1
      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == rows
    end
  end
end
