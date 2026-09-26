defmodule Platform.GameStream.Seed do
  @moduledoc """
  Seeds the play host's agent and runtime row (task 01a0db5f stage 2).
  `mix platform.seed_play_host` wraps it; a prod release calls it through
  `bin/platform rpc 'Platform.GameStream.Seed.run(owner_email: "...", token_path: "...")'`.

  ## What it writes

    * an agent with the fixed slug `play-host`;
    * an `agent_runtimes` row (default `runtime_id` `play-host-wave`) owned by
      `owner_email`, bound to that agent by `agent_id` — NOT through
      `Federation.link_agent/2`, which would mark the agent `external` and
      make it a dispatch target. A play host answers play frames and nothing
      else;
    * `metadata["client_info"]["features"] = ["game_stream_host"]`, the same
      declaration the host makes at join, so the row reads as a host even
      before its first connection;
    * `allowed_bundles: []` — the host calls no tools.

  ## The token goes to a FILE, never to output

  A token is minted only when the row is created, or when `rotate: true`.
  It is written to `token_path` (created with mode 0600) and never printed,
  logged or returned. A rerun without `rotate` reuses the row, mints
  nothing and leaves the file alone.
  """

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Repo

  @agent_slug "play-host"
  @agent_name "Play Host"
  @default_runtime_id "play-host-wave"

  @type result :: %{
          agent: Agent.t(),
          runtime: AgentRuntime.t(),
          token_written: boolean()
        }

  @doc """
  Options: `:owner_email` (required), `:token_path` (required),
  `:runtime_id` (default `"play-host-wave"`), `:rotate` (default false).
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts) do
    with {:ok, owner_email} <- fetch_string(opts, :owner_email),
         {:ok, token_path} <- fetch_string(opts, :token_path),
         %User{} = owner <- Repo.get_by(User, email: owner_email) || {:error, :unknown_owner},
         {:ok, agent} <- find_or_create_agent() do
      runtime_id = Keyword.get(opts, :runtime_id, @default_runtime_id)
      rotate? = Keyword.get(opts, :rotate, false)

      case Federation.get_runtime_by_runtime_id(runtime_id) do
        nil -> create_runtime(owner, agent, runtime_id, token_path)
        %AgentRuntime{} = existing -> refresh_runtime(existing, agent, token_path, rotate?)
      end
    end
  end

  defp create_runtime(owner, agent, runtime_id, token_path) do
    with {:ok, runtime} <-
           Federation.register_runtime(owner.id, %{
             runtime_id: runtime_id,
             display_name: "Play host (#{runtime_id})",
             agent_id: agent.id,
             allowed_bundles: [],
             metadata: %{"client_info" => client_info()}
           }),
         {:ok, runtime, raw_token} <- Federation.activate_runtime(runtime),
         :ok <- write_token(token_path, raw_token) do
      {:ok, %{agent: agent, runtime: runtime, token_written: true}}
    end
  end

  defp refresh_runtime(existing, agent, token_path, rotate?) do
    with {:ok, runtime} <- Federation.update_metadata(existing, %{"client_info" => client_info()}),
         {:ok, runtime} <- Federation.update_allowed_bundles(runtime, []),
         {:ok, runtime} <- bind_agent(runtime, agent) do
      if rotate? do
        with {:ok, runtime, raw_token} <- Federation.activate_runtime(runtime),
             :ok <- write_token(token_path, raw_token) do
          {:ok, %{agent: agent, runtime: runtime, token_written: true}}
        end
      else
        {:ok, %{agent: agent, runtime: runtime, token_written: false}}
      end
    end
  end

  defp bind_agent(%AgentRuntime{agent_id: id} = runtime, %Agent{id: id}), do: {:ok, runtime}

  defp bind_agent(runtime, agent),
    do: runtime |> AgentRuntime.changeset(%{agent_id: agent.id}) |> Repo.update()

  defp find_or_create_agent do
    case Repo.get_by(Agent, slug: @agent_slug) do
      nil ->
        %Agent{}
        |> Agent.changeset(%{slug: @agent_slug, name: @agent_name, status: "active"})
        |> Repo.insert()

      %Agent{} = agent ->
        {:ok, agent}
    end
  end

  defp client_info, do: %{"features" => [Platform.GameStream.host_feature()]}

  defp write_token(path, token) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, token)
    File.chmod!(path, 0o600)
    :ok
  rescue
    error -> {:error, {:token_write_failed, Exception.message(error)}}
  end

  defp fetch_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end
end
