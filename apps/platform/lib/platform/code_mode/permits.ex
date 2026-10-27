defmodule Platform.CodeMode.Permits do
  @moduledoc """
  The node-wide native guest gate (task 01a17b0b stage 1): at most `size/0`
  wasm guests do native work at once on this node, across every pool that
  calls `Platform.CodeMode.Runtime` (the agent `burrow_run` pool and the
  canvas handler pool alike).

  ## Why

  Wasmex 0.15.1 runs every guest, and the engine's 10 ms epoch ticker, on
  ONE tokio runtime with `available_parallelism` workers. A CPU-bound guest
  yields only when the epoch advances, and the epoch advances only when the
  ticker gets a worker. With as many spinning guests as workers the ticker
  starves, so no wall deadline lands and runs end by fuel, seconds late.
  Capping guests at one fewer than the workers always leaves the ticker a
  worker.

  ## Size

  `max(1, native_workers() - 1)`, overridable with `config :platform,
  #{inspect(__MODULE__)}, size: n`. `native_workers/0` mirrors Rust's
  `available_parallelism`: the logical processors this OS process may run
  on, capped by a cgroup v2 CPU quota (`/sys/fs/cgroup/cpu.max`) when one
  is set.

  ## One key cannot take the whole node

  A run may name a key (`Platform.CodeMode.Runtime`'s `:permit_key`: one
  canvas, one agent runtime). A key holds at most `max(1, size - 1)`
  permits at once, so one canvas looping in every handler slot it is
  allowed still leaves a permit for every other canvas and agent. A waiter
  held back only by its own key's cap does not hold back other keys.

  ## Waiting and releasing

  A run that cannot take a permit waits until `deadline` (a monotonic
  millisecond time, the run's own wall deadline), then gets
  `{:error, :timeout}`. Freed permits go to the oldest waiter whose key is
  under its cap. A waiter that dies leaves the queue.

  A permit is returned when its guest is idle, not when its caller gives
  up: `release/2` after the native call returned, `release_when_idle/2`
  after a timeout, and the same idle drain when the holder dies. Idle means
  `Platform.CodeMode.Runtime.notify_when_idle/3` answered (the same probe
  `Platform.CodeMode.Slots` uses).
  """

  use GenServer

  alias Platform.CodeMode.Runtime

  @cpu_max "/sys/fs/cgroup/cpu.max"

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The configured permit count: app env `:size`, else `max(1, native_workers() - 1)`."
  @spec configured_size() :: pos_integer()
  def configured_size do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :size) do
      n when is_integer(n) and n > 0 -> n
      _ -> max(1, native_workers() - 1)
    end
  end

  @doc """
  The tokio worker count wasmex sizes its runtime to: logical processors
  available to this OS process, capped by the cgroup v2 CPU quota.
  """
  @spec native_workers() :: pos_integer()
  def native_workers, do: native_workers(processors(), File.read(@cpu_max))

  @doc false
  # Pure part, public for the tests: `cpu_max` is a `File.read/1` result.
  def native_workers(processors, cpu_max) do
    case cgroup_quota(cpu_max) do
      nil -> max(processors, 1)
      quota -> max(min(processors, quota), 1)
    end
  end

  defp processors do
    case :erlang.system_info(:logical_processors_available) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case :erlang.system_info(:logical_processors_online) do
          n when is_integer(n) and n > 0 -> n
          _ -> :erlang.system_info(:schedulers_online)
        end
    end
  end

  # "max 100000" is no quota; "400000 100000" is 4 CPUs. Rust floors.
  defp cgroup_quota({:ok, contents}) do
    with [quota, period] <- String.split(String.trim(contents)),
         {quota, ""} <- Integer.parse(quota),
         {period, ""} when period > 0 <- Integer.parse(period) do
      max(div(quota, period), 1)
    else
      _ -> nil
    end
  end

  defp cgroup_quota(_), do: nil

  @doc """
  Take a permit for the calling process under `key` (any term; nil for no
  per-key cap), waiting until `deadline`
  (`System.monotonic_time(:millisecond)`) at the latest.
  """
  @spec acquire(GenServer.server(), term(), integer()) :: {:ok, reference()} | {:error, :timeout}
  def acquire(server \\ __MODULE__, key, deadline),
    do: GenServer.call(server, {:acquire, self(), key, deadline}, :infinity)

  @doc "Record the Store a permit's guest runs in."
  def attach_store(server \\ __MODULE__, permit, store),
    do: GenServer.cast(server, {:attach_store, permit, store})

  @doc "Return a permit whose native call has returned."
  def release(server \\ __MODULE__, permit), do: GenServer.cast(server, {:release, permit})

  @doc "Return a permit once its Store is idle (after a timeout)."
  def release_when_idle(server \\ __MODULE__, permit),
    do: GenServer.cast(server, {:release_when_idle, permit})

  @doc "`%{size: n, per_key: n, held: n, waiting: n}` now."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    # Prepare the shared artifact before admitting calls. Compilation can
    # take longer than a short request's entire wall budget under load.
    {:ok, _} = Runtime.compiled()
    size = Keyword.get_lazy(opts, :size, &configured_size/0)
    per_key = Keyword.get(opts, :per_key, max(1, size - 1))
    {:ok, %{size: size, per_key: per_key, held: %{}, waiting: :queue.new()}}
  end

  @impl true
  # Freed permits are handed off at once, so any waiter still queued is
  # held back by the node cap or its own key's cap: a new run that is
  # eligible now takes a permit without overtaking an eligible waiter.
  def handle_call({:acquire, pid, key, deadline}, from, state) do
    monitor = Process.monitor(pid)

    if eligible?(state, key) do
      {:reply, {:ok, monitor}, grant(state, monitor, key)}
    else
      wait = max(deadline - System.monotonic_time(:millisecond), 0)
      timer = Process.send_after(self(), {:expire, monitor}, wait)
      waiter = %{ref: monitor, key: key, from: from, timer: timer}
      {:noreply, %{state | waiting: :queue.in(waiter, state.waiting)}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       size: state.size,
       per_key: state.per_key,
       held: map_size(state.held),
       waiting: :queue.len(state.waiting)
     }, state}
  end

  @impl true
  def handle_cast({:attach_store, permit, store}, state),
    do: {:noreply, update_held(state, permit, &%{&1 | store: store})}

  def handle_cast({:release, permit}, state), do: {:noreply, free(state, permit)}
  def handle_cast({:release_when_idle, permit}, state), do: {:noreply, drain(state, permit)}

  @impl true
  # The permit ref IS the holder's monitor ref.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.held, ref),
      do: {:noreply, drain(state, ref)},
      else: {:noreply, drop_waiter(state, ref)}
  end

  def handle_info({:expire, ref}, state) do
    case take_waiter(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {waiter, state} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(waiter.from, {:error, :timeout})
        {:noreply, state}
    end
  end

  def handle_info({:idle, permit}, state), do: {:noreply, free(state, permit)}

  defp grant(state, ref, key),
    do: put_in(state, [:held, ref], %{key: key, store: nil, draining: false})

  defp eligible?(state, key) do
    map_size(state.held) < state.size and
      (key == nil or Enum.count(state.held, fn {_, h} -> h.key == key end) < state.per_key)
  end

  defp drain(state, permit) do
    case Map.get(state.held, permit) do
      %{store: nil} ->
        free(state, permit)

      %{draining: true} ->
        state

      %{store: store} ->
        :ok = Runtime.notify_when_idle(store, self(), {:idle, permit})
        update_held(state, permit, &%{&1 | draining: true})

      nil ->
        state
    end
  end

  defp free(state, permit) do
    case Map.pop(state.held, permit) do
      {nil, _held} ->
        state

      {_entry, held} ->
        Process.demonitor(permit, [:flush])
        hand_off(%{state | held: held})
    end
  end

  # Grant freed permits to the oldest waiters whose key is under its cap.
  defp hand_off(state) do
    waiting = :queue.to_list(state.waiting)

    with true <- map_size(state.held) < state.size,
         %{} = waiter <- Enum.find(waiting, &eligible?(state, &1.key)) do
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:ok, waiter.ref})
      rest = :queue.from_list(Enum.reject(waiting, &(&1.ref == waiter.ref)))
      hand_off(grant(%{state | waiting: rest}, waiter.ref, waiter.key))
    else
      _ -> state
    end
  end

  defp drop_waiter(state, ref) do
    case take_waiter(state, ref) do
      {nil, state} ->
        state

      {waiter, state} ->
        Process.cancel_timer(waiter.timer)
        state
    end
  end

  defp take_waiter(state, ref) do
    {matched, rest} = state.waiting |> :queue.to_list() |> Enum.split_with(&(&1.ref == ref))

    case matched do
      [waiter] -> {waiter, %{state | waiting: :queue.from_list(rest)}}
      [] -> {nil, state}
    end
  end

  defp update_held(state, permit, fun) do
    case Map.fetch(state.held, permit) do
      {:ok, entry} -> put_in(state, [:held, permit], fun.(entry))
      :error -> state
    end
  end
end
