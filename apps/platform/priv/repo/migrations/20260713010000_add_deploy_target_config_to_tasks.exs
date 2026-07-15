defmodule Platform.Repo.Migrations.AddDeployTargetConfigToTasks do
  @moduledoc """
  Task 019f5e66 stage 2 — introduces the richer per-task deploy-target
  config map. The column is additive alongside the existing
  `deploy_target` string; both live side-by-side until every read/write
  caller has been migrated to the new shape.

  TODO: drop the legacy `deploy_target` string column in a follow-up
  once all read/write callers migrate.
  """
  use Ecto.Migration

  def up do
    # `add_if_not_exists` keeps a re-run of this migration idempotent —
    # important because the backfill UPDATE below is guarded to only
    # touch rows that have not yet been backfilled, so a partial retry
    # is safe end-to-end.
    alter table(:tasks) do
      add_if_not_exists(:deploy_target_config, :map, default: nil)
    end

    flush()

    # Backfill: for existing rows with a legacy `deploy_target` string,
    # synthesise the new-shape config. v1 assumption (per plan stage 2
    # guardrails): every non-null legacy `deploy_target` was docker_deploy
    # — that was the only strategy that ever consulted the column.
    #
    # Only rows where `deploy_target_config IS NULL` are touched, so
    # re-running this migration (or a follow-up that adds another
    # source of truth) will not clobber values written by later
    # callers.
    execute("""
    UPDATE tasks
       SET deploy_target_config = jsonb_build_object(
         'strategy', 'docker_deploy',
         'target',   deploy_target
       )
     WHERE deploy_target IS NOT NULL
       AND deploy_target_config IS NULL
    """)
  end

  def down do
    alter table(:tasks) do
      remove(:deploy_target_config)
    end
  end
end
