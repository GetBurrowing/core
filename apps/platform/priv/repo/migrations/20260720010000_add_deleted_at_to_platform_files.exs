defmodule Platform.Repo.Migrations.AddDeletedAtToPlatformFiles do
  use Ecto.Migration

  @moduledoc """
  Soft-delete marker for files (task 019f7cb0 stage 2).

  A non-NULL `deleted_at` hides the row from every get/list/search path
  (`Platform.Files` applies `not_deleted/1` at the query root) while the
  row itself sticks around for the 30-day restore window. The stage-3
  purge sweeper hard-deletes rows whose `deleted_at` is past retention.

  The partial index only covers deleted rows: live-row queries filter on
  `deleted_at IS NULL` inside project-scoped queries already served by
  the project_id index, while the sweeper scans exactly the deleted set.
  """
  def change do
    alter table(:platform_files) do
      add(:deleted_at, :utc_datetime_usec, null: true)
    end

    create(
      index(:platform_files, [:deleted_at],
        where: "deleted_at IS NOT NULL",
        name: :platform_files_deleted_at_index
      )
    )
  end
end
