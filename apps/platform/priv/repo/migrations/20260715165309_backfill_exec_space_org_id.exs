defmodule Platform.Repo.Migrations.BackfillExecSpaceOrgId do
  @moduledoc """
  Pin-to-Chat v4, stage 2 (task 019f62a1) — data repair.

  Stamps `org_id` on every `kind = "execution"` chat_spaces row where
  `org_id IS NULL` but the linked task (via `metadata->>'task_id'`)
  resolves to a project with an `org_id`.

  ## Why

  `Platform.Orchestration.ExecutionSpace.find_or_create/1` (fixed in the
  companion code change of this stage) now stamps `org_id` on new exec
  spaces derived from `task → project.org_id`. Every exec space created
  before this fix — including task 019f62a1's own execution space —
  has `org_id = NULL`.

  Post-ADR-0042 `Platform.Chat.get_space_by_slug/2` hard-scopes on
  `org_id` when the caller supplies one. `ChatLive.handle_params/3`
  resolves the viewer's active org via `PlatformWeb.LiveAuth` and passes
  it as the scope. NULL-org exec-space rows can never match, so clicking
  a pinned task's rail row lands on `/chat` (the index) which
  push_navigates to the first channel. Users read this as "loading bar
  but doesn't take me to the space." This backfill restores the missing
  join key so those rows resolve normally.

  ## SQL shape

  A `linked` CTE narrows to the exec rows whose `metadata->>'task_id'`
  is UUID-shaped and does the `::uuid` cast there; a `candidates` CTE
  then joins through to the project and picks at most ONE row per
  `(target_org_id, slug)` pair (`DISTINCT ON`, oldest wins); the UPDATE
  touches only those candidates. See the two statements below.

  ## THE `::uuid` CAST IS FILTERED, NOT TRUSTED (task 01a044c6)

  `metadata` is `jsonb`, so `metadata->>'task_id'` can hold ANY string —
  there is no constraint, and no changeset, that keeps a uuid there. A
  bare `(metadata->>'task_id')::uuid` over a non-UUID string raises
  `22P02 invalid_text_representation`, and a raise inside a migration
  does not skip the row: it takes the whole migration down. This
  statement originally cast unfiltered, straight in a JOIN condition.

  The exposure was never live on our own databases — the only writer of
  that key is `ExecutionSpace.find_or_create/1`, which cannot reach the
  insert with a malformed `task_id` (`resolve_task_org_id/1` puts the
  value through an Ecto query first and raises). It is a REPLAY hazard:
  a restored backup, a hand-edited row, or a future writer at that key
  would abort this migration on the next database it runs against, and
  a migration that has already succeeded here gives no warning of it.

  The cast now sits in the target list of a CTE whose `WHERE` has
  already rejected anything that is not UUID-shaped. Within one query
  level the scan's qual is evaluated before its target list is
  projected, so the cast only ever sees rows that passed the regex, and
  the CTE is `MATERIALIZED` so the planner cannot inline it and lift the
  cast back above the filter. This mirrors
  `20260827133700_backfill_meeting_space_org_id.exs`, which guards
  `metadata->>'meeting_id'` the same way.

  A row with a malformed `task_id` is SKIPPED, not repaired and not
  fatal — it keeps `org_id = NULL` and the stage-3 safety net
  (`system_prefix_fallback/1`) resolves it unscoped, exactly like the
  race-produced duplicates below. On well-formed data the guard changes
  nothing: every row it excludes is a row the unguarded statement could
  only have raised on.

  ## Idempotency

  Only updates rows where `org_id IS NULL`. Rows that already carry an
  `org_id` (including anything created after the code fix ships) are
  left untouched. Re-running is a no-op.

  ## Race-produced duplicates

  A pre-existing race in `ExecutionSpace.find_or_create/1` (documented
  in the stage plan; NOT fixed here) can leave two or more exec-space
  rows for the same task, all with `org_id = NULL` and identical
  `task-exec-<8char>` slugs. Blindly UPDATEing both with the same
  `org_id` in one statement would trip `chat_spaces_unique_org_slug`
  (partial UNIQUE on `(org_id, slug) WHERE org_id IS NOT NULL`) — the
  `NOT EXISTS` guard evaluates against the pre-UPDATE snapshot so
  in-statement pair-collisions still fire. The `DISTINCT ON` clause
  layers on TOP of the `NOT EXISTS` guard: it picks the OLDEST NULL-org
  row per `(target_org_id, slug)` pair. The others are skipped — they
  keep `org_id = NULL` and the stage-3 safety-net fallback
  (`system_prefix_fallback/1`) resolves them unscoped. Not perfect
  data, but the migration succeeds and every affected route works.

  The `NOT EXISTS` guard ALSO covers the case where a row with the
  target `(org_id, slug)` pre-exists in the table (created by a
  post-fix code path with the correct stamp).

  ## `up/0` returns its row count

  An integer, not a `Postgrex.Result`. `Ecto.Migration.Runner` discards
  the return value of `up/0`, so this costs the migrator nothing. It is
  here for the companion test: a backfill is INVISIBLE to CI — the
  suite runs against a freshly migrated EMPTY database, where a
  migration that matches zero rows is indistinguishable from one that
  works — so the test needs a number it can assert on, taken from the
  shipped function rather than from a copy of its SQL.

  ## Down

  Non-reversible data repair. Clearing the backfilled `org_id`s would
  re-introduce the routing dead-end this migration fixes; `down/0` is a
  no-op.

  ## Migration hygiene

  Raw SQL only. No `Platform.Audit.record/1` or PubSub broadcasts —
  migrations run before the app supervision tree per the 2026-07-14
  outage journal and PR #545. `Ecto.Adapters.SQL.query!/3` rather than
  `execute/1` so `up/0` stays callable outside the migration runner,
  which is what lets the companion test exercise the SHIPPED function.
  """

  use Ecto.Migration

  @backfill_sql """
  WITH linked AS MATERIALIZED (
    SELECT s.id          AS space_id,
           s.slug        AS slug,
           s.inserted_at AS space_inserted_at,
           (s.metadata->>'task_id')::uuid AS task_id
    FROM   chat_spaces s
    WHERE  s.kind = 'execution'
      AND  s.org_id IS NULL
      AND  s.metadata->>'task_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ),
  candidates AS (
    SELECT DISTINCT ON (p.org_id, l.slug)
           l.space_id,
           p.org_id AS target_org_id
    FROM   linked l
    JOIN   tasks t ON t.id = l.task_id
    JOIN   projects p ON p.id = t.project_id
    WHERE  p.org_id IS NOT NULL
      AND  NOT EXISTS (
        SELECT 1
        FROM   chat_spaces s2
        WHERE  s2.org_id = p.org_id
          AND  s2.slug   = l.slug
          AND  s2.id    <> l.space_id
      )
    ORDER BY p.org_id, l.slug, l.space_inserted_at ASC
  )
  UPDATE chat_spaces s
  SET    org_id     = c.target_org_id,
         updated_at = NOW()
  FROM   candidates c
  WHERE  s.id = c.space_id
  """

  @doc "The repair statement, exposed so the test can read the shipped SQL."
  def backfill_sql, do: @backfill_sql

  def up do
    %Postgrex.Result{num_rows: rows} =
      Ecto.Adapters.SQL.query!(Platform.Repo, @backfill_sql, [])

    rows
  end

  def down do
    :ok
  end
end
