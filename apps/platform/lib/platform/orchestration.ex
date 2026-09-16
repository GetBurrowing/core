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
  When a stage was most recently acked, from the durable `runtime_events` log.

  The recency twin of `stage_acked?/2`, and it exists because the boolean is
  not enough to answer "is an executor still working this stage?". Callers
  that need to compare an ack against a deadline need the instant, not the
  fact.

  ## Why not read `LeaseManager`'s `safety_net_at` instead

  Because it is gone exactly when the question is hardest. `TaskRouter.terminate/2`
  calls `clear_liveness/1`, which deletes the whole ETS lease row, so a router
  that stops and restarts reads back no deadline at all — while the executor it
  dispatched is still running. That is the shape reported in task `01a04135`:
  an ack at 02:09 with a 03:39 safety net, a router restart, and a re-dispatch
  of the same stage at 02:17. Postgres is the only store that survives it.

  Returns `nil` when the stage has never been acked, and for a nil/blank
  `stage_id` — planning-phase acks are emitted with `stage_id: ""` and matching
  those would hand back an ack belonging to no stage, the same trap
  `stage_acked?/2` documents.

  Ordered by `occurred_at` then `id` so a re-ack in the same microsecond still
  resolves to the newer row (ids are UUIDv7, monotonic in time). Shares
  `stage_acked?/2`'s deliberately un-indexed query shape — see that function's
  cost note before adding an index for this.
  """
  @spec last_stage_ack_at(String.t(), String.t() | nil) :: DateTime.t() | nil
  def last_stage_ack_at(task_id, stage_id),
    do: last_stage_event_at(task_id, stage_id, "execution.acked")

  @doc """
  The most recent stage ack as `{occurred_at, subagent_id}`, or `nil`.

  The identity twin of `last_stage_ack_at/2`, and it exists because an INSTANT
  alone does not let a reader tell a live executor from a dead one. On the
  2026-09-11 incident (ticket `01a08e86`) the router withheld a dispatch saying
  the stage "already has an acked executor"; the executor had returned twenty
  minutes earlier, and the notice named neither when the ack happened nor who
  made it, so the only way to check the assertion was to query `runtime_events`
  by hand. Handing back the subagent handle alongside the instant is what makes
  the notice checkable by the person reading it.

  `subagent_id` is read from the `execution.acked` payload, whose shape is
  documented at `RuntimeSupervision`'s `@event_statuses` entry:
  `%{"stage_id", "acked_at", "runtime_id", "subagent_id"}`. It is `nil` for
  legacy rows written before task `019f6c73` made the handle mandatory — a nil
  is a real and expected value here, not a failure, and callers must render it
  rather than crash on it.

  Returns the `occurred_at` column, NOT the payload's `"acked_at"` string: the
  column is what `last_stage_ack_at/2` compares against `safety_net_ms`, and a
  notice quoting a different field than the guard measured would be the kind of
  near-miss this stage exists to remove. Same `stage_id` guard, ordering and
  deliberately un-indexed query shape as `last_stage_event_at/3` — read
  `stage_acked?/2`'s cost note before adding an index for this.
  """
  @spec last_stage_ack(String.t(), String.t() | nil) :: {DateTime.t(), String.t() | nil} | nil
  def last_stage_ack(_task_id, stage_id) when stage_id in [nil, ""], do: nil

  def last_stage_ack(task_id, stage_id) when is_binary(task_id) and is_binary(stage_id) do
    from(e in RuntimeEvent,
      where:
        e.task_id == ^task_id and e.event_type == "execution.acked" and
          fragment("?->>'stage_id' = ?", e.payload, ^stage_id),
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: 1,
      select: {e.occurred_at, fragment("?->>'subagent_id'", e.payload)}
    )
    |> Repo.one()
  end

  def last_stage_ack(_task_id, _stage_id), do: nil

  @doc """
  When a stage last emitted `event_type`, from the durable `runtime_events` log.

  The general form behind `last_stage_ack_at/2`. It exists because "was this
  stage acked recently" is not on its own the same question as "is an executor
  still on it": an `execution.finished` arriving AFTER the ack says the
  subagent is gone, and a caller comparing the two instants can tell the
  difference. `TaskRouter`'s live-acked-executor guard does exactly that.

  Same `stage_id` guard and the same deliberately un-indexed query shape as
  `stage_acked?/2` — read that function's cost note before adding an index.
  """
  @spec last_stage_event_at(String.t(), String.t() | nil, String.t()) :: DateTime.t() | nil
  def last_stage_event_at(_task_id, stage_id, _event_type) when stage_id in [nil, ""], do: nil

  def last_stage_event_at(task_id, stage_id, event_type)
      when is_binary(task_id) and is_binary(stage_id) and is_binary(event_type) do
    Repo.one(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task_id and e.event_type == ^event_type and
            fragment("?->>'stage_id' = ?", e.payload, ^stage_id),
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: 1,
        select: e.occurred_at
      )
    )
  end

  def last_stage_event_at(_task_id, _stage_id, _event_type), do: nil

  @doc """
  Resolve the agent runtime for a task with an agent assignee.

  Delegates to `TaskRouterWatcher.resolve_runtime_for_task/1`.
  """
  @spec resolve_runtime_for_task(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate resolve_runtime_for_task(task), to: TaskRouterWatcher
end
