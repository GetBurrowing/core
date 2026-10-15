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
  this function with a column mapping, so no context compares effects.

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
      its node. A node covers a path when its path equals it, or is a
      prefix ending in `/` that the path starts with.
  """

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Platform.Access
  alias Platform.Access.{Permitted, Scope}

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
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_from <= ? AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NULL AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
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
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_from <= ? AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NOT DISTINCT FROM ? AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
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
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_from <= ? AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NULL AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
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
            "EXISTS (SELECT 1 FROM org_memory_node_paths np WHERE np.node_id = ANY(?) AND np.valid_from <= ? AND (np.valid_to IS NULL OR np.valid_to > ?) AND np.workspace_id IS NOT DISTINCT FROM ? AND (np.path = ? OR (right(np.path, 1) = '/' AND starts_with(?, np.path))))",
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
