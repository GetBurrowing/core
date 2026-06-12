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

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(file_key)a
  @optional ~w(workspace_id content frontmatter version updated_by)a

  def changeset(wiki_page, attrs) do
    wiki_page
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:workspace_id, :file_key],
      name: :org_wiki_pages_workspace_id_file_key_index
    )
  end

  @doc """
  Changeset for upserts with optimistic locking on version.
  Increments version on each update.
  """
  def update_changeset(wiki_page, attrs) do
    wiki_page
    |> cast(attrs, [:content, :frontmatter, :updated_by])
    |> validate_required([:content])
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
