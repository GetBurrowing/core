defmodule Platform.Repo.Migrations.AddSocialClosingVideos do
  use Ecto.Migration

  def change do
    alter table(:social_profiles) do
      add(:closing_video, :map, null: false, default: %{})
    end

    create table(:social_closing_assets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # Keep provenance even after an explicit later Files purge; no cascading file FK.
      add(:file_id, :binary_id, null: false)
      add(:content_hash, :text, null: false)
      add(:byte_size, :bigint, null: false)
      add(:duration_s, :float, null: false)
      add(:width, :integer, null: false)
      add(:height, :integer, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:social_closing_assets, [:profile_id, :file_id]))
    create(index(:social_closing_assets, [:file_id]))

    create(
      constraint(:social_closing_assets, :closing_measurements_positive,
        check:
          "byte_size > 0 AND byte_size <= 209715200 AND duration_s > 0 AND width > 0 AND height > 0"
      )
    )
  end
end
