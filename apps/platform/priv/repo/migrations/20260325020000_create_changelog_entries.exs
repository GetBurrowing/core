defmodule Platform.Repo.Migrations.CreateChangelogEntries do
  use Ecto.Migration

  def change do
    create table(:changelog_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:pr_number, :integer)
      add(:pr_url, :string)
      add(:commit_sha, :string)
      add(:author, :string)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :nilify_all))
      add(:tags, {:array, :string}, default: [], null: false)
      add(:merged_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:changelog_entries, [:pr_number]))
    create(index(:changelog_entries, [:merged_at]))
    create(index(:changelog_entries, [:task_id]))
  end
end
