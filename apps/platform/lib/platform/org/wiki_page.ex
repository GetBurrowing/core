defmodule Platform.Org.WikiPage do
  @moduledoc """
  Schema for org-level wiki pages.

  These pages are analogous to OpenClaw workspace files (SOUL.md, MEMORY.md)
  but scoped to the organization. Agents read and write them to maintain
  shared organizational context.

  `file_key` is a free-form path-like string (e.g. `org/identity.md`,
  `project/abc-123/decisions.md`). Uniqueness is enforced by the
  `(workspace_id, file_key)` index; no module-level whitelist constrains it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_wiki_pages" do
    field(:workspace_id, :binary_id)
    field(:file_key, :string)
    field(:content, :string, default: "")
    field(:frontmatter, :map, default: %{})
    field(:version, :integer, default: 1)
    field(:updated_by, :binary_id)

    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:project, Platform.Tasks.Project)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(file_key)a
  @optional ~w(workspace_id content frontmatter version updated_by org_id project_id)a

  def changeset(wiki_page, attrs) do
    wiki_page
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> maybe_default_org_id()
    |> validate_required([:org_id])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:workspace_id, :file_key],
      name: :org_wiki_pages_workspace_id_file_key_index
    )
  end

  # ADR 0042: org_id is required at the DB level. Legacy callers that don't
  # yet pass org_id are silently attached to the install's root org so
  # existing write paths keep working while we migrate them. Resolved
  # structurally via `Platform.Tenancy.get_root_org/0` (`parent_org_id IS
  # NULL`) — resolving by slug instead (task 01a068f6) meant an install
  # whose root org was not literally "fabrikam" resolved nil here and wrote
  # the row unowned.
  defp maybe_default_org_id(changeset) do
    case Ecto.Changeset.get_field(changeset, :org_id) do
      nil ->
        case Platform.Tenancy.get_root_org() do
          %Platform.Tenancy.Org{id: id} -> Ecto.Changeset.put_change(changeset, :org_id, id)
          nil -> changeset
        end

      _ ->
        changeset
    end
  end

  @doc """
  Changeset for upserts with optimistic locking on version.
  Increments version on each update.

  `:org_id` / `:project_id` are castable here (task 01a0008c stage 2)
  so a row whose tenancy is wrong can be repaired by rewriting it.
  Before this, they were castable on insert and nowhere else, which
  made `maybe_default_org_id/1`'s Fabrikam fallback a **permanent** state
  for any page written at a tenant path — the path said one tenant,
  the row said another, and no write through `Wiki.upsert_page/3`
  could ever move it back.

  There is no re-defaulting on this path: an update that does not
  mention the keys leaves them exactly as they are. `Wiki.upsert_page/3`
  only forwards keys its caller actually supplied, so this widening
  cannot move a page that nobody asked to move.
  """
  def update_changeset(wiki_page, attrs) do
    wiki_page
    |> cast(attrs, [:content, :frontmatter, :updated_by, :org_id, :project_id])
    |> validate_required([:content, :org_id])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
    |> optimistic_lock(:version)
  end

  @doc """
  Deprecated. Returns an empty list — `file_key` is no longer constrained
  to a hardcoded whitelist. Kept exported so legacy V1 callers don't crash;
  T5 removes both this and the V1 federation tools that referenced it.
  """
  @deprecated "file_key is no longer whitelist-constrained; this returns []"
  def allowed_file_keys, do: []

  @doc """
  Deprecated. Alias for `allowed_file_keys/0`.
  """
  @deprecated "file_key is no longer whitelist-constrained; this returns []"
  def valid_file_keys, do: []
end
