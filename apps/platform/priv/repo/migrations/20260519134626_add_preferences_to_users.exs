defmodule Platform.Repo.Migrations.AddPreferencesToUsers do
  use Ecto.Migration

  # Chat plan v2 Stage 3 — per-user UI preferences stored as a single JSONB
  # blob on the users row. Today this holds `chat_section_order` (the user's
  # drag-reorder of sub-org sections in the chat rail); future stages can
  # share the same column for other lightweight UI prefs (theme overrides,
  # collapsed-sections, etc.) without a new migration each time.
  #
  # Default `%{}` keeps the column non-null so callers can always read it
  # as a map without nil-guards. Postgres JSONB → Ecto `:map`.
  def change do
    alter table(:users) do
      add_if_not_exists(:preferences, :map, default: %{}, null: false)
    end
  end
end
