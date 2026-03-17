defmodule Platform.Execution.LocalRunner do
  @moduledoc """
  First-party local execution provider for ADR 0011 MVP.

  This provider allocates a deterministic per-run workspace and spawns a real
  local OS process behind a BEAM wrapper so the control plane can describe,
  stop, and kill the run through a stable provider ref.

  ## Credential leasing

  Callers can pass a `CredentialLease` in opts under `:credential_lease`. The
  lease is converted to an OS-level environment variable map and merged with the
  child process environment before spawn.  GitHub leases inject `GITHUB_TOKEN`
  and the git author identity vars; model leases inject the provider's API key.

  ## Command resolution

  The command to run is resolved in this order:
    1. `:command` opt passed to `spawn_run/2`
    2. `run.meta[:command]` (atom key)
    3. `run.meta["command"]` (string key)

  Args follow the same resolution order.
  """

  @behaviour Platform.Execution.Runner

  alias Platform.Execution.{
    CredentialLease,
    LocalProcessWrapper,
    LocalWorkspace,
    Run
  }

  @impl true
  def spawn_run(%Run{} = run, opts) do
    lease = Keyword.get(opts, :credential_lease)

    with {:ok, workspace} <- LocalWorkspace.ensure_workspace(run, opts),
         {:ok, command, args} <- resolve_command(run, opts),
         env_overrides = build_env(lease),
         {:ok, wrapper} <-
           LocalProcessWrapper.start_link(
             run_id: run.id,
             run_server: Keyword.get(opts, :run_server, self()),
             workspace_root: workspace.root,
             workspace_path: workspace.path,
             ack_file_path: Path.join(workspace.path, ".context-ack-version"),
             ack_version: Keyword.get(opts, :context_version),
             command: command,
             args: args,
             env: env_overrides
           ) do
      {:ok, LocalProcessWrapper.provider_ref(wrapper)}
    end
  end

  @impl true
  def request_stop(%Run{} = run, _opts) do
    case fetch_wrapper(run) do
      {:ok, wrapper} -> LocalProcessWrapper.request_stop(wrapper)
      {:error, :wrapper_exited} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def force_stop(%Run{} = run, _opts) do
    case fetch_wrapper(run) do
      {:ok, wrapper} -> LocalProcessWrapper.force_stop(wrapper)
      {:error, :wrapper_exited} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def describe_run(%Run{} = run, _opts) do
    case fetch_wrapper(run) do
      {:ok, wrapper} ->
        LocalProcessWrapper.describe(wrapper)

      {:error, :wrapper_exited} ->
        ref = if is_map(run.runner_ref), do: run.runner_ref, else: %{}
        {:ok, Map.merge(ref, %{status: :exited, exit_code: run.exit_code})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def push_context(%Run{} = _run, _context, _opts), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_wrapper(%Run{runner_ref: %{wrapper_pid: wrapper}}) when is_pid(wrapper) do
    resolve_wrapper(wrapper)
  end

  defp fetch_wrapper(%Run{runner_ref: %{"wrapper_pid" => wrapper}}) when is_pid(wrapper) do
    resolve_wrapper(wrapper)
  end

  defp fetch_wrapper(_run), do: {:error, :missing_wrapper}

  defp resolve_wrapper(wrapper) when is_pid(wrapper) do
    if Process.info(wrapper) do
      {:ok, wrapper}
    else
      {:error, :wrapper_exited}
    end
  end

  defp resolve_command(%Run{} = run, opts) do
    case Keyword.get(opts, :command) || Map.get(run.meta, :command) ||
           Map.get(run.meta, "command") do
      nil ->
        {:error, :missing_command}

      command when is_binary(command) ->
        args =
          Keyword.get(opts, :args) ||
            Map.get(run.meta, :args) ||
            Map.get(run.meta, "args") ||
            []

        {:ok, command, Enum.map(List.wrap(args), &to_string/1)}
    end
  end

  defp build_env(nil), do: []
  defp build_env(%CredentialLease{} = lease), do: Enum.to_list(CredentialLease.to_env(lease))
end
