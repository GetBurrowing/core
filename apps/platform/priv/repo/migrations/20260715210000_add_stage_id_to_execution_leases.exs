defmodule Platform.Repo.Migrations.AddStageIdToExecutionLeases do
  @moduledoc """
  Repartition `execution_leases` from task-scoped uniqueness to
  `{task_id, phase, runtime_id, stage_id}`-scoped uniqueness so the
  router can carry a distinct lease (and blocker) per plan stage
  without one stage's stale row masking the next stage's dispatch.

  ## Shape

    * Add `stage_id :binary_id` (nullable). Pre-migration `active` rows
      carry NULL and the new partial unique index accepts them because
      Postgres treats multiple NULLs as distinct in a UNIQUE index —
      that's the intentional legacy escape hatch. No data backfill is
      needed; historical rows age out via the 15-min TTL.
    * Drop the existing partial unique index
      `execution_leases_active_unique_idx` (`(task_id, phase, runtime_id)
      WHERE status IN ('active','blocked')`).
    * Create the replacement partial unique index
      `execution_leases_active_stage_unique_idx` on
      `(task_id, phase, runtime_id, stage_id)` with the same
      `WHERE status IN ('active','blocked')` predicate.
    * Add a plain btree index `execution_leases_task_stage_idx` on
      `(task_id, stage_id)` for the stage-scoped read paths coming in
      stage 2 (`current_lease_for_stage/2`, `drop_leases_for_stage/2`).

  ## Reversal

  `down/0` restores the task-scoped unique index so a rollback keeps
  the schema consistent with the pre-migration router code. The
  `stage_id` column is dropped in reverse order so the unique index
  drop precedes the column drop.
  """

  use Ecto.Migration

  def up do
    alter table(:execution_leases) do
      add(:stage_id, :binary_id)
    end

    drop(index(:execution_leases, [:task_id, :phase, :runtime_id],
      name: :execution_leases_active_unique_idx
    ))

    create(
      unique_index(:execution_leases, [:task_id, :phase, :runtime_id, :stage_id],
        where: "status in ('active', 'blocked')",
        name: :execution_leases_active_stage_unique_idx
      )
    )

    create(index(:execution_leases, [:task_id, :stage_id], name: :execution_leases_task_stage_idx))
  end

  def down do
    drop(index(:execution_leases, [:task_id, :stage_id], name: :execution_leases_task_stage_idx))

    drop(index(:execution_leases, [:task_id, :phase, :runtime_id, :stage_id],
      name: :execution_leases_active_stage_unique_idx
    ))

    create(
      unique_index(:execution_leases, [:task_id, :phase, :runtime_id],
        where: "status in ('active', 'blocked')",
        name: :execution_leases_active_unique_idx
      )
    )

    alter table(:execution_leases) do
      remove(:stage_id)
    end
  end
end
