defmodule Platform.Orchestration.TaskRouterNonCurrentPlanTransitionTest do
  @moduledoc """
  Task 019f9b61 stage 2: the router's `{:stage_transitioned, stage}` clause.

  `Tasks.subscribe_board/0` is the global `tasks:board` firehose, so every
  router receives every task's stage transitions. The clause has three
  outcomes, each pinned here:

    * a stage of ANOTHER task's plan is ignored silently;
    * a stage of the router's OWN task on a plan that is not the current
      approved plan is ignored WITH a warning, and does not change state;
    * a stage of the current approved plan drives the router as before.

  async: false — routers share the sandbox in shared mode and the
  LeaseManager is a global singleton.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.{LeaseManager, TaskRouter}
  alias Platform.Tasks

  @ignore_prefix "[TaskRouter] ignoring stage_transitioned"

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Non-Current Plan Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/router-non-current"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router Non-Current Plan Task",
        description: "Exercises stage_transitioned on a non-current plan",
        deploy_target: "production"
      })

    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}

    # Allow dynamically started TaskRouter processes to share the test sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task, assignee: assignee}
  end

  defp create_stage(plan, name) do
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: name,
        description: "stage #{name}"
      })

    stage
  end

  defp running_stage(plan, name) do
    {:ok, stage} = plan |> create_stage(name) |> Tasks.transition_stage("running")
    assert stage.status == "running"
    stage
  end

  defp start_router(task, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    # Barrier: the init work has been processed before the event under test.
    _ = TaskRouter.current_status(task.id)
    pid
  end

  test "no approved plan: a running stage on a pending_review plan is ignored with a warning",
       %{task: task, assignee: assignee} do
    {:ok, review_plan} =
      Tasks.create_plan(%{task_id: task.id, status: "pending_review", version: 1})

    stage = running_stage(review_plan, "coding")
    assert Tasks.current_plan(task.id) == nil

    pid = start_router(task, assignee)

    {status, log} =
      with_log(fn ->
        send(pid, {:stage_transitioned, stage})
        TaskRouter.current_status(task.id)
      end)

    assert log =~ @ignore_prefix
    assert log =~ task.id
    assert log =~ stage.id
    assert log =~ "none approved"

    assert status.current_stage_id == nil
  end

  test "superseded version: a stage on v1 is ignored and the warning names v2 as current",
       %{task: task, assignee: assignee} do
    {:ok, v1} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    old_stage = create_stage(v1, "old")

    {:ok, v2} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 2})
    _current_stage = create_stage(v2, "current")

    assert Tasks.current_plan(task.id).id == v2.id

    pid = start_router(task, assignee)
    before = TaskRouter.current_status(task.id)

    {:ok, old_stage} = Tasks.transition_stage(old_stage, "running")

    {status, log} =
      with_log(fn ->
        send(pid, {:stage_transitioned, old_stage})
        TaskRouter.current_status(task.id)
      end)

    assert log =~ @ignore_prefix
    assert log =~ old_stage.id
    assert log =~ v1.id
    assert log =~ "current approved plan (#{v2.id})"

    assert status.current_stage_id == before.current_stage_id
    assert status.status == before.status
    refute status.current_stage_id == old_stage.id
  end

  test "NEGATIVE CONTROL: another task's stage transition stays silent",
       %{project: project, task: task, assignee: assignee} do
    {:ok, _own_plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, other_task} =
      Tasks.create_task(%{project_id: project.id, title: "Some other task"})

    {:ok, other_plan} =
      Tasks.create_plan(%{task_id: other_task.id, status: "approved", version: 1})

    other_stage = running_stage(other_plan, "foreign")

    pid = start_router(task, assignee)

    {status, log} =
      with_log(fn ->
        send(pid, {:stage_transitioned, other_stage})
        TaskRouter.current_status(task.id)
      end)

    refute log =~ "ignoring stage_transitioned"
    refute status.current_stage_id == other_stage.id
  end

  test "matched path: a running stage on the current approved plan still drives the router",
       %{task: task, assignee: assignee} do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    stage = create_stage(plan, "coding")

    pid = start_router(task, assignee)
    assert TaskRouter.current_status(task.id).current_stage_id == nil

    {:ok, stage} = Tasks.transition_stage(stage, "running")

    {status, log} =
      with_log(fn ->
        send(pid, {:stage_transitioned, stage})
        TaskRouter.current_status(task.id)
      end)

    assert status.current_stage_id == stage.id
    refute log =~ "ignoring stage_transitioned"
  end

  test "plan_task_id/1 answers nil for a malformed id", %{task: task} do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # Positive control: a real plan id resolves to its task.
    assert Tasks.plan_task_id(plan.id) == task.id

    assert Tasks.plan_task_id("not-a-uuid") == nil
    assert Tasks.plan_task_id(nil) == nil
    assert Tasks.plan_task_id(Ecto.UUID.generate()) == nil
  end
end
