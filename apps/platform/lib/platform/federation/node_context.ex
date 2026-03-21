defmodule Platform.Federation.NodeContext do
  @moduledoc """
  Lightweight ETS-backed context store keyed by agent_id.

  Tracks the current space each agent is engaged in, so that
  NodeCommandHandler can resolve which space to target for canvas
  commands without requiring an explicit space_id param.

  Entries expire after 30 minutes of inactivity.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.minutes(30)

  # ── Public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Set the current space for an agent. Resets the TTL."
  @spec set_space(binary(), binary()) :: :ok
  def set_space(agent_id, space_id) when is_binary(agent_id) and is_binary(space_id) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {agent_id, space_id, expires_at})
    GenServer.cast(__MODULE__, {:schedule_expiry, agent_id, expires_at})
    :ok
  end

  @doc "Get the current space for an agent, or nil if expired/unset."
  @spec get_space(binary()) :: binary() | nil
  def get_space(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, space_id, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          space_id
        else
          :ets.delete(@table, agent_id)
          nil
        end

      [] ->
        nil
    end
  end

  @doc "Clear the space context for an agent."
  @spec clear_space(binary()) :: :ok
  def clear_space(agent_id) when is_binary(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table, timers: %{}}}
  end

  @impl true
  def handle_cast({:schedule_expiry, agent_id, expires_at}, state) do
    # Cancel any existing timer for this agent
    state = cancel_timer(state, agent_id)

    delay = max(expires_at - System.monotonic_time(:millisecond), 0)
    timer_ref = Process.send_after(self(), {:expire, agent_id, expires_at}, delay)
    {:noreply, put_in(state, [:timers, agent_id], timer_ref)}
  end

  @impl true
  def handle_info({:expire, agent_id, expected_expires_at}, state) do
    # Only delete if the entry hasn't been refreshed since this timer was set
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, _space_id, ^expected_expires_at}] ->
        :ets.delete(@table, agent_id)

      _ ->
        :ok
    end

    {:noreply, %{state | timers: Map.delete(state.timers, agent_id)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ──

  defp cancel_timer(state, agent_id) do
    case Map.get(state.timers, agent_id) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        %{state | timers: Map.delete(state.timers, agent_id)}
    end
  end
end
