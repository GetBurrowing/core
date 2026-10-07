defmodule Platform.CodeMode.Slots do
  @moduledoc """
  Concurrency caps for `suite_run` (task 01a114a8 stage 2): at most
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
  """

  use GenServer

  alias Platform.CodeMode.Limits

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Take a slot for `runtime_id` on behalf of the calling process. Returns
  `{:ok, slot}`, `{:error, :runtime_busy}` or `{:error, :node_busy}`.
  """
  @spec acquire(String.t(), Limits.t()) :: {:ok, reference()} | {:error, atom()}
  def acquire(runtime_id, limits \\ Limits.get()),
    do: GenServer.call(__MODULE__, {:acquire, runtime_id, self(), limits})

  @doc "Record the Store a slot's run executes in."
  def attach_store(slot, store), do: GenServer.call(__MODULE__, {:attach_store, slot, store})

  @doc "Free a slot whose native call has returned."
  def release(slot), do: GenServer.cast(__MODULE__, {:release, slot})

  @doc "Free a slot once its Store is idle (after a timeout)."
  def release_when_idle(slot), do: GenServer.cast(__MODULE__, {:release_when_idle, slot})

  @doc "Slots held now: `%{total: n, by_runtime: %{runtime_id => n}}`."
  def held, do: GenServer.call(__MODULE__, :held)

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
        server = self()

        Task.start(fn ->
          _ = Wasmex.StoreOrCaller.get_fuel(store)
          send(server, {:idle, slot})
        end)

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
