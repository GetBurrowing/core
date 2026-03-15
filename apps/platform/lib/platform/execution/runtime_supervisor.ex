defmodule Platform.Execution.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for active execution runs.

  Each running task/execution attempt gets its own `Platform.Execution.RunServer`
  child process so liveness, checkpoints, and stop/kill timers remain isolated.
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
