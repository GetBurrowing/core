defmodule Platform.Agents.WorkspaceBootstrap do
  @moduledoc """
  Bootstraps a native agent runtime from the mounted OpenClaw-compatible workspace.

  This keeps the slice grounded in the existing `Platform.Agents` OTP runtime:

    * read `openclaw.json` from the mounted workspace path
    * upsert the selected agent into the platform tables
    * sync the top-level workspace files used by the runtime shell
    * start or refresh the supervised `AgentServer`
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.{Agent, AgentServer, Config, MemoryContext, SlugLookup, WorkspaceFile}
  alias Platform.Repo

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md MEMORY.md TOOLS.md HEARTBEAT.md)
  @source_key "workspace_source"
  @default_workspace_path "/data/agents/zip"

  @type status :: %{
          configured?: boolean(),
          bootable?: boolean(),
          reachable?: boolean(),
          running?: boolean(),
          workspace_path: String.t(),
          agent_slug: String.t() | nil,
          agent_name: String.t() | nil,
          agent: Agent.t() | nil,
          pid: pid() | nil,
          error: term() | nil
        }

  @doc """
  Return deterministic runtime status for the mounted agent workspace.
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    requested_path = workspace_path(opts)

    with {:ok, layout} <- resolve_layout(requested_path),
         {:ok, parsed} <- Config.parse_file(layout.config_path),
         {:ok, parsed_agent} <- select_agent(parsed.agents, opts) do
      {agent, error} =
        case lookup_parsed_agent(parsed_agent) do
          {:ok, agent} -> {agent, nil}
          {:error, :not_found} -> {nil, nil}
          {:error, :ambiguous_slug} -> {nil, {:ambiguous_slug, parsed_agent.id}}
        end

      pid = agent && AgentServer.whereis(agent.id)

      %{
        configured?: true,
        bootable?: true,
        reachable?: is_pid(pid) and Process.alive?(pid),
        running?: is_pid(pid),
        workspace_path: layout.workspace_path,
        agent_slug: parsed_agent.id,
        agent_name: parsed_agent.name,
        agent: agent,
        pid: pid,
        error: error
      }
    else
      {:error, reason} ->
        %{
          configured?: false,
          bootable?: false,
          reachable?: false,
          running?: false,
          workspace_path: requested_path,
          agent_slug: nil,
          agent_name: nil,
          agent: nil,
          pid: nil,
          error: reason
        }
    end
  end

  @doc """
  List configured agent entries from the mounted workspace without mutating the database.
  """
  @spec list_configured_agents(keyword()) :: {:ok, [Config.parsed_agent()]} | {:error, term()}
  def list_configured_agents(opts \\ []) do
    requested_path = workspace_path(opts)

    with {:ok, layout} <- resolve_layout(requested_path),
         {:ok, parsed} <- Config.parse_file(layout.config_path) do
      {:ok, parsed.agents}
    end
  end

  @doc """
  Ensure the configured mounted agent exists in the database.
  """
  @spec ensure_agent(keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure_agent(opts \\ []) do
    requested_path = workspace_path(opts)

    with {:ok, layout} <- resolve_layout(requested_path),
         {:ok, parsed} <- Config.parse_file(layout.config_path),
         {:ok, parsed_agent} <- select_agent(parsed.agents, opts) do
      Repo.transaction(fn ->
        agent = upsert_agent!(parsed_agent, layout)
        sync_workspace_files!(agent.id, layout.workspace_path)
        agent
      end)
      |> normalize_transaction_result()
    end
  end

  @doc """
  Ensure the mounted agent is persisted and its runtime is reachable.
  """
  @spec boot(keyword()) :: {:ok, status()} | {:error, term()}
  def boot(opts \\ []) do
    with {:ok, layout} <- resolve_layout(workspace_path(opts)),
         {:ok, agent} <- ensure_agent(opts),
         existing_pid <- AgentServer.whereis(agent.id),
         {:ok, pid} <- AgentServer.start_agent(agent) do
      if is_pid(existing_pid) do
        _ = AgentServer.refresh(agent.id)
      end

      {:ok,
       %{
         configured?: true,
         bootable?: true,
         reachable?: Process.alive?(pid),
         running?: true,
         workspace_path: layout.workspace_path,
         agent_slug: agent.slug,
         agent_name: agent.name,
         agent: Repo.get!(Agent, agent.id),
         pid: pid,
         error: nil
       }}
    end
  end

  @doc """
  Fire-and-forget variant of `boot/1` for callers that must not block their
  own process on the runtime boot — LiveView mount/event hooks
  (`ShellLive.default_agent_status/0`, `PresenceHooks.ensure_native_agent_presence/1`)
  that kick a boot when the agent is unreachable.

  Spawns under `Platform.TaskSupervisor` (task 01a089e5 stage 3) rather than
  a bare `Task.start`, for two reasons: an `async: true` test whose sandbox
  connection this process doesn't own gets a `rescue` instead of an unlinked
  crash racing test output, and a shared-mode (`async: false`) test gets this
  child drained by `Platform.DataCase`'s `on_exit`
  (`Platform.SandboxHelpers.await_supervised_writes/1`) instead of it
  potentially outliving the sandbox checkin — the same hazard bare
  `Task.start` sites in this module's callers were invisible to.
  """
  @spec boot_async(keyword()) :: {:ok, pid()} | {:error, term()}
  def boot_async(opts \\ []) do
    # `start_child`, not `async_nolink`. Callers here are LiveView
    # mount/event hooks that fire this and move on — nothing awaits or
    # `Task.yield`s the result. `async_nolink` sends a `{ref, result}` reply
    # back to whichever process called `boot_async/1`; `ShellLive` and
    # `PresenceHooks` are mixed into every shell-wrapped LiveView (not just
    # ShellLive itself), and a sibling like `ChangelogLive` has no
    # catch-all `handle_info/2` clause — that reply arriving there is a
    # real `FunctionClauseError` crash, not a hypothetical (it's what this
    # fix actually produced under `async_nolink` before this rewrite,
    # task 01a089e5 stage 3).
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        boot(opts)
      rescue
        DBConnection.OwnershipError ->
          Logger.debug(
            "[WorkspaceBootstrap] boot_async sandbox-owned DB call from Task.Supervised child — dropping"
          )

          {:error, :sandbox_unowned}
      end
    end)
  end

  defp workspace_path(opts) do
    Keyword.get(
      opts,
      :workspace_path,
      Application.get_env(:platform, :agent_workspace_path, @default_workspace_path)
    )
  end

  @doc false
  def resolve_layout(path) when is_binary(path) do
    expanded = Path.expand(path)
    direct_config = Path.join(expanded, "openclaw.json")
    parent = Path.dirname(expanded)
    parent_config = Path.join(parent, "openclaw.json")

    cond do
      File.regular?(direct_config) ->
        {:ok,
         %{
           root_path: expanded,
           config_path: direct_config,
           workspace_path: resolve_workspace_dir(expanded)
         }}

      File.regular?(parent_config) ->
        {:ok,
         %{
           root_path: parent,
           config_path: parent_config,
           workspace_path: expanded
         }}

      true ->
        {:error, :enoent}
    end
  end

  defp resolve_workspace_dir(root_path) do
    nested_workspace = Path.join(root_path, "workspace")

    if File.dir?(nested_workspace) do
      nested_workspace
    else
      root_path
    end
  end

  defp select_agent([agent], _opts), do: {:ok, agent}

  defp select_agent(agents, opts) do
    target = Keyword.get(opts, :agent_id) || Keyword.get(opts, :slug)

    case target do
      nil ->
        select_default_agent(agents)

      target ->
        case Enum.find(agents, &(&1.id == target)) do
          nil -> {:error, {:agent_not_found, target}}
          agent -> {:ok, agent}
        end
    end
  end

  defp select_default_agent([]), do: {:error, :no_agents}

  defp select_default_agent(agents) do
    cond do
      agent = Enum.find(agents, &agent_marked_default?/1) ->
        {:ok, agent}

      agent = Enum.find(agents, &(&1.id == "main")) ->
        {:ok, agent}

      true ->
        {:ok, hd(agents)}
    end
  end

  defp agent_marked_default?(%{raw: raw}) when is_map(raw) do
    Map.get(raw, "default") == true
  end

  defp agent_marked_default?(_agent), do: false

  defp source_metadata(layout) do
    %{
      @source_key => %{
        "path" => Path.expand(layout.root_path),
        "config_path" => Path.expand(layout.config_path),
        "workspace_path" => Path.expand(layout.workspace_path)
      }
    }
  end

  defp upsert_agent!(parsed_agent, layout) do
    attrs =
      parsed_agent.attrs
      |> Map.update(:metadata, source_metadata(layout), fn metadata ->
        Map.merge(metadata || %{}, source_metadata(layout))
      end)

    case lookup_parsed_agent(parsed_agent) do
      {:error, :not_found} ->
        %Agent{}
        |> Agent.changeset(attrs)
        |> Repo.insert!()

      {:ok, %Agent{} = agent} ->
        agent
        |> Agent.changeset(attrs)
        |> Repo.update!()

      {:error, :ambiguous_slug} ->
        raise ArgumentError,
              "cannot upsert agent #{inspect(parsed_agent.id)}: more than one agent has that " <>
                "slug in workspace #{inspect(Map.get(parsed_agent.attrs, :workspace_id))}; " <>
                "refusing to pick one to update"
    end
  end

  # Scoped to the parsed agent's OWN workspace (nil = IS NULL), because that
  # is the row an insert would collide with. An unscoped slug lookup raised
  # Ecto.MultipleResultsError whenever any two workspaces shared the slug
  # (task 01a0e77c).
  defp lookup_parsed_agent(parsed_agent) do
    SlugLookup.resolve(parsed_agent.id,
      workspace_id: Map.get(parsed_agent.attrs, :workspace_id)
    )
  end

  defp sync_workspace_files!(agent_id, workspace_path) do
    existing =
      agent_id
      |> MemoryContext.list_workspace_files()
      |> Map.new(fn file -> {file.file_key, file} end)

    seen_keys =
      Enum.reduce(@workspace_files, MapSet.new(), fn file_key, acc ->
        path = Path.join(workspace_path, file_key)

        if File.regular?(path) do
          content = File.read!(path)

          case Map.get(existing, file_key) do
            %WorkspaceFile{content: ^content} ->
              :ok

            _ ->
              {:ok, _workspace_file} =
                MemoryContext.upsert_workspace_file(agent_id, file_key, content)
          end

          MapSet.put(acc, file_key)
        else
          acc
        end
      end)

    stale_keys =
      existing
      |> Map.keys()
      |> Enum.filter(&(&1 in @workspace_files and not MapSet.member?(seen_keys, &1)))

    if stale_keys != [] do
      from(wf in WorkspaceFile, where: wf.agent_id == ^agent_id and wf.file_key in ^stale_keys)
      |> Repo.delete_all()
    end

    :ok
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
