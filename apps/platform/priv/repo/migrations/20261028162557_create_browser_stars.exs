defmodule Platform.Repo.Migrations.CreateBrowserStars do
  use Ecto.Migration

  def change do
    alter table(:chat_canvases) do
      add(:location_epoch, :integer, default: 0, null: false)
    end

    create table(:browser_stars, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all))
      add(:file_id, references(:platform_files, type: :binary_id, on_delete: :delete_all))
      add(:attachment_id, references(:chat_attachments, type: :binary_id, on_delete: :delete_all))
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:browser_stars, :browser_stars_one_target,
        check: "num_nonnulls(canvas_id, file_id, attachment_id) = 1"
      )
    )

    for target <- [:canvas_id, :file_id, :attachment_id] do
      create(unique_index(:browser_stars, [:user_id, target], where: "#{target} IS NOT NULL"))
    end

    create(index(:browser_stars, [:user_id, :inserted_at, :id]))
  end
end
