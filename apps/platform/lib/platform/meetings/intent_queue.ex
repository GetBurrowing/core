defmodule Platform.Meetings.IntentQueue do
  @moduledoc """
  Meeting-lifetime intent queue — ETS-backed staging area for
  classified transcript intents awaiting downstream promotion (task
  creation, digest inclusion, etc.).

  Sits between the classifier (stage 3+) and the promoter (later
  stages): the classifier pushes intents in, the promoter drains them
  in batches per room. Living in ETS (not Ecto) matches Rowan's
  standing rule for meeting-lifetime ephemeral state: nothing here
  needs to survive a node restart — if a meeting is still in progress
  after a bounce the transcript will re-flow and re-classify.

  ## Data shape

  Table: `:meeting_intent_queue`, `set`, `named_table`, `public`,
  `read_concurrency: true` — mirrors `Platform.Meetings.State` so the
  ownership + concurrency story is identical.

  Row: `{{room_id, dedupe_key}, item_map}` where `item_map` is:

      %{
        intent: atom(),
        target_role: atom() | nil,
        confidence: float(),
        chunk_id: binary() | nil,
        inserted_at_monotonic: integer(),  # milliseconds
        meeting_id: binary() | nil
      }

  The composite `{room_id, dedupe_key}` key gives us natural
  per-`(room, dedupe_key)` idempotence via `:ets.insert_new/2`: two
  classifier passes over the same chunk that produce the same
  dedupe_key collapse to one entry without any coordinating lock.

  ## Cleanup

    * Subscribes to `Platform.Meetings.PubSub.subscribe_meeting_finished/0`
      — on `{:meeting_finished, %{room_id: id}}`, drops all rows for
      that room. This is the primary path.
    * Periodic sweep every 30 min as belt-and-braces: any row older
      than 30 min (by `inserted_at_monotonic`) is deleted. Catches
      rooms whose finished event was missed (crash between
      `broadcast_meeting_finished` and this handler running).
  """

  use GenServer

  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @table :meeting_intent_queue

  # 30 minutes, expressed in milliseconds for direct comparison with
  # `System.monotonic_time(:millisecond)`.
  @sweep_interval_ms :timer.minutes(30)
  @max_age_ms :timer.minutes(30)

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start the queue owner. Creates the named public ETS table on init
  so writes/reads from any process are lock-free. Booted from
  `Platform.Application`'s child list.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # `:public` lets any process insert / delete (enqueue and
    # pop_batch run in the caller's process); `:named_table` lets
    # readers reference `@table` directly without locating the owning
    # pid. `:set` matches idempotence semantics — one row per
    # `{room_id, dedupe_key}`.
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # A previous incarnation (crash + supervisor restart) may have
        # left the table around; `:public` tables die with their owner
        # so this branch is defensive against tests that pre-create
        # the table.
        :ok
    end

    MeetingsPubSub.subscribe_meeting_finished()
    schedule_sweep()

    {:ok, %{}}
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Enqueue a classified intent for `room_id`. Returns `{:ok, :inserted}`
  on first write, `{:ok, :duplicate}` when a row with the same
  `{room_id, dedupe_key}` already exists.

  Idempotence is atomic (`:ets.insert_new/2` — a single ETS op) so
  concurrent classifier passes can't both win.

  Emits `[:platform, :meetings, :intent_queue, :enqueue]` telemetry on
  BOTH the insert and duplicate paths so downstream observers can
  distinguish first-writes from dedupe hits.
  """
  @spec enqueue(binary(), binary(), map()) :: {:ok, :inserted} | {:ok, :duplicate}
  def enqueue(room_id, dedupe_key, item_map)
      when is_binary(room_id) and is_binary(dedupe_key) and is_map(item_map) do
    stamped =
      item_map
      |> Map.put_new(:inserted_at_monotonic, System.monotonic_time(:millisecond))

    result =
      if ensure_table() do
        case :ets.insert_new(@table, {{room_id, dedupe_key}, stamped}) do
          true -> :inserted
          false -> :duplicate
        end
      else
        # Defensive: table hasn't been created yet (early boot / test
        # harness). Treat as no-op insert so callers don't crash.
        :inserted
      end

    :telemetry.execute(
      [:platform, :meetings, :intent_queue, :enqueue],
      %{count: 1},
      %{result: result, room_id: room_id, dedupe_key: dedupe_key}
    )

    {:ok, result}
  end

  @doc """
  Return up to `limit` items for `room_id` and remove them from the
  queue. Uses a match-spec that captures the composite key so we
  delete the exact rows we return (no race with a concurrent
  `enqueue/3`).
  """
  @spec pop_batch(binary(), pos_integer()) :: [map()]
  def pop_batch(room_id, limit) when is_binary(room_id) and is_integer(limit) and limit > 0 do
    if ensure_table() do
      # Capture (dedupe_key, item) tuples for this room. `:"$1"` binds
      # dedupe_key, `:"$2"` binds the value map; we return them as a
      # 2-tuple via `{{:"$1", :"$2"}}` (match-spec quoting).
      match_spec = [
        {{{room_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
      ]

      case :ets.select(@table, match_spec, limit) do
        :"$end_of_table" ->
          []

        {pairs, _continuation} ->
          # Delete the exact rows we captured, then hand the items
          # back to the caller.
          Enum.map(pairs, fn {dedupe_key, item} ->
            :ets.delete(@table, {room_id, dedupe_key})
            item
          end)
      end
    else
      []
    end
  end

  @doc """
  Drop every entry for `room_id`. Called on `:meeting_finished`
  broadcasts and available for tests / operational overrides.

  Serialised through the queue owner so the count-then-delete pair is
  atomic within the queue's view — otherwise a concurrent enqueue
  between the count and delete would skew the telemetry
  `removed_count`.

  Emits `[:platform, :meetings, :intent_queue, :drop]` with
  `%{count: removed_count}` measurements and
  `%{room_id, removed_count}` metadata.
  """
  @spec drop_for_room(binary()) :: :ok
  def drop_for_room(room_id) when is_binary(room_id) do
    GenServer.call(__MODULE__, {:drop_for_room, room_id})
  end

  @doc """
  Non-destructive read — return every item currently queued for
  `room_id`. Intended for tests + operational inspection; the
  promoter should use `pop_batch/2` instead.
  """
  @spec list_for_room(binary()) :: [map()]
  def list_for_room(room_id) when is_binary(room_id) do
    if ensure_table() do
      @table
      |> :ets.match_object({{room_id, :_}, :_})
      |> Enum.map(fn {_, item} -> item end)
    else
      []
    end
  end

  # ── Handlers ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:drop_for_room, room_id}, _from, state) when is_binary(room_id) do
    do_drop_for_room(room_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:meeting_finished, %{room_id: room_id}}, state) when is_binary(room_id) do
    # Call the inline helper — NOT `drop_for_room/1` — because a
    # GenServer synchronously calling itself deadlocks. The helper
    # runs in the queue owner's own process, which is already the
    # serialisation point we want.
    do_drop_for_room(room_id)
    {:noreply, state}
  end

  # Tolerate mis-shaped events without crashing the queue owner —
  # the classifier's PubSub bus is shared with unrelated payloads
  # in some test setups.
  def handle_info({:meeting_finished, _payload}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ───────────────────────────────────────────────────────────────

  # Serialised drop path. Runs in the queue owner's process so
  # `:ets.select_count/2` and `:ets.match_delete/2` see the same
  # snapshot — concurrent enqueues from other processes still write
  # atomically to ETS, but the count returned here matches what we
  # actually removed.
  defp do_drop_for_room(room_id) do
    removed_count =
      if ensure_table() do
        pattern = {{room_id, :_}, :_}
        # `:ets.select_count/2` matches the same pattern used for
        # `match_delete/2`; the match spec `{pattern, [], [true]}`
        # tells ETS to count each row that matches without pulling
        # the row bodies into userspace.
        count = :ets.select_count(@table, [{pattern, [], [true]}])
        :ets.match_delete(@table, pattern)
        count
      else
        0
      end

    :telemetry.execute(
      [:platform, :meetings, :intent_queue, :drop],
      %{count: removed_count},
      %{room_id: room_id, removed_count: removed_count}
    )

    :ok
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined -> false
      _ -> true
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Delete every row whose age (by `:inserted_at_monotonic`) exceeds
  # `@max_age_ms`. We compute the cutoff once so all rows are checked
  # against a single instant.
  defp sweep_expired do
    cutoff = System.monotonic_time(:millisecond) - @max_age_ms

    # Match specs can't reach inside a map value, so we take the
    # two-step: pull every row, filter in Elixir, delete by key.
    # The queue is meeting-lifetime and small, so a full scan every
    # 30 min is a rounding-error cost.
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, item} ->
      case Map.get(item, :inserted_at_monotonic) do
        ts when is_integer(ts) and ts < cutoff -> :ets.delete(@table, key)
        _ -> :ok
      end
    end)
  end
end
