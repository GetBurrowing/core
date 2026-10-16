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

  def manage?(%Scope{} = scope, %Agent{} = agent) do
    runtime = Repo.get_by(AgentRuntime, agent_id: agent.id)
    runtime = runtime || (agent.runtime_id && Repo.get(AgentRuntime, agent.runtime_id))
    manage?(scope, runtime)
  end

  def manage?(%Scope{} = scope, nil), do: Access.holds_anywhere?(scope, "agents.manage_all")
  def manage?(_, _), do: false

  @spec may_federate?(Scope.t()) :: boolean()
  def may_federate?(%Scope{} = scope), do: Access.holds_anywhere?(scope, "agents.manage_own")
  def may_federate?(_), do: false

  @spec may_create_ownerless?(Scope.t()) :: boolean()
  def may_create_ownerless?(%Scope{} = scope),
    do: Access.holds_anywhere?(scope, "agents.manage_all")

  def may_create_ownerless?(_), do: false

  def may_assign?(scope, agent), do: manage?(scope, agent)
  def may_release?(scope, agent), do: manage?(scope, agent)

  defp manage_owner?(scope, owner_id) when is_binary(owner_id) do
    own? =
      match?(%{id: ^owner_id}, scope.actor) and
        Access.holds_anywhere?(scope, "agents.manage_own")

    owner_org_ids =
      from(m in OrgMembership, where: m.user_id == ^owner_id and not m.external, select: m.org_id)
      |> Repo.all()

    own? or Enum.any?(owner_org_ids, &Access.can?(scope, "agents.manage_all", &1))
  end

  defp manage_owner?(scope, _), do: may_create_ownerless?(scope)
end
