defmodule Platform.CodeMode.Store do
  @moduledoc """
  `store.get / set / delete` for `burrow_run` scripts (task 01a114a8 stage 2).

  One ETS row per `{agent_id, scope, key}`, where `scope` is the run's
  `session` when it names one and its runtime_id otherwise, so two runs of
  one agent share values only when they share a session (or a runtime).
  Values are stored as their JSON text.

  The same lifecycle shape as `Platform.Federation.Peers.NonceCache`: this
  GenServer owns the table and sweeps expired rows every
  `sweep_interval_ms/0`; a row past `expires_at` that the sweep has not
  reached is treated as absent. Reads run in the caller's process. Writes
  and deletes go through the server so the per-agent byte total
  (`{{:usage, agent_id}, bytes}` rows) cannot race.

  ## Bounds (`Platform.CodeMode.Limits`)

  TTL defaults to 30 min and is capped at 6 h; a value may be 256 KB of JSON;
  one agent may hold 4 MB in total. A write past a bound is refused, never
  truncated.

  ## Ephemeral by design

  A restart wipes it, and it is per node. Nothing in it is persisted, logged
  or visible to any other agent.
  """

  use GenServer

  alias Platform.CodeMode.Limits

  @table :code_mode_store
  @sweep_interval_ms 60_000
  @max_key_bytes 256

  @doc false
  def sweep_interval_ms, do: @sweep_interval_ms

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The stored JSON text for `key`, or nil."
  @spec get(term(), String.t(), String.t(), integer()) :: {:ok, String.t() | nil}
  def get(agent_id, scope, key, now_ms \\ now()) do
    case :ets.lookup(@table, {agent_id, scope, key}) do
      [{_k, json, expires_at}] when expires_at > now_ms -> {:ok, json}
      _ -> {:ok, nil}
    end
  end

  @doc """
  Store `json` (a value's JSON text) under `key` for `ttl_ms` (nil for the
  default). Returns `:ok` or `{:error, code, message}`.
  """
  @spec set(term(), String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, String.t(), String.t()}
  def set(agent_id, scope, key, json, ttl_ms) do
    limits = Limits.get()

    cond do
      not valid_key?(key) ->
        {:error, "invalid_key", "a store key is a non-empty string of at most 256 bytes"}

      byte_size(json) > limits.store_value_bytes ->
        {:error, "value_too_large",
         "a stored value may be #{limits.store_value_bytes} bytes of JSON"}

      true ->
        ttl = ttl_ms(ttl_ms, limits)
        GenServer.call(__MODULE__, {:set, {agent_id, scope, key}, json, ttl, limits})
    end
  end

  @doc "Remove `key`. Always `:ok`."
  @spec delete(term(), String.t(), String.t()) :: :ok
  def delete(agent_id, scope, key),
    do: GenServer.call(__MODULE__, {:delete, {agent_id, scope, key}})

  @doc "Bytes `agent_id` holds (live and not-yet-swept rows)."
  @spec usage(term()) :: non_neg_integer()
  def usage(agent_id) do
    case :ets.lookup(@table, {:usage, agent_id}) do
      [{_k, bytes}] -> bytes
      [] -> 0
    end
  end

  @doc "Deletes expired rows. Returns the count."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms \\ now()), do: GenServer.call(__MODULE__, {:sweep, now_ms})

  @doc "Deletes every row. Tests use it to model a restart."
  def reset, do: GenServer.call(__MODULE__, :reset)

  defp valid_key?(key), do: is_binary(key) and key != "" and byte_size(key) <= @max_key_bytes

  defp ttl_ms(ttl, limits) when is_integer(ttl) and ttl > 0, do: min(ttl, limits.store_max_ttl_ms)
  defp ttl_ms(_ttl, limits), do: limits.store_ttl_ms

  defp now, do: System.system_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, {agent_id, _, _} = key, json, ttl, limits}, _from, state) do
    previous = row_bytes(key)
    used = usage(agent_id) - previous
    size = row_size(key, json)

    reply =
      if used + size > limits.store_agent_bytes do
        {:error, "store_full",
         "this agent's store holds at most #{limits.store_agent_bytes} bytes"}
      else
        :ets.insert(@table, {key, json, now() + ttl})
        :ets.insert(@table, {{:usage, agent_id}, used + size})
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, key}, _from, state) do
    drop(key)
    {:reply, :ok, state}
  end

  def handle_call({:sweep, now_ms}, _from, state), do: {:reply, do_sweep(now_ms), state}

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(now())
    schedule_sweep()
    {:noreply, state}
  end

  defp do_sweep(now_ms) do
    expired = :ets.select(@table, [{{:"$1", :_, :"$2"}, [{:"=<", :"$2", now_ms}], [:"$1"]}])
    Enum.each(expired, &drop/1)
    length(expired)
  end

  defp drop({agent_id, _, _} = key) do
    bytes = row_bytes(key)

    if bytes > 0 do
      :ets.delete(@table, key)
      :ets.insert(@table, {{:usage, agent_id}, max(usage(agent_id) - bytes, 0)})
    end
  end

  defp row_bytes(key) do
    case :ets.lookup(@table, key) do
      [{_k, json, _exp}] -> row_size(key, json)
      [] -> 0
    end
  end

  defp row_size({_agent, _scope, k}, json), do: byte_size(k) + byte_size(json)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
