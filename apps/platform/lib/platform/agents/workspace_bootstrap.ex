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

  alias Platform.Agents.{Agent, AgentServer, Config, MemoryContext, WorkspaceFile}
  alias Platform.Repo

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md MEMORY.md TOOLS.md HEARTBEAT.md)
  @source_key "workspace_source"
  @default_workspace_path "/data/agents/zip/workspace"

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
    workspace_path = workspace_path(opts)

    with {:ok, parsed} <- load_workspace_config(workspace_path),
         {:ok, parsed_agent} <- select_agent(parsed.agents, opts) do
      agent = Repo.get_by(Agent, slug: parsed_agent.id)
      pid = agent && AgentServer.whereis(agent.id)

      %{
        configured?: true,
        bootable?: true,
        reachable?: is_pid(pid) and Process.alive?(pid),
        running?: is_pid(pid),
        workspace_path: workspace_path,
        agent_slug: parsed_agent.id,
        agent_name: parsed_agent.name,
        agent: agent,
        pid: pid,
        error: nil
      }
    else
      {:error, reason} ->
        %{
          configured?: false,
          bootable?: false,
          reachable?: false,
          running?: false,
          workspace_path: workspace_path,
          agent_slug: nil,
          agent_name: nil,
          agent: nil,
          pid: nil,
          error: reason
        }
    end
  end

  @doc """
  Ensure the configured mounted agent exists in the database.
  """
  @spec ensure_agent(keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure_agent(opts \\ []) do
    workspace_path = workspace_path(opts)

    with {:ok, parsed} <- load_workspace_config(workspace_path),
         {:ok, parsed_agent} <- select_agent(parsed.agents, opts) do
      Repo.transaction(fn ->
        attrs =
          parsed_agent.attrs
          |> Map.update(:metadata, source_metadata(workspace_path), fn metadata ->
            Map.merge(metadata || %{}, source_metadata(workspace_path))
          end)

        agent =
          case Repo.get_by(Agent, slug: parsed_agent.id) do
            nil ->
              %Agent{}
              |> Agent.changeset(attrs)
              |> Repo.insert!()

            %Agent{} = agent ->
              agent
              |> Agent.changeset(attrs)
              |> Repo.update!()
          end

        sync_workspace_files!(agent.id, workspace_path)
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
    with {:ok, agent} <- ensure_agent(opts),
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
         workspace_path: workspace_path(opts),
         agent_slug: agent.slug,
         agent_name: agent.name,
         agent: Repo.get!(Agent, agent.id),
         pid: pid,
         error: nil
       }}
    end
  end

  defp workspace_path(opts) do
    Keyword.get(
      opts,
      :workspace_path,
      Application.get_env(:platform, :agent_workspace_path, @default_workspace_path)
    )
  end

  defp load_workspace_config(workspace_path) do
    workspace_path
    |> Path.join("openclaw.json")
    |> Config.parse_file()
  end

  defp select_agent([agent], _opts), do: {:ok, agent}

  defp select_agent(agents, opts) do
    target = Keyword.get(opts, :agent_id) || Keyword.get(opts, :slug)

    case target do
      nil ->
        {:error, {:multiple_agents, Enum.map(agents, & &1.id)}}

      target ->
        case Enum.find(agents, &(&1.id == target)) do
          nil -> {:error, {:agent_not_found, target}}
          agent -> {:ok, agent}
        end
    end
  end

  defp source_metadata(workspace_path) do
    %{
      @source_key => %{
        "path" => Path.expand(workspace_path)
      }
    }
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
