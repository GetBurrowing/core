defmodule Platform.Orchestration do
  @moduledoc """
  Task dispatch, heartbeat management, and execution escalation.

  This domain is responsible for ensuring assigned tasks keep moving. It
  assembles deterministic execution context, dispatches to federated agents
  via the RuntimeChannel, monitors stage progression through PubSub, and
  escalates when agents go silent.

  All routing decisions are deterministic — no LLM in the router.

  Routers are started and stopped declaratively by `TaskRouterWatcher`, which
  monitors task state changes via PubSub. There is no imperative API for
  starting/stopping routers from outside this domain.

  ## Public API

    - `task_status/1` — get current router status for a task
    - `resolve_runtime_for_task/1` — resolve agent runtime for a task
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.{RuntimeEvent, RuntimeSupervision, TaskRouter, TaskRouterWatcher}
  alias Platform.Repo

  @doc "Get current router status for a task."
  @spec task_status(String.t()) :: map()
  def task_status(task_id) do
    TaskRouter.current_status(task_id)
  end

  @doc "Persist a normalized runtime execution event and update lease state."
  defdelegate record_runtime_event(attrs), to: RuntimeSupervision, as: :record_event

  @doc "Fetch the current active execution lease for a task, if any."
  defdelegate current_lease_for_task(task_id), to: RuntimeSupervision

  @doc "Fetch the current active execution lease for a specific task/runtime pair, if any."
  defdelegate current_lease_for_task_runtime(task_id, runtime_id), to: RuntimeSupervision

  @doc """
  Has ANY runtime already acked this specific stage of this task?

  The durable answer to "did someone ack stage X". `LeaseManager` is ETS keyed
  by task_id ALONE and `clear/1` deletes the whole row, so the in-memory ack
  flag does not survive the ~15 `clear_liveness/1` sites in `TaskRouter` —
  several of which immediately re-dispatch and re-arm a fresh 5-minute no-ack
  countdown against a stage whose executor already acked and has no reason to
  ack again. That is the `execution.no_ack_timeout` false positive. The
  `execution.acked` runtime_event row, by contrast, is permanent.

  Note the storage shape: `runtime_events` has NO `stage_id` COLUMN. The schema
  is task_id / lease_id / phase / runtime_id / event_type / occurred_at /
  idempotency_key / payload, and `ToolSurface.emit_task_ack/4` writes the stage
  id into `payload["stage_id"]`. Hence the JSONB `->>` fragment rather than a
  plain column comparison.

  A nil or empty `stage_id` returns `false` WITHOUT querying. Planning-phase
  acks are emitted with `stage_id: ""`, and matching those would make this
  function answer "acked" for stages nobody acked — an alarm that suppresses
  itself everywhere is strictly worse than one that fires spuriously.

  ## Query cost — deliberately un-indexed, do not "fix" this

  Migration `20260325013000_create_execution_leases_and_runtime_events.exs`
  indexes `runtime_events` on `[:task_id]`, `[:runtime_id]`, `[:event_type]`
  and `[:occurred_at]`, plus a unique index on `idempotency_key`. There is no
  composite `(task_id, event_type)` index and no index on `payload`, so this
  plans as an index scan on `task_id` followed by an in-memory filter on
  `event_type` and the JSONB key. Rows per task run tens-to-hundreds and this
  is called ONLY on the alarm path — once per elapsed no-ack deadline, never in
  a request hot path. No new index is warranted; please do not add a
  speculative one.
  """
  @spec stage_acked?(String.t(), String.t() | nil) :: boolean()
  def stage_acked?(_task_id, stage_id) when stage_id in [nil, ""], do: false

  def stage_acked?(task_id, stage_id) when is_binary(task_id) and is_binary(stage_id) do
    Repo.exists?(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task_id and e.event_type == "execution.acked" and
            fragment("?->>'stage_id' = ?", e.payload, ^stage_id),
        limit: 1
      )
    )
  end

  def stage_acked?(_task_id, _stage_id), do: false

  @doc """
  Resolve the agent runtime for a task with an agent assignee.

  Delegates to `TaskRouterWatcher.resolve_runtime_for_task/1`.
  """
  @spec resolve_runtime_for_task(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate resolve_runtime_for_task(task), to: TaskRouterWatcher
end
