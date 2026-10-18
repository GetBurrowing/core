defmodule Platform.Org.Wiki.Indexer do
  @moduledoc """
  Async indexer for the org wiki — translates T2's `"org_wiki:index"` PubSub
  events into `Platform.Memory` ingest / delete calls (ADR-0041, T3).

  ## Design

  The wiki write path (`Platform.Org.Wiki.upsert_page/3`, `delete_page/2`,
  `Wiki.Journal.append/2`) broadcasts an index event and returns
  immediately. This GenServer subscribes once at boot and accumulates
  pending work in-memory between debounced flush ticks:

      * `pending_pages`    — `%{page_id => :upsert}`
      * `pending_journal`  — `%{entry_id => :upsert}`
      * `pending_deletes`  — `%{page_id => :delete}`

  Maps key on row id, so duplicate writes to the same row dedupe naturally
  within a tick window. At flush time we load each row from `Platform.Repo`
  — this is race-safe: if the row was deleted between event and flush,
  `Repo.get/2` returns `nil` and we skip it.

  Conflict resolution between corpora:

      * upsert then upsert  → one ingest (latest content via Repo load)
      * upsert then delete  → delete wins; pending_pages drops the id,
                              pending_deletes picks it up
      * delete then upsert  → upsert wins (unusual; mirrors how the wiki
                              module would broadcast events in order)

  ## Tunables

  Read from `Application.get_env(:platform, :wiki_indexer, [])`:

      * `tick_ms`           — debounce window before flush (default 200ms)
      * `max_batch_size`    — provider call chunk size (default 50)
      * `retry_initial_ms`  — first retry delay (default 1_000ms)
      * `retry_max_ms`      — cap on retry delay (default 30_000ms)
      * `retry_warn_after`  — log a warning after N consecutive failures
                              for the same corpus (default 5)
      * `retry_timeout_floor_ms` — minimum retry delay after a receive
                              timeout (default 30_000ms; see below)
      * `max_attempts`      — consecutive failures of one corpus after which
                              its pending ids are dropped (default 8)

  Every tunable can also be passed in `start_link/1` opts, which win over
  application config.

  ## Retries (task 01a0d8c9)

  A failed corpus is re-enqueued and retried with exponential backoff
  (`retry_initial_ms * 2^(attempt-1)`, capped at `retry_max_ms`). Each corpus
  keeps its own attempt counter and its own due time:

    * **Receive timeouts are `:possibly_in_progress`.** A
      `%Req.TransportError{reason: :timeout}` (or bare `:timeout`) means the
      client stopped waiting, not that memory-service stopped working: the
      ingest is probably still embedding. Resending at once makes the
      service embed the same content again, so after a timeout the retry
      delay is at least `retry_timeout_floor_ms`. Other errors keep the
      plain backoff.
    * **A corpus in backoff is held.** A flush triggered by a new wiki
      event only dispatches corpora with no failures outstanding. A corpus
      in backoff is flushed only by its retry timer (or `flush_now/1`);
      events for it still accumulate in its pending set and go out with
      that retry. Before this, every unrelated journal append resent every
      failed page immediately, whatever the backoff said.
    * **Retries are bounded.** When a corpus has failed `max_attempts`
      times in a row, the indexer logs one `Logger.error` line naming the
      corpus, the ids, the attempt count and the last reason, emits
      `:gave_up` telemetry, drops those ids from pending and resets the
      counter. The rows stay in Postgres; they are re-indexed the next
      time they are written.

  ## Trade-off: the flush is synchronous

  The flush runs inside this GenServer, not in a Task, so corpora are
  dispatched one after another and a slow call delays the rest. With the
  long ingest timeout (`Platform.Memory.Providers.MemoryService`, 120s by
  default) a slow page ingest makes the journal and delete corpora wait up
  to that long behind it. Before, they waited 5s per attempt, and the
  2026-09-25 incident repeated that 146 times; one long wait that succeeds
  is cheaper than many short ones that each cost a full re-embed. Moving the
  flush off-process would need in-flight tracking per corpus to keep the
  "never two copies in flight" property, and is not done here.

  ## Telemetry

      [:platform, :org, :wiki_indexer, :flushed]
        measurements: %{pages_count, journal_count, deletes_count, latency_us}
        metadata:     %{}

      [:platform, :org, :wiki_indexer, :retry]
        measurements: %{attempt, delay_ms}
        metadata:     %{kind, reason, class}   # class: :possibly_in_progress | :failed

      [:platform, :org, :wiki_indexer, :gave_up]
        measurements: %{attempts, count}
        metadata:     %{kind, ids, reason}

  ## Provider gate

  `Platform.Memory.enabled?/0` is checked at flush time. With the Noop
  provider (the default when `MEMORY_SERVICE_URL` is unset), flush drops
  pending sets without dispatching — events are consumed so they don't
  accumulate, and no HTTP traffic happens. A single "indexing disabled"
  log line is emitted at init.
  """

  use GenServer

  require Logger

  alias Platform.Memory
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Indexer.Payload
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @default_tick_ms 200
  @default_max_batch_size 50
  @default_retry_initial_ms 1_000
  @default_retry_max_ms 30_000
  @default_retry_warn_after 5
  @default_retry_timeout_floor_ms 30_000
  @default_max_attempts 8

  @corpora [:pages, :journal, :deletes]

  @flush_message :flush

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Start the indexer. Single instance per node — registered under the
  module name so tests can find it without a registry lookup.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Synchronously force a flush of all pending work. Returns once the
  flush handler has run. Test-only — production relies on the timer.
  """
  @spec flush_now(GenServer.server()) :: :ok
  def flush_now(server \\ __MODULE__) do
    GenServer.call(server, :flush_now, 30_000)
  end

  @doc """
  Inspect the current state — useful for tests. Returns the bare state map.
  """
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :__state)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

    if not Memory.enabled?() do
      Logger.info(
        "Platform.Org.Wiki.Indexer: memory indexing disabled (Noop provider); " <>
          "events will be consumed but not dispatched."
      )
    end

    state = %{
      pending_pages: %{},
      pending_journal: %{},
      pending_deletes: %{},
      flush_timer: nil,
      retry_attempts: %{pages: 0, journal: 0, deletes: 0},
      # Monotonic ms at which a corpus in backoff may be retried; nil when
      # the corpus has no failure outstanding.
      retry_due_at: %{pages: nil, journal: nil, deletes: nil},
      retry_timer: nil,
      tick_ms: Keyword.get(opts, :tick_ms, config(:tick_ms, @default_tick_ms)),
      max_batch_size:
        Keyword.get(opts, :max_batch_size, config(:max_batch_size, @default_max_batch_size)),
      retry_initial_ms:
        Keyword.get(opts, :retry_initial_ms, config(:retry_initial_ms, @default_retry_initial_ms)),
      retry_max_ms:
        Keyword.get(opts, :retry_max_ms, config(:retry_max_ms, @default_retry_max_ms)),
      retry_warn_after:
        Keyword.get(opts, :retry_warn_after, config(:retry_warn_after, @default_retry_warn_after)),
      retry_timeout_floor_ms:
        Keyword.get(
          opts,
          :retry_timeout_floor_ms,
          config(:retry_timeout_floor_ms, @default_retry_timeout_floor_ms)
        ),
      max_attempts: Keyword.get(opts, :max_attempts, config(:max_attempts, @default_max_attempts))
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:wiki_page_written, %{page_id: page_id}}, state) do
    state
    |> update_in([:pending_pages], &Map.put(&1, page_id, :upsert))
    # Dropping the same id from pending_deletes covers the unusual
    # delete-then-upsert ordering; upsert wins.
    |> update_in([:pending_deletes], &Map.delete(&1, page_id))
    |> schedule_flush()
    |> noreply()
  end

  def handle_info({:wiki_page_deleted, %{page_id: page_id}}, state) do
    state
    # Delete wins over a same-tick upsert: drop pending_pages, enqueue delete.
    |> update_in([:pending_pages], &Map.delete(&1, page_id))
    |> update_in([:pending_deletes], &Map.put(&1, page_id, :delete))
    |> schedule_flush()
    |> noreply()
  end

  def handle_info({:wiki_journal_appended, %{entry_id: entry_id}}, state) do
    state
    |> update_in([:pending_journal], &Map.put(&1, entry_id, :upsert))
    |> schedule_flush()
    |> noreply()
  end

  def handle_info(@flush_message, state) do
    state = %{state | flush_timer: nil}
    {:noreply, do_flush(state, :event)}
  end

  def handle_info(:retry_flush, state) do
    state = %{state | retry_timer: nil}
    {:noreply, do_flush(state, :retry)}
  end

  # Ignore any other PubSub message tag — defensive, since the topic
  # is exclusively the wiki index channel.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush_now, _from, state) do
    state =
      state
      |> cancel_flush_timer()
      |> do_flush(:force)

    {:reply, :ok, state}
  end

  def handle_call(:__state, _from, state), do: {:reply, state, state}

  # ── Internals ─────────────────────────────────────────────────────────

  defp noreply(state), do: {:noreply, state}

  # Set the flush timer iff one isn't already armed. The first event in
  # a quiet window arms the timer; subsequent events in the same window
  # join the batch without resetting the deadline.
  defp schedule_flush(%{flush_timer: nil} = state) do
    ref = Process.send_after(self(), @flush_message, state.tick_ms)
    %{state | flush_timer: ref}
  end

  defp schedule_flush(state), do: state

  defp cancel_flush_timer(%{flush_timer: nil} = state), do: state

  defp cancel_flush_timer(%{flush_timer: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | flush_timer: nil}
  end

  defp cancel_retry_timer(%{retry_timer: nil} = state), do: state

  defp cancel_retry_timer(%{retry_timer: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | retry_timer: nil}
  end

  # ── Flush ─────────────────────────────────────────────────────────────

  # `mode` decides which corpora in backoff may be dispatched:
  #   :event  — a debounced wiki event; corpora in backoff are held
  #   :retry  — the retry timer; corpora whose due time has passed go out
  #   :force  — flush_now/1; everything goes out
  # A corpus with no failure outstanding is dispatched in every mode.
  defp do_flush(state, mode) do
    start = System.monotonic_time(:microsecond)

    if Memory.enabled?() do
      state = flush_pending(state, mode)
      latency = System.monotonic_time(:microsecond) - start

      :telemetry.execute(
        [:platform, :org, :wiki_indexer, :flushed],
        %{
          pages_count: state[:__last_flushed_pages] || 0,
          journal_count: state[:__last_flushed_journal] || 0,
          deletes_count: state[:__last_flushed_deletes] || 0,
          latency_us: latency
        },
        %{}
      )

      state
      |> Map.drop([:__last_flushed_pages, :__last_flushed_journal, :__last_flushed_deletes])
    else
      # Disabled: consume pending sets without dispatch so the in-memory
      # state stays bounded. No HTTP, no telemetry payload.
      %{state | pending_pages: %{}, pending_journal: %{}, pending_deletes: %{}}
    end
  end

  defp flush_pending(state, mode) do
    now = System.monotonic_time(:millisecond)

    {state, counts} =
      Enum.reduce(@corpora, {state, %{}}, fn kind, {acc, counts} ->
        if dispatchable?(acc, kind, mode, now) do
          ids = acc |> Map.fetch!(pending_key(kind)) |> Map.keys()
          outcome = dispatch_corpus(kind, ids, acc)

          {reconcile_pending(acc, kind, outcome.result, ids),
           Map.put(counts, kind, outcome.count)}
        else
          # Held: the corpus is in backoff. Its pending set (including ids
          # that arrived since the failure) waits for its own retry.
          {acc, Map.put(counts, kind, 0)}
        end
      end)

    state
    |> Map.put(:__last_flushed_pages, counts.pages)
    |> Map.put(:__last_flushed_journal, counts.journal)
    |> Map.put(:__last_flushed_deletes, counts.deletes)
    |> maybe_schedule_retry()
  end

  defp dispatchable?(state, kind, mode, now) do
    cond do
      state.retry_attempts[kind] == 0 -> true
      mode == :force -> true
      mode == :retry -> due?(state.retry_due_at[kind], now)
      true -> false
    end
  end

  defp due?(nil, _now), do: true
  defp due?(due_at, now), do: due_at <= now

  defp dispatch_corpus(:pages, ids, state), do: ingest_corpus(:pages, ids, state, &load_page/1)

  defp dispatch_corpus(:journal, ids, state),
    do: ingest_corpus(:journal, ids, state, &load_journal/1)

  defp dispatch_corpus(:deletes, ids, state), do: delete_corpus(ids, state)

  defp pending_key(:pages), do: :pending_pages
  defp pending_key(:journal), do: :pending_journal
  defp pending_key(:deletes), do: :pending_deletes

  defp pending_value(:deletes), do: :delete
  defp pending_value(_kind), do: :upsert

  # Each corpus ingest is split into chunks bounded by `max_batch_size`
  # so a giant burst doesn't push an unbounded payload through the
  # provider. Returns a small struct so the caller can both pattern-match
  # the outcome AND surface the dispatched count to telemetry.
  defp ingest_corpus(_kind, [], _state, _loader), do: %{result: :ok, count: 0}

  defp ingest_corpus(kind, ids, state, loader) do
    entries =
      ids
      |> Enum.map(loader)
      |> Enum.reject(&is_nil/1)

    if entries == [] do
      %{result: :ok, count: 0}
    else
      case entries
           |> Enum.chunk_every(state.max_batch_size)
           |> ingest_chunks() do
        :ok ->
          %{result: :ok, count: length(entries)}

        {:error, reason} ->
          %{result: {:error, {kind, reason}}, count: 0}
      end
    end
  end

  defp ingest_chunks([]), do: :ok

  defp ingest_chunks([chunk | rest]) do
    case Memory.ingest(chunk) do
      {:ok, _count} -> ingest_chunks(rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_corpus([], _state), do: %{result: :ok, count: 0}

  defp delete_corpus(ids, state) do
    case ids
         |> Enum.chunk_every(state.max_batch_size)
         |> delete_chunks() do
      :ok -> %{result: :ok, count: length(ids)}
      {:error, reason} -> %{result: {:error, {:deletes, reason}}, count: 0}
    end
  end

  defp delete_chunks([]), do: :ok

  defp delete_chunks([chunk | rest]) do
    case Memory.delete(Enum.map(chunk, &to_string/1)) do
      {:ok, _count} -> delete_chunks(rest)
      {:error, reason} -> {:error, reason}
    end
  end

  # On success, clear the corresponding pending set and reset its retry
  # state. On error, either re-merge the ids into pending and schedule the
  # corpus's own retry, or — once it has failed `max_attempts` times in a
  # row — give up on those ids.
  defp reconcile_pending(state, kind, :ok, _ids) do
    state
    |> Map.put(pending_key(kind), %{})
    |> put_in([:retry_attempts, kind], 0)
    |> put_in([:retry_due_at, kind], nil)
  end

  defp reconcile_pending(state, kind, {:error, {_kind, reason}}, ids) do
    attempt = state.retry_attempts[kind] + 1

    if attempt >= state.max_attempts do
      give_up(state, kind, ids, attempt, reason)
    else
      class = classify(reason)
      delay = retry_delay(attempt, class, state)
      log_retry(state, kind, reason, attempt, class, delay)

      state
      |> Map.update!(pending_key(kind), fn current ->
        Enum.reduce(ids, current, fn id, acc -> Map.put(acc, id, pending_value(kind)) end)
      end)
      |> put_in([:retry_attempts, kind], attempt)
      |> put_in([:retry_due_at, kind], System.monotonic_time(:millisecond) + delay)
    end
  end

  # A receive timeout means the client stopped waiting, not that the
  # service stopped working: the ingest is probably still embedding.
  defp classify(%Req.TransportError{reason: :timeout}), do: :possibly_in_progress
  defp classify(:timeout), do: :possibly_in_progress
  defp classify(_reason), do: :failed

  defp give_up(state, kind, ids, attempts, reason) do
    Logger.error(
      "Platform.Org.Wiki.Indexer: giving up on #{kind} after #{attempts} consecutive " <>
        "failed attempts; dropping ids=#{inspect(ids)} (last reason=#{inspect(reason)}). " <>
        "They stay unindexed until next written."
    )

    :telemetry.execute(
      [:platform, :org, :wiki_indexer, :gave_up],
      %{attempts: attempts, count: length(ids)},
      %{kind: kind, ids: ids, reason: inspect(reason)}
    )

    state
    |> Map.update!(pending_key(kind), &Map.drop(&1, ids))
    |> put_in([:retry_attempts, kind], 0)
    |> put_in([:retry_due_at, kind], nil)
  end

  defp log_retry(state, kind, reason, attempt, class, delay) do
    :telemetry.execute(
      [:platform, :org, :wiki_indexer, :retry],
      %{attempt: attempt, delay_ms: delay},
      %{kind: kind, reason: inspect(reason), class: class}
    )

    if attempt >= state.retry_warn_after do
      Logger.warning(
        "Platform.Org.Wiki.Indexer: #{kind} ingest failed #{attempt} times " <>
          "in a row (reason=#{inspect(reason)}, #{class}); retrying in #{delay}ms."
      )
    end

    :ok
  end

  # Arm one retry timer for the earliest due corpus in backoff. Deadlines
  # are absolute, so re-arming on every flush never pushes a retry later.
  # A corpus with pending ids and no failure outstanding (ids that arrived
  # after a give-up) gets an ordinary debounced flush.
  defp maybe_schedule_retry(state) do
    state = cancel_retry_timer(state)
    now = System.monotonic_time(:millisecond)

    due =
      @corpora
      |> Enum.filter(&(state.retry_attempts[&1] > 0))
      |> Enum.map(&state.retry_due_at[&1])
      |> Enum.reject(&is_nil/1)

    state =
      case due do
        [] ->
          state

        dues ->
          ref = Process.send_after(self(), :retry_flush, max(Enum.min(dues) - now, 0))
          %{state | retry_timer: ref}
      end

    unheld_pending? =
      Enum.any?(@corpora, fn kind ->
        state.retry_attempts[kind] == 0 and map_size(Map.fetch!(state, pending_key(kind))) > 0
      end)

    if unheld_pending?, do: schedule_flush(state), else: state
  end

  # Exponential backoff with cap: initial * 2^(attempt-1), capped at
  # retry_max_ms. After a receive timeout the delay is at least
  # retry_timeout_floor_ms, even above the cap.
  defp retry_delay(attempt, class, state) do
    candidate = state.retry_initial_ms * Integer.pow(2, max(attempt - 1, 0))
    delay = min(candidate, state.retry_max_ms)

    case class do
      :possibly_in_progress -> max(delay, state.retry_timeout_floor_ms)
      :failed -> delay
    end
  end

  # ── Repo loaders ──────────────────────────────────────────────────────

  # Loaded at flush time, not event time — if the row was deleted between
  # the event and the flush, Repo.get/2 returns nil and we drop it
  # silently. The delete event (if any) is handled in its own corpus.
  defp load_page(id) do
    case Repo.get(WikiPage, id) do
      nil -> nil
      %WikiPage{} = page -> Payload.from_page(page)
    end
  end

  defp load_journal(id) do
    case Repo.get(WikiJournalEntry, id) do
      nil -> nil
      %WikiJournalEntry{} = entry -> Payload.from_journal_entry(entry)
    end
  end

  defp config(key, default) do
    :platform
    |> Application.get_env(:wiki_indexer, [])
    |> Keyword.get(key, default)
  end
end
