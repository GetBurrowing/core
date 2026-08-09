defmodule Platform.Repo.Migrations.CreateTaskPhaseTransitions do
  @moduledoc """
  Task 019fe4a8, stage 1 — an append-only time series of task status
  changes, so cycle time can be decomposed per phase instead of collapsing
  to one created-to-done number.

  ## Shape

  One row per observed status change. Rows are never updated and never
  deleted except by cascade when the parent task is deleted.

  ## Columns

    * `task_id` — FK `tasks`, `on_delete: :delete_all`, NOT NULL.
    * `from_status` — NULLABLE. Null means "no prior status recorded".
    * `to_status` — NOT NULL.
    * `occurred_at` — when the change happened, NOT NULL.
    * `actor_kind` — `user` | `agent` | `system` | `unknown`, NOT NULL.
      Deliberately four-valued and NOT a boolean: separating a wait on a
      human gate from a wait on the engine is the entire point of the
      table. Collapsing it loses the only question it exists to answer.
    * `actor_id` — user UUID, agent UUID, or null for `system`.
    * `actor_label` — free-form attribution (e.g. `system:auto`).
    * `via` — short tag naming the code path that caused the write.

  ## Deliberately NO unique constraint on (task_id, to_status)

  A task legitimately re-enters a status many times: `blocked` is reachable
  from most states and back, `done -> planning` reopens, and `in_progress`
  is re-enterable from both `in_review` and `deploying`. Any uniqueness here
  would reject real transitions.
  """

  use Ecto.Migration

  def change do
    create table(:task_phase_transitions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:from_status, :string)
      add(:to_status, :string, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:actor_kind, :string, null: false)
      add(:actor_id, :string)
      add(:actor_label, :string)
      add(:via, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:task_phase_transitions, [:task_id, :occurred_at]))
    create(index(:task_phase_transitions, [:to_status, :occurred_at]))
  end
end
