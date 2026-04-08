defmodule Platform.Org.ContextFile do
  @moduledoc """
  Schema for org-level context files (ORG_IDENTITY.md, ORG_MEMORY.md, etc.).

  These files are analogous to OpenClaw workspace files (SOUL.md, MEMORY.md)
  but scoped to the organization. Agents read and write them to maintain
  shared organizational context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_context_files" do
    field(:workspace_id, :binary_id)
    field(:file_key, :string)
    field(:content, :string, default: "")
    field(:version, :integer, default: 1)
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(file_key)a
  @optional ~w(workspace_id content version updated_by)a

  def changeset(context_file, attrs) do
    context_file
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:file_key, allowed_file_keys())
    |> unique_constraint([:workspace_id, :file_key],
      name: :org_context_files_workspace_id_file_key_index
    )
  end

  @doc """
  Changeset for upserts with optimistic locking on version.
  Increments version on each update.
  """
  def update_changeset(context_file, attrs) do
    context_file
    |> cast(attrs, [:content, :updated_by])
    |> validate_required([:content])
    |> optimistic_lock(:version)
  end

  @doc "List of allowed file keys for org context files."
  def allowed_file_keys do
    ~w(ORG_IDENTITY.md ORG_MEMORY.md ORG_AGENTS.md ORG_DIRECTORY.md)
  end
end
