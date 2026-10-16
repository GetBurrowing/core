defmodule Platform.Access.Agents do
  @moduledoc "Authorization for agent ownership and responsibility changes."

  import Ecto.Query

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @spec manage?(Scope.t(), AgentRuntime.t() | Agent.t() | nil) :: boolean()
  def manage?(%Scope{} = scope, %AgentRuntime{owner_user_id: owner_id}),
    do: manage_owner?(scope, owner_id)

  # An agent may have several runtimes (one per host it federates from), each
  # with its own owner. Managing the agent means managing every one of them;
  # an agent with no runtime is ownerless and needs `agents.manage_all`.
  def manage?(%Scope{} = scope, %Agent{} = agent) do
    runtimes =
      case Repo.all(from(r in AgentRuntime, where: r.agent_id == ^agent.id)) do
        [] -> List.wrap(agent.runtime_id && Repo.get(AgentRuntime, agent.runtime_id))
        runtimes -> runtimes
      end

    case runtimes do
      [] -> manage?(scope, nil)
      runtimes -> Enum.all?(runtimes, &manage?(scope, &1))
    end
  end

  def manage?(%Scope{} = scope, nil), do: Access.holds_anywhere?(scope, "agents.manage_all")
  def manage?(_, _), do: false

  @spec may_federate?(Scope.t()) :: boolean()
  def may_federate?(%Scope{} = scope), do: Access.module_access?(scope, :agents)
  def may_federate?(_), do: false

  @spec may_create_ownerless?(Scope.t()) :: boolean()
  def may_create_ownerless?(%Scope{} = scope),
    do: Access.holds_anywhere?(scope, "agents.manage_all")

  def may_create_ownerless?(_), do: false

  def may_assign?(scope, agent), do: manage?(scope, agent)
  def may_release?(scope, agent), do: manage?(scope, agent)

  defp manage_owner?(scope, owner_id) when is_binary(owner_id) do
    own? =
      match?(%{id: ^owner_id}, scope.actor) and may_federate?(scope)

    cond do
      own? ->
        true

      Access.can?(scope, "install.admin") ->
        true

      true ->
        from(m in OrgMembership,
          where: m.user_id == ^owner_id and not m.external,
          select: m.org_id
        )
        |> Repo.all()
        |> Enum.any?(&Access.can?(scope, "agents.manage_all", &1))
    end
  end

  defp manage_owner?(scope, _), do: may_create_ownerless?(scope)
end
