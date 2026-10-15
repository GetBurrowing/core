defmodule Platform.Access.MemoryNodeMerge do
  @moduledoc """
  Re-points the grants of a DISPLACED memory node onto the node that
  displaced it (task 01a1386d-e528 stage 1,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  `Platform.Org.Wiki.Nodes.move/3` calls `merge/2` when a single-page rename
  overwrites a page whose location already has its own node. The displaced
  node's interval is closed and its grants move to the moved node. When both
  nodes hold a grant for the same (principal, permission) tuple and one of
  them is a deny, the deny is kept and the allow dropped, as an explicit step,
  so the merge fails closed.

  This lives under `Platform.Access` because it compares grant EFFECTS, and
  `Platform.Access` is the only module that does. `Nodes` decides identity
  and never permission.

  ## Before `access_grants` exists

  The `access_grants` table is created by stage 2 of the same task. Until
  then there is nothing to re-point, and `merge/2` is a no-op: it looks the
  relation up with `to_regclass/1` and returns `:ok` when it is absent.
  Stage 2 owns the table and may replace these statements with queries on
  its schema; the column names here are the ones stage 2's plan specifies
  (`principal_type`, `principal_id`, `principal_role_key`, `permission`,
  `resource_type`, `resource_id`, `effect`).
  """

  alias Platform.Repo

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
  Moves every grant on `displaced_node_id` to `moved_node_id`, keeping a
  deny over an allow on the same tuple. Must run inside the rename's
  transaction. Returns `:ok`.
  """
  @spec merge(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def merge(displaced_node_id, moved_node_id)
      when is_binary(displaced_node_id) and is_binary(moved_node_id) do
    if grants_table?() do
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
    end

    :ok
  end

  defp grants_table? do
    %{rows: [[present?]]} =
      Repo.query!("SELECT to_regclass('access_grants') IS NOT NULL", [])

    present?
  end
end
