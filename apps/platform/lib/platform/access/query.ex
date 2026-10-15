defmodule Platform.Access.Query do
  @moduledoc """
  The one place an access decision becomes an Ecto condition (task
  01a1386d-e528 stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`).

  `where_permitted/5` asks `Platform.Access.permitted/3` for the
  grant-aware set (inheritance already expanded there, through
  `Platform.Access.Lineage`) and expresses deny-wins once:

      (allow == :all OR column IN allow) AND column NOT IN deny

  Every context's `scope_by/3` (stack member 3 stages 3-4) is a thin call to
  this function, to `where_readable/5`, or to `restrict/5` (the same
  deny-wins condition composed with a surface's existing check) with a
  column mapping, so no context compares effects.

  ## Column mappings

    * id types (`:project`, `:task`, `:stack`, `:space`, `:canvas`):
      `%{id: :id}` — the column of the query's root binding holding the
      resource id.
    * memory (`:memory_page`): `%{path: :file_key}` plus optional
      `workspace_id: column` (default: nodes with a NULL workspace, as
      `Platform.Org.Wiki.Nodes` reads by default) and optional `at:`, a
      column (for example a feedback row's `:inserted_at`) or a `DateTime`.
      Without `:at` the predicate reads CURRENT node paths
      (`valid_to IS NULL`); with it, the interval that covered the row's
      path at that instant, so a row recorded before a rename still reaches
      its node. A node's FIRST interval is open backward (task
      01a1386d-e528 stage 4): nodes are created on demand, when a grant is
      first made, so a row recorded at that location before the grant
      existed still reaches the node, as `Platform.Org.Wiki.Nodes.resolve/2`
      reads it. A node covers a path when its path equals it, or is a
      prefix ending in `/` that the path starts with.
  """

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Platform.Access
  alias Platform.Access.{Permitted, Scope}
  alias Platform.Agents.AgentRuntime

  @memory_types [:memory_page, :memory_node]

  @doc """
  Restrict `query` (its root binding) to the `resource_type` rows `scope`
  may `permission`. See the moduledoc for `column_mapping`.
  """
  @spec where_permitted(Ecto.Queryable.t(), Scope.t(), String.t(), atom(), map()) ::
          Ecto.Query.t()
  def where_permitted(query, %Scope{} = scope, permission, resource_type, column_mapping) do
    permitted = Access.permitted(scope, permission, resource_type)
    from(r in query, where: ^condition(permitted, Map.new(column_mapping)))
  end

  @doc """
  Restrict `query` with explicit grants IN CONJUNCTION WITH the surface's
  existing check (task 01a1386d-e528 stage 3). The ADR names this function
  `restrict/5`, "which short-circuits" `where_permitted/5`:
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Decisions`.

  The existing check stands in for the role-rule allow (step 3 of the
  moduledoc order in `Platform.Access`):

    * **No grant names `permission`** → the query is returned unchanged, or,
      when `column_mapping` carries `:base`, with `where: ^base` and nothing
      else. A grant-less scope therefore reads exactly what the surface read
      before this stage.
    * **Grants apply** → `(base OR column IN allow) AND column NOT IN deny`,
      over `Platform.Access.granted/3` (explicit grants only, inheritance
      expanded). Deny wins.

  `column_mapping` is `%{id: column}` plus an optional `:base`, an Ecto
  `dynamic` on the root binding that IS the existing check (for example a
  guest's live `chat_participants` subquery). Without `:base` the existing
  check is whatever the query already filters on, an allow can add nothing
  to it, and only denies narrow it. Pass `:base` where an allow must be able
  to widen past the check (an inherited execution space for a guest).
  """
  @spec restrict(Ecto.Queryable.t(), Scope.t(), String.t(), atom(), map()) ::
          Ecto.Queryable.t()
  def restrict(query, %Scope{} = scope, permission, resource_type, column_mapping) do
    mapping = Map.new(column_mapping)
    base = Map.get(mapping, :base)

    cond do
      Access.grants_apply?(scope, permission) and resource_type in @memory_types ->
        granted = Access.granted(scope, permission, resource_type)
        from(r in query, where: ^restrict_memory_condition(granted, mapping, base))

      Access.grants_apply?(scope, permission) or Access.restriction_ids(scope, permission, resource_type) != [] ->
        granted = Access.granted(scope, permission, resource_type)
        from(r in query, where: ^restrict_condition(granted, mapping, base))

      is_nil(base) ->
        query

      true ->
        from(r in query, where: ^base)
    end
  end

  @doc """
  The listing form a context's `scope_by/3` uses (task 01a1386d-e528
  stage 3): `where_permitted/5` for every scope but an agent runtime's, and
  `restrict/5` (no `:base`) for a runtime's.

  A runtime's Scope (member 2's `for_runtime/1`) carries `mcp.<bundle>` and
  `chat.read` only, never `tasks.read` or `canvas.read`, until stack member 5
  caps it at its owner (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Agents`). Its MCP tool authorization is the
  existing check its listings pass today, so a runtime's listing keeps
  today's rows with no grant and loses what an agent-principal deny covers.
  An agent-principal ALLOW therefore adds nothing to a runtime listing in
  this member: today's check already admits every row.

  ## Memory (`:memory_page`, task 01a1386d-e528 stage 4)

  Org memory's surfaces carry no role check today: the memory MCP tools,
  `Platform.Org.Wiki` and `Platform.MemoryFeedback` read every page for
  every caller, and a guest (who holds no `memory.read` role rule) is kept
  off `/org_memory` by the rail, not by a row filter. So for memory:

    * **no grant names the permission** → the query is returned UNCHANGED
      for every scope, user or runtime. A grant-less scope reads exactly
      what the surface read before;
    * a runtime's Scope → `restrict/5` with no `:base`: only a deny narrows;
    * any other Scope → `where_permitted/5`: the role rule (`:all` for an
      internal member) or an explicit allow covers the path, and no deny
      covers it. A guest holding grants therefore reads only what its
      allows cover.
  """
  @spec where_readable(Ecto.Queryable.t(), Scope.t(), String.t(), atom(), map()) ::
          Ecto.Queryable.t()
  def where_readable(query, %Scope{} = scope, permission, type, mapping)
      when type in @memory_types do
    cond do
      not Access.grants_apply?(scope, permission) ->
        query

      match?(%Scope{actor: %AgentRuntime{}}, scope) ->
        restrict(query, scope, permission, type, Map.delete(Map.new(mapping), :base))

      true ->
        where_permitted(query, scope, permission, type, mapping)
    end
  end

  def where_readable(query, %Scope{actor: %AgentRuntime{}} = scope, permission, type, mapping),
    do: restrict(query, scope, permission, type, Map.delete(Map.new(mapping), :base))

  def where_readable(query, %Scope{} = scope, permission, type, mapping),
    do: where_permitted(query, scope, permission, type, mapping)

  # Memory: `(base OR an allow node covers the path) AND no deny node covers
  # it`; with no `:base`, an allow adds nothing and only denies narrow.
  defp restrict_memory_condition(%Permitted{allow: allow, deny: deny}, mapping, base) do
    allowed =
      case {base, allow} do
        {nil, _} -> dynamic([r], true)
        {base, []} -> base
        {base, ids} -> dynamic([r], ^base or ^covered(ids, mapping))
      end

    case deny do
      [] -> allowed
      ids -> dynamic([r], ^allowed and not (^covered(ids, mapping)))
    end
  end

  defp restrict_condition(%Permitted{allow: allow, deny: deny}, mapping, base) do
    col = Map.fetch!(mapping, :id)

    allowed =
      case {base, allow} do
        {nil, _} -> dynamic([r], true)
        {base, []} -> base
        {base, ids} -> dynamic([r], ^base or field(r, ^col) in ^ids)
      end

    case deny do
      [] -> allowed
      ids -> dynamic([r], ^allowed and field(r, ^col) not in ^ids)
    end
  end

  @doc """
  The Ecto `dynamic` for a `%Permitted{}` on the root binding. Exposed for
  callers composing it with other conditions.
  """
  @spec condition(Permitted.t(), map()) :: Ecto.Query.dynamic_expr()
  def condition(%Permitted{resource_type: :memory_node, allow: allow, deny: deny}, mapping) do
    allowed = if allow == :all, do: dynamic([r], true), else: covered(allow, mapping)

    case deny do
      [] -> allowed
      ids -> dynamic([r], ^allowed and not (^covered(ids, mapping)))
    end
  end

  def condition(%Permitted{allow: allow, deny: deny}, mapping) do
    col = Map.fetch!(mapping, :id)

    allowed =
      case allow do
        :all -> dynamic([r], true)
        [] -> dynamic([r], false)
        ids -> dynamic([r], field(r, ^col) in ^ids)
      end

    case deny do
      [] -> allowed
      ids -> dynamic([r], ^allowed and field(r, ^col) not in ^ids)
    end
  end

  # ── memory: does a node in `ids` cover the row's path? ────────────────

  defp covered([], _mapping), do: dynamic([r], false)

  defp covered(ids, mapping) do
    path = Map.fetch!(mapping, :path)
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)

    case {Map.get(mapping, :at), Map.get(mapping, :workspace_id)} do
      {nil, nil} ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_to IS NULL AND np.workspace_id IS NULL AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            field(r, ^path),
            field(r, ^path)
          )
        )

      {nil, ws} ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_to IS NULL AND np.workspace_id IS NOT DISTINCT FROM ? AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            field(r, ^ws),
            field(r, ^path),
            field(r, ^path)
          )
        )

      {%DateTime{} = at, nil} ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND (np.valid_from <= ? OR NOT EXISTS (SELECT 1 FROM org_memory_node_paths np0 WHERE np0.node_id = np.node_id AND np0.valid_from < np.valid_from)) AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NULL AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            ^at,
            ^at,
            field(r, ^path),
            field(r, ^path)
          )
        )

      {%DateTime{} = at, ws} ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND (np.valid_from <= ? OR NOT EXISTS (SELECT 1 FROM org_memory_node_paths np0 WHERE np0.node_id = np.node_id AND np0.valid_from < np.valid_from)) AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NOT DISTINCT FROM ? AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            ^at,
            ^at,
            field(r, ^ws),
            field(r, ^path),
            field(r, ^path)
          )
        )

      {at, nil} when is_atom(at) ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND (np.valid_from <= ? OR NOT EXISTS (SELECT 1 FROM org_memory_node_paths np0 WHERE np0.node_id = np.node_id AND np0.valid_from < np.valid_from)) AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NULL AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            field(r, ^at),
            field(r, ^at),
            field(r, ^path),
            field(r, ^path)
          )
        )

      {at, ws} when is_atom(at) ->
        dynamic(
          [r],
          fragment(
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND (np.valid_from <= ? OR NOT EXISTS (SELECT 1 FROM org_memory_node_paths np0 WHERE np0.node_id = np.node_id AND np0.valid_from < np.valid_from)) AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NOT DISTINCT FROM ? AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
            ^ids,
            field(r, ^at),
            field(r, ^at),
            field(r, ^ws),
            field(r, ^path),
            field(r, ^path)
          )
        )
    end
  end
end
