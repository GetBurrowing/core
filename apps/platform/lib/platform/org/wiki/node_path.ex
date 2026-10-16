defmodule Platform.Org.Wiki.NodePath do
  @moduledoc """
  One interval of a `Platform.Org.Wiki.Node`'s path history (task
  01a1386d-e528, `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  The node occupied `path` during `[valid_from, valid_to)`. `valid_to` is
  `nil` for the node's current location; the partial unique index
  `org_memory_node_paths_current_location_index` allows at most one current
  node per `(workspace_id, path)`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "org_memory_node_paths" do
    field(:workspace_id, :binary_id)
    field(:path, :string)
    field(:valid_from, :utc_datetime_usec)
    field(:valid_to, :utc_datetime_usec)

    belongs_to(:node, Platform.Org.Wiki.Node)
  end

  @doc "Changeset for opening a new interval."
  def open_changeset(node_path, attrs) do
    node_path
    |> cast(attrs, [:node_id, :workspace_id, :path, :valid_from])
    |> validate_required([:node_id, :path, :valid_from])
    |> foreign_key_constraint(:node_id)
    |> unique_constraint([:workspace_id, :path],
      name: :org_memory_node_paths_current_location_index
    )
  end
end
