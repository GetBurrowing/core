defmodule Platform.Meetings.IntentQueue do
  @moduledoc """
  Public entry point for the meeting intent queue.

  A thin facade over `Platform.Meetings.IntentQueue.Server`: one
  Registry-keyed GenServer per meeting, owning an unnamed ETS table
  that dies with the process, rows keyed by a generated UUIDv7 so a
  remote runtime can address one intent, a nine-value status enum whose
  terminal rows are RETAINED so a live UI has something to render, and
  an ack-gated serial cursor that keeps at most one intent in front of
  a meeting's agents at a time.

  ## What this replaced

  Before task 019f70b8 the queue was ONE global GenServer owning one
  named public ETS table `:meeting_intent_queue`, keyed
  `{room_id, dedupe_key}`, with a two-value status (`:pending |
  :dispatching`), an attempts/retry cap, a 30-minute sweep, and a
  `mark_dispatched/2` that DELETED the row. Stage 2 introduced the
  per-meeting server alongside it; **stage 3 deleted the legacy queue
  outright**, along with its sweep, its retry cap, and the classifier's
  dual-write. Nothing delegates to it any more — the module is gone.

  The retry cap went with it deliberately: under the ack contract the
  outcome of a dispatch is reported by the target (`intent_ack`) or
  decided by the ack timeout, so "try it N more times and then give up"
  no longer describes anything. A dispatch that fails to reach a
  runtime is a visible `:dispatch_failed` row the producer can act on,
  not a silent retry budget.

  ## Meeting id is required

  Every entry point is keyed by `meeting_id`. A transcript chunk from a
  room with no linked `Meeting` row has no queue and is not enqueued —
  the per-meeting owner is Registry-keyed by meeting_id and there is
  nowhere for such a row to live. The classifier logs and drops it
  rather than pretending.
  """

  require Logger

  alias Platform.Meetings.IntentQueue.Server
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor
  alias Platform.Meetings.IntentRuntimeAdapter

  @type status :: Server.status()
  @type row :: Server.row()

  # ── Per-meeting queue (task 019f70b8) ──────────────────────────────────────

  @doc """
  Enqueue a classified intent into `meeting_id`'s queue, starting the
  queue owner if this is the meeting's first intent.

  Returns `{:ok, row}` or `{:duplicate, existing_row}` — the latter
  when `attrs[:dedupe_key]` already has a row, preserving the
  idempotence the old composite ETS key gave for free.
  """
  @spec enqueue(binary(), map()) :: {:ok, row()} | {:duplicate, row()} | {:error, term()}
  def enqueue(meeting_id, attrs) when is_binary(meeting_id) and is_map(attrs) do
    case QueueSupervisor.ensure_started(meeting_id, room_id: Map.get(attrs, :room_id)) do
      {:ok, _pid} ->
        with_queue(meeting_id, {:error, :queue_unavailable}, fn ->
          Server.enqueue(meeting_id, attrs)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every intent row for `meeting_id`, oldest first, including terminal
  rows. Returns `[]` when no queue owner is running — a meeting that
  has never produced an intent is indistinguishable from one whose
  queue has ended, and both render as an empty strip.
  """
  @spec list(binary()) :: [row()]
  def list(meeting_id) when is_binary(meeting_id) do
    with_queue(meeting_id, [], fn -> Server.list(meeting_id) end)
  end

  @doc "Fetch one intent row by id."
  @spec get(binary(), binary()) :: {:ok, row()} | {:error, :not_found}
  def get(meeting_id, intent_id) when is_binary(meeting_id) and is_binary(intent_id) do
    with_queue(meeting_id, {:error, :not_found}, fn -> Server.get(meeting_id, intent_id) end)
  end

  @doc """
  Move an intent row to `status`, merging `attrs` and broadcasting the
  matching event on `meeting:<meeting_id>:intents`.
  """
  @spec transition(binary(), binary(), status(), map()) ::
          {:ok, row()} | {:error, :not_found} | {:error, {:invalid_status, term()}}
  def transition(meeting_id, intent_id, status, attrs \\ %{})
      when is_binary(meeting_id) and is_binary(intent_id) do
    with_queue(meeting_id, {:error, :not_found}, fn ->
      Server.transition(meeting_id, intent_id, status, attrs)
    end)
  end

  @doc "Remove an intent row. Idempotent, and silent by design (see `Server`)."
  @spec delete(binary(), binary()) :: :ok
  def delete(meeting_id, intent_id) when is_binary(meeting_id) and is_binary(intent_id) do
    with_queue(meeting_id, :ok, fn -> Server.delete(meeting_id, intent_id) end)
  end

  @doc """
  Cancel an intent on the producer's behalf, reaching the target's
  runtime when the intent has already left the building (task 019f70b8
  stage 4).

  This is the function the stage-7 X and pencil buttons call. It is
  status-aware, because "cancel" means four different things depending
  on where the row is:

  | row status              | what happens                                          | returns                      |
  |-------------------------|-------------------------------------------------------|------------------------------|
  | `:queued`               | removed from ETS; nobody ever saw it                  | `{:ok, :deleted, row}`       |
  | `:dispatched` / `:acked`| `intent_cancelled` broadcast to the target's runtime, carrying the `subagent_id` captured at ack; the row waits for `intent_ack(status: :cancel_honored)` | `{:ok, :cancel_requested, row}` |
  | `:dispatched` / `:acked`, runtime gone | nothing to signal — landed `:cancelled` locally         | `{:ok, :cancelled, row}`     |
  | `:completed`            | the work finished before the X landed                 | `{:ok, :cancelled_late, row}`|
  | other terminal          | nothing to cancel                                     | `{:error, {:not_cancellable, status}}` |

  Opts are forwarded to
  `Platform.Meetings.IntentRuntimeAdapter.cancel/2`: `:reason`
  (`:wrong_intent | :wrong_target | :not_actionable | :other`),
  `:corrected_intent`, `:corrected_target_agent_id`.

  The durable record of a correction is a `meeting_intent_corrections`
  row, which stage 6 owns and this function deliberately does not
  write: a cancel that reaches a runtime and a cancel that is logged
  for LLM tuning are two different concerns, and coupling them here
  would mean the queue could not be exercised without a table.

  Note the asymmetry in the in-flight row: it is NOT marked cancelled
  when the signal goes out. Until the target answers, the honest state
  is still "with a runtime" — a row we optimistically marked
  `:cancelled` while a subagent kept working would be exactly the
  invisibility this task exists to remove. If the target never answers,
  the ack window resolves the row as `:timed_out`.
  """
  @spec cancel(binary(), binary(), keyword()) ::
          {:ok, :deleted | :cancel_requested | :cancelled | :cancelled_late, row()}
          | {:error, :not_found}
          | {:error, {:not_cancellable, status()}}
  def cancel(meeting_id, intent_id, opts \\ [])
      when is_binary(meeting_id) and is_binary(intent_id) and is_list(opts) do
    with_queue(meeting_id, {:error, :not_found}, fn ->
      case Server.begin_cancel(meeting_id, intent_id) do
        {:ok, :signal, row} -> signal_cancel(meeting_id, row, opts)
        {:ok, outcome, row} -> {:ok, outcome, row}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # The row is with a runtime. Ask that runtime to stop, and only fall
  # back to a local landing when there is demonstrably nobody to ask —
  # the agent was deleted, or its runtime link was removed, since the
  # dispatch went out. Marking it `:cancelled` then is the honest
  # answer: the producer pulled it and no subagent can be told, so
  # leaving the row in flight until the ack window expires would show
  # `:timed_out` for something that was actually cancelled.
  defp signal_cancel(meeting_id, row, opts) do
    case IntentRuntimeAdapter.cancel(row, opts) do
      :ok ->
        {:ok, :cancel_requested, row}

      {:error, reason} ->
        Logger.info(
          "[IntentQueue] cancel could not reach a runtime — landing locally " <>
            "meeting_id=#{meeting_id} intent_id=#{row.id} reason=#{inspect(reason)}"
        )

        case transition(meeting_id, row.id, :cancelled) do
          {:ok, cancelled} -> {:ok, :cancelled, cancelled}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  True when a queue owner is currently running for `meeting_id`.

  Checks `Process.alive?/1` rather than trusting the Registry lookup
  alone: Registry cleanup is driven by a monitor, so for a short window
  after the owner exits the lookup still returns its (dead) pid.
  """
  @spec running?(binary()) :: boolean()
  def running?(meeting_id) when is_binary(meeting_id) do
    case Server.whereis(meeting_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  @doc """
  Stop `meeting_id`'s queue owner, dropping its ETS table. Normally
  driven by the `:meeting_finished` broadcast the server subscribes to;
  exposed for tests and operational overrides.
  """
  @spec stop(binary()) :: :ok
  def stop(meeting_id) when is_binary(meeting_id), do: QueueSupervisor.stop(meeting_id)

  @doc "The nine valid row statuses."
  @spec statuses() :: [status()]
  defdelegate statuses(), to: Server

  @doc "Statuses meaning the intent is with a runtime right now."
  @spec in_flight_statuses() :: [status()]
  defdelegate in_flight_statuses(), to: Server

  @doc "Statuses no further transition is expected from."
  @spec terminal_statuses() :: [status()]
  defdelegate terminal_statuses(), to: Server

  @doc "Statuses that release the serial dispatch cursor."
  @spec advancing_statuses() :: [status()]
  defdelegate advancing_statuses(), to: Server

  @doc "The four `intent_ack` statuses a runtime may report."
  @spec ack_statuses() :: [atom()]
  defdelegate ack_statuses(), to: Server

  @doc """
  Resolve an `intent_id` to its owning meeting.

  Registry-backed and cheap; safe to call from the MCP tool surface,
  which only ever receives an intent id.
  """
  @spec locate(binary()) :: {:ok, binary()} | {:error, :not_found}
  defdelegate locate(intent_id), to: Server

  # ── Serial cursor + ack (task 019f70b8 stage 3) ────────────────────────────

  @doc """
  Reserve this meeting's next `:queued` intent for dispatch.

  `{:ok, row}` hands over a row that is still `:queued` — the caller
  commits it with `transition/4` to `:dispatched` or `:dispatch_failed`.
  `{:busy, intent_id}` means an intent is already with a runtime, and
  `:empty` means there is nothing to send.
  """
  @spec claim_next(binary()) :: {:ok, row()} | {:busy, binary()} | :empty
  def claim_next(meeting_id) when is_binary(meeting_id) do
    with_queue(meeting_id, :empty, fn -> Server.claim_next(meeting_id) end)
  end

  @doc """
  Land an `intent_ack` from a target runtime. See
  `Platform.Meetings.IntentQueue.Server.ack/5` for the status table.
  """
  @spec ack(binary(), binary(), binary(), atom(), binary() | nil) ::
          {:ok, row()} | {:error, term()}
  def ack(meeting_id, intent_id, subagent_id, ack_status, note \\ nil)
      when is_binary(meeting_id) and is_binary(intent_id) and is_binary(subagent_id) do
    with_queue(meeting_id, {:error, :not_found}, fn ->
      Server.ack(meeting_id, intent_id, subagent_id, ack_status, note)
    end)
  end

  @doc """
  Record a schema-rejected `intent_ack` attempt. Never mutates the ETS
  row — it only decides whether an eventual timeout is reported as
  `:no_ack_spawn_failed` rather than `:timed_out`.
  """
  @spec record_rejected_ack(binary(), binary()) :: :ok
  def record_rejected_ack(meeting_id, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    with_queue(meeting_id, :ok, fn -> Server.record_rejected_ack(meeting_id, intent_id) end)
  end

  @doc "The intent id currently holding this meeting's cursor, or nil."
  @spec cursor(binary()) :: binary() | nil
  def cursor(meeting_id) when is_binary(meeting_id) do
    with_queue(meeting_id, nil, fn -> Server.cursor(meeting_id) end)
  end

  @doc "Schema-rejected ack attempts observed for `intent_id`."
  @spec rejected_ack_count(binary(), binary()) :: non_neg_integer()
  def rejected_ack_count(meeting_id, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    with_queue(meeting_id, 0, fn -> Server.rejected_ack_count(meeting_id, intent_id) end)
  end

  @doc "Meeting ids with a live queue owner. Operational/test reflection."
  @spec live_meeting_ids() :: [binary()]
  defdelegate live_meeting_ids(), to: QueueSupervisor

  @doc """
  Start `meeting_id`'s queue owner if it isn't running, with opts.

  `enqueue/2` calls this for you. Reach for it directly when a caller
  needs to set server options before the first intent lands — chiefly
  `:ack_timeout_ms`, which tests drive down from the 90s default.
  """
  @spec ensure_started(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate ensure_started(meeting_id, opts \\ []), to: QueueSupervisor

  # A meeting's queue can end at any instant — `:meeting_finished`
  # lands, the owner stops, and its ETS table goes with it. Every entry
  # point therefore has to tolerate "the queue was there a microsecond
  # ago and isn't now", because there is no lock that would make the
  # liveness check and the call atomic.
  #
  # Without this a MeetingLive mounting as its meeting ends would take
  # a `GenServer.call` exit straight through the LiveView — the caller
  # asked "what is in the queue", the honest answer is "nothing", and
  # a crash is not that answer. Timeouts and genuine crashes inside the
  # server are NOT swallowed: those are bugs and must surface.
  defp with_queue(meeting_id, absent, fun) do
    if running?(meeting_id) do
      try do
        fun.()
      catch
        :exit, {:noproc, _} -> absent
        :exit, {:normal, _} -> absent
        :exit, {:shutdown, _} -> absent
        :exit, {{:shutdown, _}, _} -> absent
      end
    else
      absent
    end
  end
end
