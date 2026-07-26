defmodule Platform.Meetings.IntentQueue.Server do
  @moduledoc """
  One intent-queue owner per meeting (task 019f70b8 stage 2).

  Registered `{:via, Registry, {Platform.Meetings.Registry, meeting_id}}`
  and started on demand by `Platform.Meetings.IntentQueue.Supervisor`.

  ## Why per-meeting, and why an unnamed table

  `init/1` creates an **unnamed, `:protected`** ETS table owned by this
  process. That is the whole point of the redesign: the table is
  reachable only through its `tid`, which only this process holds, so
  when the meeting ends and the server stops, the table is reclaimed by
  the VM. Cleanup is structural rather than sweep-dependent — there is
  no periodic reaper here because there is nothing left to reap.

  `:protected` (not `:public`) means every write funnels through this
  process. That is deliberate: stage 3 hangs an ack-gated serial
  dispatch cursor off this same mailbox, and a cursor whose invariant
  ("at most one row in `:dispatched` or `:acked` per meeting") can be
  violated by an out-of-band `:ets.insert/2` from any process is not an
  invariant at all.

  ## Row shape

  Keyed by a generated UUIDv7 `id` so a remote runtime can address a
  single intent (`intent_ack(intent_id, ...)`, stage 3). The old
  `{room_id, dedupe_key}` composite was not addressable off-node.

      %{
        id: binary(),                       # UUIDv7, the ETS key
        meeting_id: binary(),
        room_id: binary() | nil,
        transcript_chunk_id: binary() | nil,
        chunk_excerpt: binary() | nil,      # truncated utterance, for the UI
        classified_intent: atom() | binary() | nil,
        confidence: float() | nil,
        target_role: atom() | binary() | nil,
        target_agent_id: binary() | nil,
        target_agent_slug: binary() | nil,
        status: status(),
        subagent_id: binary() | nil,        # stamped at ack (stage 3)
        enqueued_at: DateTime.t(),
        dispatched_at: DateTime.t() | nil,
        acked_at: DateTime.t() | nil,
        completed_at: DateTime.t() | nil,
        cancelled_at: DateTime.t() | nil,
        timed_out_at: DateTime.t() | nil,
        dispatch_failure_reason: atom() | binary() | nil,
        model_used: binary() | nil,
        elapsed_ms: non_neg_integer() | nil,
        dedupe_key: binary() | nil,
        seq: pos_integer()                  # insertion order, for list/1
      }

  `enqueued_at` and `seq` are additions to the plan's field list. `seq`
  gives `list/1` a stable, monotonic order that survives clock skew
  (ETS `:set` iteration order is unspecified, and the stage-3 cursor
  needs "oldest queued row" to be well-defined); `enqueued_at` is the
  human-facing counterpart the UI renders.

  ## Status enum

  Nine values, introduced by this task — the pre-existing queue only
  had `:pending | :dispatching`:

    * **in-flight** — `:queued`, `:dispatched`, `:acked`
    * **success**   — `:completed`
    * **cancelled** — `:cancelled`, `:cancelled_late`
    * **errors**    — `:timed_out`, `:dispatch_failed`,
      `:no_ack_spawn_failed`

  The three error states are deliberately NOT collapsed. `:timed_out`
  means no ack of any kind arrived — we waited and got nothing.
  `:dispatch_failed` means we never reached a runtime. `:no_ack_spawn_failed`
  means the runtime tried to ack and the ack was schema-rejected, i.e.
  it could not spawn a subagent. Those are three different operator
  actions (wait longer / fix the runtime link / fix the target), so
  they stay three different states all the way out to the chip in the
  UI.

  ## Terminal rows are retained

  Unlike the module this replaces — whose `mark_dispatched/2` DELETED
  the row, leaving a live UI nothing to render — terminal rows stay in
  the table until the meeting ends. The table still dies with the
  meeting, so retention costs one meeting's worth of rows and nothing
  more.

  ## Broadcasts

  Every transition publishes on `meeting:<meeting_id>:intents` via
  `Platform.Meetings.PubSub`. `enqueue/2` publishes `:intent_classified`;
  `transition/4` publishes the event matching the destination status.

  `delete/2` is deliberately SILENT. It exists for the stage-7
  "remove a `:queued` row" path, where the caller is the one surface
  that already knows the row is gone and where a correction row — not a
  queue event — is the durable record. Anything cancelling a row that
  has actually been dispatched must go through
  `transition(meeting_id, id, :cancelled)`, which does broadcast.

  ## Ack-gated serial cursor (task 019f70b8 stage 3)

  The server holds a **cursor**: at most ONE row per meeting may be
  `:dispatched` or `:acked` at a time. `claim_next/1` hands the oldest
  `:queued` row to the dispatcher and pins the cursor to it; the cursor
  releases only when that row reaches a terminal status. This replaces
  the pre-019f70b8 dispatcher's batch claim (50 rows per tick, fanned
  out through `Task.Supervisor.async_nolink`), which could put an
  unbounded number of intents in front of one agent at once.

  Head-of-line blocking is per-meeting and deliberate — the point of a
  meeting-scoped producer is that its target agents get one thing to do
  at a time. Meetings never block each other: each has its own server.

  `claim_next/1` returns the row still `:queued`. The caller decides
  what happens next and says so with an explicit transition
  (`:dispatched` on success, `:dispatch_failed` when no runtime can be
  reached). Marking `:dispatched` here rather than in `claim_next/1`
  is what lets stage 4 fail a dispatch without first broadcasting a
  `:intent_dispatched` event that never happened. A caller that dies
  between claim and transition is covered by a claim watchdog, which
  releases the cursor and leaves the row `:queued` for the next
  re-drive.

  ## Ack semantics

  `ack/5` is the queue half of the `intent_ack` MCP tool:

    * `:working` → `:acked`, stamps `acked_at` + `subagent_id`. The
      cursor does NOT advance: the target has confirmed it spawned a
      subagent, not that the work is done. The ack timer is re-armed —
      a live ack is evidence of liveness and earns a fresh window.
    * `:completed` → `:completed`, stamps `completed_at`, advances.
    * `:rejected` → `:completed` (terminal) + advances, and emits
      `[:platform, :meetings, :intent_rejected]` carrying everything
      stage 6 needs to write a `wrong_target` correction row.
    * `:cancel_honored` → `:cancelled` from an in-flight row, or
      `:cancelled_late` when `:completed` already landed.

  The producer-facing half of cancellation is `begin_cancel/2` (task
  019f70b8 stage 4): it decides atomically whether a cancel means
  "delete a row nobody has seen", "signal the runtime and wait for
  `:cancel_honored`", or "too late, it already completed", and applies
  the queue side of that decision. The runtime signal itself is
  `Platform.Meetings.IntentRuntimeAdapter`'s job — this process holds
  no DB connection and has no business resolving agents.

  A schema-rejected ack never reaches `ack/5` — the tool surface
  rejects it and calls `record_rejected_ack/2` instead, which touches
  a counter in GenServer state and leaves the ETS row byte-identical.

  ## Ack timeout, and why `:timed_out` ≠ `:no_ack_spawn_failed`

  `queue_ack_timeout_ms` (default 90s, per-meeting override in opts,
  global default under `Application.get_env(:platform,
  Platform.Meetings.IntentQueue, [])`) arms when a row is marked
  `:dispatched` and re-arms on every `:working` ack. On expiry:

    * the row was never successfully acked AND we observed at least one
      schema-rejected `intent_ack` for it → `:no_ack_spawn_failed`. The
      runtime tried and could not produce a subagent id; that is a
      broken target, and it is red.
    * otherwise → `:timed_out`. We waited and got nothing back. Amber,
      not red: retry or wait longer, nothing is provably broken.

  The rejected-ack counter lives in GenServer state as
  `%{intent_id => count}` — deliberately not a durable table. It is
  evidence about one meeting's dispatch attempts and has no meaning
  after that meeting ends.
  """

  use GenServer

  require Logger

  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @registry Platform.Meetings.Registry

  @statuses [
    :queued,
    :dispatched,
    :acked,
    :completed,
    :cancelled,
    :timed_out,
    :dispatch_failed,
    :no_ack_spawn_failed,
    :cancelled_late
  ]

  @in_flight_statuses [:dispatched, :acked]

  @terminal_statuses [
    :completed,
    :cancelled,
    :timed_out,
    :dispatch_failed,
    :no_ack_spawn_failed,
    :cancelled_late
  ]

  # Statuses that release the serial cursor. Identical to
  # @terminal_statuses today — they are kept as separate lists because
  # they answer different questions ("is more expected from this row?"
  # vs "may the next row go out?") and the plan enumerates the advance
  # set explicitly.
  @advancing_statuses @terminal_statuses

  # Ack window default. 90s is the plan's number: long enough that a
  # runtime cold-starting a subagent isn't punished, short enough that
  # a wedged target doesn't hold a meeting's queue for the whole
  # meeting.
  @default_ack_timeout_ms 90_000

  # Ack statuses the `intent_ack` MCP tool may carry.
  @ack_statuses [:working, :completed, :rejected, :cancel_honored]

  # Fields a caller may set through `enqueue/2` / `transition/4`. Any
  # other key in the attrs map is dropped rather than merged, so a
  # typo'd field can't silently shadow `:status` or invent a column the
  # UI doesn't know how to render.
  @writable_fields [
    :room_id,
    :transcript_chunk_id,
    :chunk_excerpt,
    :classified_intent,
    :confidence,
    :target_role,
    :target_agent_id,
    :target_agent_slug,
    :subagent_id,
    :dispatch_failure_reason,
    :model_used,
    :elapsed_ms,
    :dedupe_key
  ]

  # Destination status -> the timestamp field stamped on arrival.
  # `:dispatch_failed` has no dedicated column in the approved row
  # shape; it carries `dispatch_failure_reason` instead.
  #
  # `:no_ack_spawn_failed` stamps `timed_out_at` because it IS the
  # timeout path — it is reached only when the ack window expires — and
  # the UI wants "how long did we wait" for both amber and red timeout
  # outcomes. It additionally carries
  # `dispatch_failure_reason: :subagent_spawn_rejected`.
  @status_timestamps %{
    dispatched: :dispatched_at,
    acked: :acked_at,
    completed: :completed_at,
    cancelled: :cancelled_at,
    cancelled_late: :cancelled_at,
    timed_out: :timed_out_at,
    no_ack_spawn_failed: :timed_out_at
  }

  @type status ::
          :queued
          | :dispatched
          | :acked
          | :completed
          | :cancelled
          | :timed_out
          | :dispatch_failed
          | :no_ack_spawn_failed
          | :cancelled_late

  @type row :: map()

  # ── Reflection ─────────────────────────────────────────────────────────────

  @doc "Every valid row status, in in-flight → terminal reading order."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Statuses that mean "this intent is with a runtime right now". The
  stage-3 serial cursor holds at most one row in this set per meeting.
  """
  @spec in_flight_statuses() :: [status()]
  def in_flight_statuses, do: @in_flight_statuses

  @doc "Statuses no further transition is expected from."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Statuses that release the serial dispatch cursor."
  @spec advancing_statuses() :: [status()]
  def advancing_statuses, do: @advancing_statuses

  @doc "The four `intent_ack` statuses a runtime may report."
  @spec ack_statuses() :: [atom()]
  def ack_statuses, do: @ack_statuses

  @doc "True when `status` is one of the nine valid values."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc "Default ack window in ms, before per-meeting/app-env overrides."
  @spec default_ack_timeout_ms() :: pos_integer()
  def default_ack_timeout_ms, do: @default_ack_timeout_ms

  @doc """
  Resolve an `intent_id` to the meeting whose queue owns it, without
  the caller having to know the meeting up front.

  The `intent_ack` MCP tool receives only an intent id — a remote
  runtime has no reason to know the meeting UUID — so the owning server
  registers each row's id in the same Registry it is itself registered
  in, under a `{:intent, id}` key. The index is process-owned, so it
  dies with the meeting exactly like the ETS table does.
  """
  @spec locate(binary()) :: {:ok, binary()} | {:error, :not_found}
  def locate(intent_id) when is_binary(intent_id) do
    case Registry.lookup(@registry, {:intent, intent_id}) do
      [{pid, meeting_id}] ->
        if Process.alive?(pid), do: {:ok, meeting_id}, else: {:error, :not_found}

      [] ->
        {:error, :not_found}
    end
  end

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start a queue owner for `meeting_id`. Prefer
  `Platform.Meetings.IntentQueue.Supervisor.ensure_started/2` — direct
  `start_link/1` is for tests that want an unsupervised instance.

  Opts:

    * `:meeting_id` (required) — Registry key.
    * `:room_id` — seeds the `:meeting_finished` shutdown match before
      the first enqueue arrives.
    * `:ack_timeout_ms` — per-meeting override of the ack window.
      Falls back to `Application.get_env(:platform,
      Platform.Meetings.IntentQueue, [])[:queue_ack_timeout_ms]`, then
      to `#{@default_ack_timeout_ms}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    meeting_id = Keyword.fetch!(opts, :meeting_id)
    GenServer.start_link(__MODULE__, opts, name: via(meeting_id))
  end

  @doc "`{:via, Registry, …}` name for `meeting_id`."
  @spec via(binary()) :: {:via, Registry, {module(), binary()}}
  def via(meeting_id) when is_binary(meeting_id),
    do: {:via, Registry, {@registry, meeting_id}}

  @doc "Pid of the queue owner for `meeting_id`, or `nil`."
  @spec whereis(binary()) :: pid() | nil
  def whereis(meeting_id) when is_binary(meeting_id) do
    case Registry.lookup(@registry, meeting_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl GenServer
  def init(opts) do
    meeting_id = Keyword.fetch!(opts, :meeting_id)

    # UNNAMED + :protected. The tid never leaves this process, so the
    # table is unreachable — and therefore collected — the instant the
    # server stops. This is what makes "the queue dies with the
    # meeting" structurally true instead of sweep-dependent.
    table = :ets.new(:intent_queue, [:set, :protected, read_concurrency: true])

    MeetingsPubSub.subscribe_meeting_finished()

    {:ok,
     %{
       meeting_id: meeting_id,
       room_id: Keyword.get(opts, :room_id),
       table: table,
       # dedupe_key -> intent_id. Survives the key change from the old
       # `{room_id, dedupe_key}` composite: `:ets.insert_new/2` used to
       # give idempotence for free, and now that the key is a generated
       # id we have to carry the index ourselves.
       dedupe_index: %{},
       seq: 0,
       # ── serial cursor (stage 3) ──
       # intent_id currently held by a runtime, or nil when the meeting
       # is free to dispatch the next queued row.
       cursor: nil,
       # {intent_id, timer_ref} for the armed ack window, or nil.
       ack_timer: nil,
       # {intent_id, timer_ref} guarding a claimed-but-not-yet-
       # transitioned row against a caller that died mid-dispatch.
       claim_timer: nil,
       # intent_id -> count of schema-rejected `intent_ack` attempts.
       # Drives the `:no_ack_spawn_failed` / `:timed_out` split.
       rejected_acks: %{},
       ack_timeout_ms: resolve_ack_timeout_ms(opts)
     }}
  end

  # Per-meeting opt wins, then app env, then the module default —
  # mirrors the `stall_window_ms` pattern in `IntentDispatcher`.
  defp resolve_ack_timeout_ms(opts) do
    Keyword.get(opts, :ack_timeout_ms) ||
      :platform
      |> Application.get_env(Platform.Meetings.IntentQueue, [])
      |> Keyword.get(:queue_ack_timeout_ms, @default_ack_timeout_ms)
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Insert a new intent row for this meeting.

  Returns `{:ok, row}` on first write and `{:duplicate, row}` when
  `attrs[:dedupe_key]` matches a row already in the table — in which
  case the EXISTING row comes back untouched and nothing is broadcast.
  Rows enqueued without a `:dedupe_key` never collapse.
  """
  @spec enqueue(binary(), map()) :: {:ok, row()} | {:duplicate, row()}
  def enqueue(meeting_id, attrs) when is_binary(meeting_id) and is_map(attrs) do
    GenServer.call(via(meeting_id), {:enqueue, attrs})
  end

  @doc "Every row for this meeting, oldest first. Includes terminal rows."
  @spec list(binary()) :: [row()]
  def list(meeting_id) when is_binary(meeting_id) do
    GenServer.call(via(meeting_id), :list)
  end

  @doc "Fetch one row by intent id."
  @spec get(binary(), binary()) :: {:ok, row()} | {:error, :not_found}
  def get(meeting_id, intent_id) when is_binary(meeting_id) and is_binary(intent_id) do
    GenServer.call(via(meeting_id), {:get, intent_id})
  end

  @doc """
  Move a row to `status`, merging any `attrs` (restricted to the
  writable field set) and stamping the timestamp that status owns.

  Returns `{:ok, updated_row}`, `{:error, :not_found}`,
  `{:error, {:invalid_status, status}}`, or
  `{:error, {:cursor_busy, other_intent_id}}` when moving to
  `:dispatched` while another row already holds this meeting's cursor.
  Broadcasts the event matching `status` on success.
  """
  @spec transition(binary(), binary(), status(), map()) ::
          {:ok, row()}
          | {:error, :not_found}
          | {:error, {:invalid_status, term()}}
          | {:error, {:cursor_busy, binary()}}
  def transition(meeting_id, intent_id, status, attrs \\ %{})
      when is_binary(meeting_id) and is_binary(intent_id) and is_map(attrs) do
    GenServer.call(via(meeting_id), {:transition, intent_id, status, attrs})
  end

  @doc """
  Remove a row outright. Idempotent, and deliberately silent — see the
  moduledoc for why cancellation of a live row must use
  `transition/4` instead.
  """
  @spec delete(binary(), binary()) :: :ok
  def delete(meeting_id, intent_id) when is_binary(meeting_id) and is_binary(intent_id) do
    GenServer.call(via(meeting_id), {:delete, intent_id})
  end

  # ── Serial cursor + ack (stage 3) ──────────────────────────────────────────

  @doc """
  Hand the oldest `:queued` row to the caller and pin the cursor to it.

  Returns:

    * `{:ok, row}` — the row is reserved and still `:queued`. The
      caller MUST follow with `transition/4` to `:dispatched` (on a
      successful hand-off) or to `:dispatch_failed` (when no runtime
      could be reached). Failing to do either releases the cursor after
      the ack window via the claim watchdog.
    * `{:busy, intent_id}` — this meeting already has a row with a
      runtime. Nothing to do; the cursor's release will re-drive.
    * `:empty` — no `:queued` rows.
  """
  @spec claim_next(binary()) :: {:ok, row()} | {:busy, binary()} | :empty
  def claim_next(meeting_id) when is_binary(meeting_id) do
    GenServer.call(via(meeting_id), :claim_next)
  end

  @doc """
  Land an `intent_ack` from the target runtime.

  `ack_status` is one of `#{inspect(@ack_statuses)}`. `subagent_id` has
  already been shape-validated by the tool surface — this function
  stamps it, it does not police it.

  Returns `{:ok, row}`, `{:error, :not_found}`,
  `{:error, {:invalid_ack_status, status}}`, or
  `{:error, {:invalid_ack_state, current_status}}` when the row is not
  in a state that ack means anything for (e.g. acking a `:queued` row).
  """
  @spec ack(binary(), binary(), binary(), atom(), binary() | nil) ::
          {:ok, row()} | {:error, term()}
  def ack(meeting_id, intent_id, subagent_id, ack_status, note \\ nil)
      when is_binary(meeting_id) and is_binary(intent_id) and is_binary(subagent_id) do
    GenServer.call(via(meeting_id), {:ack, intent_id, subagent_id, ack_status, note})
  end

  @doc """
  Record that a runtime attempted an `intent_ack` for `intent_id` and
  the ack was schema-rejected (bad or missing `subagent_id`).

  Deliberately does NOT touch the ETS row: a schema-rejected ack is not
  a partial ack, and the row must stay byte-identical. The counter only
  changes what an eventual TIMEOUT is called — `:no_ack_spawn_failed`
  instead of `:timed_out`.
  """
  @spec record_rejected_ack(binary(), binary()) :: :ok
  def record_rejected_ack(meeting_id, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    GenServer.call(via(meeting_id), {:record_rejected_ack, intent_id})
  end

  @doc """
  Atomically decide what cancelling `intent_id` means right now, and
  apply the part of that decision the queue owns.

  Cancellation spans two worlds — an ETS row here and a subagent on
  somebody else's machine — and only one of them can be settled
  synchronously. This call settles the queue side and tells the caller
  what, if anything, it must still do over the wire:

    * `{:ok, :deleted, row}` — the row was `:queued`, never left the
      building, and has been removed. Nothing to signal.
    * `{:ok, :signal, row}` — the row is `:dispatched` or `:acked`. It
      is left UNTOUCHED (the ack window keeps running) and the caller
      must broadcast the cancel to `row.subagent_id`'s runtime. The row
      lands `:cancelled` when the target answers
      `intent_ack(status: :cancel_honored)`.
    * `{:ok, :cancelled_late, row}` — `:completed` already landed. The
      row is transitioned to `:cancelled_late` here and there is nobody
      left to signal. Not a failure: the work happened, and the
      producer's X arrived after it (AC8).
    * `{:error, {:not_cancellable, status}}` — the row is already
      terminal for some other reason. Use `delete/2` to clear it.

  The status read and the branch are one message so a completion
  landing mid-decision cannot produce a `:queued` row that was actually
  dispatched a microsecond ago. The remaining race — completion landing
  AFTER we answer `{:ok, :signal, row}` — is handled where it belongs,
  in `ack_destination/2`, which turns the eventual `:cancel_honored`
  into `:cancelled_late`.
  """
  @spec begin_cancel(binary(), binary()) ::
          {:ok, :deleted | :signal | :cancelled_late, row()}
          | {:error, :not_found}
          | {:error, {:not_cancellable, status()}}
  def begin_cancel(meeting_id, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    GenServer.call(via(meeting_id), {:begin_cancel, intent_id})
  end

  @doc "The intent id currently holding this meeting's cursor, or nil."
  @spec cursor(binary()) :: binary() | nil
  def cursor(meeting_id) when is_binary(meeting_id) do
    GenServer.call(via(meeting_id), :cursor)
  end

  @doc "Schema-rejected ack attempts observed for `intent_id`."
  @spec rejected_ack_count(binary(), binary()) :: non_neg_integer()
  def rejected_ack_count(meeting_id, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    GenServer.call(via(meeting_id), {:rejected_ack_count, intent_id})
  end

  @doc "The ack window this meeting's queue is running with, in ms."
  @spec ack_timeout_ms(binary()) :: pos_integer()
  def ack_timeout_ms(meeting_id) when is_binary(meeting_id) do
    GenServer.call(via(meeting_id), :ack_timeout_ms)
  end

  # ── Handlers ───────────────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:enqueue, attrs}, _from, state) do
    dedupe_key = Map.get(attrs, :dedupe_key)

    case dedupe_key && Map.get(state.dedupe_index, dedupe_key) do
      nil ->
        do_enqueue(attrs, dedupe_key, state)

      existing_id ->
        case lookup(state, existing_id) do
          {:ok, existing} ->
            emit_enqueue_telemetry(state, :duplicate, existing)
            {:reply, {:duplicate, existing}, state}

          :error ->
            # Index pointed at a row that was deleted out from under
            # it. Heal the index and treat this as a first write.
            do_enqueue(attrs, dedupe_key, %{
              state
              | dedupe_index: Map.delete(state.dedupe_index, dedupe_key)
            })
        end
    end
  end

  def handle_call(:list, _from, state) do
    rows =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, row} -> row end)
      |> Enum.sort_by(& &1.seq)

    {:reply, rows, state}
  end

  def handle_call({:get, intent_id}, _from, state) do
    case lookup(state, intent_id) do
      {:ok, row} -> {:reply, {:ok, row}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:transition, intent_id, status, attrs}, _from, state) do
    if valid_status?(status) do
      do_transition(intent_id, status, attrs, state)
    else
      {:reply, {:error, {:invalid_status, status}}, state}
    end
  end

  def handle_call({:delete, intent_id}, _from, state) do
    {:reply, :ok, do_delete(intent_id, state)}
  end

  # Cancellation's queue half (task 019f70b8 stage 4). See `begin_cancel/2`
  # for why the decision and the ETS mutation have to be one message.
  def handle_call({:begin_cancel, intent_id}, _from, state) do
    case lookup(state, intent_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{status: :queued} = row} ->
        # Never dispatched, so nobody out there knows about it. Silent
        # delete — the durable record of a producer pulling a row is a
        # correction row (stage 6), not a queue event.
        {:reply, {:ok, :deleted, row}, do_delete(intent_id, state)}

      {:ok, %{status: status} = row} when status in @in_flight_statuses ->
        # Left exactly as it is. The caller signals the runtime; the
        # row moves when the target answers `:cancel_honored`, or when
        # the ack window gives up on it.
        {:reply, {:ok, :signal, row}, state}

      {:ok, %{status: :completed} = row} ->
        {_reply, updated, state} = apply_transition(row, :cancelled_late, %{}, state)
        {:reply, {:ok, :cancelled_late, updated}, state}

      {:ok, %{status: status}} ->
        {:reply, {:error, {:not_cancellable, status}}, state}
    end
  end

  def handle_call(:claim_next, _from, state) do
    cond do
      is_binary(state.cursor) ->
        {:reply, {:busy, state.cursor}, state}

      true ->
        case oldest_queued(state) do
          nil ->
            {:reply, :empty, state}

          row ->
            # The row stays `:queued`. The caller commits it with an
            # explicit transition; the watchdog covers a caller that
            # never gets there.
            state =
              %{state | cursor: row.id}
              |> arm_claim_watchdog(row.id)

            {:reply, {:ok, row}, state}
        end
    end
  end

  def handle_call({:ack, intent_id, subagent_id, ack_status, note}, _from, state) do
    if ack_status in @ack_statuses do
      do_ack(intent_id, subagent_id, ack_status, note, state)
    else
      {:reply, {:error, {:invalid_ack_status, ack_status}}, state}
    end
  end

  def handle_call({:record_rejected_ack, intent_id}, _from, state) do
    case lookup(state, intent_id) do
      {:ok, %{status: status}} when status in @in_flight_statuses ->
        rejected = Map.update(state.rejected_acks, intent_id, 1, &(&1 + 1))
        {:reply, :ok, %{state | rejected_acks: rejected}}

      _ ->
        # No row, or a row nobody is waiting on. Nothing to remember —
        # a rejected ack only means something while a timeout is
        # pending on that intent.
        {:reply, :ok, state}
    end
  end

  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  def handle_call({:rejected_ack_count, intent_id}, _from, state),
    do: {:reply, Map.get(state.rejected_acks, intent_id, 0), state}

  def handle_call(:ack_timeout_ms, _from, state), do: {:reply, state.ack_timeout_ms, state}

  @impl GenServer
  def handle_info({:meeting_finished, payload}, state) when is_map(payload) do
    if finished_for_us?(payload, state) do
      Logger.debug(
        "[IntentQueue.Server] meeting finished — stopping queue meeting_id=#{state.meeting_id}"
      )

      # Normal stop: the DynamicSupervisor runs these `:temporary`, so
      # no restart, and the ETS table goes with the process.
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # Ack window expired. Which failure this is depends on whether the
  # runtime ever tried to ack — see the moduledoc.
  def handle_info({:ack_timeout, intent_id}, state) do
    state = %{state | ack_timer: nil}

    case lookup(state, intent_id) do
      {:ok, %{status: status} = row} when status in @in_flight_statuses ->
        rejected_attempts = Map.get(state.rejected_acks, intent_id, 0)

        {destination, attrs} =
          if status == :dispatched and rejected_attempts > 0 do
            {:no_ack_spawn_failed, %{dispatch_failure_reason: :subagent_spawn_rejected}}
          else
            {:timed_out, %{}}
          end

        Logger.info(
          "[IntentQueue.Server] ack window expired — meeting_id=#{state.meeting_id} " <>
            "intent_id=#{intent_id} from=#{status} to=#{destination} " <>
            "rejected_ack_attempts=#{rejected_attempts}"
        )

        {_reply, _row, state} = apply_transition(row, destination, attrs, state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # The dispatcher claimed a row and never came back to commit it —
  # crashed mid-resolution, or the node it ran on went away. Release
  # the cursor and leave the row `:queued` so the next re-drive picks
  # it up. No new status is invented for "we tried to try".
  def handle_info({:claim_watchdog, intent_id}, state) do
    state = %{state | claim_timer: nil}

    case lookup(state, intent_id) do
      {:ok, %{status: :queued}} when state.cursor == intent_id ->
        Logger.warning(
          "[IntentQueue.Server] claim never committed — releasing cursor " <>
            "meeting_id=#{state.meeting_id} intent_id=#{intent_id}"
        )

        {:noreply, release_cursor(state, intent_id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ───────────────────────────────────────────────────────────────

  defp do_delete(intent_id, state) do
    dedupe_index =
      case lookup(state, intent_id) do
        {:ok, %{dedupe_key: key}} when is_binary(key) -> Map.delete(state.dedupe_index, key)
        _ -> state.dedupe_index
      end

    :ets.delete(state.table, intent_id)
    Registry.unregister(@registry, {:intent, intent_id})

    state = %{state | dedupe_index: dedupe_index}

    # Deleting the row the cursor is pinned to has to release it, or
    # the meeting wedges on a row that no longer exists.
    if state.cursor == intent_id do
      release_cursor(state, intent_id)
    else
      %{state | rejected_acks: Map.delete(state.rejected_acks, intent_id)}
    end
  end

  defp do_transition(intent_id, status, attrs, state) do
    case lookup(state, intent_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, row} ->
        # The one-in-flight-per-meeting invariant is enforced HERE, at
        # the only door into `:dispatched`, rather than trusted to
        # every caller. Without this a second `transition(.., :dispatched)`
        # would quietly put two intents in front of the same agent —
        # exactly the failure mode the serial cursor exists to prevent.
        if status == :dispatched and is_binary(state.cursor) and state.cursor != intent_id do
          {:reply, {:error, {:cursor_busy, state.cursor}}, state}
        else
          {reply, _updated, state} = apply_transition(row, status, attrs, state)
          {:reply, reply, state}
        end
    end
  end

  # The single write path for every status change. Returns
  # `{reply, updated_row, state}` so both the `handle_call` and the
  # timer-driven `handle_info` callers can share it.
  defp apply_transition(row, status, attrs, state) do
    updated =
      row
      |> Map.merge(writable(attrs))
      |> Map.put(:status, status)
      |> stamp_status_timestamp(status)

    :ets.insert(state.table, {updated.id, updated})

    # Learn the room from the transition too — a row can be
    # dispatched before the classifier ever stamped room_id.
    state =
      state
      |> maybe_learn_room(updated)
      |> apply_cursor_effects(updated, status)

    broadcast(state.meeting_id, status, updated)
    maybe_emit_correction_hook(state, updated, status)

    {{:ok, updated}, updated, state}
  end

  # Cursor bookkeeping, expressed once so no transition site can forget
  # a timer.
  #
  # A `:working` ack re-arms rather than clears the window: proof of
  # life buys a fresh window rather than letting the original expire
  # under a target that is demonstrably working.
  defp apply_cursor_effects(state, row, status) when status in @in_flight_statuses do
    if is_nil(state.cursor) or state.cursor == row.id do
      state
      |> Map.put(:cursor, row.id)
      |> cancel_claim_watchdog()
      |> arm_ack_timer(row.id)
    else
      state
    end
  end

  defp apply_cursor_effects(state, row, status) when status in @advancing_statuses do
    if state.cursor == row.id do
      release_cursor(state, row.id)
    else
      # A row that was never the cursor (e.g. a `:queued` row cancelled
      # from the UI) still drops its rejected-ack bookkeeping.
      %{state | rejected_acks: Map.delete(state.rejected_acks, row.id)}
    end
  end

  defp apply_cursor_effects(state, _row, _status), do: state

  # Free the meeting for its next intent, drop this row's per-intent
  # bookkeeping, and poke the dispatcher. The poke is a broadcast
  # rather than a direct send so the dispatcher stays a subscriber and
  # nothing here needs to know whether one is running.
  defp release_cursor(state, intent_id) do
    state =
      %{
        state
        | cursor: nil,
          rejected_acks: Map.delete(state.rejected_acks, intent_id)
      }
      |> cancel_ack_timer()
      |> cancel_claim_watchdog()

    notify_drain(state)
    state
  end

  defp notify_drain(state) do
    MeetingsPubSub.broadcast_intent_enqueued(%{
      meeting_id: state.meeting_id,
      room_id: state.room_id
    })
  end

  defp arm_ack_timer(state, intent_id) do
    state = cancel_ack_timer(state)
    ref = Process.send_after(self(), {:ack_timeout, intent_id}, state.ack_timeout_ms)
    %{state | ack_timer: {intent_id, ref}}
  end

  defp cancel_ack_timer(%{ack_timer: nil} = state), do: state

  defp cancel_ack_timer(%{ack_timer: {_id, ref}} = state) do
    Process.cancel_timer(ref)
    %{state | ack_timer: nil}
  end

  defp arm_claim_watchdog(state, intent_id) do
    state = cancel_claim_watchdog(state)
    ref = Process.send_after(self(), {:claim_watchdog, intent_id}, state.ack_timeout_ms)
    %{state | claim_timer: {intent_id, ref}}
  end

  defp cancel_claim_watchdog(%{claim_timer: nil} = state), do: state

  defp cancel_claim_watchdog(%{claim_timer: {_id, ref}} = state) do
    Process.cancel_timer(ref)
    %{state | claim_timer: nil}
  end

  defp oldest_queued(state) do
    state.table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, row} -> row end)
    |> Enum.filter(&(&1.status == :queued))
    |> Enum.min_by(& &1.seq, fn -> nil end)
  end

  # ── Ack ────────────────────────────────────────────────────────────────────

  defp do_ack(intent_id, subagent_id, ack_status, note, state) do
    case lookup(state, intent_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, row} ->
        case ack_destination(row.status, ack_status) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:ok, destination} ->
            attrs = %{subagent_id: subagent_id}

            {reply, updated, state} = apply_transition(row, destination, attrs, state)

            if ack_status == :rejected do
              emit_rejected_hook(state, row, updated, note)
            end

            {:reply, reply, state}
        end
    end
  end

  # `:rejected` lands the row on `:completed` — the target looked at it
  # and is done with it. The tuning signal ("wrong target") is carried
  # by the correction hook, not by a tenth status.
  defp ack_destination(current, :working) when current in @in_flight_statuses, do: {:ok, :acked}

  defp ack_destination(current, :completed) when current in @in_flight_statuses,
    do: {:ok, :completed}

  defp ack_destination(current, :rejected) when current in @in_flight_statuses,
    do: {:ok, :completed}

  defp ack_destination(current, :cancel_honored) when current in @in_flight_statuses,
    do: {:ok, :cancelled}

  # The completed-then-cancelled race: the target finished the work
  # before the cancel reached it. Not a crash and not a lie — a
  # distinct status the UI can explain (AC8).
  defp ack_destination(:completed, :cancel_honored), do: {:ok, :cancelled_late}

  defp ack_destination(current, _ack_status), do: {:error, {:invalid_ack_state, current}}

  # ── Stage-6 correction hooks ───────────────────────────────────────────────
  #
  # Stage 6 writes durable `meeting_intent_corrections` rows off these
  # two events. They are emitted here, at the transition sites, because
  # this is the only place that still holds both the pre-transition
  # status (the correction's `dispatch_outcome`) and the row's
  # classification fields. Guarded like every other telemetry call in
  # this subsystem: a broken listener must not tap the queue.

  defp maybe_emit_correction_hook(state, row, :no_ack_spawn_failed) do
    emit_telemetry(
      [:platform, :meetings, :intent_no_ack_spawn_failed],
      %{count: 1},
      correction_metadata(state, row, :no_ack_spawn_failed)
    )
  end

  defp maybe_emit_correction_hook(_state, _row, _status), do: :ok

  defp emit_rejected_hook(state, row_before, row_after, note) do
    metadata =
      state
      |> correction_metadata(row_after, row_before.status)
      |> Map.put(:note, note)

    emit_telemetry([:platform, :meetings, :intent_rejected], %{count: 1}, metadata)
  end

  defp correction_metadata(state, row, dispatch_outcome) do
    %{
      meeting_id: state.meeting_id,
      room_id: row.room_id,
      intent_id: row.id,
      classified_intent: row.classified_intent,
      target_role: row.target_role,
      target_agent_id: row.target_agent_id,
      chunk_excerpt: row.chunk_excerpt,
      subagent_id: row.subagent_id,
      dispatch_outcome: dispatch_outcome
    }
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
    :ok
  rescue
    _ -> :ok
  end

  defp do_enqueue(attrs, dedupe_key, state) do
    id = Platform.Types.UUIDv7.generate()
    seq = state.seq + 1

    row =
      attrs
      |> writable()
      |> Map.merge(%{
        id: id,
        meeting_id: state.meeting_id,
        status: :queued,
        subagent_id: nil,
        enqueued_at: DateTime.utc_now(),
        dispatched_at: nil,
        acked_at: nil,
        completed_at: nil,
        cancelled_at: nil,
        timed_out_at: nil,
        seq: seq
      })
      |> then(&Map.merge(default_row(), &1))

    :ets.insert(state.table, {id, row})

    # Reverse index so `intent_ack(intent_id, …)` can find this meeting
    # from an id alone. Registered by THIS process, so it is reclaimed
    # with the queue.
    Registry.register(@registry, {:intent, id}, state.meeting_id)

    dedupe_index =
      if is_binary(dedupe_key),
        do: Map.put(state.dedupe_index, dedupe_key, id),
        else: state.dedupe_index

    state =
      %{state | dedupe_index: dedupe_index, seq: seq}
      |> maybe_learn_room(row)

    emit_enqueue_telemetry(state, :inserted, row)
    MeetingsPubSub.broadcast_intent_classified(state.meeting_id, row)
    notify_drain(state)

    {:reply, {:ok, row}, state}
  end

  # Carried forward from the pre-019f70b8 global queue so the
  # inserted-vs-duplicate observability contract survives the rewrite.
  # `meeting_id` and `intent_id` are new; `room_id` / `dedupe_key` /
  # `result` keep their old meanings.
  defp emit_enqueue_telemetry(state, result, row) do
    emit_telemetry(
      [:platform, :meetings, :intent_queue, :enqueue],
      %{count: 1},
      %{
        result: result,
        meeting_id: state.meeting_id,
        room_id: row.room_id,
        intent_id: row.id,
        dedupe_key: row.dedupe_key
      }
    )
  end

  # Every nilable field present on every row, so consumers (and the
  # stage-7 expanded table) can pattern-match without `Map.get/3`
  # defensiveness.
  defp default_row do
    %{
      room_id: nil,
      transcript_chunk_id: nil,
      chunk_excerpt: nil,
      classified_intent: nil,
      confidence: nil,
      target_role: nil,
      target_agent_id: nil,
      target_agent_slug: nil,
      dispatch_failure_reason: nil,
      model_used: nil,
      elapsed_ms: nil,
      dedupe_key: nil
    }
  end

  defp writable(attrs), do: Map.take(attrs, @writable_fields)

  defp lookup(state, intent_id) do
    case :ets.lookup(state.table, intent_id) do
      [{^intent_id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  defp stamp_status_timestamp(row, status) do
    case Map.get(@status_timestamps, status) do
      nil -> row
      field -> Map.put(row, field, DateTime.utc_now())
    end
  end

  defp maybe_learn_room(%{room_id: nil} = state, %{room_id: room_id}) when is_binary(room_id),
    do: %{state | room_id: room_id}

  defp maybe_learn_room(state, _row), do: state

  # `meeting:finished` carries `%{transcript_id, room_id, space_id}` —
  # meeting_id is NOT in the canonical payload, so the room is the
  # join. We match on meeting_id too because callers are free to
  # enrich, and a server that has not yet seen a room_id must not stop
  # on somebody else's meeting.
  defp finished_for_us?(payload, state) do
    cond do
      Map.get(payload, :meeting_id) == state.meeting_id -> true
      is_binary(state.room_id) and Map.get(payload, :room_id) == state.room_id -> true
      true -> false
    end
  end

  defp broadcast(meeting_id, :queued, row),
    do: MeetingsPubSub.broadcast_intent_classified(meeting_id, row)

  defp broadcast(meeting_id, :dispatched, row),
    do: MeetingsPubSub.broadcast_intent_dispatched(meeting_id, row)

  defp broadcast(meeting_id, :acked, row),
    do: MeetingsPubSub.broadcast_intent_acked(meeting_id, row)

  defp broadcast(meeting_id, :completed, row),
    do: MeetingsPubSub.broadcast_intent_completed(meeting_id, row)

  defp broadcast(meeting_id, status, row) when status in [:cancelled, :cancelled_late],
    do: MeetingsPubSub.broadcast_intent_cancelled(meeting_id, row)

  defp broadcast(meeting_id, :timed_out, row),
    do: MeetingsPubSub.broadcast_intent_timed_out(meeting_id, row)

  defp broadcast(meeting_id, :dispatch_failed, row),
    do: MeetingsPubSub.broadcast_intent_dispatch_failed(meeting_id, row)

  defp broadcast(meeting_id, :no_ack_spawn_failed, row),
    do: MeetingsPubSub.broadcast_intent_no_ack_spawn_failed(meeting_id, row)
end
