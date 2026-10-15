defmodule Platform.Access.AgentWake do
  @moduledoc """
  May an agent be WOKEN onto a task or a space (task 01a1386e-45a5 stage 2,
  RBAC stack member 7; `0058-rbac-v2-roles-scopes-and-agent-capping.md
  § Precedence`, "The grant-less short-circuit")?

  Three surfaces wake an agent and call this module after their own existing
  check has admitted: `Platform.Orchestration.PhaseRuntime.resolve/1` (the
  TaskRouter's dispatch target), `Platform.Chat`'s `@`-mention summon, and
  `Platform.Chat.AttentionRouter`'s routing of a message to an agent that is
  already a participant.

  ## The decision is two `Platform.Access.check/3` calls

  An agent is refused when EITHER of these is not `:ok`:

    * `Access.check(Scope.for_user(owner), permission, resource)`, the human
      who owns the agent's runtime (skipped when the runtime has no
      `owner_user_id`);
    * `Access.check(Scope.for_runtime(runtime), permission, resource)`, the
      agent's OWN grants. For an agent with no linked runtime the agent
      principal's grants are read directly, because `Scope.for_runtime/1`
      takes a runtime row.

  This module compares no effect itself. It is not general owner-capping
  (stack position 5): it refuses only the wake, not the agent's tools.

  ## The short-circuit, and why it is an over-approximation

  Building both Scopes costs several queries per agent (memberships, the
  participant snapshot, the agent roster, the grant rows). With no grants
  every `check/3` returns `:ok`, so that work decides nothing. `denied/3`
  and `check/4` therefore first run ONE `EXISTS` over `access_grants` for
  every principal either Scope could load:

    * `{:agent, id}` for the agent ids and their runtimes' `agent_id`;
    * `{:user, owner}` for the runtimes' owners;
    * any role grant in an org one of those owners is a member of. A Scope
      loads only the role keys the member holds there, so this matches MORE
      rows than any Scope loads, never fewer.

  When it finds nothing, no Scope could carry a grant, `check/3` would
  answer `:ok` for every agent, and nothing is denied. When it finds
  something, the full per-agent decision runs. Correctness never depends on
  the short-circuit; only the query count does.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Scope}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @doc """
  The ids among `agent_ids` the owner-or-agent decision refuses for
  `permission` on `resource`, as a `MapSet`. With no grant reachable from
  any of them this is ONE query and an empty set.
  """
  @spec denied([binary()], String.t(), term()) :: MapSet.t(binary())
  def denied(agent_ids, permission, resource) when is_list(agent_ids) and is_binary(permission) do
    ids = agent_ids |> Enum.filter(&valid_id?/1) |> Enum.uniq()

    if ids == [] or not any_grants?(ids) do
      MapSet.new()
    else
      runtimes = runtimes_by_agent(ids)

      for id <- ids,
          check(id, Map.get(runtimes, id), permission, resource) != :ok,
          into: MapSet.new(),
          do: id
    end
  end

  @doc """
  The owner-or-agent decision for one agent whose runtime the caller already
  holds (`nil` when the agent has none): `:ok` or `{:error, :denied}`.
  Short-circuits through the same `EXISTS` as `denied/3`.
  """
  @spec check_agent(Agent.t() | binary(), AgentRuntime.t() | nil, String.t(), term()) ::
          :ok | {:error, :denied}
  def check_agent(%Agent{id: id}, runtime, permission, resource),
    do: check_agent(id, runtime, permission, resource)

  def check_agent(agent_id, runtime, permission, resource)
      when is_binary(agent_id) and is_binary(permission) do
    if valid_id?(agent_id) and any_grants?([agent_id]),
      do: check(agent_id, runtime, permission, resource),
      else: :ok
  end

  # ── the decision: two Access.check/3 calls ───────────────────────────

  defp check(agent_id, runtime, permission, resource) do
    with :ok <- Access.check(owner_scope(runtime), permission, resource) do
      Access.check(agent_scope(agent_id, runtime), permission, resource)
    end
  end

  defp owner_scope(%AgentRuntime{owner_user_id: owner}) when is_binary(owner),
    do: Scope.for_user(%{id: owner})

  defp owner_scope(_runtime), do: nil

  defp agent_scope(_agent_id, %AgentRuntime{} = runtime), do: Scope.for_runtime(runtime)

  defp agent_scope(agent_id, nil),
    do: %Scope{
      actor: {:agent, agent_id},
      grants: Grants.list_for_principals([{:agent, agent_id}])
    }

  # ── the short-circuit ────────────────────────────────────────────────

  # ONE statement: does any grant exist for a principal either Scope of any
  # of these agents could load? See the moduledoc for why it over-matches.
  defp any_grants?(agent_ids) do
    linked =
      from(r in AgentRuntime,
        join: a in Agent,
        on: a.runtime_id == r.id,
        where: a.id in type(^agent_ids, {:array, :binary_id})
      )

    owners = from([r, _a] in linked, where: not is_nil(r.owner_user_id), select: r.owner_user_id)
    runtime_agents = from([r, _a] in linked, where: not is_nil(r.agent_id), select: r.agent_id)
    owner_orgs = from(m in OrgMembership, where: m.user_id in subquery(owners), select: m.org_id)

    Repo.exists?(
      from(g in Grant,
        where:
          (g.principal_type == "agent" and
             (g.principal_id in type(^agent_ids, {:array, :binary_id}) or
                g.principal_id in subquery(runtime_agents))) or
            (g.principal_type == "user" and g.principal_id in subquery(owners)) or
            (g.principal_type == "role" and g.org_id in subquery(owner_orgs))
      )
    )
  end

  defp runtimes_by_agent(agent_ids) do
    from(a in Agent,
      join: r in AgentRuntime,
      on: r.id == a.runtime_id,
      where: a.id in type(^agent_ids, {:array, :binary_id}),
      select: {a.id, r}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp valid_id?(id), do: is_binary(id) and Platform.UUID.valid?(id)
end
