defmodule Platform.Repo.Migrations.AddSponsorUserIdToTaskStacks do
  use Ecto.Migration

  @moduledoc """
  ADR 0042 Decision 8 (Stack Sponsor): human shepherd accountable for the
  stack landing, distinct from any member task's technical assignee.
  Mirrors the tasks-sponsor pattern added in
  `20260702204229_add_sponsor_user_id_to_tasks.exs` so `Dalton` (and the
  `?sponsor=mine` board pill) can filter stacks and tasks through the same
  slot with one URL toggle.

  Nullable — an unsponsored stack is legitimate. `on_delete: :nilify_all`
  so deleting a user does NOT hard-delete or cascade-abandon their
  sponsored stacks; the sponsor slot simply clears (stacks are first-class
  atomic bundles of work — losing a sponsor mid-flight is a routine
  people-side event, not a data-integrity emergency). Partial index on
  non-NULL rows keeps the "stacks I'm sponsoring" lookup cheap and pays
  zero storage cost for unsponsored stacks.
  """

  def up do
    alter table(:task_stacks) do
      add(:sponsor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id),
        null: true
      )
    end

    create(index(:task_stacks, [:sponsor_user_id], where: "sponsor_user_id IS NOT NULL"))
  end

  def down do
    drop(index(:task_stacks, [:sponsor_user_id]))

    alter table(:task_stacks) do
      remove(:sponsor_user_id)
    end
  end
end
