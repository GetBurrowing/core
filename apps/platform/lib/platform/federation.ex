defmodule Platform.Federation do
  @moduledoc """
  Context module for agent federation — runtime registration,
  token management, and runtime ↔ agent linking.
  """

  require Logger
  import Ecto.Query

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Federation.RuntimePresence
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

  @doc """
  Shallow-merge new top-level keys into a runtime's `metadata` map and
  persist the result via the regular changeset path.

  Existing top-level keys not present in `new_keys` are preserved. The
  merge is intentionally shallow at the top level: setting
  `"client_info"` REPLACES the nested map under that key — the caller is
  responsible for assembling the full nested structure they want stored.

  Writes through `AgentRuntime.changeset/2` so validations and
  `updated_at` stay consistent with the rest of the runtime mutations.
  """
  @spec update_metadata(AgentRuntime.t(), map()) ::
          {:ok, AgentRuntime.t()} | {:error, Ecto.Changeset.t()}
  def update_metadata(%AgentRuntime{} = runtime, new_keys) when is_map(new_keys) do
    merged = Map.merge(runtime.metadata || %{}, new_keys)

    runtime
    |> AgentRuntime.changeset(%{metadata: merged})
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
      {:ok, %{agent: agent}} ->
        auto_roster_federated_agent(agent)
        {:ok, agent}

      {:error, _step, changeset, _} ->
        {:error, changeset}
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
      {:ok, %{agent: agent}} ->
        auto_roster_federated_agent(agent)
        {:ok, agent}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Add a federated agent to the roster of every non-archived channel space
  in its workspace.

  Runs best-effort: idempotent via `Chat.ensure_space_agent/3` (no-op when
  the agent is already on a space's roster), logs-but-ignores per-space
  errors so a single misbehaving space never blocks agent creation. The
  roster add emits `{:roster_changed, space_id}` pubsub so any open shell
  LiveView refreshes automatically.

  Rationale: until a federated agent is in a space's roster, it is not
  @-mentionable from that space, which makes newly-provisioned agents
  effectively invisible until an operator manually adds them. Auto-adding
  to every channel in the workspace mirrors the UX of a human user being
  added to an org — they can see every room by default; operators remove
  from specific spaces later if needed. (See ADR 0019 for the roster
  model.)
  """
  @spec auto_roster_federated_agent(Agent.t()) :: :ok
  def auto_roster_federated_agent(%Agent{id: agent_id, workspace_id: workspace_id} = agent) do
    # `workspace_id` may be nil in single-tenant / default-org setups; in that
    # case we roster against the channel spaces that also have a nil
    # workspace_id. `Chat.list_spaces/1` handles the nil semantics with
    # `is_nil/1` internally.
    spaces = Chat.list_spaces(workspace_id: workspace_id, kind: "channel")

    Enum.each(spaces, fn %Space{id: space_id} ->
      case Chat.ensure_space_agent(space_id, agent_id, role: "member") do
        {:ok, _space_agent} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Federation] auto-roster failed for agent=#{agent.slug} space=#{space_id} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  @doc "Ensure the runtime's linked agent has a participant in the given space."
  def ensure_runtime_agent_participant(%AgentRuntime{agent_id: agent_id} = _runtime, space_id)
      when is_binary(agent_id) do
    Chat.add_agent_participant(space_id, agent_id)
  end

  def ensure_runtime_agent_participant(_runtime, _space_id) do
    {:error, :no_linked_agent}
  end

  # ── Query helpers ───────────────────────────────────────────────────

  @doc "Fetch the runtime linked to an agent (by the agent's runtime_id FK)."
  def get_runtime_for_agent(%Agent{runtime_id: nil}), do: nil
  def get_runtime_for_agent(%Agent{runtime_id: rid}), do: get_runtime(rid)

  @doc "List spaces an agent participates in, with the participant's attention_mode."
  def agent_spaces(%Agent{id: agent_id}) do
    from(p in Participant,
      join: s in Space,
      on: s.id == p.space_id,
      where: p.participant_type == "agent" and p.participant_id == ^agent_id,
      select: %{
        space_id: s.id,
        space_name: s.name,
        space_slug: s.slug,
        attention_mode: p.attention_mode
      },
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  # ── Observability ───────────────────────────────────────────────────

  @doc """
  Returns the federation health status for all active runtimes.

  Combines DB records with live presence data to show connectivity,
  connected_at, last_seen_at, and historical last_connected_at.
  """
  def federation_status do
    runtimes = Repo.all(from(r in AgentRuntime, where: r.status == "active"))
    presence = RuntimePresence.list_all()

    # Build agent lookup — AgentRuntime has agent_id as a raw field, no association
    agent_ids = runtimes |> Enum.map(& &1.agent_id) |> Enum.reject(&is_nil/1)

    agents =
      if agent_ids != [] do
        from(a in Platform.Agents.Agent, where: a.id in ^agent_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      else
        %{}
      end

    Enum.map(runtimes, fn runtime ->
      online_info = Map.get(presence, runtime.runtime_id)
      agent = Map.get(agents, runtime.agent_id)

      %{
        runtime_id: runtime.runtime_id,
        agent_name: agent && agent.name,
        agent_slug: agent && agent.slug,
        agent_id: runtime.agent_id,
        status: runtime.status,
        online: online_info != nil,
        connected_at: online_info && online_info.connected_at,
        last_seen_at: online_info && online_info.last_seen_at,
        last_connected_at: runtime.last_connected_at
      }
    end)
  end

  @doc """
  Broadcast a ping event to a runtime channel.

  The runtime client is expected to respond with a "pong" event,
  which will update the last_seen_at via RuntimePresence.touch/1.
  """
  def ping_runtime(runtime_id) do
    topic = "runtime:#{runtime_id}"
    PlatformWeb.Endpoint.broadcast(topic, "ping", %{timestamp: DateTime.utc_now()})
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp generate_token_pair do
    raw = AgentRuntime.generate_token()
    hash = AgentRuntime.hash_token(raw)
    {raw, hash}
  end
end
