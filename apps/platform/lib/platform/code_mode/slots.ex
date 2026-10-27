defmodule Platform.CodeMode.Slots do
  @moduledoc """
  Concurrency caps for `burrow_run` (task 01a114a8 stage 2): at most
  `per_runtime_concurrency` runs per runtime and `global_concurrency` per
  node (`Platform.CodeMode.Limits`). A run over either cap is refused at
  once, never queued.

  ## A slot is freed when the wasm Store is idle, not when a caller gives up

  The holder registers its Store (`attach_store/2`). On a normal return the
  holder releases directly: the native call has returned. On a timeout, or
  when the holder process dies, the slot is held until a probe
  (`Wasmex.StoreOrCaller.get_fuel/1`) completes on that Store. A Store runs
  one operation at a time, so the probe completes only after the run's
  native call has returned. That call is bounded: Wasmex interrupts it at
  its deadline, and a host call whose Elixir process died fails at once
  (the callback token is dropped with the dead process's mailbox).

  ## More than one pool

  `start_link/1` takes a `:name` (default `__MODULE__`, the agent pool every
  `burrow_run` uses). Each function below has a variant taking the server as
  its first argument, so a second pool shares this drain logic instead of
  re-implementing it. Canvas handlers (task 01a1316b-aab0 stage 1) run in
  their own pool, `Platform.Canvas.ScriptEngine.Slots`, keyed by canvas id
  with the canvas limits, so a canvas can never hold an agent's slot or the
  reverse. The one-argument forms are unchanged.

  ## Slots are not native permits

  A slot bounds how many runs a pool admits; it is refused at once, never
  queued. Holding a slot does not take a native permit: every admitted run
  then waits, inside `Platform.CodeMode.Runtime`, for one of the node-wide
  `Platform.CodeMode.Permits` that bound how many guests execute at once
  across both pools.
  """

  use GenServer

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Runtime

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Take a slot for `runtime_id` on behalf of the calling process. Returns
  `{:ok, slot}`, `{:error, :runtime_busy}` or `{:error, :node_busy}`.
  `runtime_id` is the per-key cap's key: a runtime id in the agent pool, a
  canvas id in the canvas pool.
  """
  @spec acquire(String.t(), Limits.t()) :: {:ok, reference()} | {:error, atom()}
  def acquire(runtime_id, limits \\ Limits.get()), do: acquire(__MODULE__, runtime_id, limits)

  @doc "`acquire/2` on the pool `server`."
  @spec acquire(GenServer.server(), String.t(), Limits.t()) ::
          {:ok, reference()} | {:error, atom()}
  def acquire(server, runtime_id, limits),
    do: GenServer.call(server, {:acquire, runtime_id, self(), limits})

  @doc "Record the Store a slot's run executes in."
  def attach_store(slot, store), do: attach_store(__MODULE__, slot, store)

  @doc "`attach_store/2` on the pool `server`."
  def attach_store(server, slot, store), do: GenServer.call(server, {:attach_store, slot, store})

  @doc "Free a slot whose native call has returned."
  def release(slot), do: release(__MODULE__, slot)

  @doc "`release/1` on the pool `server`."
  def release(server, slot), do: GenServer.cast(server, {:release, slot})

  @doc "Free a slot once its Store is idle (after a timeout)."
  def release_when_idle(slot), do: release_when_idle(__MODULE__, slot)

  @doc "`release_when_idle/1` on the pool `server`."
  def release_when_idle(server, slot), do: GenServer.cast(server, {:release_when_idle, slot})

  @doc "Slots held now: `%{total: n, by_runtime: %{runtime_id => n}}`."
  def held, do: held(__MODULE__)

  @doc "`held/0` on the pool `server`."
  def held(server), do: GenServer.call(server, :held)

  @impl true
  def init(_opts), do: {:ok, %{slots: %{}}}

  @impl true
  def handle_call({:acquire, runtime_id, pid, limits}, _from, state) do
    for_runtime = Enum.count(state.slots, fn {_ref, s} -> s.runtime_id == runtime_id end)

    cond do
      for_runtime >= limits.per_runtime_concurrency ->
        {:reply, {:error, :runtime_busy}, state}

      map_size(state.slots) >= limits.global_concurrency ->
        {:reply, {:error, :node_busy}, state}

      true ->
        slot = make_ref()
        monitor = Process.monitor(pid)

        entry = %{runtime_id: runtime_id, monitor: monitor, store: nil, draining: false}
        {:reply, {:ok, slot}, put_in(state, [:slots, slot], entry)}
    end
  end

  def handle_call({:attach_store, slot, store}, _from, state) do
    {:reply, :ok, update_slot(state, slot, &%{&1 | store: store})}
  end

  def handle_call(:held, _from, state) do
    by_runtime = state.slots |> Map.values() |> Enum.frequencies_by(& &1.runtime_id)
    {:reply, %{total: map_size(state.slots), by_runtime: by_runtime}, state}
  end

  @impl true
  def handle_cast({:release, slot}, state), do: {:noreply, free(state, slot)}
  def handle_cast({:release_when_idle, slot}, state), do: {:noreply, drain(state, slot)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.slots, fn {_slot, s} -> s.monitor == monitor end) do
      {slot, _entry} -> {:noreply, drain(state, slot)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:idle, slot}, state), do: {:noreply, free(state, slot)}

  defp drain(state, slot) do
    case Map.get(state.slots, slot) do
      %{store: nil} ->
        free(state, slot)

      %{draining: true} ->
        state

      %{store: store} ->
        :ok = Runtime.notify_when_idle(store, self(), {:idle, slot})
        update_slot(state, slot, &%{&1 | draining: true})

      nil ->
        state
    end
  end

  defp free(state, slot) do
    case Map.pop(state.slots, slot) do
      {nil, _slots} ->
        state

      {entry, slots} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | slots: slots}
    end
  end

  defp update_slot(state, slot, fun) do
    case Map.fetch(state.slots, slot) do
      {:ok, entry} -> put_in(state, [:slots, slot], fun.(entry))
      :error -> state
    end
  end
end
