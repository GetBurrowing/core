defmodule Platform.Federation.RuntimePresence do
  @moduledoc """
  Tracks which external agent runtimes are currently connected via WebSocket.

  Simple Agent-based process holding a MapSet of connected runtime_ids.
  Called from RuntimeChannel join/terminate to maintain online state.
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
  end

  @doc "Mark a runtime as online."
  def track(runtime_id) do
    Agent.update(__MODULE__, &MapSet.put(&1, runtime_id))
  end

  @doc "Mark a runtime as offline."
  def untrack(runtime_id) do
    Agent.update(__MODULE__, &MapSet.delete(&1, runtime_id))
  end

  @doc "Check if a runtime is currently connected."
  def online?(runtime_id) do
    Agent.get(__MODULE__, &MapSet.member?(&1, runtime_id))
  end

  @doc "List all currently connected runtime_ids."
  def list_online do
    Agent.get(__MODULE__, &MapSet.to_list/1)
  end
end
