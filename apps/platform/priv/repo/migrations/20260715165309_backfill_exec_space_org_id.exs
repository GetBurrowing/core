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
  before this fix — including task 019f62a1's own execution space at
  `019f62a1-1657-746f-b5e8-97463d294f21` — has `org_id = NULL`.

  Post-ADR-0042 `Platform.Chat.get_space_by_slug/2` hard-scopes on
  `org_id` when the caller supplies one. `ChatLive.handle_params/3`
  resolves the viewer's active org via `PlatformWeb.LiveAuth` and passes
  it as the scope. NULL-org exec-space rows can never match, so clicking
  a pinned task's rail row lands on `/chat` (the index) which
  push_navigates to the first channel. Users read this as "loading bar
  but doesn't take me to the space." This backfill restores the missing
  join key so those rows resolve normally.

  ## SQL shape

  Selects candidates via a CTE that picks at most ONE row per
  `(target_org_id, slug)` pair (`DISTINCT ON`, oldest wins), then
  UPDATEs only those candidates:

      WITH candidates AS (
        SELECT DISTINCT ON (p.org_id, s.slug)
               s.id, p.org_id AS target_org_id
        FROM   chat_spaces s
        JOIN   tasks t ON (s.metadata->>'task_id')::uuid = t.id
        JOIN   projects p ON p.id = t.project_id
        WHERE  s.kind = 'execution'
          AND  s.org_id IS NULL
          AND  p.org_id IS NOT NULL
          AND  NOT EXISTS (
            SELECT 1 FROM chat_spaces s2
            WHERE s2.org_id = p.org_id
              AND s2.slug   = s.slug
              AND s2.id    != s.id
          )
        ORDER BY p.org_id, s.slug, s.inserted_at ASC
      )
      UPDATE chat_spaces s
      SET    org_id = c.target_org_id, updated_at = NOW()
      FROM   candidates c
      WHERE  s.id = c.id

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

  ## Down

  Non-reversible data repair. Clearing the backfilled `org_id`s would
  re-introduce the routing dead-end this migration fixes; `down/0` is a
  no-op.

  ## Migration hygiene

  Raw SQL only. No `Platform.Audit.record/1` or PubSub broadcasts —
  migrations run before the app supervision tree per the 2026-07-14
  outage journal and PR #545.
  """

  use Ecto.Migration

  def up do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      WITH candidates AS (
        SELECT DISTINCT ON (p.org_id, s.slug)
               s.id AS space_id,
               p.org_id AS target_org_id
        FROM   chat_spaces s
        JOIN   tasks t ON (s.metadata->>'task_id')::uuid = t.id
        JOIN   projects p ON p.id = t.project_id
        WHERE  s.kind = 'execution'
          AND  s.org_id IS NULL
          AND  p.org_id IS NOT NULL
          AND  NOT EXISTS (
            SELECT 1
            FROM   chat_spaces s2
            WHERE  s2.org_id = p.org_id
              AND  s2.slug   = s.slug
              AND  s2.id    != s.id
          )
        ORDER BY p.org_id, s.slug, s.inserted_at ASC
      )
      UPDATE chat_spaces s
      SET    org_id     = c.target_org_id,
             updated_at = NOW()
      FROM   candidates c
      WHERE  s.id = c.space_id
      """,
      []
    )
  end

  def down do
    :ok
  end
end
