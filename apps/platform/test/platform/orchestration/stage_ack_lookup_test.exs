defmodule Platform.Orchestration.StageAckLookupTest do
  @moduledoc """
  `Platform.Orchestration.last_stage_ack_at/3` and `last_stage_ack/3` — the
  durable, runtime-scoped "did the dispatched runtime ack this stage" read that
  survives `LeaseManager.clear/1`.

  Until task `01a0db63-c4f3` this file pinned the unscoped `stage_acked?/2`.
  That function was deleted with its `/2` siblings; every case below is the
  same case retargeted at the `/3` read, plus the runtime-scope cases the `/2`
  form could not express.

  Rows are written through `Platform.Orchestration.record_runtime_event/1`, the
  real write path `ToolSurface.emit_task_ack/4` uses, so the test exercises the
  actual `payload["stage_id"]` shape rather than a hand-built row that could
  agree with a wrong query.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks

  @runtime "runtime:test"

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{name: "Ack Lookup Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ack Lookup Task"})
    task
  end

  defp record_ack!(task_id, stage_id, runtime_id \\ @runtime) do
    {:ok, event} =
      Orchestration.record_runtime_event(%{
        "task_id" => task_id,
        "phase" => "execution",
        "runtime_id" => runtime_id,
        "event_type" => "execution.acked",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{
          "stage_id" => stage_id,
          "acked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "subagent_id" => "subagent-test"
        }
      })

    event
  end

  test "returns the writer's ack for a persisted execution.acked whose payload stage_id matches" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()
    event = record_ack!(task.id, stage_id)

    assert Orchestration.last_stage_ack_at(task.id, stage_id, @runtime) == event.occurred_at

    assert {occurred_at, "subagent-test"} =
             Orchestration.last_stage_ack(task.id, stage_id, @runtime)

    assert occurred_at == event.occurred_at
  end

  test "nil for another runtime's ack of the same stage" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()
    record_ack!(task.id, stage_id, "runtime:other")

    assert Orchestration.last_stage_ack_at(task.id, stage_id, @runtime) == nil
    assert Orchestration.last_stage_ack(task.id, stage_id, @runtime) == nil

    # Positive control on the same row: the writer's own scope sees it.
    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage_id, "runtime:other")
  end

  test "nil for a nil or blank runtime_id even when acks exist" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()
    record_ack!(task.id, stage_id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage_id, @runtime)
    assert Orchestration.last_stage_ack_at(task.id, stage_id, nil) == nil
    assert Orchestration.last_stage_ack_at(task.id, stage_id, "") == nil
    assert Orchestration.last_stage_ack(task.id, stage_id, nil) == nil
    assert Orchestration.last_stage_ack(task.id, stage_id, "") == nil
  end

  test "nil for a different stage_id on the same task" do
    task = create_task!()
    record_ack!(task.id, Ecto.UUID.generate())

    assert Orchestration.last_stage_ack_at(task.id, Ecto.UUID.generate(), @runtime) == nil
  end

  test "nil for a matching stage_id on a DIFFERENT task" do
    acked_task = create_task!()
    other_task = create_task!()
    stage_id = Ecto.UUID.generate()
    record_ack!(acked_task.id, stage_id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(acked_task.id, stage_id, @runtime)
    assert Orchestration.last_stage_ack_at(other_task.id, stage_id, @runtime) == nil
  end

  test "nil when the task has no ack rows at all" do
    task = create_task!()

    assert Orchestration.last_stage_ack_at(task.id, Ecto.UUID.generate(), @runtime) == nil
  end

  test "nil for a non-acked event type carrying the same payload stage_id" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()

    {:ok, _} =
      Orchestration.record_runtime_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => @runtime,
        "event_type" => "execution.started",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{"stage_id" => stage_id}
      })

    assert Orchestration.last_stage_ack_at(task.id, stage_id, @runtime) == nil
  end

  # LOAD-BEARING. Planning-phase acks are emitted with `stage_id: ""`. Without
  # the nil/empty guard this read would answer "acked" for every stage on a
  # task that ever saw a planning ack — an alarm that suppresses itself
  # everywhere, strictly worse than the false positive being fixed.
  #
  # The `""`-payload row is inserted through the RuntimeEvent changeset rather
  # than `record_runtime_event/1`, and that is deliberate rather than a
  # shortcut: `RuntimeSupervision.upsert_lease/2` reads `payload["stage_id"]`
  # into an `execution_leases.stage_id` (uuid) `where:` clause, so `""` raises
  # Ecto.Query.CastError before the row is written. The row shape is still real
  # — the schema permits it and any writer not going through the lease upsert
  # produces it — and it is the ONLY shape under which this guard can be shown
  # to fire. The row is written by the SAME runtime the read is scoped to, so
  # only the stage_id guard stands between it and a hit.
  test "nil for empty or nil stage_id even when acks exist" do
    task = create_task!()
    record_ack!(task.id, Ecto.UUID.generate())

    {:ok, _} =
      %RuntimeEvent{}
      |> RuntimeEvent.changeset(%{
        task_id: task.id,
        phase: "planning",
        runtime_id: @runtime,
        event_type: "execution.acked",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "planning-ack-#{System.unique_integer([:positive])}",
        payload: %{"stage_id" => "", "subagent_id" => "subagent-test"}
      })
      |> Repo.insert()

    assert Orchestration.last_stage_ack_at(task.id, "", @runtime) == nil
    assert Orchestration.last_stage_ack_at(task.id, nil, @runtime) == nil
    assert Orchestration.last_stage_ack(task.id, "", @runtime) == nil
    assert Orchestration.last_stage_ack(task.id, nil, @runtime) == nil
  end
end
