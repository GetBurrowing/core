defmodule Platform.Repo.Migrations.CreateSocialWeeklyNoteRequests do
  use Ecto.Migration

  def change do
    create table(:social_weekly_note_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:week_start, :date, null: false)
      add(:request_sent, :boolean, null: false, default: false)
      add(:link_sent, :boolean, null: false, default: false)
      add(:claim_until, :utc_datetime_usec)
      add(:claim_token, :binary_id)
    end

    create(unique_index(:social_weekly_note_requests, [:profile_id, :week_start]))
  end
end
