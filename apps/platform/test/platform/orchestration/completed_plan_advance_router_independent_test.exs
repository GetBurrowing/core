defmodule Platform.Orchestration.CompletedPlanAdvanceRouterIndependentTest do
  @moduledoc """
  Task 019fbe9e stage 4, reconcile half — a FALSIFICATION, pinned as a test.

  ## The claim under test

  The stage was briefed to add a reconcile sweep that finds tasks whose current
  plan is `completed` but whose status has not advanced past the plan's phase,
  and applies "the same mapping the router uses"
  (`in_progress -> in_review -> deploying -> done`). The premise is that the
  advance is an in-memory PubSub effect and therefore lost whenever no router
  is alive to receive the broadcast.

  Both halves of that premise are false against this tree:

  1. **The advance is not event-delivered.** `PlanEngine.complete_plan/2` — the
     only writer of `plan.status = "completed"` — calls
     `PlanCompletion.advance_task/2` synchronously, BEFORE broadcasting. Router
     liveness cannot affect it. The first test below is the stage's own
     late-precondition fixture (complete the plan with no router alive, assert
     the task advanced) and it passes without any new code, which is what makes
     it a falsification rather than a regression guard.

  2. **The mapping no longer exists, by design.** The router's status-mapping
     arm was deleted by task 019fa2fc, whose notes record that the mapping
     MANUFACTURED this stall class: `in_review` is a dead end in the
     single-plan model (review lives in the same plan) and `deploying` is a
     dead end for a task with no deploy stage and no deploy strategy to move it
     back out. Re-adding it in a sweep would reintroduce the removed defect.

  3. **A sweep keyed on status would overrun deliberate refusals.**
     `PlanCompletion` returns `:noop` for `:awaiting_rollup`, `:stack_member`,
     `:not_deployable` and `:degenerate_plan`. Those tasks sit at
     `in_progress` / `in_review` with a `completed` plan as their CORRECT
     state — a status-keyed sweep cannot tell them from a dropped advance,
     because the completion REASON is the only thing that distinguishes them
     and it is not on the row.

  So the reconcile half ships as this file rather than as a sweep. Test 2 is
  the standing guard: if a later change adds the sweep anyway, it goes red.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Completed Plan Project #{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  test "a plan completing with NO router alive still advances the task", %{project: project} do
    %{task: task, plan: plan} = strategy_task(project, %{"type" => "none"})

    # The precondition the ticket blames: nobody is subscribed for this task.
    assert Registry.lookup(Platform.Orchestration.Registry, task.id) == []
    assert Tasks.get_task_record(task.id).status == "in_progress"

    {:ok, completed} = PlanEngine.advance(plan.id)
    assert completed.status == "completed"

    # No barrier, no sleep, no tick: the advance happened inside `advance/1`.
    assert Tasks.get_task_record(task.id).status == "done"
  end

  test "CONTROL: a reconcile tick does NOT advance a task PlanCompletion declined", %{
    project: project
  } do
    # `no_op_wait_for_rollup` with a nil `stack_id`: the deploy ships via a
    # rollup PR that may never have been opened, so `in_progress` with a
    # `completed` plan is this task's correct resting state. It is exactly the
    # row a status-keyed "plan completed but task not advanced" sweep would
    # pick up and push to `in_review`.
    %{task: task, plan: plan} = strategy_task(project, %{"type" => "no_op_wait_for_rollup"})
    assert task.stack_id == nil

    {:ok, completed} = PlanEngine.advance(plan.id)
    assert completed.status == "completed"
    assert Tasks.get_task_record(task.id).status == "in_progress"

    watcher_pid = start_supervised!(TaskRouterWatcher)
    send(watcher_pid, :reconcile)
    TaskRouterWatcher.sync()

    assert Tasks.get_task_record(task.id).status == "in_progress",
           "a reconcile sweep advanced a task PlanCompletion deliberately refused to advance"
  end

  defp strategy_task(project, strategy) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Completed plan #{strategy["type"]}",
        status: "in_progress",
        deploy_strategy: strategy
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    %{task: task, plan: plan}
  end
end
