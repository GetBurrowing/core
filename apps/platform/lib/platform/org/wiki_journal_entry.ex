defmodule Platform.Org.WikiJournalEntry do
  @moduledoc """
  Schema for org-level wiki journal entries — short-lived, append-only notes.

  Entries surface in agent context as `ORG_NOTES-YYYY-MM-DD` (last 2 days).
  For curated long-term knowledge, use `org/memory.md` via `Platform.Org.Context.upsert_context_file/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_wiki_journal_entries" do
    field(:workspace_id, :binary_id)
    field(:date, :date)
    field(:content, :string)
    field(:authored_by, :binary_id)
    field(:metadata, :map, default: %{})

    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:project, Platform.Tasks.Project)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(content date)a
  @optional ~w(workspace_id authored_by metadata org_id project_id)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> maybe_default_org_id()
    |> validate_required([:org_id])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
  end

  # ADR 0042: org_id is required at the DB level. Legacy callers that don't
  # yet pass org_id are silently attached to the install's root org so
  # existing write paths keep working while we migrate them. Resolved
  # structurally via `Platform.Tenancy.get_root_org/0` (`parent_org_id IS
  # NULL`) — resolving by slug instead (task 01a068f6) meant an install
  # whose root org did not carry the expected slug resolved nil here and wrote
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
end
