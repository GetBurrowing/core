defmodule Platform.Federation.RuntimePresence do
  @moduledoc """
  Tracks which external agent runtimes are currently connected via WebSocket.

  Agent-based process holding a map of runtime_id => connection info with timestamps.
  Called from RuntimeChannel join/terminate to maintain online state.

  Each entry is a map with:
    - connected_at: DateTime when the current session started
    - last_seen_at: DateTime of last incoming message (liveness indicator)
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Mark a runtime as online, recording the connection timestamp."
  def track(runtime_id) do
    now = DateTime.utc_now()

    Agent.update(__MODULE__, fn state ->
      Map.put(state, runtime_id, %{connected_at: now, last_seen_at: now})
    end)
  end

  @doc "Mark a runtime as offline."
  def untrack(runtime_id) do
    Agent.update(__MODULE__, &Map.delete(&1, runtime_id))
  end

  @doc "Check if a runtime is currently connected."
  def online?(runtime_id) do
    Agent.get(__MODULE__, &Map.has_key?(&1, runtime_id))
  end

  @doc """
  Update the last_seen_at timestamp for a runtime (call on any incoming message).

  Self-heals when the entry is missing: any inbound frame from a live channel
  process upserts the presence entry. This recovers the map after this Agent
  process crashes/restarts while the RuntimeChannel Cowboy WS processes stay
  running — otherwise the presence map would be permanently empty even though
  every runtime is still connected, since `track/1` only runs at join time.
  """
  def touch(runtime_id) do
    Agent.update(__MODULE__, fn state ->
      now = DateTime.utc_now()

      case Map.get(state, runtime_id) do
        nil -> Map.put(state, runtime_id, %{connected_at: now, last_seen_at: now})
        entry -> Map.put(state, runtime_id, %{entry | last_seen_at: now})
      end
    end)
  end

  @doc "Get connection info for a specific runtime, or nil if offline."
  def status(runtime_id) do
    Agent.get(__MODULE__, &Map.get(&1, runtime_id))
  end

  @doc "List all currently connected runtime_ids."
  def list_online do
    Agent.get(__MODULE__, &Map.keys(&1))
  end

  @doc "Return the full presence map: %{runtime_id => %{connected_at: DateTime, last_seen_at: DateTime}}"
  def list_all do
    Agent.get(__MODULE__, & &1)
  end
end
