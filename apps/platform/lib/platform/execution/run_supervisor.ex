defmodule Platform.Execution.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for `Platform.Execution.RunServer` processes.

  One `RunServer` process is started per active run. Servers are registered
  via `Platform.Execution.Registry` (a `Registry` with unique keys).
  """

  use DynamicSupervisor

  alias Platform.Execution.{Run, RunServer}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a `RunServer` for `run` under this supervisor."
  @spec start_run(Run.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(%Run{} = run, opts \\ []) do
    child_spec = {RunServer, Keyword.merge(opts, run: run)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Terminates the `RunServer` for `run_id`."
  @spec stop_run(String.t()) :: :ok | {:error, :not_found}
  def stop_run(run_id) do
    case Registry.lookup(Platform.Execution.Registry, {:run_server, run_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end
end
