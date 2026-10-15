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

  ## Every write is ledgered (task 01a1386e-30bd stage 1)

  `grant/2`, `deny/2` and `revoke/2` take `actor:` (a `%Platform.Access.Scope{}`,
  required) and `via_agent_id:`, and run through
  `Platform.Access.Changes.commit/4`, which writes the
  `Platform.Access.Change` row with the exact before/after rows in the same
  transaction. The arity-1 forms act as `Scope.system/0` (recorded
  `actor_type: "system"`). `merge_memory_nodes/2` is recorded as a
  `system_repoint` change when it moves or drops any row.

  A non-system actor's write is delegated (task 01a1386e-30bd stage 2):
  `Platform.Access.Delegation` refuses it with
  `{:error, %{missing:, resource:, rule:}}`, writing nothing, unless the
  actor holds `access.manage` on the resource (and, for a widening change,
  the permission itself), and unless it would leave a managed resource with
  no manager.

  ## Precedence is not here

  `merge_memory_nodes/2` keeps a deny over an allow when two nodes' grants
  merge, as the explicit merge step the ADR requires. Every DECISION reads
  grants in `Platform.Access` (`can?/3`, `permitted/3`) and
  `Platform.Access.Query`.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Platform.Access.{Changes, Grant, Role, RoleAssignment, Scope}
  alias Platform.Tenancy.OrgMembership
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
  #
  # Every write goes through `Platform.Access.Changes.commit/4`, the one
  # writer to `access_grants` (task 01a1386e-30bd stage 1): the change row
  # with its before/after snapshot is written in the same transaction.

  @doc """
  Insert an `allow` grant as `Platform.Access.Scope.system/0` (recorded
  `actor_type: "system"`). Equivalent to `grant(attrs, actor: Scope.system())`.
  """
  @spec grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def grant(attrs), do: grant(attrs, actor: Scope.system())

  @doc """
  Insert an `allow` grant as `opts[:actor]` (a `%Scope{}`, required), with
  `opts[:via_agent_id]` recorded on the ledger row. See the moduledoc for the
  accepted shapes. `granted_by` defaults to the actor's user id.
  """
  @spec grant(map(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def grant(attrs, opts), do: insert(attrs, "allow", "grant", opts)

  @doc "Insert a `deny` grant as `Platform.Access.Scope.system/0`."
  @spec deny(map()) :: {:ok, Grant.t()} | {:error, term()}
  def deny(attrs), do: deny(attrs, actor: Scope.system())

  @doc "Insert a `deny` grant as `opts[:actor]`. Options as `grant/2`."
  @spec deny(map(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def deny(attrs, opts), do: insert(attrs, "deny", "deny", opts)

  @doc """
  Delete a grant by struct or id as `Platform.Access.Scope.system/0`.
  `{:error, :not_found}` when absent.
  """
  @spec revoke(Grant.t() | binary()) :: {:ok, Grant.t()} | {:error, term()}
  def revoke(grant_or_id), do: revoke(grant_or_id, actor: Scope.system())

  @doc "Delete a grant by struct or id as `opts[:actor]`. Options as `grant/2`."
  @spec revoke(Grant.t() | binary(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def revoke(%Grant{id: id}, opts), do: revoke(id, opts)

  def revoke(id, opts) when is_binary(id) do
    actor = actor!(opts)

    with true <- Platform.UUID.valid?(id),
         %Grant{} = grant <- Repo.get(Grant, id) do
      key = Grant.tuple_key(grant)

      mutation = fn ->
        case Repo.get(Grant, id) do
          %Grant{} = current -> Repo.delete(current)
          nil -> {:error, :not_found}
        end
      end

      actor
      |> Changes.commit("revoke", mutation,
        query: tuple_query(grant),
        keys: [key],
        org_id: grant.org_id,
        via_agent_id: Keyword.get(opts, :via_agent_id)
      )
      |> unwrap()
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
  `access_role_assignments` row. A USER's assignment counts only while the
  user has an `org_memberships` row in the assignment's org (any row,
  internal or external), so an assignment in an org the user has since left
  holds nothing. An agent's assignments always count.

  Returns `{grants, assignments}`, grants ordered by id as
  `list_for_principals/1` orders them, and each assignment as
  `%{org_id, role_key, permissions}` (the custom role's permission map). With
  no principals and no actor it returns `{[], []}` without querying.
  """
  @spec list_for_actor([principal_key()], {:user | :agent, binary()} | nil) ::
          {[Grant.t()], [%{org_id: binary(), role_key: String.t(), permissions: map()}]}
  def list_for_actor(principals, actor)

  def list_for_actor([], nil), do: {[], []}

  def list_for_actor(principals, nil), do: {list_for_principals(principals), []}

  def list_for_actor(principals, {type, id}) when type in [:user, :agent] and is_binary(id) do
    type = Atom.to_string(type)

    held =
      from(a in RoleAssignment,
        as: :assignment,
        where:
          a.principal_type == ^type and a.principal_id == ^id and
            a.role_key == parent_as(:grant).principal_role_key and
            a.org_id == parent_as(:grant).org_id
      )
      |> held_by_member(type)

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
        as: :assignment,
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
      |> held_by_member(type)

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

  # A user's assignment holds only while a membership row joins it on
  # (user, org). This is the assignment's own provenance check, not a viewer
  # visibility scope: root-org widening must NOT extend it.
  defp held_by_member(query, "user") do
    membership =
      from(m in OrgMembership,
        where: m.user_id == parent_as(:assignment).principal_id,
        where: m.org_id == parent_as(:assignment).org_id
      )

    from(a in query, where: exists(subquery(membership)))
  end

  defp held_by_member(query, "agent"), do: query

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

  defp insert(attrs, effect, action, opts) do
    actor = actor!(opts)
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
          granted_by: Map.get(attrs, :granted_by) || actor_user_id(actor)
        })

      changeset = Grant.changeset(%Grant{}, fields)

      if changeset.valid? do
        tuple = Ecto.Changeset.apply_changes(changeset)

        actor
        |> Changes.commit(action, fn -> Repo.insert(changeset) end,
          query: tuple_query(tuple),
          keys: [Grant.tuple_key(tuple)],
          org_id: org_id,
          via_agent_id: Keyword.get(opts, :via_agent_id)
        )
        |> unwrap()
      else
        {:error, changeset}
      end
    end
  end

  defp actor!(opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, %Scope{} = actor} ->
        actor

      _ ->
        raise ArgumentError,
              "Platform.Access.Grants writes need `actor:` (a %Platform.Access.Scope{}); " <>
                "the arity-1 forms act as Scope.system/0"
    end
  end

  defp unwrap({:ok, %{result: result}}), do: {:ok, result}
  defp unwrap({:error, _} = error), do: error

  defp actor_user_id(%Scope{actor: %Platform.Accounts.User{id: id}}), do: id
  defp actor_user_id(_), do: nil

  # The rows of one (principal, permission, resource) tuple: at most one,
  # by the access_grants unique index.
  defp tuple_query(%Grant{} = g) do
    base =
      from(r in Grant,
        where:
          r.principal_type == ^g.principal_type and r.permission == ^g.permission and
            r.resource_type == ^g.resource_type and r.resource_id == ^g.resource_id
      )

    case g do
      %Grant{principal_id: nil, principal_role_key: key} ->
        from(r in base, where: is_nil(r.principal_id) and r.principal_role_key == ^key)

      %Grant{principal_id: pid} ->
        from(r in base, where: r.principal_id == ^pid and is_nil(r.principal_role_key))
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
    query =
      from(g in Grant,
        where:
          g.resource_type == "memory_node" and
            g.resource_id in ^[displaced_node_id, moved_node_id]
      )

    case Changes.commit(
           Scope.system(),
           "system_repoint",
           fn -> {:ok, repoint(displaced_node_id, moved_node_id)} end,
           query: query
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp repoint(displaced_node_id, moved_node_id) do
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
