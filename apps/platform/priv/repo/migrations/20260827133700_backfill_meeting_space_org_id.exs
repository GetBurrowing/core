defmodule Platform.Repo.Migrations.BackfillMeetingSpaceOrgId do
  @moduledoc """
  Task `019fcfdd` stage 3 — data repair for `chat_spaces.org_id` on the two
  meeting-shaped kinds.

  Stamps `org_id` on every `kind = 'meeting'` and `kind = 'guest_meeting'`
  chat_spaces row where `org_id IS NULL` but the row's meeting resolves to a
  project that carries an org.

  ## Why these rows are NULL in the first place

  No migration has ever populated `chat_spaces.org_id` for either kind.
  `20260604000000_add_org_id_to_chat_spaces.exs` added the column and
  backfilled `kind = 'channel'` ONLY, by slug→org-slug mapping, and says so:
  "Non-channel spaces (dm/group/execution/system/meeting) are left NULL".
  `20260715165309_backfill_exec_space_org_id.exs` then repaired
  `kind = 'execution'` and nothing else. Meeting spaces have never been in
  scope for either.

  On the write side, `Meetings.create_meeting/1` built the attrs for
  `Chat.create_space/1` with no `:org_id` key at all — it did not pass nil, it
  omitted the key — so every meeting space minted before stage 2 of this task
  carries `org_id IS NULL`, including the row `invite_external_user/3` seats
  participants into. `create_guest_chat_space/2` has always stamped the org
  when one resolved, so the `guest_meeting` population here is the residue:
  rows minted before that helper gained `maybe_put_org_id/2`, plus any row
  whose org did not resolve at mint time.

  Stage 2 fixed the write path. This is the repair for the rows that already
  exist.

  ## The joins

  Two statements, because the two kinds reach their meeting differently.

    * `kind = 'meeting'` — the meeting OWNS the space, so the link is the real
      FK column: `meetings.chat_space_id = chat_spaces.id`. Then
      `meetings.project_id → projects.org_id`.

    * `kind = 'guest_meeting'` — the space is per-invite identity bookkeeping
      minted by `Meetings.create_guest_chat_space/2`, which records the origin
      as `metadata->>'meeting_id'`. There is no FK, so the join is
      `(metadata->>'meeting_id')::uuid = meetings.id`, then the same
      `project → org` hop.

  ## LEFTOVER NULLs ARE THE CORRECT OUTCOME, NOT AN INCOMPLETE RUN

  Read this before concluding that a NULL `org_id` on a meeting-shaped row
  after this migration means the migration failed to finish.

  A row is deliberately left NULL when its meeting cannot be resolved to a
  project that has an org. The reachable shapes are:

    * a `kind = 'meeting'` space with NO `meetings` row pointing at it.
      Reachable: `projects.id` cascades `ON DELETE delete_all` to `meetings`,
      but `meetings.chat_space_id` cascades the other way (deleting the SPACE
      deletes the meeting), so deleting a project reaps the meeting and
      ORPHANS its chat space.
    * a `kind = 'guest_meeting'` space whose `metadata->>'meeting_id'` names a
      meeting that no longer exists — same cascade, and `metadata` is jsonb
      with no FK to keep it honest — or whose metadata carries no
      `meeting_id` key at all.

  Two shapes that read like candidates are NOT reachable today and the
  guards for them are defensive only: `meetings.project_id` is `NOT NULL` at
  the database level with a real FK (`20260514120000_create_meetings.exs`),
  and `projects.org_id` is `NOT NULL` (`20260618181114_adr_0042_org_project_topology.exs`).
  So "the meeting has no project" and "the project has no org" cannot occur
  through the meetings table while those constraints stand. The `p.org_id IS
  NOT NULL` predicate below is kept anyway, mirroring the exec backfill, so
  the statement stays correct if either constraint is ever relaxed.

  Those leftover rows keep working. `PlatformWeb.Plugs.ExternalUserScope`'s
  third resolution step, `system_prefix_fallback/1`, does an UNSCOPED slug
  lookup for any slug matching `Chat.reserved_slug_prefix?/1`, and
  `ChatLive.system_prefix_fallback/1` mirrors it. That fallback is NOT made
  obsolete by this migration and is deliberately untouched: it stays
  permanently load-bearing for the `dm-` / `group-` / `task-exec-` prefixes,
  which are cross-org by design and stay NULL forever.

  For the same reason NO `NOT NULL` constraint is added to
  `chat_spaces.org_id` here, and none should be. `dm`, `group` and `system`
  spaces are deliberately org-less, and two of the write paths that create
  them bypass `Chat.create_space/1` with a direct `Multi.insert`.

  ## Determinism and collision safety

  Each statement is a two-level CTE.

  `one_per_space` picks at most ONE candidate row per chat space
  (`DISTINCT ON (s.id)`, oldest meeting wins). Nothing enforces that a chat
  space is referenced by only one meeting — `meetings.chat_space_id` carries a
  plain index, not a unique one — and `UPDATE ... FROM` against a join that
  yields two rows for the same target picks one of them arbitrarily and
  reports no error. This level makes the choice explicit and repeatable.

  `candidates` then picks at most ONE row per `(target_org_id, slug)` pair,
  oldest space wins, and a `NOT EXISTS` guard skips any space whose target
  pair is already held by a different row. Together those keep the UPDATE off
  `chat_spaces_unique_org_slug` — the partial UNIQUE on `(org_id, slug) WHERE
  org_id IS NOT NULL` from `20260618220754`. The `NOT EXISTS` guard evaluates
  against the pre-UPDATE snapshot, so it cannot see a collision this same
  statement is about to create; `DISTINCT ON` is what covers that case. For
  `kind = 'meeting'` this second level is belt-and-braces — `20260630000000`
  added `chat_spaces_meeting_slug`, UNIQUE on `(slug) WHERE kind = 'meeting'`,
  so two meeting spaces cannot share a slug — but for `guest_meeting`, whose
  slugs are `guest-<8 random chars>`, it is a real guard. A skipped row keeps
  `org_id = NULL` and the reserved-prefix fallback continues to resolve it.

  ## The uuid cast is filtered, not trusted

  `metadata` is jsonb, so `metadata->>'meeting_id'` can hold any string, and
  `::uuid` on a non-UUID string RAISES — which would abort the whole
  migration. The guest statement therefore does the cast in the target list of
  a subquery whose `WHERE` has already rejected anything that is not
  UUID-shaped. Within one query level `WHERE` is applied before the target
  list is evaluated, so the cast only ever sees rows that pass the regex, and
  the CTE is `MATERIALIZED` so the planner cannot inline it and reorder the
  two. (The exec backfill at `20260715165309` casts unfiltered and carries
  this exposure; it is not being changed here.)

  ## Idempotency

  Both statements only touch rows where `org_id IS NULL`, so rows already
  stamped — including everything minted by the post-stage-2 code path — are
  left alone and re-running is a no-op.

  ## `up/0` returns its row counts

  `{meeting_rows, guest_meeting_rows}`, not `:ok`. `Ecto.Migration.Runner`
  discards the return value of `up/0`, so this costs the migrator nothing
  (the exec backfill at `20260715165309` already returns a `Postgrex.Result`
  for the same reason: nobody reads it). It is here for the companion test.
  A backfill is INVISIBLE to CI — the suite runs against a freshly migrated
  EMPTY database, where a migration that matches zero rows is
  indistinguishable from one that works — so the test needs a number it can
  assert on, taken from the shipped function rather than from a copy of its
  SQL.

  ## Down

  Non-reversible data repair. Clearing these `org_id`s would put the rows back
  behind the unscoped fallback; `down/0` is a no-op.

  ## Migration hygiene

  Raw SQL through `Ecto.Adapters.SQL.query!/3`, not schema modules, per the
  convention `SeedRootOrgs` established and the exec backfill followed: a data
  migration must replay identically years from now, independent of how the
  `Space` / `Meeting` / `Project` schemas later evolve. Calling `query!/3`
  directly rather than `execute/1` also keeps `up/0` callable outside the
  migration runner, which is what lets the companion test run the SHIPPED
  function instead of a copy of its SQL. No `Platform.Audit.record/1` and no
  PubSub broadcast — migrations run before the app supervision tree.
  """

  use Ecto.Migration

  @meeting_sql """
  WITH one_per_space AS MATERIALIZED (
    SELECT DISTINCT ON (s.id)
           s.id          AS space_id,
           s.slug        AS slug,
           s.inserted_at AS space_inserted_at,
           p.org_id      AS target_org_id
    FROM   chat_spaces s
    JOIN   meetings m ON m.chat_space_id = s.id
    JOIN   projects p ON p.id = m.project_id
    WHERE  s.kind = 'meeting'
      AND  s.org_id IS NULL
      AND  p.org_id IS NOT NULL
    ORDER BY s.id, m.inserted_at ASC, m.id ASC
  ),
  candidates AS (
    SELECT DISTINCT ON (o.target_org_id, o.slug)
           o.space_id,
           o.target_org_id
    FROM   one_per_space o
    WHERE  NOT EXISTS (
      SELECT 1
      FROM   chat_spaces s2
      WHERE  s2.org_id = o.target_org_id
        AND  s2.slug   = o.slug
        AND  s2.id    <> o.space_id
    )
    ORDER BY o.target_org_id, o.slug, o.space_inserted_at ASC, o.space_id ASC
  )
  UPDATE chat_spaces s
  SET    org_id     = c.target_org_id,
         updated_at = NOW()
  FROM   candidates c
  WHERE  s.id = c.space_id
  """

  @guest_meeting_sql """
  WITH linked AS MATERIALIZED (
    SELECT s.id          AS space_id,
           s.slug        AS slug,
           s.inserted_at AS space_inserted_at,
           (s.metadata->>'meeting_id')::uuid AS meeting_id
    FROM   chat_spaces s
    WHERE  s.kind = 'guest_meeting'
      AND  s.org_id IS NULL
      AND  s.metadata->>'meeting_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ),
  one_per_space AS MATERIALIZED (
    SELECT DISTINCT ON (l.space_id)
           l.space_id,
           l.slug,
           l.space_inserted_at,
           p.org_id AS target_org_id
    FROM   linked l
    JOIN   meetings m ON m.id = l.meeting_id
    JOIN   projects p ON p.id = m.project_id
    WHERE  p.org_id IS NOT NULL
    ORDER BY l.space_id, m.inserted_at ASC, m.id ASC
  ),
  candidates AS (
    SELECT DISTINCT ON (o.target_org_id, o.slug)
           o.space_id,
           o.target_org_id
    FROM   one_per_space o
    WHERE  NOT EXISTS (
      SELECT 1
      FROM   chat_spaces s2
      WHERE  s2.org_id = o.target_org_id
        AND  s2.slug   = o.slug
        AND  s2.id    <> o.space_id
    )
    ORDER BY o.target_org_id, o.slug, o.space_inserted_at ASC, o.space_id ASC
  )
  UPDATE chat_spaces s
  SET    org_id     = c.target_org_id,
         updated_at = NOW()
  FROM   candidates c
  WHERE  s.id = c.space_id
  """

  @doc "The `kind = 'meeting'` repair statement, exposed so the test can read the shipped SQL."
  def meeting_sql, do: @meeting_sql

  @doc "The `kind = 'guest_meeting'` repair statement, exposed so the test can read the shipped SQL."
  def guest_meeting_sql, do: @guest_meeting_sql

  def up do
    %Postgrex.Result{num_rows: meeting_rows} =
      Ecto.Adapters.SQL.query!(Platform.Repo, @meeting_sql, [])

    %Postgrex.Result{num_rows: guest_meeting_rows} =
      Ecto.Adapters.SQL.query!(Platform.Repo, @guest_meeting_sql, [])

    {meeting_rows, guest_meeting_rows}
  end

  def down do
    :ok
  end
end
