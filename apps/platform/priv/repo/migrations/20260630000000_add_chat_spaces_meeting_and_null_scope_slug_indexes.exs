defmodule Platform.Repo.Migrations.AddChatSpacesMeetingAndNullScopeSlugIndexes do
  @moduledoc """
  Close the NULL-scope slug-duplication loophole in `chat_spaces`.

  ## The loophole

  Before this migration `chat_spaces` had two unique indexes:
    * `chat_spaces_unique_slug` on `(workspace_id, slug)`
    * `chat_spaces_unique_org_slug` on `(org_id, slug) WHERE org_id IS NOT NULL`

  Postgres btree-uniqueness treats `(NULL, x)` as never-equal-to-itself, and
  the org-scoped index explicitly excludes NULL `org_id`. A row whose
  `workspace_id` AND `org_id` are both NULL falls through BOTH constraints.
  `PlatformWeb.ChatLive.bootstrap_space/2` was creating exactly such rows when
  a user navigated to a meeting-backing-space slug (`/chat/meeting-<uuid>`)
  the user couldn't see in their org — minting one duplicate per visit. Four
  identical `kind="channel"` rows for the same meeting slug accumulated in
  prod (`name="Meeting <uuid_with_dashes_as_spaces>"`), surfacing as visible
  channel-rail dupes on mobile.

  ## What this adds

  Two partial unique indexes that, together with the bootstrap_space code
  tightening shipped in the same PR, make the loophole structurally
  impossible:

    * `chat_spaces_meeting_slug` UNIQUE on `(slug) WHERE kind = 'meeting'` —
      meeting backing spaces use the `"meeting-{uuid}"` slug convention which
      is globally unique by construction; this index enforces that invariant
      at the DB level. Belt-and-suspenders against `Meetings.create_meeting/2`
      retries / races.

    * `chat_spaces_null_scope_channel_slug` UNIQUE on
      `(slug) WHERE kind = 'channel' AND org_id IS NULL AND workspace_id IS NULL` —
      makes the NULL-scope channel-slug class a constraint violation. With
      `bootstrap_space/2` now passing `org_id` from the caller's membership,
      no new NULL/NULL channel rows should be minted; this index catches any
      future regression at insert time instead of letting it silently
      duplicate.

  Kinds `dm`, `group`, `execution`, `system` are deliberately untouched by
  both indexes — DMs share `slug = ''` by design, execution rooms reuse a
  task-derived slug on every task re-run, and group/system spaces have their
  own creation paths that don't go through `bootstrap_space/2`.

  ## Data backfill: `stark-industries` row 019f1407-35dc-7c67-b90e-b11c4776dbbf

  Prod has one lingering NULL/NULL channel row from the bootstrap_space
  loophole: the `stark-industries` channel inserted 2026-06-29 with
  org_id and workspace_id both NULL. It's the ONLY channel-row representing
  Stark Industries — there is no parallel org-scoped row to fall back
  on — so the right move is to backfill its org_id to the SXI org
  (`019e40c6-dac2-7757-b8d1-65f9ba24efa7`, derived via the SXI project's
  org_id) rather than delete the row.

  The UPDATE targets the row by exact id, so it no-ops cleanly on any DB
  where that row doesn't exist (fresh dev / CI). The pre-flight below
  catches any OTHER NULL/NULL channel rows that may have appeared in the
  window between authoring this migration and it actually running, and
  raises a useful error pointing at the surviving offenders.

  ## Pre-flight collision checks

  Both indexes get a defensive pre-flight DO block in the same shape as
  `20260618220754_add_chat_spaces_org_slug_unique_index.exs` — surfaces
  any existing duplicate that would trip the index creation, with a query
  the operator can run to inspect.
  """
  use Ecto.Migration

  def up do
    # Backfill the known prod NULL/NULL channel row to its proper org_id.
    # Targets by exact row id so it no-ops on environments without this row.
    execute("""
    UPDATE chat_spaces
    SET org_id = '019e40c6-dac2-7757-b8d1-65f9ba24efa7'
    WHERE id = '019f1407-35dc-7c67-b90e-b11c4776dbbf'
      AND org_id IS NULL
      AND workspace_id IS NULL
    """)

    # Pre-flight: any kind='meeting' slug duplicates?
    execute("""
    DO $$
    DECLARE
      dup_count integer;
    BEGIN
      SELECT count(*) INTO dup_count FROM (
        SELECT slug
        FROM chat_spaces
        WHERE kind = 'meeting'
        GROUP BY slug
        HAVING count(*) > 1
      ) duplicates;

      IF dup_count > 0 THEN
        RAISE EXCEPTION
          'chat_spaces has % kind=meeting slug duplicates; resolve before adding the unique index. Run: SELECT slug, count(*) FROM chat_spaces WHERE kind = ''meeting'' GROUP BY slug HAVING count(*) > 1;',
          dup_count;
      END IF;
    END $$;
    """)

    create(
      unique_index(:chat_spaces, [:slug],
        where: "kind = 'meeting'",
        name: :chat_spaces_meeting_slug
      )
    )

    # Pre-flight: any kind='channel' NULL/NULL slug duplicates?
    # After the backfill above, the known SXI row should be out of this set.
    # Anything remaining is a fresh regression that must be cleaned manually.
    execute("""
    DO $$
    DECLARE
      dup_count integer;
      offender_count integer;
    BEGIN
      SELECT count(*) INTO dup_count FROM (
        SELECT slug
        FROM chat_spaces
        WHERE kind = 'channel'
          AND org_id IS NULL
          AND workspace_id IS NULL
        GROUP BY slug
        HAVING count(*) > 1
      ) duplicates;

      IF dup_count > 0 THEN
        RAISE EXCEPTION
          'chat_spaces has % kind=channel NULL-scope slug duplicates; resolve before adding the unique index. Run: SELECT slug, count(*) FROM chat_spaces WHERE kind = ''channel'' AND org_id IS NULL AND workspace_id IS NULL GROUP BY slug HAVING count(*) > 1;',
          dup_count;
      END IF;

      -- Also raise if any NULL/NULL channel rows remain at all (not just
      -- duplicates) so the operator notices the regression even when only
      -- one offender exists. The bootstrap_space/2 code fix shipped with
      -- this migration eliminates the only known production path that
      -- produces these rows.
      SELECT count(*) INTO offender_count
      FROM chat_spaces
      WHERE kind = 'channel'
        AND org_id IS NULL
        AND workspace_id IS NULL;

      IF offender_count > 0 THEN
        RAISE WARNING
          'chat_spaces still has % NULL-scope kind=channel rows after backfill; the partial unique index will allow them (one per slug) but new inserts will fail. Inspect: SELECT id, name, slug, inserted_at FROM chat_spaces WHERE kind = ''channel'' AND org_id IS NULL AND workspace_id IS NULL ORDER BY inserted_at;',
          offender_count;
      END IF;
    END $$;
    """)

    create(
      unique_index(:chat_spaces, [:slug],
        where: "kind = 'channel' AND org_id IS NULL AND workspace_id IS NULL",
        name: :chat_spaces_null_scope_channel_slug
      )
    )
  end

  def down do
    drop_if_exists(
      unique_index(:chat_spaces, [:slug], name: :chat_spaces_null_scope_channel_slug)
    )

    drop_if_exists(unique_index(:chat_spaces, [:slug], name: :chat_spaces_meeting_slug))

    # The org_id backfill is intentionally NOT reverted — restoring the
    # NULL would re-introduce the bug the migration fixes.
  end
end
