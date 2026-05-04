defmodule Platform.Repo.Migrations.RemoveReadyTaskStatus do
  use Ecto.Migration

  @moduledoc """
  Backfill any task currently in `ready` status per the ADR 0029 lifecycle
  cleanup (the `ready` gate is removed; plan approval is the start signal).

  Strategy:
  - If the task has an `approved` (or further-advanced) plan, move the task
    to `in_progress`. The plan was already greenlit; the only thing the
    `ready` gate added was a manual click.
  - Otherwise, move the task back to `planning` so a fresh plan can be
    drafted under the new lifecycle.

  No schema change — `tasks.status` is a free string. The Elixir side now
  refuses to insert/transition into `ready` (`@valid_task_transitions` and
  `@valid_drop_transitions` no longer reference it), so once this backfill
  runs there should be no rows left in that state.
  """

  def up do
    # Tasks with an approved/executing/completed plan -> in_progress.
    execute("""
    UPDATE tasks
    SET status = 'in_progress',
        updated_at = NOW()
    WHERE status = 'ready'
      AND id IN (
        SELECT DISTINCT task_id
        FROM plans
        WHERE status IN ('approved', 'executing', 'completed')
      )
    """)

    # Remaining `ready` tasks (no approved plan) -> planning.
    execute("""
    UPDATE tasks
    SET status = 'planning',
        updated_at = NOW()
    WHERE status = 'ready'
    """)
  end

  def down do
    # Irreversible — we don't know which previously-ready tasks should go
    # back. Document and no-op.
    :ok
  end
end
