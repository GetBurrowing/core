defmodule Platform.Repo.Migrations.CreateSocialWeeklyNotes do
  @moduledoc "Social authoring 11/11 (task 01a16c52): measured weekly suggestions and human decisions."
  use Ecto.Migration

  def change do
    create table(:social_weekly_notes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:week_start, :date, null: false)
      add(:author_kind, :text, null: false)
      add(:author_id, :binary_id)
      add(:summary, :text, null: false)
      # embeds_many serializes as a JSONB list, not a PostgreSQL jsonb[].
      add(:items, :map, null: false, default: fragment("'[]'::jsonb"))
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:social_weekly_notes, [:profile_id, :week_start]))
    create(index(:social_weekly_notes, [:org_id]))

    create(
      constraint(:social_weekly_notes, :social_weekly_notes_author_check,
        check:
          "(author_kind = 'agent' AND author_id IS NOT NULL) OR (author_kind = 'system' AND author_id IS NULL)"
      )
    )

    create(
      constraint(:social_weekly_notes, :social_weekly_notes_summary_check,
        check: "char_length(btrim(summary)) BETWEEN 1 AND 2000"
      )
    )

    create(
      constraint(:social_weekly_notes, :social_weekly_notes_items_check,
        check: "jsonb_typeof(items) = 'array'"
      )
    )

    create(
      constraint(:social_weekly_notes, :social_weekly_notes_monday_check,
        check: "extract(isodow from week_start) = 1"
      )
    )
  end
end
