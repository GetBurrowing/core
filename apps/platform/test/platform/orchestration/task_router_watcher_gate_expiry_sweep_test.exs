defmodule Platform.Orchestration.TaskRouterWatcherGateExpirySweepTest do
  @moduledoc """
  Task 019fa605 stage 1 — `TaskRouterWatcher.sweep_expired_architecture_gates/0`.

  ## The defect

  `TaskRouterWatcher.should_run?/1` requires `assignee_type == "agent"`, so a
  task whose PLANNING assignee is a USER never gets a router, never arms
  `{:architecture_gate_deadline, plan_id}`, and therefore never has anything
  that calls `Tasks.resolve_architecture_gate(plan, :expired)`.

  `Tasks.architecture_gate/1` still PROJECTS the overdue gate as
  `{:resolved, %{"state" => "expired", "source" => "deadline"}}` — the level
  guarantee — but that projection is a read, not a write, and nothing
  downstream of it re-enters `settle_plan_submission/1 -> maybe_auto_approve/1`.
  So a task carrying `auto_approve_plan: true` sits at `pending_review`
  forever on a plan configured to approve itself.

  This sweep is literally "the deadline timer for tasks that have no router":
  it re-asks `Tasks.architecture_gate/1` (never re-deriving the overdue rule)
  and makes the SAME single call the router's deadline handler makes.

  ## What these tests do NOT prove

  `config :platform, :task_router_watcher_reconcile, false` in
  `config/test.exs` means the 5-minute tick never fires under test. These
  tests drive `sweep_expired_architecture_gates/0` DIRECTLY, so they do not
  prove the sweep is wired into `handle_info(:reconcile, _)`. That wiring is
  covered by the plan's e2e_behavior case, which sends `:reconcile` to the
  live watcher and asserts on the reconcile log line.

  ## Fixture arming is part of the test, not of the setup

  `maybe_auto_approve/1` returns `{:ok, plan}` UNTOUCHED unless
  `task.auto_approve_plan` or `task.stack.auto_accept_plan` is set, and
  `auto_approve_precondition/2` skips on an empty plan or a missing
  execution/review assignee. 019fa510 stage 5's first re-entrancy test
  survived the very mutation it was written to kill because its fixture did
  not satisfy that condition. So every test whose outcome depends on the auto
  path asserts the arming INLINE via `assert_armed!/2`, and keys its outcome
  on `auto_approved_at` — never on `approved_by` alone, which an outer human
  write overwrites.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stage, Task}

  defp u, do: System.unique_integer([:positive])

  setup do
    test_pid = self()
    handler_id = "gate-expiry-sweep-#{u()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :architecture_gate_swept],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:swept, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, project} = Tasks.create_project(%{name: "Gate Expiry Sweep #{u()}"})

    %{project: project}
  end

  # THE LOAD-BEARING FIXTURE DETAIL: `assignee_type: "user"`.
  #
  # Against an agent-assigned task a router would exist, arm the deadline and
  # settle the row, and this whole file would test a path the production
  # defect does not live on. `opts` allows `assignee_type: "agent"` so the
  # contrast can be asserted rather than assumed.
  defp task_fixture(project, opts \\ []) do
    assignee_type = Keyword.get(opts, :assignee_type, "user")
    assignee_id = Keyword.get(opts, :assignee_id, Ecto.UUID.generate())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Gate expiry sweep fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
        assignee_type: assignee_type,
        assignee_id: assignee_id,
        phase_assignees: %{
          "planning" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type},
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan}
  end

  # The state a GATED submit leaves behind: plan `pending_review`, gate open,
  # cursor at `:architecting`, and `planning_step_outcomes["architecture"]`
  # written `complete` from `{:ok, :dispatched}` at submit time.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    {:ok, _task} = Tasks.record_planning_step(task.id, :architecture, {:ok, :dispatched})
    gated
  end

  # Push `deadline_at` into the past leaving `state` as `"pending"` — the row
  # shape a real gate reaches when its timeout elapses and no router exists to
  # notice. Written through `update_all` so no changeset can normalise it.
  defp expire_deadline!(%Plan{} = plan, seconds_ago) do
    verdict =
      Map.put(
        Repo.get!(Plan, plan.id).architecture_verdict,
        "deadline_at",
        DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
      )

    {1, _} =
      Plan
      |> where([p], p.id == ^plan.id)
      |> Repo.update_all(set: [architecture_verdict: verdict])

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

  # ── THE FALSIFIER ─────────────────────────────────────────────────────
  #
  # Run BEFORE the production edit against unmodified `origin/main`
  # (0f9b021a). It failed with:
  #
  #     ** (UndefinedFunctionError) function
  #        Platform.Orchestration.TaskRouterWatcher.sweep_expired_architecture_gates/0
  #        is undefined or private
  #
  # and, with the call stubbed out to prove no OTHER settler exists, on the
  # status assertion: the plan was still `"pending_review"` with
  # `auto_approved_at: nil` and a verdict still reading `"pending"`. See the
  # commit message for the full detonation.

  describe "FALSIFIER: an armed user-assigned task with an expired gate and no router" do
    test "reaches approved through the sweep", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      assert_armed!(task, plan)

      # POSITIVE CONTROLS ON THE FIXTURE. An agent-assigned task would sail
      # through every assertion below while exercising a path that HAS a
      # router and therefore does not have the bug.
      refute TaskRouterWatcher.should_run?(reload(task))
      refute TaskRouterWatcher.router_running?(task.id)

      # And the projection already says expired while the row still says
      # pending — the gap between the two IS the defect.
      assert {:resolved, %{"state" => "expired", "source" => "deadline"}} =
               Tasks.architecture_gate(plan.id)

      assert reload(plan).architecture_verdict["state"] == "pending"
      assert reload(plan).status == "pending_review"

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      settled = reload(plan)
      assert settled.status == "approved"
      assert settled.auto_approved_at
      assert settled.approved_by == "system:auto"
    end
  end

  describe "the stage-5 invariant survives the fix" do
    test "approving does not erase the record that nobody reviewed the plan", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)
      assert_armed!(task, plan)

      assert %{settled: 1} = TaskRouterWatcher.sweep_expired_architecture_gates()

      settled = reload(plan)

      # Both halves are required. An approved plan whose gate now reads
      # `passed`, or whose planning step reads `complete`, is a FAILURE and
      # worse than the stall it replaced.
      assert settled.status == "approved"
      assert settled.auto_approved_at
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.architecture_verdict["source"] == "deadline"
      assert is_binary(settled.architecture_verdict["resolved_at"])

      assert Tasks.planning_gate_failed?(reload(task))
      assert [%{step: "architecture", detail: detail}] = Tasks.failed_planning_steps(reload(task))
      assert detail =~ "expired"
    end

    test "a sibling task whose architect actually passed is NOT reported as failed", %{
      project: project
    } do
      # POSITIVE CONTROL for the assertion above: `planning_gate_failed?/1`
      # would also be true for the expired task if it were true of
      # everything.
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      assert_armed!(task, plan)

      {:ok, _passed} = Tasks.resolve_architecture_gate(gated, :pass, source: "mcp")

      assert reload(plan).architecture_verdict["state"] == "passed"
      refute Tasks.planning_gate_failed?(reload(task))
      assert Tasks.failed_planning_steps(reload(task)) == []
    end
  end

  describe "the stack auto_accept_plan twin shares the stall" do
    test "a stack member with auto_approve_plan false is settled via the stack flag", %{
      project: project
    } do
      slug = "gate-expiry-#{u()}"

      {:ok, stack} =
        Platform.Tasks.Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Gate expiry #{slug}",
          base_branch: "main",
          rollup_branch: Platform.Tasks.Stacks.rollup_branch_name(slug),
          auto_accept_plan: true
        })

      {task, plan} = task_fixture(project, auto_approve_plan: false)
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      # POSITIVE CONTROL that the STACK arm fires and not the task arm.
      assert reload(task).auto_approve_plan == false
      assert Repo.preload(reload(task), :stack).stack.auto_accept_plan == true
      refute TaskRouterWatcher.should_run?(reload(task))

      test_pid = self()
      auto_handler = "auto-approved-#{u()}"

      :ok =
        :telemetry.attach(
          auto_handler,
          [:platform, :plan, :auto_approved],
          fn _e, _m, meta, _cfg -> send(test_pid, {:auto_approved, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(auto_handler) end)

      assert %{settled: 1} = TaskRouterWatcher.sweep_expired_architecture_gates()

      assert_receive {:auto_approved, %{via: :stack, plan_id: plan_id}}
      assert plan_id == plan.id

      settled = reload(plan)
      assert settled.status == "approved"
      assert settled.auto_approved_at
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.architecture_verdict["source"] == "deadline"
      assert Tasks.planning_gate_failed?(reload(task))
    end
  end

  describe "non-armed control" do
    test "the gate still settles but the plan stays pending_review", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: false)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      assert reload(task).auto_approve_plan == false

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      settled = reload(plan)
      assert settled.status == "pending_review"
      assert is_nil(settled.auto_approved_at)
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.architecture_verdict["source"] == "deadline"
      assert Tasks.planning_gate_failed?(reload(task))
    end
  end

  describe "exclusions" do
    test "a gate whose deadline is in the FUTURE is observed, not settled", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      _gated = open_gate!(task, plan)
      assert_armed!(task, plan)

      # `open_architecture_gate/2` stamps `now + architecture_gate_timeout_ms`,
      # which is in the future. No `expire_deadline!/2` call here.
      assert {:open, _} = Tasks.architecture_gate(plan.id)

      assert %{scanned: 1, settled: 0, observed: 1} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert_receive {:swept, _e, _m, %{action: :observed_only, reason: :not_overdue}}

      assert reload(plan).status == "pending_review"
      assert reload(plan).architecture_verdict["state"] == "pending"
    end

    test "a gate overdue by more than the max age is observed, not settled", %{project: project} do
      # THE DEPLOY-DAY GUARD. Without it the first production tick after this
      # ships settles every historical overdue gate at once and can
      # auto-approve plans abandoned weeks ago.
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 8 * 24 * 3600)
      assert_armed!(task, plan)

      assert %{scanned: 1, settled: 0, observed: 1} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert_receive {:swept, _e, _m, %{action: :observed_only, reason: :too_old}}

      assert reload(plan).status == "pending_review"
      assert reload(plan).architecture_verdict["state"] == "pending"
    end

    test "a gate inside the grace window is observed, not settled", %{project: project} do
      # The grace keeps a healthy router's own deadline timer the primary
      # settler and the sweep a backstop. Correctness does not depend on it:
      # `record_architecture_verdict/3`'s guarded UPDATE already makes the
      # race deterministic.
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 30)
      assert_armed!(task, plan)

      assert %{scanned: 1, settled: 0, observed: 1} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert_receive {:swept, _e, _m, %{action: :observed_only, reason: :within_grace}}

      assert reload(plan).status == "pending_review"
    end

    test "draft and superseded plans carrying a stale pending verdict are not candidates", %{
      project: project
    } do
      # Settling a superseded version would drive `approve_plan/3` on a
      # non-`pending_review` plan, get `{:error, :invalid_transition}`, and
      # log a `maybe_auto_approve` warning on every tick forever.
      {task_a, plan_a} = task_fixture(project, auto_approve_plan: true)
      gated_a = open_gate!(task_a, plan_a)
      _ = expire_deadline!(gated_a, 3600)
      {1, _} = Plan |> where([p], p.id == ^plan_a.id) |> Repo.update_all(set: [status: "draft"])

      {task_b, plan_b} = task_fixture(project, auto_approve_plan: true)
      gated_b = open_gate!(task_b, plan_b)
      _ = expire_deadline!(gated_b, 3600)

      {1, _} =
        Plan |> where([p], p.id == ^plan_b.id) |> Repo.update_all(set: [status: "rejected"])

      # PAIRED, per the anti-vacuity rule: a THIRD plan in the same sweep
      # that IS `pending_review` proves the sweep is capable of speaking.
      {task_c, plan_c} = task_fixture(project, auto_approve_plan: true)
      gated_c = open_gate!(task_c, plan_c)
      _ = expire_deadline!(gated_c, 3600)
      assert_armed!(task_c, plan_c)

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert reload(plan_c).status == "approved"
      assert reload(plan_a).status == "draft"
      assert reload(plan_a).architecture_verdict["state"] == "pending"
      assert reload(plan_b).status == "rejected"
      assert reload(plan_b).architecture_verdict["state"] == "pending"
    end

    test "a soft-deleted task's plan is not a candidate", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      {1, _} =
        Task
        |> where([t], t.id == ^task.id)
        |> Repo.update_all(set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)])

      assert %{scanned: 0, settled: 0, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert reload(plan).status == "pending_review"
    end
  end

  describe "idempotence" do
    test "a second pass settles nothing and does not re-touch the verdict", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)
      assert_armed!(task, plan)

      assert %{settled: 1} = TaskRouterWatcher.sweep_expired_architecture_gates()

      first = reload(plan)

      assert %{scanned: 0, settled: 0, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      second = reload(plan)
      assert second.auto_approved_at == first.auto_approved_at
      assert second.architecture_verdict == first.architecture_verdict
      assert [_only_one] = Repo.all(from(p in Plan, where: p.task_id == ^task.id))
    end
  end

  describe "telemetry" do
    test "a settled candidate emits action: :settled with its ids", %{project: project} do
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)
      assert_armed!(task, plan)

      assert %{settled: 1} = TaskRouterWatcher.sweep_expired_architecture_gates()

      assert_receive {:swept, [:platform, :orchestration, :architecture_gate_swept], %{count: 1},
                      %{action: :settled, plan_id: plan_id, task_id: task_id, reason: :expired}}

      assert plan_id == plan.id
      assert task_id == task.id
    end
  end
end
