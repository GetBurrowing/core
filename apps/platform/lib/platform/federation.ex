defmodule Platform.Federation do
  @moduledoc """
  Context module for agent federation — runtime registration,
  token management, and runtime ↔ agent linking.
  """

  import Ecto.Query

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Repo

  # ── Runtime registration ────────────────────────────────────────────

  @doc "Register a new external runtime."
  def register_runtime(owner_user_id, attrs) do
    %AgentRuntime{}
    |> AgentRuntime.changeset(Map.merge(attrs, %{owner_user_id: owner_user_id}))
    |> Repo.insert()
  end

  @doc "Fetch a runtime by its primary key."
  def get_runtime(id), do: Repo.get(AgentRuntime, id)

  @doc "Fetch a runtime by its human-readable runtime_id."
  def get_runtime_by_runtime_id(runtime_id) do
    Repo.get_by(AgentRuntime, runtime_id: runtime_id)
  end

  @doc "Fetch a runtime by verifying a raw auth token."
  def get_runtime_by_token(raw_token) when is_binary(raw_token) do
    hash = AgentRuntime.hash_token(raw_token)

    Repo.one(
      from(r in AgentRuntime,
        where: r.auth_token_hash == ^hash and r.status == "active"
      )
    )
  end

  @doc "List all runtimes owned by a user."
  def list_runtimes(owner_user_id) do
    Repo.all(from(r in AgentRuntime, where: r.owner_user_id == ^owner_user_id))
  end

  @doc "Activate a runtime and generate an auth token."
  def activate_runtime(%AgentRuntime{} = runtime) do
    {raw_token, hash} = generate_token_pair()

    case runtime
         |> AgentRuntime.changeset(%{status: "active", auth_token_hash: hash})
         |> Repo.update() do
      {:ok, updated} -> {:ok, updated, raw_token}
      error -> error
    end
  end

  @doc "Suspend a runtime."
  def suspend_runtime(%AgentRuntime{} = runtime) do
    runtime
    |> AgentRuntime.changeset(%{status: "suspended"})
    |> Repo.update()
  end

  @doc "Revoke a runtime (permanent)."
  def revoke_runtime(%AgentRuntime{} = runtime) do
    runtime
    |> AgentRuntime.changeset(%{status: "revoked", auth_token_hash: nil})
    |> Repo.update()
  end

  @doc "Generate a new auth token for a runtime, replacing any existing one."
  def generate_runtime_token(%AgentRuntime{} = runtime) do
    {raw_token, hash} = generate_token_pair()

    case runtime
         |> AgentRuntime.changeset(%{auth_token_hash: hash})
         |> Repo.update() do
      {:ok, updated} -> {:ok, updated, raw_token}
      error -> error
    end
  end

  # ── Runtime ↔ Agent linking ─────────────────────────────────────────

  @doc "Link an agent to a runtime, setting it as external."
  def link_agent(%AgentRuntime{} = runtime, %Agent{} = agent) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :agent,
      Agent.changeset(agent, %{runtime_type: "external", runtime_id: runtime.id})
    )
    |> Ecto.Multi.update(
      :runtime,
      AgentRuntime.changeset(runtime, %{agent_id: agent.id})
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{agent: agent}} -> {:ok, agent}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  def link_agent(%AgentRuntime{} = runtime, agent_attrs) when is_map(agent_attrs) do
    attrs =
      agent_attrs
      |> Map.put(:runtime_type, "external")
      |> Map.put(:runtime_id, runtime.id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:agent, Agent.changeset(%Agent{}, attrs))
    |> Ecto.Multi.run(:runtime, fn _repo, %{agent: agent} ->
      runtime
      |> AgentRuntime.changeset(%{agent_id: agent.id})
      |> Repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{agent: agent}} -> {:ok, agent}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Ensure the runtime's linked agent has a participant in the given space."
  def ensure_runtime_agent_participant(%AgentRuntime{agent_id: agent_id} = _runtime, space_id)
      when is_binary(agent_id) do
    Chat.ensure_agent_participant(space_id, agent_id)
  end

  def ensure_runtime_agent_participant(_runtime, _space_id) do
    {:error, :no_linked_agent}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp generate_token_pair do
    raw = AgentRuntime.generate_token()
    hash = AgentRuntime.hash_token(raw)
    {raw, hash}
  end
end
