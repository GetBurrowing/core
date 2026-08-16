defmodule Platform.Orchestration.StageAckLookupTest do
  @moduledoc """
  `Platform.Orchestration.stage_acked?/2` — the durable "did someone ack this
  stage" read that survives `LeaseManager.clear/1`.

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

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{name: "Ack Lookup Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ack Lookup Task"})
    task
  end

  defp record_ack!(task_id, stage_id) do
    {:ok, event} =
      Orchestration.record_runtime_event(%{
        "task_id" => task_id,
        "phase" => "execution",
        "runtime_id" => "runtime:test",
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

  test "true for a persisted execution.acked whose payload stage_id matches" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()
    record_ack!(task.id, stage_id)

    assert Orchestration.stage_acked?(task.id, stage_id)
  end

  test "false for a different stage_id on the same task" do
    task = create_task!()
    record_ack!(task.id, Ecto.UUID.generate())

    refute Orchestration.stage_acked?(task.id, Ecto.UUID.generate())
  end

  test "false for a matching stage_id on a DIFFERENT task" do
    acked_task = create_task!()
    other_task = create_task!()
    stage_id = Ecto.UUID.generate()
    record_ack!(acked_task.id, stage_id)

    assert Orchestration.stage_acked?(acked_task.id, stage_id)
    refute Orchestration.stage_acked?(other_task.id, stage_id)
  end

  test "false when the task has no ack rows at all" do
    task = create_task!()

    refute Orchestration.stage_acked?(task.id, Ecto.UUID.generate())
  end

  test "false for a non-acked event type carrying the same payload stage_id" do
    task = create_task!()
    stage_id = Ecto.UUID.generate()

    {:ok, _} =
      Orchestration.record_runtime_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => "runtime:test",
        "event_type" => "execution.started",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{"stage_id" => stage_id}
      })

    refute Orchestration.stage_acked?(task.id, stage_id)
  end

  # LOAD-BEARING. Planning-phase acks are emitted with `stage_id: ""`. Without
  # the nil/empty guard this function would answer "acked" for every stage on a
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
  # to fire. Verified by mutation: delete the `stage_id in [nil, ""]` clause and
  # this assertion goes red.
  test "false for empty or nil stage_id even when acks exist" do
    task = create_task!()
    record_ack!(task.id, Ecto.UUID.generate())

    {:ok, _} =
      %RuntimeEvent{}
      |> RuntimeEvent.changeset(%{
        task_id: task.id,
        phase: "planning",
        runtime_id: "runtime:test",
        event_type: "execution.acked",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "planning-ack-#{System.unique_integer([:positive])}",
        payload: %{"stage_id" => "", "subagent_id" => "subagent-test"}
      })
      |> Repo.insert()

    refute Orchestration.stage_acked?(task.id, "")
    refute Orchestration.stage_acked?(task.id, nil)
  end
end
