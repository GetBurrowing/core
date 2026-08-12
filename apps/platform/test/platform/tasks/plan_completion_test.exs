defmodule Platform.Tasks.PlanCompletionTest do
  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Tasks
  alias Platform.Tasks.PlanCompletion
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stacks

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Plan Completion Project"})
    %{project: project}
  end

  # ── deploying -> done, with NO router alive ───────────────────────────

  describe "advance_task/2 :deploy_stage_passed" do
    test "moves a deploying task to done with no TaskRouter subscribed", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy then done, routerless",
          status: "in_review",
          deploy_strategy: %{"type" => "manual"},
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — injects the deploy stage and moves the task to `deploying`.
      {:ok, plan_after_inject} = PlanEngine.advance(plan.id)
      deploy_stage = Enum.find(plan_after_inject.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage.status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"

      [validation] = Tasks.list_validations(deploy_stage.id)

      # THE TRAP THIS TEST EXISTS TO AVOID: if a TaskRouter is alive for this
      # task, the `{:plan_updated, status: "completed"}` PubSub clause performs
      # the deploying -> done transition and this test passes both BEFORE and
      # AFTER the fix, proving nothing. The structural guarantee is the
      # fixture: `create_task/1` with no assignee leaves `assignee_id` nil, and
      # `TaskRouterWatcher.should_run?/1` requires `assignee_type == "agent"`
      # AND a non-nil `assignee_id`, so no router is ever started. Assert it
      # rather than assuming it — before and after.
      assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
             "a TaskRouter is alive for this task — the test no longer reproduces " <>
               "the production condition (a dropped broadcast with no subscriber)"

      PlanEngine.evaluate_validation(validation.id, %{status: "passed", evaluated_by: "test"})

      assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
             "a TaskRouter started mid-test — see the comment above"

      # Synchronous on the FIRST read. No polling, no barrier: the advance
      # happens inside the same call stack as the plan write.
      assert Tasks.get_task_record(task.id).status == "done"

      final_plan = Tasks.get_plan(plan.id)
      assert final_plan.status == "completed"
      assert Enum.find(final_plan.stages, &(&1.name == "Deploy: Manual")).status == "passed"
    end

    test "holds at deploying when the deploy stage is unsettled (019f9b34)", %{project: project} do
      %{plan: plan, task: task} = deploying_fixture(project, "running")

      log =
        capture_log(fn ->
          assert PlanCompletion.advance_task(plan, :deploy_stage_passed) == :noop
        end)

      # A `completed` plan is NOT evidence the deploy landed. Incident 019f9ae5
      # flipped a task to `done` eight minutes before its PR merged; the guard
      # that stopped it has to survive being moved off the router.
      assert Tasks.get_task_record(task.id).status == "deploying"
      assert log =~ "held task #{task.id} at deploying"
      assert log =~ "Deploy: PR merge=running"
    end

    test "promotes a deploying task whose plan has no deploy stage at all", %{project: project} do
      # `deploy_stages_settled?/1` filters to deploy stages and `Enum.all?/2`
      # over an empty list is `true`. That default must NOT be tightened into
      # "there must be a settled deploy stage", which would lock a task with no
      # deploy stage out of `done` forever.
      #
      # Ported from `task_router_test.exs` ("a plan with no deploy stage at all
      # still promotes the task to done") when task 019fa2fc stage 3 deleted
      # the router arm that test drove.
      %{plan: plan, task: task} = deploying_fixture(project, "passed", "Build")

      assert Tasks.list_stages(plan.id) |> Enum.all?(&(not PlanEngine.deploy_stage?(&1)))

      assert {:ok, %{status: "done"}} = PlanCompletion.advance_task(plan, :deploy_stage_passed)
      assert Tasks.get_task_record(task.id).status == "done"
    end

    test "is idempotent — a second advance neither warns nor errors", %{project: project} do
      %{plan: plan, task: task} = deploying_fixture(project, "passed")

      assert {:ok, %{status: "done"}} = PlanCompletion.advance_task(plan, :deploy_stage_passed)

      # `@valid_task_transitions` maps `"done" => ~w(planning)`, so an
      # unguarded retry would return `{:error, :invalid_transition}` and log the
      # spurious warning task 019fa2fc calls out. The status guard makes the
      # repeat silent.
      log =
        capture_log(fn ->
          assert PlanCompletion.advance_task(plan, :deploy_stage_passed) == :noop
        end)

      assert Tasks.get_task_record(task.id).status == "done"
      refute log =~ "invalid_transition"
      refute log =~ "[PlanCompletion]"
    end
  end

  # ── strategy "none" -> done, with NO router alive ─────────────────────

  describe "advance_task/2 :no_deploy_strategy" do
    test "moves an in_progress task to done when the strategy is none", %{project: project} do
      %{task: task, plan: plan} = strategy_fixture(project, %{"type" => "none"}, "in_progress")

      drive_plan_to_completion(plan, task)

      assert Tasks.get_task_record(task.id).status == "done"
      assert Tasks.get_plan(plan.id).status == "completed"
    end

    test "moves an in_review task to done when the strategy is none", %{project: project} do
      %{task: task, plan: plan} = strategy_fixture(project, %{"type" => "none"}, "in_review")

      drive_plan_to_completion(plan, task)

      # `in_review -> done` is legal per `@valid_task_transitions`. The router's
      # legacy arm mapped this to `deploying` instead, which parked the task in a
      # status with no deploy stage and no strategy to ever move it out — a stall
      # manufactured by the very code path this task removes.
      assert Tasks.get_task_record(task.id).status == "done"
      assert Tasks.get_plan(plan.id).status == "completed"
    end

    test "does NOT move a task whose strategy is no_op_wait_for_rollup", %{project: project} do
      # `DeployStageBuilder.build_stage/2` returns `:skip` for BOTH `"none"` and
      # `"no_op_wait_for_rollup"`, and both land on the single `:skip` call site
      # in `maybe_inject_deploy_or_complete/2`. Treating that call site as
      # "strategy is none" would sweep this task to `done` while it waits for a
      # rollup PR that will never be opened — the same "reported as deployed
      # without deploying" bug, in a new place.
      #
      # Real stack members cannot reach here (`dispatch_deploy_for_task/1`
      # rejects on any non-nil `stack_id`, and the earlier `cond` arm catches
      # them). The reachable hole is exactly this: `stack_id == nil` with an
      # explicit `no_op_wait_for_rollup` override.
      %{task: task, plan: plan} =
        strategy_fixture(project, %{"type" => "no_op_wait_for_rollup"}, "in_progress")

      assert task.stack_id == nil

      drive_plan_to_completion(plan, task)

      assert Tasks.get_plan(plan.id).status == "completed"
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end
  end

  # ── scope boundaries: reasons that must never advance ─────────────────

  describe "advance_task/2 scope boundaries" do
    test "leaves a stack member untouched", %{project: project} do
      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "plan-completion-boundary",
          name: "Plan completion boundary",
          rollup_branch: Stacks.rollup_branch_name("plan-completion-boundary")
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member",
          status: "in_progress",
          stack_id: stack.id
        })

      {:ok, task} = Tasks.transition_task(task, "in_review")
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

      # DO NOT "fix" this to advance the member. Stack members ship via the
      # rollup PR (ADR 0041/0046); their terminal path is owned by
      # `Stacks.dispatch_stack_deploy/1` + `StackDeployer.handle_member_transition/3`
      # and the 019f708f sweep. The eight ADR-0046 members sitting at `deploying`
      # on 2026-07-27 are stuck because their rollup PR was NEVER OPENED — a
      # deploy that genuinely has not happened. Advancing them here would report
      # unshipped work as shipped. Asserting the direct `:noop` (rather than a
      # status after an engine run) keeps this assertion about THIS seam and not
      # about whatever the stack path does asynchronously.
      assert PlanCompletion.advance_task(plan, :stack_member) == :noop
      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    test "leaves a non-deployable task untouched", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Backlog task",
          status: "backlog"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

      assert PlanCompletion.advance_task(plan, :not_deployable) == :noop
      assert Tasks.get_task_record(task.id).status == "backlog"
    end

    test "leaves a task with a degenerate zero-stage plan untouched", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Degenerate plan task",
          status: "in_progress"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

      # A plan with no stages is not evidence that any work happened.
      assert Tasks.list_stages(plan.id) == []
      assert PlanCompletion.advance_task(plan, :degenerate_plan) == :noop
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end
  end

  # A task + approved single-stage plan carrying `strategy`, parked at
  # `task_status`. No assignee, so `TaskRouterWatcher.should_run?/1` is false
  # and no router is ever started (see the trap comment above).
  defp strategy_fixture(project, strategy, task_status) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Strategy #{strategy["type"]} at #{task_status}",
        status: "in_progress",
        deploy_strategy: strategy
      })

    task =
      if task_status == "in_progress" do
        task
      else
        {:ok, moved} = Tasks.transition_task(task, task_status)
        moved
      end

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    %{task: task, plan: plan}
  end

  # Runs the engine's completion path, asserting on both sides of the call that
  # no TaskRouter is alive — the same trap guard as the deploy test above.
  defp drive_plan_to_completion(plan, task) do
    assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
           "a TaskRouter is alive for this task — the test no longer reproduces " <>
             "the production condition (a dropped broadcast with no subscriber)"

    {:ok, _completed} = PlanEngine.advance(plan.id)

    assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
           "a TaskRouter started mid-test — see the comment above"
  end

  # A task parked at `deploying` with a `completed` plan whose sole deploy
  # stage carries `deploy_stage_status`. Built directly rather than driven
  # through `PlanEngine.advance/1` so the test controls the deploy stage's
  # status independently of the engine's own completion path.
  defp deploying_fixture(project, deploy_stage_status, stage_name \\ "Deploy: PR merge") do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Deploying fixture (#{stage_name}/#{deploy_stage_status})",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: stage_name})

    {:ok, running} = Tasks.transition_stage(stage, "running")

    if deploy_stage_status == "passed" do
      {:ok, _} = Tasks.transition_stage(running, "passed")
    end

    {:ok, task} = Tasks.transition_task(task, "deploying")

    assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
           "no router may be alive — see the trap comment above"

    %{plan: plan, task: task}
  end
end
