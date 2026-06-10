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

  ## Telemetry

      [:platform, :org, :wiki_indexer, :flushed]
        measurements: %{pages_count, journal_count, deletes_count, latency_us}
        metadata:     %{}

      [:platform, :org, :wiki_indexer, :retry]
        measurements: %{attempt}
        metadata:     %{kind, reason}

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
      retry_timer: nil,
      tick_ms: Keyword.get(opts, :tick_ms, config(:tick_ms, @default_tick_ms)),
      max_batch_size:
        Keyword.get(opts, :max_batch_size, config(:max_batch_size, @default_max_batch_size)),
      retry_initial_ms:
        Keyword.get(opts, :retry_initial_ms, config(:retry_initial_ms, @default_retry_initial_ms)),
      retry_max_ms:
        Keyword.get(opts, :retry_max_ms, config(:retry_max_ms, @default_retry_max_ms)),
      retry_warn_after:
        Keyword.get(opts, :retry_warn_after, config(:retry_warn_after, @default_retry_warn_after))
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
    {:noreply, do_flush(state)}
  end

  def handle_info(:retry_flush, state) do
    state = %{state | retry_timer: nil}
    {:noreply, do_flush(state)}
  end

  # Ignore any other PubSub message tag — defensive, since the topic
  # is exclusively the wiki index channel.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush_now, _from, state) do
    state =
      state
      |> cancel_flush_timer()
      |> do_flush()

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

  defp do_flush(state) do
    start = System.monotonic_time(:microsecond)

    if Memory.enabled?() do
      state = flush_pending(state)
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

  defp flush_pending(state) do
    %{pending_pages: pages, pending_journal: journal, pending_deletes: deletes} = state

    page_ids = Map.keys(pages)
    journal_ids = Map.keys(journal)
    delete_ids = Map.keys(deletes)

    pages_outcome = ingest_corpus(:pages, page_ids, state, &load_page/1)
    journal_outcome = ingest_corpus(:journal, journal_ids, state, &load_journal/1)
    deletes_outcome = delete_corpus(delete_ids, state)

    state
    |> reconcile_pending(:pages, pages_outcome.result, page_ids)
    |> reconcile_pending(:journal, journal_outcome.result, journal_ids)
    |> reconcile_pending(:deletes, deletes_outcome.result, delete_ids)
    |> Map.put(:__last_flushed_pages, pages_outcome.count)
    |> Map.put(:__last_flushed_journal, journal_outcome.count)
    |> Map.put(:__last_flushed_deletes, deletes_outcome.count)
    |> maybe_schedule_retry()
  end

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

  # On success, clear the corresponding pending set and reset its
  # retry counter. On error, re-merge the ids that didn't make it back
  # into pending state and bump the retry counter for that corpus.
  defp reconcile_pending(state, :pages, :ok, _ids) do
    state
    |> Map.put(:pending_pages, %{})
    |> put_in([:retry_attempts, :pages], 0)
  end

  defp reconcile_pending(state, :pages, {:error, {kind, reason}}, ids) do
    log_retry(state, kind, reason)
    re_enqueue_pages(state, ids)
  end

  defp reconcile_pending(state, :journal, :ok, _ids) do
    state
    |> Map.put(:pending_journal, %{})
    |> put_in([:retry_attempts, :journal], 0)
  end

  defp reconcile_pending(state, :journal, {:error, {kind, reason}}, ids) do
    log_retry(state, kind, reason)
    re_enqueue_journal(state, ids)
  end

  defp reconcile_pending(state, :deletes, :ok, _ids) do
    state
    |> Map.put(:pending_deletes, %{})
    |> put_in([:retry_attempts, :deletes], 0)
  end

  defp reconcile_pending(state, :deletes, {:error, {kind, reason}}, ids) do
    log_retry(state, kind, reason)
    re_enqueue_deletes(state, ids)
  end

  defp re_enqueue_pages(state, ids) do
    state
    |> Map.update!(:pending_pages, fn current ->
      Enum.reduce(ids, current, fn id, acc -> Map.put(acc, id, :upsert) end)
    end)
    |> update_in([:retry_attempts, :pages], &(&1 + 1))
  end

  defp re_enqueue_journal(state, ids) do
    state
    |> Map.update!(:pending_journal, fn current ->
      Enum.reduce(ids, current, fn id, acc -> Map.put(acc, id, :upsert) end)
    end)
    |> update_in([:retry_attempts, :journal], &(&1 + 1))
  end

  defp re_enqueue_deletes(state, ids) do
    state
    |> Map.update!(:pending_deletes, fn current ->
      Enum.reduce(ids, current, fn id, acc -> Map.put(acc, id, :delete) end)
    end)
    |> update_in([:retry_attempts, :deletes], &(&1 + 1))
  end

  defp log_retry(state, kind, reason) do
    attempt = (state.retry_attempts[kind] || 0) + 1

    :telemetry.execute(
      [:platform, :org, :wiki_indexer, :retry],
      %{attempt: attempt},
      %{kind: kind, reason: inspect(reason)}
    )

    if attempt >= state.retry_warn_after do
      Logger.warning(
        "Platform.Org.Wiki.Indexer: #{kind} ingest failed #{attempt} times " <>
          "in a row (reason=#{inspect(reason)}); continuing with capped backoff."
      )
    end

    :ok
  end

  # If any corpus has pending work after reconcile, schedule a retry
  # tick with exponential backoff based on the largest attempt counter.
  defp maybe_schedule_retry(state) do
    has_pending =
      map_size(state.pending_pages) > 0 or
        map_size(state.pending_journal) > 0 or
        map_size(state.pending_deletes) > 0

    if has_pending do
      max_attempt =
        state.retry_attempts |> Map.values() |> Enum.max(fn -> 0 end)

      delay = retry_delay(max_attempt, state)

      state = cancel_retry_timer(state)
      ref = Process.send_after(self(), :retry_flush, delay)
      %{state | retry_timer: ref}
    else
      state
    end
  end

  # Exponential backoff with cap: initial * 2^(attempt-1), capped at retry_max_ms.
  defp retry_delay(attempt, state) when attempt > 0 do
    base = state.retry_initial_ms
    cap = state.retry_max_ms
    candidate = base * Integer.pow(2, max(attempt - 1, 0))
    min(candidate, cap)
  end

  defp retry_delay(_attempt, state), do: state.retry_initial_ms

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
