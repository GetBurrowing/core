defmodule Platform.Org.MemoryEntry do
  @moduledoc """
  Schema for org-level memory entries — short-lived, append-only notes.

  Entries surface in agent context as `ORG_NOTES-YYYY-MM-DD` (last 2 days).
  For curated long-term knowledge, use `ORG_MEMORY.md` via `Platform.Org.Context.upsert_context_file/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_memory_entries" do
    field(:workspace_id, :binary_id)
    field(:date, :date)
    field(:content, :string)
    field(:authored_by, :binary_id)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(content date)a
  @optional ~w(workspace_id authored_by metadata)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
