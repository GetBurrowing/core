defmodule Platform.Chat.ContextSummaryCache do
  @moduledoc """
  ETS cache for `Platform.Chat.ContextSummary`. Task 01a0d8de stage 1.

  A GenServer owns a named, public ETS table (the `Platform.Chat.ContextPlane`
  shape). Reads go straight to ETS; only a miss talks to the GenServer.

  ## Key

  `{message_id, scope_key}`. `ContextSummary` builds `scope_key` from
  everything that changes WHICH messages a viewer may read: the thread,
  the viewer's history grant (`history_visible_from`, or `:unbounded`) and
  the external-scope user. Two viewers with the same bound share an entry;
  viewers with different bounds never do.

  ## Why ETS

  A summary is regenerable. A table would be durable state with nothing to
  keep, and writing it into message metadata would mutate the agent's
  message row. A restart costs one provider call per message next time.

  ## Collapsed misses

  `fetch/3` on a missing key claims it. A second caller for the same key
  while the first is computing waits for the first caller's result instead
  of making its own provider call. The computing process is monitored: if
  it dies, waiters get `{:error, :summariser_crashed}`. Only `{:ok, _}`
  results are stored; errors are handed to the waiters and not cached, so a
  Retry makes a fresh call.

  Entries expire after 24 hours (checked on read, swept hourly).
  """

  use GenServer

  @table :chat_context_summary_cache
  @ttl_ms :timer.hours(24)
  @sweep_ms :timer.hours(1)
  @wait_timeout_ms 120_000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The fresh cached value for `key`, or `:miss`."
  @spec lookup(term()) :: {:ok, term()} | :miss
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if expires_at > now(), do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Returns `{:hit, value}` for a fresh entry. Otherwise runs `fun` (in the
  CALLING process) at most once across concurrent callers for `key` and
  returns `{:miss, result}`; a result of `{:ok, _}` is stored.
  """
  @spec fetch(term(), (-> term()), keyword()) :: {:hit, term()} | {:miss, term()}
  def fetch(key, fun, opts \\ []) when is_function(fun, 0) do
    case lookup(key) do
      {:ok, value} ->
        {:hit, value}

      :miss ->
        timeout = Keyword.get(opts, :timeout, @wait_timeout_ms)

        case GenServer.call(__MODULE__, {:claim, key}, timeout) do
          {:hit, value} ->
            {:hit, value}

          :run ->
            result = run(fun)
            GenServer.call(__MODULE__, {:complete, key, result}, timeout)
            {:miss, result}

          {:waited, result} ->
            {:miss, result}
        end
    end
  end

  @doc "Removes every entry. For tests."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc false
  def table, do: @table

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    # in_flight: key => %{pid, ref, waiters: [from]}
    {:ok, %{table: table, in_flight: %{}}}
  end

  @impl true
  def handle_call({:claim, key}, {pid, _tag} = from, state) do
    case {lookup(key), Map.get(state.in_flight, key)} do
      {{:ok, value}, _} ->
        {:reply, {:hit, value}, state}

      {:miss, nil} ->
        ref = Process.monitor(pid)
        entry = %{pid: pid, ref: ref, waiters: []}
        {:reply, :run, put_in(state.in_flight[key], entry)}

      {:miss, entry} ->
        entry = %{entry | waiters: [from | entry.waiters]}
        {:noreply, put_in(state.in_flight[key], entry)}
    end
  end

  def handle_call({:complete, key, result}, _from, state) do
    case result do
      {:ok, _} -> :ets.insert(@table, {key, result, now() + @ttl_ms})
      _ -> :ok
    end

    {:reply, :ok, finish(state, key, result)}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.in_flight, fn {_key, entry} -> entry.ref == ref end) do
      {key, _entry} -> {:noreply, finish(state, key, {:error, :summariser_crashed})}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────

  defp finish(state, key, result) do
    case Map.pop(state.in_flight, key) do
      {nil, _} ->
        state

      {entry, in_flight} ->
        Process.demonitor(entry.ref, [:flush])
        Enum.each(entry.waiters, &GenServer.reply(&1, {:waited, result}))
        %{state | in_flight: in_flight}
    end
  end

  # A raise inside `fun` must still release the claim, or every waiter
  # blocks until its timeout.
  defp run(fun) do
    fun.()
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
