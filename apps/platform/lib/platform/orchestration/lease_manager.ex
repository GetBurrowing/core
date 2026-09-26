defmodule Platform.Orchestration.LeaseManager do
  @moduledoc """
  Ephemeral in-memory router liveness store — task 019f640d stage 2.

  Backs the event-driven TaskRouter redesign (stages 3-6): the router
  arms one `:check_no_ack` and one `:check_safety_net` timer per stage
  dispatch, then consults this module to decide whether to fire or
  reschedule when a timer wakes up. Callers to `mark_*_fired/1` get
  idempotency guarantees so a spurious re-wake never re-fires an event.

  Deliberately distinct from `Platform.Orchestration.ExecutionLease`
  (Ecto schema, `execution_leases` table) — that module is the
  persistent per-runtime lease used by RuntimeSupervision. This module
  is the transient router liveness view per Rowan's ETS rule
  ("meeting-lifetime / session-lifetime queues + caches go in ETS,
  not Ecto"). Router state is per-task and reconstructed at boot
  from PubSub replay — no need for durability.

  ## Data shape

  Table: `:orchestration_lease_manager`, `set`, `named_table`,
  `public`, `read_concurrency: true`. Mirrors
  `Platform.Meetings.IntentQueue` so the ownership + concurrency story
  is identical.

  Row: `{task_id, lease_map}` where `lease_map` is:

      %{
        stage_id: binary(),
        stage_kind: binary(),
        dispatched_at: DateTime.t(),      # FIRST dispatch of this stage-instance; a re-dispatch does not move it
        ack_at: DateTime.t() | nil,
        last_progress_at: DateTime.t() | nil,
        safety_net_at: DateTime.t() | nil,   # nil = safety-net disabled (manual_approval)
        no_ack_at: DateTime.t() | nil,       # nil = no-ack disabled OR ack received
        no_ack_fired?: boolean(),
        safety_net_fired?: boolean(),
        silenced_until: DateTime.t() | nil,  # nil = no silence; DateTime = suppress :check_no_ack until this instant
        owner_runtime_id: binary(),          # AgentRuntime runtime_id this stage-instance was dispatched to
        ack_runtime_id: binary() | nil,      # runtime_id of the caller whose ack was ACCEPTED (always the owner)
        ack_subagent_id: binary() | nil      # caller-asserted subagent handle of that ack; audit only, never verified
      }

  ## Ack ownership (task 01a0c762 stage 1)

  A lease belongs to the runtime it was dispatched to
  (`owner_runtime_id`). `record_ack/3` accepts an ack only from that
  runtime: a non-owner or `nil` caller gets
  `{:error, {:not_owner, owner_runtime_id}}` and the row is left
  exactly as it was. Before this, any caller holding a `task_id`
  could extend the safety net of a stage nobody was working, which
  bought a false liveness window of 90 to 120 minutes that ended
  parked on a human.

  The ownership key is the AgentRuntime `runtime_id`, which both
  federation transports stamp from authenticated state. `subagent_id`
  is caller-asserted and is recorded (`ack_subagent_id`) for audit
  only; it takes no part in the ownership decision.

  A same-stage dispatch to a DIFFERENT owner (reassignment) is not a
  re-dispatch: it builds a fresh row for the new owner. The old
  owner's ack says nothing about the new owner's pickup.

  ## Progress ownership (task 01a0db63 stage 1)

  `record_progress/2` is gated the same way: only the lease owner's
  progress extends `safety_net_at` and stamps `last_progress_at`. A
  non-owner or `nil` caller gets `{:error, {:not_owner, owner}}`, the
  row is left exactly as it was, and `[:platform, :orchestration,
  :progress_refused]` telemetry plus one warning record the refusal.
  Before this, a heartbeat from ANY runtime pushed the net of a stage
  whose dispatched owner was dead another 90 to 120 minutes out.

  ## Clear ownership (task 01a0dd2c stage 1)

  `clear_if_owner/2` is the event-driven delete: only the lease owner's
  terminal event removes the row. A non-owner, `nil` or non-binary
  caller gets `{:error, {:not_owner, owner}}`, the row is left exactly
  as it was, and `[:platform, :orchestration, :clear_refused]`
  telemetry plus one warning record the refusal. Before this, any
  runtime's `execution.finished` (or failed / abandoned /
  assignment.rejected) deleted the row through `clear/1`, and with the
  row gone both the no-ack and the safety-net alarm went quiet.
  `clear/1` stays unconditional: it is the router-internal path.

  All three gates (`record_ack/3`, `record_progress/2`,
  `clear_if_owner/2`) share one compare (`owner?/2`) and one refusal
  path.

  ## Dispatch vs. re-dispatch (task 019fa469 stage 6)

  `record_dispatch/5` is keyed on `stage_id` and owner, not on "a
  dispatch happened":

    * **New stage** (no row, or the row's `stage_id` differs) — build a
      fresh zero-ack row. A stage transition really has not been acked.
    * **Same stage, different owner** (reassignment, task 01a0c762) —
      build a fresh zero-ack row for the new owner.
    * **Same stage, same owner** (the row's `stage_id` and
      `owner_runtime_id` both match) — this is a
      RE-dispatch: the same prompt delivered twice. Preserve `ack_at`,
      `last_progress_at`, `dispatched_at`, `no_ack_fired?`,
      `safety_net_fired?` and `silenced_until`; extend `safety_net_at`;
      leave `no_ack_at` alone unless an ack has landed.

  Before this distinction existed, every dispatch rebuilt the row with
  `ack_at: nil` and a fresh countdown, so a duplicate `task_assigned`
  erased an ack that had already landed and re-armed the no-ack alarm
  against a live agent. The module's own docs already described the
  stage-transition semantics (see `record_ack/3` and the "Silence dies
  with the row" note below, both of which say *subsequent stage*); only
  the implementation applied them to every dispatch.

  OUT OF SCOPE here: suppressing the redundant dispatch itself. Whatever
  emits a duplicate `task_assigned` is a separate concern (sibling task
  019fa2fc's suppression work). This module only stops the duplicate
  from destroying a valid ack.

  ## Silence semantics

  `silence/3` is the operator escape hatch for the `execution.no_ack_timeout`
  alarm — used by the `alarm_silence` MCP tool (task 019f6791-c01b stage 3)
  when a subagent's MCP client cache lacks `task_ack`. Sets `silenced_until`
  to an absolute future timestamp (capped at `now + 24h`). Orthogonal to
  `ack_at` — `record_ack/3` does NOT clear the silence, and `silence/3`
  does NOT clear ack state. `clear/1` deletes the row so a stage
  transition ends any silence by side effect. Consumers (the router in
  task 019f6791-c01b stage 2) check `silenced_until` when a
  `:check_no_ack` timer fires and reschedule instead of firing when the
  silence is still in effect.

  ## Concurrency

  Reads (`get/1`) hit ETS directly and are lock-free thanks to
  `read_concurrency: true`. Every mutating call (`record_*`,
  `mark_*_fired`, `clear_if_owner/2`, but NOT `clear/1` which is a
  single-op delete) is
  serialised through the owning GenServer so the read-modify-write
  pair sees a consistent snapshot — critical for
  `mark_no_ack_fired/1`'s once-only semantics.

  ## Stage-kind timeout matrix

  See `stage_kind_timeouts/0` for the p95-buffer values embedded from
  the audit (task 019f640d stage 3). `manual_approval` is disabled
  (both `ack_ms` and `safety_net_ms` are `nil`) per Rowan's spec — the
  router treats such stages as "no safety-net" and skips arming the
  timers entirely.
  """

  use GenServer

  require Logger

  @table :orchestration_lease_manager

  # Position of the lease_map inside the ETS tuple `{task_id, lease}`.
  # `:ets.update_element/3` positions are 1-based, and the key is
  # position 1, so the lease lives at position 2.
  @item_pos 2

  # Safety-net values sourced from the audit p95 buffers. See ADR 0025
  # amendment (task 019f640d stage 6) for the full derivation. Tunable
  # in one line without touching the state machine.
  @stage_kind_timeouts %{
    "coding" => %{ack_ms: 5 * 60_000, safety_net_ms: 90 * 60_000},
    "deploying" => %{ack_ms: 5 * 60_000, safety_net_ms: 90 * 60_000},
    "review" => %{ack_ms: 5 * 60_000, safety_net_ms: 90 * 60_000},
    "ci_check" => %{ack_ms: 5 * 60_000, safety_net_ms: 90 * 60_000},
    "planning" => %{ack_ms: 5 * 60_000, safety_net_ms: 120 * 60_000},
    "manual_approval" => %{ack_ms: nil, safety_net_ms: nil}
  }

  # Upper bound for `silence/3`. Prevents indefinite alarm suppression —
  # operators must re-silence after 24h if the underlying condition
  # persists. Value chosen to comfortably outlast the longest configured
  # `safety_net_ms` (120 min for planning) while still forcing an
  # operator revisit inside a working day.
  @silence_cap_ms 24 * 60 * 60 * 1_000

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start the lease manager. Creates the named public ETS table on
  init so reads from any process are lock-free. Booted from
  `Platform.Application`'s child list BEFORE
  `Platform.Orchestration.TaskRouterSupervisor` — routers must be
  able to call `record_dispatch/5` at boot without racing the table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # `:public` tables die with their owner, so this branch is
        # defensive against tests that pre-create the table.
        :ok
    end

    {:ok, %{}}
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Return the per-stage-kind timeout matrix — a pure map, safe to call
  from any process. Consumers (the router in stage 3) look up
  `stage_kind_timeouts()[stage_kind]` to arm timers.
  """
  @spec stage_kind_timeouts() :: %{
          binary() => %{
            ack_ms: pos_integer() | nil,
            safety_net_ms: pos_integer() | nil
          }
        }
  def stage_kind_timeouts, do: @stage_kind_timeouts

  @doc """
  Record a dispatch for `task_id` on `stage_id` to the runtime
  `owner_runtime_id` (the AgentRuntime `runtime_id` the router
  addressed the dispatch to).

  When no lease exists, or the existing lease is for a DIFFERENT
  stage (a real stage transition), writes a zero-ack, zero-progress
  row with `safety_net_at` / `no_ack_at` computed from
  `dispatched_at` + the stage-kind timeouts.

  When the existing lease is for the same stage but a DIFFERENT
  owner (reassignment), a fresh row is written for the new owner:
  `ack_at` nil, no-ack re-armed from `dispatched_at`, no silence.

  When the existing lease is for the SAME stage and the SAME owner,
  this is a re-dispatch: ack / progress / fired / silence state is preserved,
  `safety_net_at` is extended, and `no_ack_at` is left on its
  original deadline (or nil'd when an ack already landed). See
  "Dispatch vs. re-dispatch" in the moduledoc for why.

  For unknown `stage_kind` values (or `manual_approval`) both
  timeouts are stored as `nil` — the router uses that as its signal
  to skip arming the corresponding timer.
  """
  @spec record_dispatch(binary(), binary(), binary(), DateTime.t(), binary()) :: :ok
  def record_dispatch(
        task_id,
        stage_id,
        stage_kind,
        %DateTime{} = dispatched_at,
        owner_runtime_id
      )
      when is_binary(task_id) and is_binary(stage_id) and is_binary(stage_kind) and
             is_binary(owner_runtime_id) do
    GenServer.call(
      __MODULE__,
      {:record_dispatch, task_id, stage_id, stage_kind, dispatched_at, owner_runtime_id}
    )
  end

  @doc """
  Record that the executor/reviewer acked the dispatch.

  `caller_runtime_id` is the AUTHENTICATED runtime making the ack. It
  must equal the lease's `owner_runtime_id`; otherwise (including
  `nil` or a non-binary caller — fail closed) the call returns
  `{:error, {:not_owner, owner_runtime_id}}`, leaves the ETS row
  unchanged, emits `[:platform, :orchestration, :ack_refused]`
  telemetry and logs one warning. `subagent_id` is recorded as
  `ack_subagent_id` for audit only.

  On an owner ack: stamps `ack_runtime_id` / `ack_subagent_id`, sets
  `ack_at: now`, clears `no_ack_at` (nil) and resets
  `no_ack_fired?` (false) so a re-dispatch on the same task later can
  arm fresh timers, and extends `safety_net_at` to `now +
  safety_net_ms` (safety-net countdown restarts from the ack instant).

  Returns `{:error, :not_found}` when no lease exists for `task_id`
  (e.g. router hasn't recorded a dispatch yet). Direct callers
  (the `task_ack` MCP tool in stage 5) treat this as a soft failure —
  belt-and-braces write that races the router boot.
  """
  @spec record_ack(binary(), binary() | nil, binary() | nil) ::
          :ok | {:error, :not_found} | {:error, {:not_owner, binary() | nil}}
  def record_ack(task_id, caller_runtime_id, subagent_id \\ nil) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:record_ack, task_id, caller_runtime_id, subagent_id})
  end

  @doc """
  Suppress the `execution.no_ack_timeout` alarm for the lease until
  `until`. Operator escape hatch used by the `alarm_silence` MCP tool
  (task 019f6791-c01b) — silence exists so an operator can tell the
  router "I know a subagent is working this stage; don't fire the
  no-ack alarm and don't post a `needs_human=true` blocker" without
  the anti-pattern of calling `report_blocker(needs_human: false)`.

  Semantics:

    * `until` MUST be a `%DateTime{}` strictly greater than `now`.
      Past or equal timestamps return `{:error, :invalid_until}`.
    * `until` is capped at `now + 24h`. Larger values return
      `{:error, :cap_exceeded}` and the caller must re-silence.
    * `reason` (>= 8 char binary at the MCP boundary — this module
      accepts any binary) is not persisted in the lease itself; the
      caller emits an audit runtime_event alongside for durability.
    * Silence is orthogonal to `ack_at`. `record_ack/3` does NOT
      clear `silenced_until` (an ack is progress, silence is an
      operator override — different lifecycles). Re-silencing on a
      row that already has a `silenced_until` overwrites the
      timestamp.
    * Silence dies with the row: `clear/1` deletes the lease and
      `record_dispatch/5` on a subsequent stage builds a fresh
      `silenced_until: nil` row. Silence never leaks across stage
      transitions.

  Returns `:ok` on success, `{:error, :not_found}` when no lease
  exists (the router hasn't recorded the dispatch yet — MCP tool
  callers surface this as a recoverable retry hint).
  """
  @spec silence(binary(), DateTime.t(), binary()) ::
          :ok | {:error, :not_found | :invalid_until | :cap_exceeded}
  def silence(task_id, %DateTime{} = until, reason)
      when is_binary(task_id) and is_binary(reason) do
    GenServer.call(__MODULE__, {:silence, task_id, until, reason})
  end

  @doc """
  Record progress from the runtime the stage was dispatched to.
  Extends `safety_net_at` to `now + safety_net_ms` for the lease's
  stage_kind and stamps `last_progress_at: now`. Does NOT clear the
  no-ack fields or `silenced_until` — progress evidence is not an ack.

  `caller_runtime_id` must equal the lease's `owner_runtime_id` (task
  01a0db63 stage 1), under the same fail-closed compare `record_ack/3`
  uses. A non-owner, `nil` or non-binary caller — and any caller
  against a row with no owner — gets `{:error, {:not_owner, owner}}`;
  the row is left exactly as it was, and the refusal is recorded as
  `[:platform, :orchestration, :progress_refused]` telemetry and one
  warning.

  There is no `record_progress/1`: it was deleted so an unthreaded
  caller fails to compile instead of silently failing closed. A future
  router-internal progress source (one with no event runtime to pass)
  must pass `lease.owner_runtime_id` explicitly, as
  `TaskRouter.maybe_fire_no_ack/3` does for `record_ack/3`.

  Returns `{:error, :not_found}` when no lease exists, checked before
  the owner compare.
  """
  @spec record_progress(binary(), term()) ::
          :ok | {:error, :not_found} | {:error, {:not_owner, binary() | nil}}
  def record_progress(task_id, caller_runtime_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:record_progress, task_id, caller_runtime_id})
  end

  @doc """
  Idempotency guard for the no-ack event. Returns `{:ok, :fired}` on
  the first call, `{:ok, :already_fired}` on every subsequent call.
  The router uses this to guarantee a single loud
  `execution.no_ack_timeout` per stage-instance regardless of how
  many `:check_no_ack` messages happen to reach it.
  """
  @spec mark_no_ack_fired(binary()) ::
          {:ok, :fired} | {:ok, :already_fired} | {:error, :not_found}
  def mark_no_ack_fired(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:mark_no_ack_fired, task_id})
  end

  @doc """
  Idempotency guard for the safety-net event. Returns
  `{:ok, :fired}` on the first call, `{:ok, :already_fired}` on
  every subsequent call. Same rationale as `mark_no_ack_fired/1`.
  """
  @spec mark_safety_net_fired(binary()) ::
          {:ok, :fired} | {:ok, :already_fired} | {:error, :not_found}
  def mark_safety_net_fired(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:mark_safety_net_fired, task_id})
  end

  @doc """
  Lock-free lookup — return the lease map for `task_id` or `nil`
  when no row exists. Hits ETS directly (bypasses the GenServer) so
  routers can consult the lease on hot paths without serialising
  through the owner.
  """
  @spec get(binary()) :: map() | nil
  def get(task_id) when is_binary(task_id) do
    if ensure_table() do
      case :ets.lookup(@table, task_id) do
        [{^task_id, lease}] -> lease
        [] -> nil
      end
    else
      nil
    end
  end

  @doc """
  Delete the lease row for `task_id` UNCONDITIONALLY. The
  router-internal path: stage transition (router upgrades to a new
  lease via `record_dispatch/5` on the next dispatch, but explicit
  `clear/1` between stages is cleaner), human gates, phase boundaries
  and router termination. Those callers are the allowlist; none of them
  acts on a runtime's say-so. Idempotent — `:ok` whether or not a row
  existed.

  A clear driven by a RUNTIME EVENT (a terminal event naming a sender)
  must go through `clear_if_owner/2` instead, so a non-owner's event
  cannot delete the owner's lease and silence its alarms (task
  01a0dd2c).
  """
  @spec clear(binary()) :: :ok
  def clear(task_id) when is_binary(task_id) do
    if ensure_table() do
      :ets.delete(@table, task_id)
    end

    :ok
  end

  @doc """
  Delete the lease row for `task_id` only when `caller_runtime_id` is
  the lease owner (task 01a0dd2c stage 1). The event-driven counterpart
  of `clear/1`.

  `caller_runtime_id` must equal the lease's `owner_runtime_id` under
  the same fail-closed compare `record_ack/3` and `record_progress/2`
  use. A non-owner, `nil` or non-binary caller — and any caller against
  a row with no owner — gets `{:error, {:not_owner, owner}}`; the row is
  left exactly as it was, and the refusal is recorded as
  `[:platform, :orchestration, :clear_refused]` telemetry and one
  warning.

  Returns `{:error, :not_found}` when no lease exists, checked before
  the owner compare. The check and the delete run in one GenServer
  call, so no dispatch can replace the row between them.
  """
  @spec clear_if_owner(binary(), term()) ::
          :ok | {:error, :not_found} | {:error, {:not_owner, binary() | nil}}
  def clear_if_owner(task_id, caller_runtime_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:clear_if_owner, task_id, caller_runtime_id})
  end

  # ── Handlers ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call(
        {:record_dispatch, task_id, stage_id, stage_kind, dispatched_at, owner_runtime_id},
        _from,
        state
      ) do
    ensure_table!()
    timeouts = timeouts_for(stage_kind)

    lease =
      case direct_get(task_id) do
        # Same stage, same owner: a duplicate delivery (019fa469 stage 6).
        %{stage_id: ^stage_id, owner_runtime_id: ^owner_runtime_id} = existing ->
          redispatch_lease(existing, stage_kind, dispatched_at, timeouts)

        # New stage, OR same stage reassigned to a different owner
        # (task 01a0c762). Reusing the old row on a reassignment would
        # let the new owner inherit the old owner's ack, i.e. a dead
        # runtime's liveness.
        _ ->
          fresh_lease(stage_id, stage_kind, dispatched_at, timeouts, owner_runtime_id)
      end

    :ets.insert(@table, {task_id, lease})
    {:reply, :ok, state}
  end

  def handle_call({:silence, task_id, until, _reason}, _from, state) do
    now = DateTime.utc_now()
    cap = DateTime.add(now, @silence_cap_ms, :millisecond)

    reply =
      cond do
        DateTime.compare(until, now) != :gt ->
          {:error, :invalid_until}

        DateTime.compare(until, cap) == :gt ->
          {:error, :cap_exceeded}

        true ->
          update_lease(task_id, fn lease ->
            Map.put(lease, :silenced_until, until)
          end)
      end

    {:reply, reply, state}
  end

  def handle_call({:record_ack, task_id, caller_runtime_id, subagent_id}, _from, state) do
    reply =
      case direct_get(task_id) do
        nil ->
          {:error, :not_found}

        lease ->
          owner = Map.get(lease, :owner_runtime_id)

          if owner?(caller_runtime_id, owner) do
            now = DateTime.utc_now()
            timeouts = timeouts_for(lease.stage_kind)

            updated =
              lease
              |> Map.put(:ack_at, now)
              |> Map.put(:no_ack_at, nil)
              |> Map.put(:no_ack_fired?, false)
              |> Map.put(:safety_net_at, maybe_add(now, timeouts.safety_net_ms))
              |> Map.put(:ack_runtime_id, caller_runtime_id)
              |> Map.put(:ack_subagent_id, subagent_id)

            :ets.update_element(@table, task_id, {@item_pos, updated})
            :ok
          else
            refuse(:ack, task_id, lease, caller_runtime_id, owner)
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:record_progress, task_id, caller_runtime_id}, _from, state) do
    reply =
      case direct_get(task_id) do
        nil ->
          {:error, :not_found}

        lease ->
          owner = Map.get(lease, :owner_runtime_id)

          if owner?(caller_runtime_id, owner) do
            now = DateTime.utc_now()
            timeouts = timeouts_for(lease.stage_kind)

            updated =
              lease
              |> Map.put(:last_progress_at, now)
              |> Map.put(:safety_net_at, maybe_add(now, timeouts.safety_net_ms))

            :ets.update_element(@table, task_id, {@item_pos, updated})
            :ok
          else
            refuse(:progress, task_id, lease, caller_runtime_id, owner)
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:clear_if_owner, task_id, caller_runtime_id}, _from, state) do
    reply =
      case direct_get(task_id) do
        nil ->
          {:error, :not_found}

        lease ->
          owner = Map.get(lease, :owner_runtime_id)

          if owner?(caller_runtime_id, owner) do
            :ets.delete(@table, task_id)
            :ok
          else
            refuse(:clear, task_id, lease, caller_runtime_id, owner)
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_no_ack_fired, task_id}, _from, state) do
    reply =
      case direct_get(task_id) do
        nil ->
          {:error, :not_found}

        %{no_ack_fired?: true} ->
          {:ok, :already_fired}

        lease ->
          :ets.update_element(
            @table,
            task_id,
            {@item_pos, Map.put(lease, :no_ack_fired?, true)}
          )

          {:ok, :fired}
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_safety_net_fired, task_id}, _from, state) do
    reply =
      case direct_get(task_id) do
        nil ->
          {:error, :not_found}

        %{safety_net_fired?: true} ->
          {:ok, :already_fired}

        lease ->
          :ets.update_element(
            @table,
            task_id,
            {@item_pos, Map.put(lease, :safety_net_fired?, true)}
          )

          {:ok, :fired}
      end

    {:reply, reply, state}
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  # A dispatch for a stage this task was not already leasing — first
  # dispatch, or a genuine stage transition. Zero-ack, zero-progress,
  # both deadlines computed from `dispatched_at`. This is the shape
  # `record_dispatch/4` has always written, and stage transitions must
  # keep getting exactly it: a new stage really has not been acked, and
  # its no-ack countdown really does start now.
  defp fresh_lease(stage_id, stage_kind, dispatched_at, timeouts, owner_runtime_id) do
    %{
      stage_id: stage_id,
      stage_kind: stage_kind,
      dispatched_at: dispatched_at,
      ack_at: nil,
      last_progress_at: nil,
      safety_net_at: maybe_add(dispatched_at, timeouts.safety_net_ms),
      no_ack_at: maybe_add(dispatched_at, timeouts.ack_ms),
      no_ack_fired?: false,
      safety_net_fired?: false,
      silenced_until: nil,
      owner_runtime_id: owner_runtime_id,
      ack_runtime_id: nil,
      ack_subagent_id: nil
    }
  end

  # Fail closed: only a binary caller equal to a binary owner is the
  # owner. `nil == nil` (an ownerless row and a caller with no
  # authenticated runtime) must NOT count as a match. The ONE compare
  # behind all three gated writes, `record_ack/3`, `record_progress/2`
  # and `clear_if_owner/2`, so the gates cannot drift apart.
  defp owner?(caller, owner) when is_binary(caller) and is_binary(owner),
    do: caller == owner

  defp owner?(_caller, _owner), do: false

  # A refused ack, progress or clear call writes NOTHING to the row: no
  # ack_at, no last_progress_at, no safety_net_at, no no_ack change, no
  # delete. The audit trail is the telemetry event and the warning, never
  # the lease. One helper for all three gated writes; only the event name
  # and the verb in the log line differ.
  defp refuse(action, task_id, lease, caller_runtime_id, owner)
       when action in [:ack, :progress, :clear] do
    :telemetry.execute(
      [:platform, :orchestration, refused_event(action)],
      %{count: 1},
      %{
        task_id: task_id,
        stage_id: lease.stage_id,
        caller_runtime_id: caller_runtime_id,
        owner_runtime_id: owner
      }
    )

    Logger.warning(
      "[LeaseManager] task #{task_id} stage #{lease.stage_id} — #{action} refused: caller runtime #{inspect(caller_runtime_id)} is not the lease owner #{inspect(owner)}. Lease left unchanged."
    )

    {:error, {:not_owner, owner}}
  end

  defp refused_event(:ack), do: :ack_refused
  defp refused_event(:progress), do: :progress_refused
  defp refused_event(:clear), do: :clear_refused

  # A re-dispatch of the stage this task is ALREADY leasing (task
  # 019fa469 stage 6). Rebuilding the row from scratch here erased an
  # ack that had already landed and re-armed a fresh 5-minute countdown
  # against an agent that was mid-flight — every `execution.no_ack_timeout`
  # observed on 2026-07-27 (roughly a dozen across six tasks) was this,
  # not a dropped runtime.
  #
  # Carried forward untouched: `ack_at`, `last_progress_at`,
  # `no_ack_fired?`, `safety_net_fired?`, `silenced_until`. All five are
  # facts about the stage-instance, and a duplicate delivery of the same
  # prompt is not new information about any of them.
  #
  # `dispatched_at` is ALSO carried forward — it names when this
  # stage-instance's ack expectation STARTED, not when a prompt was last
  # delivered. Nothing reads it except the two alert payloads
  # (`fire_no_ack_alert/2`, `fire_safety_net_alert/2`), which report
  # `elapsed_ms_since_dispatch` to a human deciding whether a runtime
  # really dropped. Refreshing it would make a six-minute-old unacked
  # dispatch alarm with "no ack after 0s" the instant a duplicate landed,
  # and would break the row's own invariant that an unacked
  # `no_ack_at == dispatched_at + ack_ms`. An alarm that misreports its
  # own elapsed time is the failure this stage exists to end.
  #
  # Refreshed: `stage_kind` (the router re-derives it per dispatch and it
  # can legitimately change as the stage's validations complete).
  #
  # `safety_net_at` is deliberately extended from the CURRENT dispatch
  # instant while `no_ack_at` is deliberately not — see
  # `redispatch_no_ack/3`. The asymmetry is intentional: the safety net
  # asks "has anything happened lately", and a re-dispatch genuinely
  # re-delivers the prompt, so it is activity. The no-ack alarm asks the
  # narrower question "did anyone ever pick this up", which a re-delivery
  # does not answer.
  defp redispatch_lease(existing, stage_kind, redispatched_at, timeouts) do
    {dispatched_at, no_ack_at} = redispatch_no_ack(existing, redispatched_at, timeouts)

    %{
      existing
      | stage_kind: stage_kind,
        dispatched_at: dispatched_at,
        safety_net_at: maybe_add(redispatched_at, timeouts.safety_net_ms),
        no_ack_at: no_ack_at
    }
  end

  # Returns `{dispatched_at, no_ack_at}` — the pair moves together so the
  # unacked invariant `no_ack_at == dispatched_at + ack_ms` survives every
  # branch.

  # Already acked → no-ack is settled for this stage-instance; nil the
  # deadline exactly as `record_ack/3` does and leave the clock where it is.
  defp redispatch_no_ack(%{ack_at: %DateTime{}} = existing, _redispatched_at, _timeouts) do
    {existing.dispatched_at, nil}
  end

  # Not acked, countdown already running → PRESERVE both. This is the
  # sub-clause that keeps the alarm honest: recomputing the deadline from
  # the re-dispatch instant would mean a stream of duplicate dispatches lets
  # a genuinely dropped runtime evade the alarm indefinitely — fixing the
  # false positives by disabling the detector.
  defp redispatch_no_ack(%{no_ack_at: %DateTime{}} = existing, _redispatched_at, _timeouts) do
    {existing.dispatched_at, existing.no_ack_at}
  end

  # Not acked and no countdown running — the previous dispatch for this
  # stage resolved a `stage_kind` with a nil `ack_ms` (`manual_approval`, or
  # an unknown kind). If this dispatch arms one, the ack expectation starts
  # NOW and the clock starts with it; if it does not, nothing changes.
  defp redispatch_no_ack(existing, redispatched_at, timeouts) do
    case maybe_add(redispatched_at, timeouts.ack_ms) do
      nil -> {existing.dispatched_at, nil}
      armed -> {redispatched_at, armed}
    end
  end

  # Runs inside the owning GenServer so the lookup + mutation pair is
  # atomic against other mutating callers. Concurrent lock-free
  # readers (via `get/1`) always see either the pre- or post-mutation
  # row — never a torn state — because `:ets.update_element/3` is a
  # single ETS op.
  defp update_lease(task_id, fun) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, lease}] ->
        updated = fun.(lease)
        :ets.update_element(@table, task_id, {@item_pos, updated})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # Inline read used by handlers. Same shape as public `get/1` but
  # skips the `ensure_table` guard — handlers only run once init has
  # created the table.
  defp direct_get(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, lease}] -> lease
      [] -> nil
    end
  end

  defp timeouts_for(stage_kind) do
    Map.get(@stage_kind_timeouts, stage_kind, %{ack_ms: nil, safety_net_ms: nil})
  end

  defp maybe_add(_dt, nil), do: nil

  defp maybe_add(%DateTime{} = dt, ms) when is_integer(ms) do
    DateTime.add(dt, ms, :millisecond)
  end

  # Public-side existence probe. Returns `true` when the table is
  # live, `false` otherwise (early boot / test harness that hasn't
  # started the GenServer). Callers use this to no-op gracefully
  # instead of crashing.
  defp ensure_table do
    case :ets.info(@table) do
      :undefined -> false
      _ -> true
    end
  end

  # Handler-side guard — the table is guaranteed by `init/1`, but
  # defensively recreate if a test wiped it between calls.
  defp ensure_table! do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
