defmodule Platform.Execution do
  @moduledoc """
  Public entrypoint for the Execution domain.

  The initial implementation focuses on the control plane introduced in
  ADR 0011: per-run OTP supervision, runner abstraction, context sessions, and
  deterministic stop/kill semantics.
  """

  alias Platform.Execution.{ContextSession, Run, RunServer}

  @doc "Start a supervised run control process."
  @spec start_run(Run.t() | map() | keyword(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_run(run_input, runner, opts \\ []) do
    do_start_run(run_input, runner, opts)
  end

  @doc "Spawn a supervised run control process and ask the provider to start the underlying run."
  @spec spawn_run(Run.t() | map() | keyword(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def spawn_run(run_input, runner, opts \\ []) do
    opts
    |> Keyword.put_new(:spawn?, true)
    |> then(&do_start_run(run_input, runner, &1))
  end

  @doc "Lookup a run server by run id."
  @spec get_run_server(String.t()) :: pid() | nil
  def get_run_server(run_id), do: RunServer.whereis(run_id)

  @doc "Return the latest in-memory run status."
  @spec get_run_status(String.t() | pid()) :: Run.t() | nil
  def get_run_status(run_id) when is_binary(run_id) do
    case get_run_server(run_id) do
      nil -> nil
      pid -> RunServer.status(pid)
    end
  end

  def get_run_status(pid) when is_pid(pid), do: RunServer.status(pid)

  @doc "Describe the latest control-plane view of a run."
  @spec describe_run(String.t() | pid()) :: {:ok, Run.t()} | {:error, term()}
  def describe_run(target) do
    with {:ok, pid} <- resolve_server(target) do
      {:ok, RunServer.status(pid)}
    end
  end

  @doc "Push a fresh context snapshot/version to a run server."
  @spec push_context(String.t() | pid(), ContextSession.t() | map() | keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def push_context(target, context_session) do
    with {:ok, pid} <- resolve_server(target) do
      RunServer.push_context(pid, context_session)
    end
  end

  @doc "Request a fast graceful stop, with automatic escalation to force kill."
  @spec stop_run(String.t() | pid(), String.t() | atom(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def stop_run(target, reason \\ :cancelled, opts \\ []), do: request_stop(target, reason, opts)

  @doc "Request a fast graceful stop, with automatic escalation to force kill."
  @spec request_stop(String.t() | pid(), String.t() | atom(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def request_stop(target, reason \\ :cancelled, opts \\ []) do
    with {:ok, pid} <- resolve_server(target) do
      RunServer.request_stop(pid, reason, opts)
    end
  end

  @doc "Escalate immediately to force-stop / kill semantics."
  @spec force_stop(String.t() | pid(), String.t() | atom(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def force_stop(target, reason \\ :killed, opts \\ []) do
    with {:ok, pid} <- resolve_server(target) do
      RunServer.force_stop(pid, reason, opts)
    end
  end

  defp do_start_run(run_input, runner, opts) do
    with {:ok, run} <- Run.new(run_input) do
      child_opts =
        opts
        |> Keyword.put(:run, run)
        |> Keyword.put(:runner, runner)

      DynamicSupervisor.start_child(Platform.Execution.RuntimeSupervisor, {RunServer, child_opts})
    end
  end

  defp resolve_server(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve_server(run_id) when is_binary(run_id) do
    case get_run_server(run_id) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end
end
