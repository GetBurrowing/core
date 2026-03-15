defmodule Platform.Agents.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for per-agent runtime processes.

  Each running agent gets its own `Platform.Agents.AgentServer` child. The
  process tree is intentionally small in T4: registry + runtime supervisor now,
  context broker / heartbeat scheduler later in the queue.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
