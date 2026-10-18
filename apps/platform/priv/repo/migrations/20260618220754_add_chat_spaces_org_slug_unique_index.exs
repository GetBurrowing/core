defmodule Platform.Repo.Migrations.AddChatSpacesOrgSlugUniqueIndex do
  @moduledoc """
  Add a partial unique index on `chat_spaces(org_id, slug) WHERE org_id IS NOT NULL`
  so a single slug (e.g. `"general"`) can exist exactly once per org without
  re-using NULL-org rows (DMs / group spaces / legacy unowned channels).

  ## Why this matters

  Post-ADR-0042 (`20260618181114_adr_0042_org_project_topology.exs`), the three
  tenant default channels were renamed to `slug = 'general'`. Combined with the
  pre-existing Acme General channel and Paragon's General, the `chat_spaces`
  table now contains five rows sharing `slug = 'general'`, each with a
  different `org_id`. `Platform.Chat.get_space_by_slug/1` used `order_by inserted_at
  asc; limit 1` and consistently returned the Acme row, so a Soylent member
  clicking the Soylent-section "General" sidebar entry would always land in
  Acme's General — the bug this stage fixes.

  The partial unique index enforces "one slug per org" at the DB level so any
  future regression that tries to insert a second `(org_id, slug)` collision
  is caught immediately.

  ## Defensive pre-flight collision check

  `20260604000000_add_org_id_to_chat_spaces.exs` already backfilled `org_id`
  on every existing channel using the old (pre-ADR-0042) slug-pattern CASE,
  so today's data should be collision-free. The DO block below makes that
  guarantee explicit: it raises before the index is created if any duplicate
  `(org_id, slug)` pair exists, surfacing the problem with a useful error
  rather than letting the unique-index creation throw a generic constraint
  violation.

  ## `WHERE org_id IS NOT NULL` clause

  DMs and group chats have `org_id = NULL` — those rows must stay distinct
  from each other even when (rare) slug collisions occur. The partial WHERE
  clause excludes them from the unique constraint, preserving the existing
  back-compat behavior for non-org-scoped spaces.

  ## Idempotent — does not duplicate the `org_id` column add

  The `org_id` column itself was added by the earlier
  `AddOrgIdToChatSpaces` migration (`IF NOT EXISTS` guard, FK to `orgs`).
  This migration only adds the new partial unique index and the collision
  pre-flight; it does not touch column definitions.
  """
  use Ecto.Migration

  def up do
    # Pre-flight: surface any existing duplicate (org_id, slug) rows so the
    # unique-index creation below cannot blow up with a less helpful error.
    # `org_id IS NOT NULL` mirrors the partial index condition.
    execute("""
    DO $$
    DECLARE
      dup_count integer;
    BEGIN
      SELECT count(*) INTO dup_count FROM (
        SELECT org_id, slug
        FROM chat_spaces
        WHERE org_id IS NOT NULL
        GROUP BY org_id, slug
        HAVING count(*) > 1
      ) duplicates;

      IF dup_count > 0 THEN
        RAISE EXCEPTION
          'chat_spaces has % (org_id, slug) duplicates; resolve before adding the unique index. Run: SELECT org_id, slug, count(*) FROM chat_spaces WHERE org_id IS NOT NULL GROUP BY org_id, slug HAVING count(*) > 1;',
          dup_count;
      END IF;
    END $$;
    """)

    create(
      unique_index(:chat_spaces, [:org_id, :slug],
        where: "org_id IS NOT NULL",
        name: :chat_spaces_unique_org_slug
      )
    )
  end

  def down do
    drop_if_exists(
      unique_index(:chat_spaces, [:org_id, :slug], name: :chat_spaces_unique_org_slug)
    )
  end
end
