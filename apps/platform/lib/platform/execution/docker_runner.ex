defmodule Platform.Execution.DockerRunner do
  # Escalation poll interval and timeout — defined before @moduledoc so they
  # can be interpolated in the module attribute doc string.
  @default_escalation_ms 10_000
  @escalation_poll_ms 500

  # Default non-root user to run containers as
  @default_runner_user "runner"

  @moduledoc """
  Docker-backed `Platform.Execution.Runner` implementation.

  This provider keeps the existing BEAM-side control plane (`RunServer`,
  `ContextSession`, liveness state) and delegates the container mechanics to the
  companion `suite-runnerd` service through `SuiteRunnerdClient`.

  The goal of this first pass is to define a clean provider seam, not to invent
  a second orchestration plane. `RunServer` still owns the lifecycle state;
  `suite-runnerd` only owns spawn/describe/stop/kill for the concrete worker.

  ## Security posture

  Every container spawned through this provider carries the following defaults
  which are forwarded to `suite-runnerd` in the spawn payload:

    - **Non-root user**: runner process runs as `runner` (UID 1000) inside the
      image. The image must have this user created.
    - **No Docker socket**: the socket is never mounted inside the runner
      container. Runners that need to build images must use a sidecar or a
      remote daemon (tracked as a future follow-up).
    - **Capability drop**: all Linux capabilities are dropped. Only the minimal
      set required by the entrypoint is added back.
    - **No new privileges**: `no-new-privileges` seccomp bit is set, preventing
      `setuid`/`setgid` privilege escalation inside the container.

  ## Host-mounted worktree

  The per-run worktree directory (`workspace_root/<run_id>`) is bind-mounted
  into the container at `/workspace`. `suite-runnerd` performs the mount using
  the paths supplied in the spawn payload's `:mount` field.

  ## Stop/kill escalation

  `stop_with_escalation/3` provides a two-phase termination:

    1. Call `request_stop/2` to send a graceful stop (SIGTERM or docker stop)
    2. Poll `describe_run/2` until the container exits or
       `escalation_timeout_ms` elapses (default `#{@default_escalation_ms} ms`)
    3. If the container is still running after the timeout, call `force_stop/2`
       (docker kill / SIGKILL)

  This avoids leaving orphaned containers while giving the agent process time to
  flush state and exit cleanly.
  """

  @behaviour Platform.Execution.Runner

  alias Platform.Execution.{CredentialLease, LocalWorkspace, Run, SuiteRunnerdClient}

  @default_client SuiteRunnerdClient

  @impl true
  def spawn_run(%Run{} = run, opts) do
    lease = Keyword.get(opts, :credential_lease)
    client = client_module(opts)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, workspace} <- LocalWorkspace.ensure_workspace(run, opts),
         {:ok, command, args} <- resolve_command(run, opts),
         payload <- build_spawn_payload(run, workspace, command, args, lease, opts),
         {:ok, provider_ref} <- client.spawn_run(run, payload, client_opts) do
      {:ok,
       provider_ref
       |> normalize_provider_ref(run, workspace)
       |> Map.put(:command, command)
       |> Map.put(:args, args)}
    end
  end

  @impl true
  def request_stop(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         :ok <-
           client_module(opts).request_stop(
             run,
             provider_ref,
             Keyword.get(opts, :client_opts, [])
           ) do
      :ok
    end
  end

  @impl true
  def force_stop(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         :ok <-
           client_module(opts).force_stop(run, provider_ref, Keyword.get(opts, :client_opts, [])) do
      :ok
    end
  end

  @impl true
  def describe_run(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         {:ok, description} <-
           client_module(opts).describe_run(
             run,
             provider_ref,
             Keyword.get(opts, :client_opts, [])
           ) do
      {:ok, Map.merge(provider_ref, normalize_description(description))}
    end
  end

  @impl true
  def push_context(%Run{} = _run, _context, _opts), do: :ok

  @doc """
  Two-phase stop with automatic escalation to a forced kill.

  Steps:
    1. Sends a graceful stop request (`request_stop/2`).
    2. Polls `describe_run/2` every `#{@escalation_poll_ms} ms` until the
       container reports a terminal status or `escalation_timeout_ms` elapses.
    3. If the container is still running after the timeout, calls `force_stop/2`.

  Returns `:ok` once the container is confirmed stopped or killed.
  Returns `{:error, reason}` only if the initial stop request fails; a failed
  escalation poll is treated as a reason to move directly to force stop.

  Options:
    - `:escalation_timeout_ms` — ms to wait before hard kill (default #{@default_escalation_ms})
    - `:client` / `:client_opts` — forwarded to underlying client calls
  """
  @spec stop_with_escalation(Run.t(), keyword()) :: :ok | {:error, term()}
  def stop_with_escalation(%Run{} = run, opts \\ []) do
    timeout_ms = Keyword.get(opts, :escalation_timeout_ms, @default_escalation_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with :ok <- request_stop(run, opts) do
      wait_for_stopped_or_escalate(run, opts, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp wait_for_stopped_or_escalate(%Run{} = run, opts, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        # Timed out waiting for graceful stop — escalate
        _ = force_stop(run, opts)
        :ok

      true ->
        case describe_run(run, opts) do
          {:ok, %{status: status}} when status in [:exited, :dead, :stopped, :killed] ->
            :ok

          {:ok, _} ->
            Process.sleep(@escalation_poll_ms)
            wait_for_stopped_or_escalate(run, opts, deadline)

          {:error, _} ->
            # Describe failed — container may be gone already; try force_stop defensively
            _ = force_stop(run, opts)
            :ok
        end
    end
  end

  defp client_module(opts), do: Keyword.get(opts, :client, @default_client)

  defp fetch_provider_ref(%Run{runner_ref: ref}) when is_map(ref) and map_size(ref) > 0,
    do: {:ok, normalize_provider_ref(ref)}

  defp fetch_provider_ref(_run), do: {:error, :missing_provider_ref}

  defp normalize_provider_ref(provider_ref, run \\ nil, workspace \\ nil)
       when is_map(provider_ref) do
    provider_ref =
      provider_ref
      |> atomize_keys(%{
        "provider" => :provider,
        "run_id" => :run_id,
        "workspace_root" => :workspace_root,
        "workspace_path" => :workspace_path,
        "container_id" => :container_id,
        "image" => :image,
        "status" => :status,
        "stop_mode" => :stop_mode,
        "exit_code" => :exit_code,
        "started_at" => :started_at,
        "finished_at" => :finished_at,
        "exit_message" => :exit_message,
        "health" => :health
      })
      |> Map.put_new(:provider, :docker)
      |> coerce_atom(:provider)
      |> coerce_atom(:status)
      |> coerce_atom(:stop_mode)
      |> coerce_atom(:health)

    provider_ref =
      case run do
        %Run{} -> Map.put_new(provider_ref, :run_id, run.id)
        _ -> provider_ref
      end

    case workspace do
      %{root: root, path: path} ->
        provider_ref
        |> Map.put_new(:workspace_root, root)
        |> Map.put_new(:workspace_path, path)

      _ ->
        provider_ref
    end
  end

  defp coerce_atom(map, key) do
    case Map.get(map, key) do
      nil -> map
      value when is_atom(value) -> map
      value when is_binary(value) -> Map.put(map, key, String.to_existing_atom(value))
      _ -> map
    end
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(map, key_map) do
    Enum.reduce(key_map, map, fn {string_key, atom_key}, acc ->
      case Map.fetch(acc, string_key) do
        {:ok, value} -> acc |> Map.delete(string_key) |> Map.put(atom_key, value)
        :error -> acc
      end
    end)
  end

  defp build_spawn_payload(run, workspace, command, args, lease, opts) do
    %{
      run_id: run.id,
      task_id: run.task_id,
      project_id: run.project_id,
      epic_id: run.epic_id,
      workspace_root: workspace.root,
      workspace_path: workspace.path,
      command: command,
      args: args,
      env: build_env(lease),
      security: build_security_opts(opts),
      mount: build_mount_opts(workspace, opts),
      meta: Map.merge(run.meta, Enum.into(Keyword.get(opts, :meta_overrides, []), %{}))
    }
  end

  # Container security posture: non-root, no socket, capability drop, no-new-privileges
  defp build_security_opts(opts) do
    %{
      user: Keyword.get(opts, :runner_user, @default_runner_user),
      no_new_privileges: true,
      capability_drop: ["ALL"],
      capability_add: Keyword.get(opts, :capability_add, []),
      no_docker_socket: true
    }
  end

  # Host-to-container bind mount for the per-run worktree
  defp build_mount_opts(%{root: root, path: path}, opts) do
    container_workspace = Keyword.get(opts, :container_workspace_path, "/workspace")

    %{
      type: "bind",
      host_source: path,
      container_target: container_workspace,
      workspace_root: root,
      read_only: false
    }
  end

  defp normalize_description(description) when is_map(description) do
    atomize_keys(description, %{
      "status" => :status,
      "exit_code" => :exit_code,
      "container_id" => :container_id,
      "image" => :image,
      "stop_mode" => :stop_mode,
      "started_at" => :started_at,
      "finished_at" => :finished_at,
      "exit_message" => :exit_message,
      "health" => :health
    })
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

  defp build_env(nil), do: %{}
  defp build_env(%CredentialLease{} = lease), do: CredentialLease.to_env(lease)
end
