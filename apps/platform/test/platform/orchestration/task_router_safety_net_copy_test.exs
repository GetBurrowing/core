defmodule Platform.Orchestration.TaskRouterSafetyNetCopyTest do
  @moduledoc """
  Task `01a0db63-e4b1` stage 1: the `execution.safety_net_fired` blocker is
  worded by `lease.ack_at`.

  An `alarm_silence`'d stage that never acked defers only the no-ack alarm;
  the safety net still fires with `ack_at: nil`. The old sentence ("The
  executor acked but ...") is false there. With `ack_at` set, the old sentence
  is kept byte-for-byte.

  Both the space post and `metadata["blocked_reason"]` receive the SAME string
  (`fire_safety_net_alert/2` passes one binding to both), so each case asserts
  both.

  The fixture keeps a running stage with open validations, so the check
  reaches `fire_safety_net_alert/2` rather than a suppression branch. Pattern
  mirrors `task_router_safety_net_suppression_test.exs`.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  @no_ack_sentence "No ack from the dispatched runtime is recorded on the lease, and no " <>
                     "validation progress arrived within the stage's safety-net window. " <>
                     "Check whether the agent is running at all; manual intervention may be required."

  @acked_sentence "The executor acked but has not produced validation progress within the " <>
                    "stage's safety-net window. Check whether the agent is stuck; manual " <>
                    "intervention may be required."

  setup do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Safety Net Copy #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Safety-net copy #{n}",
        description: "Pin the ack_at-keyed safety-net sentence",
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

    {:ok, _test} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-safety-net-copy-#{n}"}

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

  test "an unacked lease fires the no-ack sentence in both the post and blocked_reason", ctx do
    pid = boot_router!(ctx.task, ctx.assignee)

    lease = LeaseManager.get(ctx.task.id)
    assert lease, "expected the router to arm a lease"
    assert lease.ack_at == nil

    fire!(pid, ctx.task.id)

    [post] = blocker_posts(ctx.task.id)
    assert String.contains?(post, @no_ack_sentence)
    refute String.contains?(post, "The executor acked")

    reason = Tasks.get_task_record(ctx.task.id).metadata["blocked_reason"]
    assert String.contains?(reason, @no_ack_sentence)
    refute String.contains?(reason, "The executor acked")
    assert String.contains?(post, reason)
  end

  test "CONTROL: an owner-acked lease keeps the original acked sentence", ctx do
    pid = boot_router!(ctx.task, ctx.assignee)

    lease = LeaseManager.get(ctx.task.id)
    assert lease, "expected the router to arm a lease"
    assert :ok = LeaseManager.record_ack(ctx.task.id, lease.owner_runtime_id, "sub-owner")
    assert %DateTime{} = LeaseManager.get(ctx.task.id).ack_at

    fire!(pid, ctx.task.id)

    [post] = blocker_posts(ctx.task.id)
    assert String.contains?(post, @acked_sentence)
    refute String.contains?(post, "No ack from the dispatched runtime")

    reason = Tasks.get_task_record(ctx.task.id).metadata["blocked_reason"]
    assert String.contains?(reason, @acked_sentence)
    assert String.contains?(post, reason)
  end

  defp boot_router!(task, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end

  defp fire!(pid, task_id) do
    lease = LeaseManager.get(task_id)
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    refute lease.safety_net_fired?

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | safety_net_at: past}})

    send(pid, :check_safety_net)
    :ok = sync_router(task_id)
  end

  defp blocker_posts(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.map(& &1.content)
    |> Enum.filter(&String.contains?(&1, "Stage safety-net exceeded"))
  end
end
