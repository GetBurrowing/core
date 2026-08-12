defmodule Platform.Orchestration.TaskRouterPlanCompletedTest do
  @moduledoc """
  Covers the `{:plan_updated, status: "completed"}` clause in
  `Platform.Orchestration.TaskRouter` after task 019fa2fc stage 3 stripped its
  status-mapping arm.

  Deliberately a NEW file: `task_router_test.exs` is owned by task 019fa121
  (the sleep-removal rewrite) and must not be touched here.

  No `Process.sleep` anywhere. The barrier is `TaskRouter.current_status/1` — a
  plain `GenServer.call`, so it cannot be answered until every message already
  in the router's mailbox has been handled.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stacks

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Completed-Plan Project",
        repo_url: "https://github.com/test/router-completed"
      })

    %{project: project}
  end

  describe "plan completed, router alive" do
    test "a deploying task reaches done exactly once", %{project: project} do
      %{task: task, deploy_stage: deploy_stage} = deploying_task(project)
      start_router!(task)

      [validation] = Tasks.list_validations(deploy_stage.id)

      Tasks.subscribe_board()
      drain_status_changes(task.id)

      log =
        capture_log(fn ->
          PlanEngine.evaluate_validation(validation.id, %{status: "passed", evaluated_by: "test"})

          barrier(task)
        end)

      assert Tasks.get_task_record(task.id).status == "done"

      # Exactly one status change, and it is the terminal one. A second
      # state machine running one broadcast later would show up here.
      assert drain_status_changes(task.id) == ["done"]

      refute log =~ "failed to transition task"
      refute log =~ "held task #{task.id} at deploying"
    end

    test "a none-strategy task lands at done without passing through in_review or deploying",
         %{project: project} do
      %{task: task, plan: plan} = strategy_task(project, %{"type" => "none"})
      start_router!(task)

      Tasks.subscribe_board()
      drain_status_changes(task.id)

      {:ok, _completed} = PlanEngine.advance(plan.id)
      barrier(task)

      assert Tasks.get_task_record(task.id).status == "done"

      # The removed router arm mapped `in_progress -> in_review` and
      # `in_review -> deploying`. Both are dead ends in the single-plan model,
      # so the ONLY acceptable trace here is a single hop to `done`.
      assert drain_status_changes(task.id) == ["done"]
    end

    test "does not advance a task PlanCompletion deliberately declined to advance",
         %{project: project} do
      # `no_op_wait_for_rollup` with a nil `stack_id`: stage 2 taught
      # `PlanCompletion` to return `:noop` here, because the deploy ships via a
      # rollup PR that may never have been opened. The router's status-mapping
      # arm re-derived its target from the task's CURRENT status and knew
      # nothing about the completion reason, so it mapped this same task
      # `in_progress -> in_review` one broadcast later — silently undoing the
      # protection stage 2 added. That is the concrete double-advance this
      # stage removes.
      %{task: task, plan: plan} =
        strategy_task(project, %{"type" => "no_op_wait_for_rollup"})

      assert task.stack_id == nil
      start_router!(task)

      log =
        capture_log(fn ->
          {:ok, _completed} = PlanEngine.advance(plan.id)
          barrier(task)
        end)

      assert Tasks.get_plan(plan.id).status == "completed"
      assert Tasks.get_task_record(task.id).status == "in_progress"
      refute log =~ "transitioned task #{task.id} to in_review"
    end

    test "does not advance a stack member on the completed-plan broadcast", %{project: project} do
      # The eight ADR-0046 members sitting at `deploying` on 2026-07-27 are
      # stuck because their rollup PR was never opened. `PlanCompletion`
      # returns `:noop` for `:stack_member` precisely so this change stays away
      # from them; the router arm would have pushed them onward anyway.
      %{task: task, plan: plan} = stack_member_task(project)
      start_router!(task)

      log =
        capture_log(fn ->
          Tasks.broadcast_board({:plan_updated, plan})
          barrier(task)
        end)

      assert Tasks.get_task_record(task.id).status == "in_review"
      refute log =~ "failed to transition task"
      refute log =~ "transitioned task #{task.id} to deploying"
    end

    test "leaves the 019f9b34 unsettled-deploy warning to PlanCompletion", %{project: project} do
      # The guard itself moved to `Platform.Tasks.PlanCompletion` in stage 1
      # and is covered by `plan_completion_test.exs`. What must be gone from
      # here is the router's DUPLICATE re-derivation of it: the clause is now
      # liveness-only and reads no stage statuses at all.
      %{task: task, plan: plan} = unsettled_deploy_task(project)
      start_router!(task)

      log =
        capture_log(fn ->
          Tasks.broadcast_board({:plan_updated, plan})
          barrier(task)
        end)

      assert Tasks.get_task_record(task.id).status == "deploying"
      refute log =~ "[TaskRouter] held task"
    end

    test "still clears the task's liveness lease", %{project: project} do
      # One of the two side effects the clause KEEPS. The fixture's plan has no
      # running stage, so `arm_liveness_timers/3` no-ops on the re-dispatch the
      # clause also triggers — nothing can re-record the lease behind us and
      # the assertion is not racing `handle_info(:dispatch, ...)`.
      %{task: task, plan: plan, stage: stage} = settled_plan_task(project)
      start_router!(task)

      :ok = LeaseManager.record_dispatch(task.id, stage.id, "test_pass", DateTime.utc_now())

      assert LeaseManager.get(task.id)

      Tasks.broadcast_board({:plan_updated, plan})
      barrier(task)

      assert LeaseManager.get(task.id) == nil
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # A task walked through the engine to `deploying`, with a `Deploy: Manual`
  # stage running.
  defp deploying_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router deploying task",
        status: "in_review",
        deploy_strategy: %{"type" => "manual"},
        # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
        # transitions without a resolved target.
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, plan_after_inject} = PlanEngine.advance(plan.id)
    deploy_stage = Enum.find(plan_after_inject.stages, &(&1.name == "Deploy: Manual"))

    assert deploy_stage.status == "running"
    assert Tasks.get_task_record(task.id).status == "deploying"

    %{task: task, plan: plan, deploy_stage: deploy_stage}
  end

  # A task at `in_progress` with an approved single-stage plan carrying
  # `strategy`. Its stage is running, so `PlanEngine.advance/1` completes it.
  defp strategy_task(project, strategy) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router strategy #{strategy["type"]} task",
        status: "in_progress",
        deploy_strategy: strategy
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    %{task: task, plan: plan}
  end

  # A stack member parked at `in_review` with an already-`completed` plan.
  defp stack_member_task(project) do
    slug = "router-completed-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Router completed boundary",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router stack member",
        status: "in_progress",
        stack_id: stack.id,
        deploy_target: "production"
      })

    {:ok, task} = Tasks.transition_task(task, "in_review")
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

    %{task: task, plan: plan}
  end

  # A task at `in_progress` whose plan is `completed` with every stage settled
  # — no running stage, so a re-dispatch cannot arm a fresh liveness lease.
  defp settled_plan_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router settled plan",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(stage, "running")
    {:ok, stage} = Tasks.transition_stage(running, "passed")

    %{task: task, plan: plan, stage: stage}
  end

  # A task at `deploying` whose plan is `completed` while its deploy stage is
  # still `running` — the 019f9b34 / 019f9ae5 drift condition.
  defp unsettled_deploy_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router unsettled deploy",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})
    {:ok, _running} = Tasks.transition_stage(stage, "running")
    {:ok, task} = Tasks.transition_task(task, "deploying")

    %{task: task, plan: plan}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_router!(task) do
    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      # LeaseManager is a global singleton — purge this task's row.
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    # `init/1` schedules a boot dispatch; drain it so the assertions observe
    # the plan-completion event rather than boot noise.
    barrier(task)

    pid
  end

  # A complete mailbox barrier: `current_status/1` is a `GenServer.call`, so it
  # is answered only after every message queued ahead of it is handled. NOT a
  # sleep — task 019fa121 is removing all 116 of those from the sibling file.
  defp barrier(task), do: TaskRouter.current_status(task.id)

  defp drain_status_changes(task_id, acc \\ []) do
    receive do
      {:task_updated, %{id: ^task_id, status: status}} ->
        drain_status_changes(task_id, [status | acc])

      _other ->
        drain_status_changes(task_id, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
