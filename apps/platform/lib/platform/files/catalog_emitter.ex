defmodule Platform.Files.CatalogEmitter do
  @moduledoc """
  Fires a catalog card when a file finishes ingesting (task 01a0008c stage 3).

  Attaches to `[:platform, :files, :ingested, :stop]` — the event
  `Platform.Files.Ingester` emits at the end of every successful ingest,
  whichever of its three production callers started it
  (`Files.request_ingest/2`, the MCP upload tool, the upload LiveView).
  `Ingester.ingest_async/1` is the single enqueue choke point, so one
  subscription covers all of them.

  ## Bounded concurrency is the whole design

  The ingester spawns **one unsupervised-in-parallel `Task` per file**
  (`Task.Supervisor.start_child/2`), so `:stop` events arrive in bursts as
  wide as whatever the uploader dropped in at once. The live Globex corpus
  shows twelve files finishing inside 0.2s and nine more two minutes
  later. Spawning a task per event would put twelve concurrent LLM
  requests in flight from a background process with nothing above it
  applying backpressure.

  So this is a **GenServer that does the work in its own process**, and
  the telemetry handler only `cast`s to it. That makes the concurrency
  bound structural rather than a number someone has to keep honest:

    * the handler never blocks the ingest task it runs inside — `cast`
      returns immediately, and it returns `:ok` even when this server is
      not running at all;
    * a single process handles one message at a time, so **at most one
      catalog pass, and therefore at most one LLM request, exists at any
      moment** no matter how wide the burst;
    * arrival order is preserved, so the twelve-file burst is catalogued
      oldest-request-first rather than in whatever order twelve racing
      tasks would have finished.

  The cost of that choice is that the server is unresponsive while a pass
  runs. That is why `await_idle/2` is a `call`: a reply can only be
  produced once every cast ahead of it has been handled, which is exactly
  the synchronisation point tests need and costs nothing in production.

  ## Overflow drops; it does not queue

  A mailbox is unbounded, and an LLM pass is seconds while an upload is
  milliseconds. If the queue ever runs deeper than `:max_queue` (default
  200) the oldest-arriving surplus is **dropped with a log line, not
  retried**. That is not a lost card: `card_file_key` stays nil, and a nil
  `card_file_key` is precisely what `mix platform.backfill_file_cards`
  enumerates. Retry-by-backfill is the deliberate strategy for this whole
  subsystem — there is no retry queue here and there should not be one.

  ## Eligibility is re-derived, never trusted

  The `:stop` metadata carries `file_id`, `project_id` and `dedup`, and
  this module treats all three as a *hint about where to look*. The
  decision is taken by re-reading the row through
  `Platform.Files.list_catalogable_files/2`, stage 1's eligibility seam,
  and a file_id that is not in that list is dropped without ever being
  loaded.

  This matters because the seam is a disclosure boundary, not a filter.
  An `ingest_intent: "human_only"` file must never have its bytes reach an
  LLM. Today no `:stop` event can fire for one — `ingest_async/1`
  short-circuits before telemetry — so the re-check looks redundant. It is
  not: telemetry is a public bus, any code in the VM can execute that
  event with any metadata it likes, and a handler that trusts its input
  has no boundary at all. `Cataloger.catalog_file/2` re-checks through the
  same seam a second time; both checks are cheap and neither is the other's
  excuse to be skipped.

  ## Configuration

  Booted from `Platform.Application` unless
  `config :platform, :start_catalog_emitter, false` — which `config/test.exs`
  sets, so an ingest inside the Ecto sandbox does not hand work to a
  process that does not own the connection. Tests start their own
  instance with `start_supervised/1`.
  """

  use GenServer

  require Logger

  alias Platform.Files
  alias Platform.Files.Cataloger

  @stop_event [:platform, :files, :ingested, :stop]

  # Deep enough that the observed burst (12 in 0.2s, 9 more at the next
  # upload) never touches it, shallow enough that a runaway producer is
  # capped in bounded time rather than filling a mailbox for an hour.
  @default_max_queue 200

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Blocks until every event cast before this call has been handled.

  Exists because the server is single-threaded: a `call` cannot be
  answered until the casts ahead of it are done, so this is a real
  quiescence barrier and not a sleep. Used by tests; also useful from a
  remote console to watch a burst drain.
  """
  @spec await_idle(GenServer.server(), timeout()) :: :ok
  def await_idle(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :await_idle, timeout)
  end

  @doc """
  Counters since boot: `:seen`, `:catalogued`, `:noop`, `:ineligible`,
  `:errors`, `:dropped`.

  `:ineligible` counts events whose file the eligibility seam did not
  return — the re-check firing. `:dropped` counts overflow.
  """
  @spec stats(GenServer.server(), timeout()) :: map()
  def stats(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :stats, timeout)
  end

  @doc """
  The telemetry handler function.

  Public because `:telemetry` needs a remote-callable MFA (an anonymous
  function would be attached with a warning and survive no code reload),
  not because anything should call it directly.
  """
  @spec handle_event(list(atom()), map(), map(), map()) :: :ok
  def handle_event(@stop_event, _measurements, metadata, %{server: server}) do
    GenServer.cast(
      server,
      {:ingested, Map.get(metadata, :file_id), Map.get(metadata, :project_id),
       Map.get(metadata, :dedup) == true}
    )
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    handler_id = handler_id(name)

    # `terminate/2` is where the telemetry subscription is torn down, and a
    # GenServer that does not trap exits never reaches it: a supervisor
    # shutdown is an exit signal, not a `{:stop, …}` return. Without this
    # flag the handler outlives the process it casts to — harmless in
    # production (a cast to a dead name is a silent `:ok`) but in test
    # every stopped instance leaves a subscription behind that the next
    # `:telemetry.execute/3` still fans out to.
    Process.flag(:trap_exit, true)

    # Attached here rather than in `Application.start/2` so the handler
    # cannot outlive the process it casts to, and so a test-started
    # instance gets its own subscription without a second wiring step.
    :ok =
      :telemetry.attach(
        handler_id,
        @stop_event,
        &__MODULE__.handle_event/4,
        %{server: name}
      )

    state = %{
      handler_id: handler_id,
      max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
      seen: 0,
      catalogued: 0,
      noop: 0,
      ineligible: 0,
      errors: 0,
      dropped: 0
    }

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @impl GenServer
  def handle_call(:await_idle, _from, state), do: {:reply, :ok, state}
  def handle_call(:stats, _from, state), do: {:reply, Map.drop(state, [:handler_id]), state}

  @impl GenServer
  def handle_cast({:ingested, file_id, project_id, dedup?}, state) do
    state = %{state | seen: state.seen + 1}

    cond do
      overflowing?(state) ->
        Logger.warning(
          "[Files.CatalogEmitter] queue over #{state.max_queue}; dropping the card for " <>
            "file #{inspect(file_id)} — `mix platform.backfill_file_cards` is the retry"
        )

        {:noreply, %{state | dropped: state.dropped + 1}}

      not (is_binary(file_id) and is_binary(project_id)) ->
        {:noreply, %{state | ineligible: state.ineligible + 1}}

      true ->
        {:noreply, catalog(state, file_id, project_id, dedup?)}
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # The mailbox IS the queue — see the moduledoc. `:message_queue_len`
  # therefore measures exactly the backlog we want to cap. It also counts
  # any pending `await_idle` / `stats` call, which is deliberate: over-
  # counting errs toward dropping, and a dropped card is a backfill
  # candidate rather than a loss.
  defp overflowing?(%{max_queue: max_queue}) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len > max_queue
      nil -> false
    end
  end

  defp catalog(state, file_id, project_id, dedup?) do
    case eligible_file(file_id, project_id) do
      nil ->
        # Either the row is genuinely not catalogable (human_only,
        # soft-deleted, not `ingested`) or the metadata pointed somewhere
        # that does not exist. Both are the boundary working.
        %{state | ineligible: state.ineligible + 1}

      file ->
        run_pass(state, file, dedup?)
    end
  end

  # A pass runs third-party HTTP and wiki writes. Letting it take the
  # server down would drop every card queued behind it and, on restart,
  # the telemetry subscription with them — so failure is counted and
  # logged, and the row keeps its nil `card_file_key` for the backfill.
  defp run_pass(state, file, dedup?) do
    Cataloger.catalog_file(file, dedup: dedup?)
  rescue
    error ->
      Logger.error(
        "[Files.CatalogEmitter] card pass raised for file #{file.id}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      %{state | errors: state.errors + 1}
  catch
    kind, reason ->
      Logger.error(
        "[Files.CatalogEmitter] card pass exited for file #{file.id}: " <>
          "#{inspect(kind)} #{inspect(reason)}"
      )

      %{state | errors: state.errors + 1}
  else
    {:ok, _page} ->
      %{state | catalogued: state.catalogued + 1}

    {:ok, :noop, _reason} ->
      %{state | noop: state.noop + 1}

    {:error, reason} ->
      Logger.info(
        "[Files.CatalogEmitter] no card for file #{file.id}: #{inspect(reason)} " <>
          "(card_file_key stays nil; the backfill will retry)"
      )

      %{state | errors: state.errors + 1}
  end

  # THE re-check. Nothing here reads the file by id: the seam is the only
  # way a row becomes visible to this module, so an excluded row cannot be
  # loaded even by accident.
  defp eligible_file(file_id, project_id) do
    project_id
    |> Files.list_catalogable_files()
    |> Enum.find(&(&1.id == file_id))
  end

  defp handler_id(name), do: "platform-files-catalog-emitter-#{inspect(name)}"
end
