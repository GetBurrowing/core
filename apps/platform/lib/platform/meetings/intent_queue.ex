defmodule Platform.Meetings.IntentQueue do
  @moduledoc """
  Meeting-lifetime intent queue — ETS-backed staging area for
  classified transcript intents awaiting downstream promotion (task
  creation, digest inclusion, etc.).

  Sits between the classifier (stage 3+) and the dispatcher (task
  019f2452 stage 2 and later): the classifier pushes intents in, the
  dispatcher claims and delegates them out. Living in ETS (not Ecto)
  matches Rowan's standing rule for meeting-lifetime ephemeral state:
  nothing here needs to survive a node restart — if a meeting is still
  in progress after a bounce the transcript will re-flow and
  re-classify.

  ## Data shape

  Table: `:meeting_intent_queue`, `set`, `named_table`, `public`,
  `read_concurrency: true` — mirrors `Platform.Meetings.State` so the
  ownership + concurrency story is identical.

  Row: `{{room_id, dedupe_key}, item_map}` where `item_map` is:

      %{
        intent: atom(),
        target_role: atom() | binary() | nil,
        confidence: float(),
        chunk_id: binary() | nil,
        inserted_at_monotonic: integer(),  # milliseconds
        meeting_id: binary() | nil,
        # Retry-aware fields added task 019f2452 stage 1:
        status: :pending | :dispatching,
        attempts: non_neg_integer(),
        claimed_at_monotonic: integer() | nil,
        last_error: binary() | nil
      }

  The composite `{room_id, dedupe_key}` key gives us natural
  per-`(room, dedupe_key)` idempotence via `:ets.insert_new/2`: two
  classifier passes over the same chunk that produce the same
  dedupe_key collapse to one entry without any coordinating lock.

  Legacy rows (written before the retry fields shipped) MAY be missing
  `:status` / `:attempts`. All state-transition helpers treat a missing
  `:status` as `:pending` and a missing `:attempts` as `0` — purely
  additive semantics so a hot upgrade doesn't strand rows.

  ## Cleanup

    * Subscribes to `Platform.Meetings.PubSub.subscribe_meeting_finished/0`
      — on `{:meeting_finished, %{room_id: id}}`, drops all rows for
      that room. This is the primary path.
    * Periodic sweep every 30 min as belt-and-braces: any row older
      than 30 min (by `inserted_at_monotonic`) is deleted. Catches
      rooms whose finished event was missed (crash between
      `broadcast_meeting_finished` and this handler running).

  ## Retry semantics

  `mark_retry/3` bumps `:attempts` by one; once it reaches
  `@max_attempts` the helper returns `{:exhausted, attempts}` and the
  caller (typically the dispatcher) is expected to promote to
  `mark_dropped/3` with reason `:max_attempts_exceeded`. Retry counts
  are meeting-lifetime — a corrupt payload that fails three times in
  seconds gets dropped, matching Rowan's ETS-ephemeral rule ("meetings
  are short; the queue should not accumulate").
  """

  use GenServer

  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @table :meeting_intent_queue

  # 30 minutes, expressed in milliseconds for direct comparison with
  # `System.monotonic_time(:millisecond)`.
  @sweep_interval_ms :timer.minutes(30)
  @max_age_ms :timer.minutes(30)

  # Retry cap for `mark_retry/3`. Three attempts matches Rowan's
  # "meetings are short; corrupt payloads shouldn't linger" rule.
  @max_attempts 3

  # Position of the item_map inside the ETS tuple `{key, item_map}`.
  # `:ets.update_element/3` positions are 1-based, and the key is
  # position 1, so the item lives at position 2.
  @item_pos 2

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

  @doc """
  Retry cap exposed for tests and consumers that need to size their
  own back-off windows (dispatcher, StallRegistry). Purely reflective —
  don't override without shipping a new deploy.
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

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

  On the `:inserted` path (only) also broadcasts
  `{:intent_enqueued, %{room_id: room_id, dedupe_key: dedupe_key}}` on
  the `Platform.Meetings.PubSub.intent_enqueued_topic/0` topic so the
  dispatcher wakes up without polling. Dedupe hits deliberately do NOT
  re-broadcast — the dispatcher already has (or has already dispatched)
  the target row.
  """
  @spec enqueue(binary(), binary(), map()) :: {:ok, :inserted} | {:ok, :duplicate}
  def enqueue(room_id, dedupe_key, item_map)
      when is_binary(room_id) and is_binary(dedupe_key) and is_map(item_map) do
    # Stamp default retry-aware fields. `Map.put_new/3` means the
    # classifier can override any of these if it wants (tests do this
    # for the sweep + retry cases) while normal writes get sensible
    # defaults automatically.
    stamped =
      item_map
      |> Map.put_new(:inserted_at_monotonic, System.monotonic_time(:millisecond))
      |> Map.put_new(:status, :pending)
      |> Map.put_new(:attempts, 0)

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

    if result == :inserted do
      # Fire-and-forget — the broadcast helper wraps
      # `Phoenix.PubSub.broadcast/3` which is safe from any process.
      # Dedupe hits do NOT re-broadcast (would spam the dispatcher for
      # no-op writes).
      MeetingsPubSub.broadcast_intent_enqueued(%{room_id: room_id, dedupe_key: dedupe_key})
    end

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
  dispatcher should use `claim_pending/1` instead.
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

  # ── Dispatcher-facing API (task 019f2452 stage 1) ──────────────────────────

  @doc """
  Claim up to `limit` pending items across all rooms. Rows STAY in the
  table (peek-and-stamp) so a crashed dispatcher can retry after the
  sweep — the row's `:status` transitions from `:pending` to
  `:dispatching` and `:claimed_at_monotonic` is stamped with `now`.

  Serialised through the queue owner (`GenServer.call/2`) so that
  `select` → `update_element` is atomic with respect to other claim
  callers. Concurrent `enqueue/3` writes from any process still land
  atomically in ETS; the serialisation only guards claim-vs-claim
  races (two dispatcher processes competing for the same row).

  Returns `[{room_id, dedupe_key, item_map}]` where `item_map` reflects
  the post-transition state (status: `:dispatching`, claimed_at
  populated). Terminates the batch when either `limit` rows have been
  claimed OR no more pending rows exist.

  Missing `:status` on a row is treated as `:pending` (backward
  compatibility with legacy rows written before this stage).
  """
  @spec claim_pending(pos_integer()) :: [{binary(), binary(), map()}]
  def claim_pending(limit) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:claim_pending, limit})
  end

  @doc """
  Narrow-scope hot-path claim: transition exactly one row identified by
  `{room_id, dedupe_key}` from `:pending` to `:dispatching`. Cheaper
  than `claim_pending/1`, which walks every row — used by the
  dispatcher's `{:intent_enqueued, ...}` PubSub handler where the exact
  key was just published.

  Returns:

    * `{:ok, {room_id, dedupe_key, item_map}}` — row transitioned;
      `item_map` reflects the post-transition state.
    * `{:already_claimed, item_map}` — the row exists but is not
      `:pending` (someone else beat us to it). Caller should silently
      no-op; the owner will `mark_dispatched` / `mark_retry` when done.
    * `{:error, :not_found}` — the row is gone (meeting finished,
      dropped externally). Caller no-ops.

  Serialised through the queue owner so the lookup + transition pair is
  atomic against sibling claim callers (mirrors `claim_pending/1`).
  """
  @spec claim_one(binary(), binary()) ::
          {:ok, {binary(), binary(), map()}}
          | {:already_claimed, map()}
          | {:error, :not_found}
  def claim_one(room_id, dedupe_key)
      when is_binary(room_id) and is_binary(dedupe_key) do
    GenServer.call(__MODULE__, {:claim_one, room_id, dedupe_key})
  end

  @doc """
  Mark a claimed row as successfully dispatched — delete it from the
  queue. Idempotent: `:ok` on both "row deleted" and "row already
  gone" paths so a doubled call from a crashed-and-restarted
  dispatcher doesn't error.
  """
  @spec mark_dispatched(binary(), binary()) :: :ok
  def mark_dispatched(room_id, dedupe_key)
      when is_binary(room_id) and is_binary(dedupe_key) do
    GenServer.call(__MODULE__, {:mark_dispatched, room_id, dedupe_key})
  end

  @doc """
  Mark a claimed row as retryable — increment `:attempts`, reset
  `:status` back to `:pending`, and record `last_error: inspect(reason)`.

  Returns `{:ok, attempts}` while attempts is under `@max_attempts` so
  the dispatcher can log / instrument, or `{:exhausted, attempts}` when
  attempts has hit the cap. The caller (dispatcher stage 2) is expected
  to promote `:exhausted` to `mark_dropped(:max_attempts_exceeded)`.

  If the row has vanished between claim and retry (rare — meeting
  finished, drop_for_room called externally), returns `{:error, :not_found}`.
  """
  @spec mark_retry(binary(), binary(), term()) ::
          {:ok, pos_integer()} | {:exhausted, pos_integer()} | {:error, :not_found}
  def mark_retry(room_id, dedupe_key, reason)
      when is_binary(room_id) and is_binary(dedupe_key) do
    GenServer.call(__MODULE__, {:mark_retry, room_id, dedupe_key, reason})
  end

  @doc """
  Terminal drop for a claimed row. Deletes the row and emits
  `[:platform, :meetings, :intent_queue, :drop]` telemetry with the
  supplied `reason` for observability. Reasons in practice:
  `:no_assignee`, `:unknown_role`, `:max_attempts_exceeded`,
  `:target_role_nil`.

  Idempotent — a doubled call is `:ok` even if the row was already
  gone. Fires telemetry ONLY when the row was actually removed (so a
  no-op call doesn't skew the drop count).
  """
  @spec mark_dropped(binary(), binary(), atom()) :: :ok
  def mark_dropped(room_id, dedupe_key, reason)
      when is_binary(room_id) and is_binary(dedupe_key) and is_atom(reason) do
    GenServer.call(__MODULE__, {:mark_dropped, room_id, dedupe_key, reason})
  end

  @doc """
  Return every claimed-but-stuck row: `:status == :dispatching` AND
  `:claimed_at_monotonic` older than `stall_window_ms` before now.

  Used by the StallRegistry callback (wired stage 4) to re-drive
  items whose dispatcher crashed between claim and mark_dispatched.

  Returns `[{room_id, dedupe_key}]` — the caller doesn't need the
  full item_map because `mark_retry/3` operates by key.
  """
  @spec list_stalled(pos_integer()) :: [{binary(), binary()}]
  def list_stalled(stall_window_ms)
      when is_integer(stall_window_ms) and stall_window_ms > 0 do
    if ensure_table() do
      cutoff = System.monotonic_time(:millisecond) - stall_window_ms

      # Match specs can't reach inside a map value, so pull every row
      # and filter in Elixir. The queue is meeting-lifetime and
      # small — a full scan for the stall check is a rounding-error
      # cost compared to the dispatch itself.
      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn {{room_id, dedupe_key}, item} ->
        with :dispatching <- Map.get(item, :status),
             ts when is_integer(ts) and ts < cutoff <-
               Map.get(item, :claimed_at_monotonic) do
          [{room_id, dedupe_key}]
        else
          _ -> []
        end
      end)
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

  def handle_call({:claim_pending, limit}, _from, state) do
    {:reply, do_claim_pending(limit), state}
  end

  def handle_call({:claim_one, room_id, dedupe_key}, _from, state) do
    {:reply, do_claim_one(room_id, dedupe_key), state}
  end

  def handle_call({:mark_dispatched, room_id, dedupe_key}, _from, state) do
    if ensure_table() do
      :ets.delete(@table, {room_id, dedupe_key})
    end

    {:reply, :ok, state}
  end

  def handle_call({:mark_retry, room_id, dedupe_key, reason}, _from, state) do
    {:reply, do_mark_retry(room_id, dedupe_key, reason), state}
  end

  def handle_call({:mark_dropped, room_id, dedupe_key, reason}, _from, state) do
    {:reply, do_mark_dropped(room_id, dedupe_key, reason), state}
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

  # Runs inside the queue owner so the select-then-transition pair is
  # atomic against sibling claim callers. Concurrent enqueue writers
  # can still land new rows during the transition (their inserts are
  # single-op atomic in ETS); we simply won't see them in this batch,
  # which is fine — they'll be caught by the next claim or by the
  # PubSub notify.
  defp do_claim_pending(limit) do
    if ensure_table() do
      now = System.monotonic_time(:millisecond)

      # Match spec: bind key, dedupe_key, item to variables; no guard
      # (we filter by :status in Elixir because match-specs can't
      # reach inside map values); return the full triple so we can
      # transition + report in one pass.
      match_spec = [
        {{{:"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ]

      # Bounded scan — walk rows in ETS order, transition the first
      # `limit` pending ones we find. This is O(table_size) worst
      # case, but the queue is meeting-lifetime and small; the
      # dispatcher's belt-and-braces tick is 30s so any pending row
      # gets picked up quickly regardless.
      @table
      |> :ets.select(match_spec)
      |> Enum.reduce_while([], fn {room_id, dedupe_key, item}, acc ->
        cond do
          length(acc) >= limit ->
            {:halt, acc}

          pending?(item) ->
            transitioned =
              item
              |> Map.put(:status, :dispatching)
              |> Map.put(:claimed_at_monotonic, now)

            # `update_element` is a single ETS op — atomic w.r.t.
            # concurrent readers.
            :ets.update_element(@table, {room_id, dedupe_key}, {@item_pos, transitioned})
            {:cont, [{room_id, dedupe_key, transitioned} | acc]}

          true ->
            {:cont, acc}
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  end

  # Hot-path single-row claim. Kept parallel to `do_claim_pending/1`
  # so the atomicity story is identical: run inside the queue owner,
  # look up + transition + update in one call.
  defp do_claim_one(room_id, dedupe_key) do
    if ensure_table() do
      case :ets.lookup(@table, {room_id, dedupe_key}) do
        [{_key, item}] ->
          if pending?(item) do
            now = System.monotonic_time(:millisecond)

            transitioned =
              item
              |> Map.put(:status, :dispatching)
              |> Map.put(:claimed_at_monotonic, now)

            :ets.update_element(@table, {room_id, dedupe_key}, {@item_pos, transitioned})
            {:ok, {room_id, dedupe_key, transitioned}}
          else
            {:already_claimed, item}
          end

        [] ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # A row is claimable when it's explicitly `:pending` OR when
  # `:status` is missing (legacy rows written before stage 1). Any
  # other value (`:dispatching`, future statuses) means someone else
  # already owns it — leave alone.
  defp pending?(item) do
    case Map.get(item, :status) do
      :pending -> true
      nil -> true
      _ -> false
    end
  end

  defp do_mark_retry(room_id, dedupe_key, reason) do
    if ensure_table() do
      case :ets.lookup(@table, {room_id, dedupe_key}) do
        [{_key, item}] ->
          new_attempts = (Map.get(item, :attempts) || 0) + 1

          updated =
            item
            |> Map.put(:attempts, new_attempts)
            |> Map.put(:status, :pending)
            |> Map.put(:last_error, inspect(reason))
            # Clear the claim stamp so `list_stalled/1` doesn't
            # falsely flag this row while it's back in the pending
            # bucket.
            |> Map.put(:claimed_at_monotonic, nil)

          :ets.update_element(@table, {room_id, dedupe_key}, {@item_pos, updated})

          if new_attempts >= @max_attempts do
            {:exhausted, new_attempts}
          else
            {:ok, new_attempts}
          end

        [] ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp do_mark_dropped(room_id, dedupe_key, reason) do
    removed? =
      if ensure_table() do
        # `:ets.take/2` returns the removed row(s) — empty list if the
        # row was already gone, so we can distinguish a real drop
        # (fire telemetry) from a no-op call (silent).
        case :ets.take(@table, {room_id, dedupe_key}) do
          [_] -> true
          [] -> false
        end
      else
        false
      end

    if removed? do
      :telemetry.execute(
        [:platform, :meetings, :intent_queue, :drop],
        %{count: 1},
        %{room_id: room_id, dedupe_key: dedupe_key, reason: reason, removed_count: 1}
      )
    end

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
