defmodule Platform.Repo.Migrations.BackfillCascadeChildDeletionClocks do
  @moduledoc """
  Task 019f760f stage 4 — one-shot data repair for cascade children that
  were scheduled for deletion BEFORE the per-child deletion clock landed
  (stage 1) and the purger stopped joining on the org clock (stage 2).

  ## Why

  Before stage 1, hiding a scheduled org stamped each cascade child with
  `archived_cascade_org_id` (the provenance marker) but left the child's
  own `deletion_scheduled_at` NULL — the purge sweep resolved the child's
  countdown by JOINing back to its org's clock. Stage 1 changed the
  cascade to also copy the org's `deletion_scheduled_at` onto each child,
  and stage 2 rewrote `Platform.Tenancy.ContainerPurger` to key the purge
  off each child's OWN `deletion_scheduled_at`, dropping the org-clock
  join entirely.

  That leaves a gap: any child cascade-scheduled BEFORE stage 1 shipped
  has its marker set but its own clock still NULL. The stage-2 purger
  keys off the child clock, so those rows would count down forever and
  never be purged. This migration stamps each such child's own clock from
  its still-scheduled org, closing the gap so the existing retention sweep
  can eventually collect them.

  ## Predicate

  For both `projects` and `chat_spaces`, update a row when ALL hold:

    * `archived_cascade_org_id` references an org whose
      `deletion_scheduled_at IS NOT NULL` (the org is still scheduled), AND
    * the child's OWN `deletion_scheduled_at IS NULL` (never stamped —
      i.e. cascade-scheduled before stage 1).

  The child's `deletion_scheduled_at` is set to the org's
  `deletion_scheduled_at`, exactly as the stage-1 cascade now does at
  schedule time.

  ## Idempotence

  Only touches children whose own clock is still NULL. After the first
  pass every matched child carries a non-NULL clock, so re-invocation
  matches nothing and returns `{0, 0}`. Rows the org restore already
  cleared (marker + clock NUL, or a re-scheduled org that re-stamped the
  child) are never revived.

  ## One-way door

  `down/0` is a warning-only no-op. This is a targeted data repair, not a
  schema change; the stamped clocks are indistinguishable from clocks the
  live stage-1 cascade would have written, so there is nothing meaningful
  to reverse. Restore from a database backup taken before this migration
  if a rollback is ever required.

  ## Migration hygiene

  Raw SQL only, driven through `repo.query!/1`. No `Ecto.Query`,
  `Platform.Audit.record/1`, or PubSub broadcasts — migrations run before
  the app supervision tree is up (per PR #545 / the 2026-07-14 outage
  journal). No index migration: the partial indexes on
  `deletion_scheduled_at` and `archived_cascade_org_id` already exist
  (20260714010000).
  """

  use Ecto.Migration

  @migration_id "20260719000001"

  def up do
    {projects_count, chat_spaces_count} = backfill(repo())

    IO.puts(
      "[Migration #{@migration_id}] backfilled deletion_scheduled_at from the " <>
        "scheduled org clock onto #{projects_count} cascade-child project(s) " <>
        "and #{chat_spaces_count} cascade-child chat_space(s)"
    )

    :ok
  end

  def down do
    IO.warn(
      "backfill_cascade_child_deletion_clocks is a one-way data repair; the " <>
        "stamped per-child clocks are indistinguishable from clocks the live " <>
        "stage-1 cascade writes and cannot be selectively reverted — restore " <>
        "from a database backup taken before #{@migration_id} if required"
    )

    :ok
  end

  @doc """
  Stamp each cascade child's own `deletion_scheduled_at` from its still-
  scheduled org, for children the pre-stage-1 cascade left NULL. Runs the
  `projects` UPDATE then the `chat_spaces` UPDATE via `repo.query!/1` and
  returns `{projects_updated, chat_spaces_updated}` — the affected-row
  counts, so a data-migration test can drive it directly inside the Ecto
  sandbox.
  """
  @spec backfill(module()) :: {non_neg_integer(), non_neg_integer()}
  def backfill(repo) do
    %Postgrex.Result{num_rows: projects_count} =
      repo.query!("""
      UPDATE projects
         SET deletion_scheduled_at = o.deletion_scheduled_at
        FROM orgs o
       WHERE projects.archived_cascade_org_id = o.id
         AND o.deletion_scheduled_at IS NOT NULL
         AND projects.deletion_scheduled_at IS NULL
      """)

    %Postgrex.Result{num_rows: chat_spaces_count} =
      repo.query!("""
      UPDATE chat_spaces
         SET deletion_scheduled_at = o.deletion_scheduled_at
        FROM orgs o
       WHERE chat_spaces.archived_cascade_org_id = o.id
         AND o.deletion_scheduled_at IS NOT NULL
         AND chat_spaces.deletion_scheduled_at IS NULL
      """)

    {projects_count, chat_spaces_count}
  end
end
