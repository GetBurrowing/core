defmodule Platform.Repo.Migrations.AddSponsorUserIdToTasks do
  use Ecto.Migration

  # ADR 0042 (Task Sponsor): human shepherd distinct from the technical
  # assignee. Nullable — a task can have no sponsor. `on_delete: :nilify_all`
  # so deleting a user does not orphan or hard-delete their sponsored tasks;
  # the sponsor slot simply clears. Partial index on non-NULL rows keeps the
  # "tasks I'm sponsoring" lookup cheap without paying storage for the many
  # tasks with no sponsor.

  def up do
    alter table(:tasks) do
      add(:sponsor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id),
        null: true
      )
    end

    create(index(:tasks, [:sponsor_user_id], where: "sponsor_user_id IS NOT NULL"))
  end

  def down do
    drop(index(:tasks, [:sponsor_user_id]))

    alter table(:tasks) do
      remove(:sponsor_user_id)
    end
  end
end
