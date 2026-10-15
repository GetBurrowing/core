defmodule Platform.Access.Grants do
  @moduledoc """
  The context API for `access_grants` (task 01a1386d-e528 stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`). Grants are
  created through this module only: there is no grant MCP tool and no UI in
  this stack member.

      Grants.grant(%{principal: user, permission: "tasks.read", resource: {:project, id}})
      Grants.deny(%{principal: {:role, "guest"}, permission: "canvas.read", resource: {:canvas, id}})
      Grants.grant(%{principal: user, permission: "memory.read", resource: {:memory, "org/page/eng/"}})

  ## Principals

    * a `%Platform.Accounts.User{}` or `{:user, id}`;
    * an `%Platform.Agents.AgentRuntime{}` (its `agent_id`), an
      `%Platform.Agents.Agent{}`, or `{:agent, id}`. An agent's grants are
      its OWN; they are not intersected with its owner's (agent capping is
      stack position 5);
    * `{:role, key}` — every holder of `key` in the grant's `org_id`.

  ## Resources

  `{:project, id}`, `{:space, id}`, `{:canvas, id}` (or the matching
  structs), `{:memory, path}` and `{:memory_node, node_id}`.

  **A memory grant stores the NODE id, never the path.** `{:memory, path}`
  calls `Platform.Org.Wiki.Nodes.ensure/2` and stores the node it returns, so
  the grant follows renames (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).
  `ensure/2` recovers from a concurrent-create race only when no transaction
  surrounds it; `grant/1` calls it before its own insert and outside any
  transaction of its own, so call `grant/1` outside a transaction too.

  A bare namespace root (`org/page/`, `project/<uuid>/page/`,
  `space/<uuid>/page/`) is not a node (`Wiki.Routing.classify/1` does not
  classify it as a page), so a grant on a whole namespace is refused with
  `{:error, :namespace_root}`. Namespace-wide reach is a role rule
  (`memory.read :all`), not a grant.

  ## org_id

  Every row carries the resource's org: the project's, the space's, the
  canvas's space's, or the node's. When that is NULL (an org-less space) it
  falls back to the install's root org. A role grant applies to holders of
  the role key in that org. Pass `:org_id` to override.

  ## Precedence is not here

  `merge_memory_nodes/2` keeps a deny over an allow when two nodes' grants
  merge, as the explicit merge step the ADR requires. Every DECISION reads
  grants in `Platform.Access` (`can?/3`, `permitted/3`) and
  `Platform.Access.Query`.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Platform.Access.{Grant, Role, RoleAssignment}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat.{Canvas, Space}
  alias Platform.Org.Wiki.{Node, Nodes}
  alias Platform.Repo
  alias Platform.Tasks.Project

  @namespace_root ~r{\A(org/page/|(project|space)/[^/]+/page/)\z}

  @typedoc "A principal as `list_for_principals/1` takes it."
  @type principal_key ::
          {:user, binary()} | {:agent, binary()} | {:role, String.t(), binary()}

  # ── writes ────────────────────────────────────────────────────────────

  @doc "Insert an `allow` grant. See the moduledoc for the accepted shapes."
  @spec grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def grant(attrs), do: insert(attrs, "allow")

  @doc "Insert a `deny` grant. See the moduledoc for the accepted shapes."
  @spec deny(map()) :: {:ok, Grant.t()} | {:error, term()}
  def deny(attrs), do: insert(attrs, "deny")

  @doc "Delete a grant by struct or id. `{:error, :not_found}` when absent."
  @spec revoke(Grant.t() | binary()) :: {:ok, Grant.t()} | {:error, :not_found}
  def revoke(%Grant{id: id}), do: revoke(id)

  def revoke(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Grant{} = grant <- Repo.get(Grant, id) do
      Repo.delete(grant)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Every grant whose principal is one of `principals`, in ONE query.
  `[]` with no principals, without querying.
  """
  @spec list_for_principals([principal_key()]) :: [Grant.t()]
  def list_for_principals([]), do: []

  def list_for_principals(principals) when is_list(principals) do
    condition =
      Enum.reduce(principals, false, fn
        {:user, id}, acc ->
          Ecto.Query.dynamic(
            [g],
            ^acc or (g.principal_type == "user" and g.principal_id == ^id)
          )

        {:agent, id}, acc ->
          Ecto.Query.dynamic(
            [g],
            ^acc or (g.principal_type == "agent" and g.principal_id == ^id)
          )

        {:role, key, org_id}, acc ->
          Ecto.Query.dynamic(
            [g],
            ^acc or
              (g.principal_type == "role" and g.principal_role_key == ^key and
                 g.org_id == ^org_id)
          )
      end)

    Repo.all(from(g in Grant, where: ^condition, order_by: [asc: g.id]))
  end

  @doc """
  `list_for_principals/1` plus the actor's custom-role assignments, in the
  SAME ONE query (task `01a1386e-59d1` stage 1). `actor` is `{:user, id}` or
  `{:agent, id}`: the grants returned also include every role-principal
  grant whose `(principal_role_key, org_id)` the actor holds through an
  `access_role_assignments` row. `assignment_orgs` bounds which assignments
  count: a list of org ids (a user's membership orgs, so an assignment in an
  org the user has since left holds nothing), or `:any` (an agent).

  Returns `{grants, assignments}`, grants ordered by id as
  `list_for_principals/1` orders them, and each assignment as
  `%{org_id, role_key, permissions}` (the custom role's permission map). With
  no principals and no actor it returns `{[], []}` without querying.
  """
  @spec list_for_actor([principal_key()], {:user | :agent, binary()} | nil, [binary()] | :any) ::
          {[Grant.t()], [%{org_id: binary(), role_key: String.t(), permissions: map()}]}
  def list_for_actor(principals, actor, assignment_orgs)

  def list_for_actor([], nil, _assignment_orgs), do: {[], []}

  def list_for_actor(principals, nil, _assignment_orgs),
    do: {list_for_principals(principals), []}

  def list_for_actor(principals, {type, id}, assignment_orgs)
      when type in [:user, :agent] and is_binary(id) do
    type = Atom.to_string(type)

    held =
      from(a in RoleAssignment,
        where:
          a.principal_type == ^type and a.principal_id == ^id and
            a.role_key == parent_as(:grant).principal_role_key and
            a.org_id == parent_as(:grant).org_id
      )
      |> assignment_orgs_filter(assignment_orgs)

    condition =
      Ecto.Query.dynamic(
        [grant: g],
        ^principals_condition(principals) or
          (g.principal_type == "role" and exists(subquery(held)))
      )

    grants_q =
      from(g in Grant,
        as: :grant,
        where: ^condition,
        select: %{
          kind: type(^"grant", :string),
          id: g.id,
          org_id: g.org_id,
          principal_type: g.principal_type,
          principal_id: g.principal_id,
          principal_role_key: g.principal_role_key,
          permission: g.permission,
          resource_type: g.resource_type,
          resource_id: g.resource_id,
          effect: g.effect,
          granted_by: g.granted_by,
          inserted_at: g.inserted_at,
          role_permissions: type(^nil, :map)
        }
      )

    assignments_q =
      from(a in RoleAssignment,
        join: r in Role,
        on: r.key == a.role_key,
        where: a.principal_type == ^type and a.principal_id == ^id,
        select: %{
          kind: type(^"assignment", :string),
          id: a.id,
          org_id: a.org_id,
          principal_type: a.principal_type,
          principal_id: a.principal_id,
          principal_role_key: a.role_key,
          permission: type(^nil, :string),
          resource_type: type(^nil, :string),
          resource_id: type(^nil, :binary_id),
          effect: type(^nil, :string),
          granted_by: type(^nil, :binary_id),
          inserted_at: a.inserted_at,
          role_permissions: r.permissions
        }
      )
      |> assignment_orgs_filter(assignment_orgs)

    {grant_rows, assignment_rows} =
      grants_q
      |> Ecto.Query.union_all(^assignments_q)
      |> Repo.all()
      |> Enum.split_with(&(&1.kind == "grant"))

    grants =
      grant_rows
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn row ->
        Grant
        |> struct(Map.drop(row, [:kind, :role_permissions]))
        |> Ecto.put_meta(state: :loaded)
      end)

    assignments =
      assignment_rows
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn row ->
        %{org_id: row.org_id, role_key: row.principal_role_key, permissions: row.role_permissions}
      end)

    {grants, assignments}
  end

  defp assignment_orgs_filter(query, :any), do: query

  defp assignment_orgs_filter(query, org_ids) when is_list(org_ids),
    do: from(a in query, where: a.org_id in ^org_ids)

  defp principals_condition(principals) do
    Enum.reduce(principals, false, fn
      {:user, id}, acc ->
        Ecto.Query.dynamic(
          [g],
          ^acc or (g.principal_type == "user" and g.principal_id == ^id)
        )

      {:agent, id}, acc ->
        Ecto.Query.dynamic(
          [g],
          ^acc or (g.principal_type == "agent" and g.principal_id == ^id)
        )

      {:role, key, org_id}, acc ->
        Ecto.Query.dynamic(
          [g],
          ^acc or
            (g.principal_type == "role" and g.principal_role_key == ^key and
               g.org_id == ^org_id)
        )
    end)
  end

  defp insert(attrs, effect) do
    attrs = Map.new(attrs)

    with {:ok, principal} <- principal_fields(Map.get(attrs, :principal)),
         {:ok, {type, id, org_id}} <- resource_fields(Map.get(attrs, :resource)),
         {:ok, org_id} <- org_id(Map.get(attrs, :org_id) || org_id) do
      fields =
        Map.merge(principal, %{
          org_id: org_id,
          permission: Map.get(attrs, :permission),
          resource_type: type,
          resource_id: id,
          effect: effect,
          granted_by: Map.get(attrs, :granted_by)
        })

      %Grant{}
      |> Grant.changeset(fields)
      |> Repo.insert()
    end
  end

  defp principal_fields(%Platform.Accounts.User{id: id}), do: principal_fields({:user, id})

  defp principal_fields(%AgentRuntime{agent_id: id}) when is_binary(id),
    do: principal_fields({:agent, id})

  defp principal_fields(%Agent{id: id}), do: principal_fields({:agent, id})

  defp principal_fields({type, id}) when type in [:user, :agent] and is_binary(id),
    do: {:ok, %{principal_type: Atom.to_string(type), principal_id: id}}

  defp principal_fields({:role, key}) when is_binary(key),
    do: {:ok, %{principal_type: "role", principal_role_key: key}}

  defp principal_fields(_), do: {:error, :invalid_principal}

  defp resource_fields(%Project{id: id}), do: resource_fields({:project, id})
  defp resource_fields(%Space{id: id}), do: resource_fields({:space, id})
  defp resource_fields(%Canvas{id: id}), do: resource_fields({:canvas, id})

  # Every id below can arrive from a caller: a malformed one is not found,
  # never a query that raises.
  defp resource_fields({type, id})
       when type in [:project, :space, :canvas, :memory_node] and is_binary(id) do
    if Platform.UUID.valid?(id), do: fetch_resource(type, id), else: not_found()
  end

  defp resource_fields({:memory, path}) when is_binary(path) do
    if Regex.match?(@namespace_root, path) do
      {:error, :namespace_root}
    else
      case Nodes.ensure(path) do
        {:ok, %Node{id: id, org_id: org_id}} -> {:ok, {"memory_node", id, org_id}}
        {:error, _} = err -> err
      end
    end
  end

  defp resource_fields(_), do: {:error, :invalid_resource}

  defp fetch_resource(:project, id) do
    case Repo.one(from(p in Project, where: p.id == ^id, select: {p.id, p.org_id})) do
      {_, org_id} -> {:ok, {"project", id, org_id}}
      nil -> not_found()
    end
  end

  defp fetch_resource(:space, id) do
    case Repo.one(from(s in Space, where: s.id == ^id, select: {s.id, s.org_id})) do
      {_, org_id} -> {:ok, {"space", id, org_id}}
      nil -> not_found()
    end
  end

  defp fetch_resource(:canvas, id) do
    query =
      from(c in Canvas,
        left_join: s in Space,
        on: s.id == c.space_id,
        where: c.id == ^id,
        select: {c.id, s.org_id}
      )

    case Repo.one(query) do
      {_, org_id} -> {:ok, {"canvas", id, org_id}}
      nil -> not_found()
    end
  end

  defp fetch_resource(:memory_node, id) do
    case Repo.get(Node, id) do
      %Node{org_id: org_id} -> {:ok, {"memory_node", id, org_id}}
      nil -> not_found()
    end
  end

  defp not_found, do: {:error, :resource_not_found}

  defp org_id(org_id) when is_binary(org_id), do: {:ok, org_id}

  defp org_id(nil) do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> {:ok, id}
      nil -> {:error, :no_org}
    end
  end

  # ── node merge ────────────────────────────────────────────────────────

  @tuple_match """
  m.resource_type = 'memory_node'
  AND d.resource_type = 'memory_node'
  AND m.resource_id = $1
  AND d.resource_id = $2
  AND m.principal_type = d.principal_type
  AND m.principal_id IS NOT DISTINCT FROM d.principal_id
  AND m.principal_role_key IS NOT DISTINCT FROM d.principal_role_key
  AND m.permission = d.permission
  """

  @doc """
  Moves every grant on `displaced_node_id` to `moved_node_id`
  (`Platform.Org.Wiki.Nodes.move/3` calls it when a single-page rename
  overwrites a location that has its own node). When both nodes hold the
  same (principal, permission) tuple and either is a deny, the deny is kept
  and the allow dropped, so the merge fails closed. Must run inside the
  rename's transaction. Returns `:ok`.
  (Was `Platform.Access.MemoryNodeMerge`, stage 1, before the table existed.)
  """
  @spec merge_memory_nodes(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def merge_memory_nodes(displaced_node_id, moved_node_id)
      when is_binary(displaced_node_id) and is_binary(moved_node_id) do
    params = [Ecto.UUID.dump!(moved_node_id), Ecto.UUID.dump!(displaced_node_id)]

    # 1. A deny on the displaced node beats an allow on the moved node.
    Repo.query!(
      "DELETE FROM access_grants m USING access_grants d WHERE " <>
        @tuple_match <> " AND m.effect = 'allow' AND d.effect = 'deny'",
      params
    )

    # 2. Any tuple still present on the moved node wins over the displaced
    #    copy: after step 1 it is either a deny, or an allow facing an allow.
    Repo.query!(
      "DELETE FROM access_grants d USING access_grants m WHERE " <> @tuple_match,
      params
    )

    # 3. Everything left on the displaced node moves.
    Repo.query!(
      "UPDATE access_grants SET resource_id = $1 " <>
        "WHERE resource_type = 'memory_node' AND resource_id = $2",
      params
    )

    :ok
  end
end
