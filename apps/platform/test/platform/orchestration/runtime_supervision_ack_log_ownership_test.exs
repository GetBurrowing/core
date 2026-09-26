defmodule Platform.Orchestration.RuntimeSupervisionAckLogOwnershipTest do
  @moduledoc """
  Task `01a0db63-e4b1` stage 1: the execution-space line for an
  `execution.acked` row is worded by the LeaseManager ETS owner.

  A non-owner row still reaches `RuntimeSupervision.record_event/1` (the
  `RuntimeChannel` `execution_event` handler forces only `runtime_id`), and the
  router refuses it as liveness. The space log must say so rather than read
  "Runtime <B> acked dispatch".

  Every case writes a real row through `Orchestration.record_runtime_event/1`,
  the path `RuntimeChannel` uses, and asserts on the space's messages. The
  refusal case is paired with an owner positive control on the same fixture,
  and a no-lease case pins the unchanged fallback wording.

  `async: false`: the LeaseManager ETS table is global.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration
  alias Platform.Orchestration.{ExecutionSpace, LeaseManager}
  alias Platform.Tasks

  setup do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Ack Log Ownership #{n}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ack log ownership #{n}"})
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    stage_id = Ecto.UUID.generate()
    owner_a = "runtime-owner-a-#{n}"
    stranger_b = "runtime-stranger-b-#{n}"

    :ok = LeaseManager.record_dispatch(task.id, stage_id, "coding", DateTime.utc_now(), owner_a)
    on_exit(fn -> LeaseManager.clear(task.id) end)

    %{task: task, space: space, stage_id: stage_id, a: owner_a, b: stranger_b}
  end

  defp ack!(ctx, runtime_id) do
    assert {:ok, _event} =
             Orchestration.record_runtime_event(%{
               "task_id" => ctx.task.id,
               "phase" => "execution",
               "runtime_id" => runtime_id,
               "event_type" => "execution.acked",
               "idempotency_key" => "ack-log-#{System.unique_integer([:positive])}",
               "payload" => %{"stage_id" => ctx.stage_id, "subagent_id" => "sub-#{runtime_id}"}
             })

    contents(ctx)
  end

  defp contents(ctx) do
    ctx.space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.map(& &1.content)
  end

  test "(i) a non-owner ack posts the refused wording naming the owner", ctx do
    assert %{owner_runtime_id: owner} = LeaseManager.get(ctx.task.id)
    assert owner == ctx.a

    contents = ack!(ctx, ctx.b)

    refused =
      "Runtime #{ctx.b} reported an ack for execution, but this stage is dispatched to " <>
        "runtime #{ctx.a}; the ack was refused and is not counted as liveness"

    assert refused in contents

    b_acked = ~r/Runtime #{Regex.escape(ctx.b)} acked dispatch/
    refute Enum.any?(contents, &Regex.match?(b_acked, &1))
  end

  test "(ii) CONTROL: the owner's ack keeps the acked-dispatch wording", ctx do
    contents = ack!(ctx, ctx.a)

    assert "Runtime #{ctx.a} acked dispatch for execution" in contents
    refute Enum.any?(contents, &String.contains?(&1, "refused"))
  end

  test "(iii) with no lease row, a non-owner ack keeps the acked-dispatch wording", ctx do
    :ok = LeaseManager.clear(ctx.task.id)
    assert LeaseManager.get(ctx.task.id) == nil

    contents = ack!(ctx, ctx.b)

    assert "Runtime #{ctx.b} acked dispatch for execution" in contents
    refute Enum.any?(contents, &String.contains?(&1, "refused"))
  end
end
