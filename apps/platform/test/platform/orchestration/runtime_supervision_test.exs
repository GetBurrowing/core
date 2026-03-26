defmodule Platform.Orchestration.RuntimeSupervisionTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{ExecutionSpace, RuntimeSupervision}
  alias Platform.Tasks

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{name: "Lease Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lease Task"})
    task
  end

  test "record_event/1 creates an active lease and mirrors to execution space" do
    task = create_task!()
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started",
               "execution_space_id" => space.id,
               "payload" => %{"summary" => "worker booted"}
             })

    assert event.event_type == "execution.started"
    lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert lease.status == "active"
    assert lease.runtime_id == "runtime:test"

    messages = ExecutionSpace.list_messages_with_participants(space.id)
    assert Enum.any?(messages, &String.contains?(&1.content, "started execution"))
  end

  test "record_event/1 marks blockers and preserves a single active lease" do
    task = create_task!()

    assert {:ok, _started} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started"
             })

    assert {:ok, _blocked} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.blocked",
               "payload" => %{"description" => "waiting on human"}
             })

    lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert lease.status == "blocked"
    assert lease.block_reason == "waiting on human"
  end

  test "record_event/1 is idempotent by idempotency_key" do
    task = create_task!()

    attrs = %{
      "task_id" => task.id,
      "phase" => "execution",
      "runtime_id" => "runtime:test",
      "event_type" => "execution.heartbeat",
      "idempotency_key" => "same-key"
    }

    assert {:ok, first} = RuntimeSupervision.record_event(attrs)
    assert {:ok, second} = RuntimeSupervision.record_event(attrs)
    assert first.id == second.id
  end

  test "current_lease_for_task_runtime/2 expires stale leases on lookup" do
    task = create_task!()

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started"
             })

    lease_id = event.lease_id
    stale_time = DateTime.add(DateTime.utc_now(), -60, :second)

    from(l in Platform.Orchestration.ExecutionLease, where: l.id == ^lease_id)
    |> Platform.Repo.update_all(set: [expires_at: stale_time])

    assert RuntimeSupervision.current_lease_for_task_runtime(task.id, "runtime:test") == nil

    expired = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, lease_id)
    assert expired.status == "expired"
  end
end
