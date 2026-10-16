defmodule Platform.Org.Wiki.Node do
  @moduledoc """
  A stable identity for an org-memory LOCATION: a page path or a directory
  prefix ending in `/` (task 01a1386d-e528,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  A node is not a page. `org_wiki_pages` rows keep their own ids and
  semantics; a node outlives the page at its location (deleting a page keeps
  the node) and follows renames through its `Platform.Org.Wiki.NodePath`
  history. Grants anchor here, never on a path string.

  `path` is a virtual field that `Platform.Org.Wiki.Nodes` fills with the
  location the node occupied at the instant it was read.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "org_memory_nodes" do
    field(:workspace_id, :binary_id)
    field(:path, :string, virtual: true)

    belongs_to(:org, Platform.Tenancy.Org)
    has_many(:paths, Platform.Org.Wiki.NodePath)

    timestamps(type: :utc_datetime_usec)
  end
end
