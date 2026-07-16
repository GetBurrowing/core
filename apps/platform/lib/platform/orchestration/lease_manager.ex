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
        dispatched_at: DateTime.t(),
        ack_at: DateTime.t() | nil,
        last_progress_at: DateTime.t() | nil,
        safety_net_at: DateTime.t() | nil,   # nil = safety-net disabled (manual_approval)
        no_ack_at: DateTime.t() | nil,       # nil = no-ack disabled OR ack received
        no_ack_fired?: boolean(),
        safety_net_fired?: boolean(),
        silenced_until: DateTime.t() | nil   # nil = no silence; DateTime = suppress :check_no_ack until this instant
      }

  ## Silence semantics

  `silence/3` is the operator escape hatch for the `execution.no_ack_timeout`
  alarm — used by the `alarm_silence` MCP tool (task 019f6791-c01b stage 3)
  when a subagent's MCP client cache lacks `task_ack`. Sets `silenced_until`
  to an absolute future timestamp (capped at `now + 24h`). Orthogonal to
  `ack_at` — `record_ack/1` does NOT clear the silence, and `silence/3`
  does NOT clear ack state. `clear/1` deletes the row so a stage
  transition ends any silence by side effect. Consumers (the router in
  task 019f6791-c01b stage 2) check `silenced_until` when a
  `:check_no_ack` timer fires and reschedule instead of firing when the
  silence is still in effect.

  ## Concurrency

  Reads (`get/1`) hit ETS directly and are lock-free thanks to
  `read_concurrency: true`. Every mutating call (`record_*`,
  `mark_*_fired`, but NOT `clear/1` which is a single-op delete) is
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
  able to call `record_dispatch/4` at boot without racing the table.
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
  Record a fresh dispatch for `task_id`. Overwrites any prior lease
  for the same task (stage transitions upgrade in place) with a
  zero-ack, zero-progress row and computed `safety_net_at` /
  `no_ack_at` fields based on `dispatched_at` + the stage-kind
  timeouts.

  For unknown `stage_kind` values (or `manual_approval`) both
  timeouts are stored as `nil` — the router uses that as its signal
  to skip arming the corresponding timer.
  """
  @spec record_dispatch(binary(), binary(), binary(), DateTime.t()) :: :ok
  def record_dispatch(task_id, stage_id, stage_kind, %DateTime{} = dispatched_at)
      when is_binary(task_id) and is_binary(stage_id) and is_binary(stage_kind) do
    GenServer.call(
      __MODULE__,
      {:record_dispatch, task_id, stage_id, stage_kind, dispatched_at}
    )
  end

  @doc """
  Record that the executor/reviewer acked the dispatch. Sets
  `ack_at: now`, clears `no_ack_at` (nil) and resets
  `no_ack_fired?` (false) so a re-dispatch on the same task later can
  arm fresh timers, and extends `safety_net_at` to `now +
  safety_net_ms` (safety-net countdown restarts from the ack instant).

  Returns `{:error, :not_found}` when no lease exists for `task_id`
  (e.g. router hasn't recorded a dispatch yet). Direct callers
  (the `task_ack` MCP tool in stage 5) treat this as a soft failure —
  belt-and-braces write that races the router boot.
  """
  @spec record_ack(binary()) :: :ok | {:error, :not_found}
  def record_ack(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:record_ack, task_id})
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
    * Silence is orthogonal to `ack_at`. `record_ack/1` does NOT
      clear `silenced_until` (an ack is progress, silence is an
      operator override — different lifecycles). Re-silencing on a
      row that already has a `silenced_until` overwrites the
      timestamp.
    * Silence dies with the row: `clear/1` deletes the lease and
      `record_dispatch/4` on a subsequent stage builds a fresh
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
  Record progress (a validation_pass, execution.progress runtime
  event, etc). Extends `safety_net_at` to `now + safety_net_ms` for
  the lease's stage_kind and stamps `last_progress_at: now`. Does
  NOT clear the no-ack fields — progress evidence is not an ack.

  Returns `{:error, :not_found}` when no lease exists.
  """
  @spec record_progress(binary()) :: :ok | {:error, :not_found}
  def record_progress(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:record_progress, task_id})
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
  Delete the lease row for `task_id`. Called on stage transition
  (router upgrades to a new lease via `record_dispatch/4` on the
  next dispatch, but explicit `clear/1` between stages is cleaner)
  or router termination. Idempotent — `:ok` whether or not a row
  existed.
  """
  @spec clear(binary()) :: :ok
  def clear(task_id) when is_binary(task_id) do
    if ensure_table() do
      :ets.delete(@table, task_id)
    end

    :ok
  end

  # ── Handlers ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call(
        {:record_dispatch, task_id, stage_id, stage_kind, dispatched_at},
        _from,
        state
      ) do
    ensure_table!()
    timeouts = timeouts_for(stage_kind)

    lease = %{
      stage_id: stage_id,
      stage_kind: stage_kind,
      dispatched_at: dispatched_at,
      ack_at: nil,
      last_progress_at: nil,
      safety_net_at: maybe_add(dispatched_at, timeouts.safety_net_ms),
      no_ack_at: maybe_add(dispatched_at, timeouts.ack_ms),
      no_ack_fired?: false,
      safety_net_fired?: false,
      silenced_until: nil
    }

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

  def handle_call({:record_ack, task_id}, _from, state) do
    reply =
      update_lease(task_id, fn lease ->
        now = DateTime.utc_now()
        timeouts = timeouts_for(lease.stage_kind)

        lease
        |> Map.put(:ack_at, now)
        |> Map.put(:no_ack_at, nil)
        |> Map.put(:no_ack_fired?, false)
        |> Map.put(:safety_net_at, maybe_add(now, timeouts.safety_net_ms))
      end)

    {:reply, reply, state}
  end

  def handle_call({:record_progress, task_id}, _from, state) do
    reply =
      update_lease(task_id, fn lease ->
        now = DateTime.utc_now()
        timeouts = timeouts_for(lease.stage_kind)

        lease
        |> Map.put(:last_progress_at, now)
        |> Map.put(:safety_net_at, maybe_add(now, timeouts.safety_net_ms))
      end)

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
