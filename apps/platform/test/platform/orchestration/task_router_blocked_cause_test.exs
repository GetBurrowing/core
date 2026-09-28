defmodule Platform.Orchestration.TaskRouterBlockedCauseTest do
  @moduledoc """
  Task 01a0e7ac stage 1: the router's two escalations record their CAUSE on
  the task as `metadata["blocked_cause"]`, not only as prose.

  A fired no-ack writes kind `execution.no_ack_timeout`; a fired safety net
  writes kind `execution.safety_net_fired`. Both carry the lease's stage_id
  and owner runtime, and the status the task held before the block.

  Clock-poke pattern mirrors `task_router_stale_no_ack_timer_test.exs`
  (`expire_no_ack_deadline!/1`) and `task_router_safety_net_copy_test.exs`.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Orchestration.{LeaseManager, TaskRouter}
  alias Platform.Tasks

  setup do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Router Blocked Cause #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router blocked cause #{n}",
        description: "Pin the router's blocked_cause stamp",
        deploy_target: "production"
      })

    {:ok, task} = Tasks.transition_task_status(task, "in_progress")
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage one",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-blocked-cause-#{n}"}

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

      LeaseManager.clear(task.id)
    end)

    %{task: task, stage: stage, assignee: assignee}
  end

  test "a fired no-ack records kind execution.no_ack_timeout with the lease's stage and owner",
       %{task: task, stage: stage, assignee: assignee} do
    pid = boot_router!(task, assignee)

    lease = LeaseManager.get(task.id)
    assert lease.no_ack_at, "expected an armed no-ack deadline"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task.id, %{lease | no_ack_at: past}})

    send(pid, :check_no_ack)
    :ok = sync_router(task.id)

    record = Tasks.get_task_record(task.id)
    assert record.status == "blocked"

    assert %{
             "kind" => "execution.no_ack_timeout",
             "stage_id" => stage_id,
             "runtime_id" => runtime_id,
             "prior_status" => "in_progress",
             "at" => _
           } = record.metadata["blocked_cause"]

    assert stage_id == stage.id
    assert runtime_id == assignee.id
    assert runtime_id == lease.owner_runtime_id
    assert String.starts_with?(record.metadata["blocked_reason"], "Executor never acked")
  end

  test "a fired safety net records kind execution.safety_net_fired",
       %{task: task, stage: stage, assignee: assignee} do
    pid = boot_router!(task, assignee)

    lease = LeaseManager.get(task.id)
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task.id, %{lease | safety_net_at: past}})

    send(pid, :check_safety_net)
    :ok = sync_router(task.id)

    record = Tasks.get_task_record(task.id)
    assert record.status == "blocked"

    assert %{
             "kind" => "execution.safety_net_fired",
             "stage_id" => stage_id,
             "runtime_id" => runtime_id,
             "prior_status" => "in_progress"
           } = record.metadata["blocked_cause"]

    assert stage_id == stage.id
    assert runtime_id == assignee.id
    assert String.starts_with?(record.metadata["blocked_reason"], "Stage safety-net exceeded")
  end

  defp boot_router!(task, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end
end
