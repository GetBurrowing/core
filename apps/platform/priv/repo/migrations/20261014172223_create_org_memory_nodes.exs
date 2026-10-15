defmodule Platform.Repo.Migrations.CreateOrgMemoryNodes do
  @moduledoc """
  Task 01a1386d-e528 stage 1 (stack `rbac-roles`), recorded in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`:
  a stable identity for org-memory LOCATIONS, so a resource grant anchors to
  a node and follows renames instead of matching a path string.

    * `org_memory_nodes` — one row per location identity (`id` uuidv7,
      nullable `workspace_id`, `org_id` FK to `orgs`). A node can name a page
      path or a directory prefix ending in `/`.
    * `org_memory_node_paths` — the path history of each node: one interval
      `[valid_from, valid_to)` per location the node has occupied. A rename
      closes the current interval and opens a new one, so a reader holding a
      timestamp (a feedback row recorded before the rename) still reaches the
      node it was about.

  ## At most one current node per location

  A partial unique index on `(workspace_id, path) WHERE valid_to IS NULL`.
  `workspace_id` is NULL for every org-scoped page, and under the default
  `NULLS DISTINCT` two org-scoped current rows for one path would both insert.
  The index is therefore `NULLS NOT DISTINCT`, which is Postgres 15 syntax;
  `require_pg15!/0` runs first, mirroring
  `20260924160000_add_experiment_surfaces_and_signals`.

  ## Nothing existing changes

  Both tables are new and empty. No existing table, column or row is touched,
  so no production data changes meaning. `org_wiki_pages` keeps its
  semantics. Nodes are created on demand by grant creation, never on page
  write. `down/0` drops both tables.
  """

  use Ecto.Migration

  def up do
    require_pg15!()

    create table(:org_memory_nodes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_id, :uuid)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:org_memory_nodes, [:org_id]))

    create table(:org_memory_node_paths, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:node_id, references(:org_memory_nodes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, :uuid)
      add(:path, :text, null: false)
      add(:valid_from, :utc_datetime_usec, null: false)
      add(:valid_to, :utc_datetime_usec)
    end

    create(index(:org_memory_node_paths, [:node_id]))
    create(index(:org_memory_node_paths, [:workspace_id, :path, :valid_from]))

    create(
      unique_index(:org_memory_node_paths, [:workspace_id, :path],
        where: "valid_to IS NULL",
        nulls_distinct: false,
        name: :org_memory_node_paths_current_location_index
      )
    )

    create(
      constraint(:org_memory_node_paths, :org_memory_node_paths_interval_check,
        check: "valid_to IS NULL OR valid_to >= valid_from"
      )
    )
  end

  def down do
    drop(table(:org_memory_node_paths))
    drop(table(:org_memory_nodes))
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. The at-most-one-current-
      node-per-location index on org_memory_node_paths cannot be built without it.
      Upgrade the server.
      """
    end
  end
end
