defmodule Platform.Execution do
  @moduledoc """
  Public API for the Execution domain.

  Execution manages the lifecycle of agent runs: creating runs, tracking their
  context plane, and driving state transitions.

  ## Responsibilities

    - Create and start `RunServer` processes for individual runs
    - Expose high-level operations: start_run, stop_run, push_context, ack_context
    - Route context operations through `Platform.Execution.ContextSession`
    - Provide observability: get_run, get_snapshot, context status

  ## Architecture

  Each run is supervised by `Platform.Execution.RunSupervisor` (DynamicSupervisor).
  Runs are registered in `Platform.Execution.Registry` for lookup.

  Context operations are mediated by `Platform.Execution.ContextSession` which
  bridges the run to `Platform.Context`.

  ## Usage

      # Start a new run
      {:ok, run} = Platform.Execution.start_run("task-id", opts)

      # Get the context snapshot
      {:ok, snapshot} = Platform.Execution.get_snapshot(run.id)

      # Push context items from a runner
      {:ok, version} = Platform.Execution.push_context(run.id, %{"key" => "value"})

      # Runner acknowledges context
      {:ok, run} = Platform.Execution.ack_context(run.id, version)

      # Transition to running
      {:ok, run} = Platform.Execution.transition(run.id, :running)

      # Finish
      {:ok, run} = Platform.Execution.transition(run.id, :completed)
  """

  alias Platform.Execution.{Run, RunServer, RunSupervisor}

  # ---------------------------------------------------------------------------
  # Run lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Creates and starts a new run for `task_id`.

  Options:
    - `:project_id`       — project scope for context inheritance
    - `:epic_id`          — epic scope for context inheritance
    - `:runner_type`      — atom identifying the runner (:local, :docker, etc.)
    - `:stale_timeout_ms` — ms before run is considered stale (default 30s)
    - `:dead_timeout_ms`  — ms after stale before run is considered dead (default 120s)
    - `:meta`             — arbitrary metadata map

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec start_run(String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(task_id, opts \\ []) do
    run_id = Keyword.get(opts, :run_id) || generate_id()

    run = Run.new(run_id, task_id, opts)

    case RunSupervisor.start_run(run, opts) do
      {:ok, _pid} -> {:ok, run}
      {:error, {:already_started, _}} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a run, transitioning it to `cancelled` and closing its context session.
  """
  @spec stop_run(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def stop_run(run_id) do
    RunServer.transition(run_id, :cancelled)
  end

  @doc "Returns the current run struct."
  @spec get_run(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def get_run(run_id) do
    RunServer.get_run(run_id)
  end

  @doc "Transitions a run to `new_status`."
  @spec transition(String.t(), Run.status()) :: {:ok, Run.t()} | {:error, term()}
  def transition(run_id, new_status) do
    RunServer.transition(run_id, new_status)
  end

  # ---------------------------------------------------------------------------
  # Context operations
  # ---------------------------------------------------------------------------

  @doc """
  Returns the merged context snapshot for `run_id`.

  Inherits from project → epic → task → run scopes.
  Returns `{:ok, %{items: [...], version: n, required_version: n}}`.
  """
  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def get_snapshot(run_id) do
    RunServer.get_snapshot(run_id)
  end

  @doc """
  Pushes context items into the run's context session.

  Returns `{:ok, new_version}`.
  """
  @spec push_context(String.t(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def push_context(run_id, items, opts \\ []) do
    RunServer.push_context(run_id, items, opts)
  end

  @doc """
  Records that the runner has acknowledged context `version`.

  Returns `{:ok, updated_run}`.
  """
  @spec ack_context(String.t(), non_neg_integer()) :: {:ok, Run.t()} | {:error, term()}
  def ack_context(run_id, version) do
    RunServer.ack_context(run_id, version)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
