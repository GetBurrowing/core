defmodule Platform.Repo.Migrations.AddOrgIdToChatSpaces do
  @moduledoc """
  Add `chat_spaces.org_id` — the channel→org "identity" FK (chat sidebar v2,
  Stage 1). This is the single source of truth that replaces the hardcoded
  name-pattern bucketing in `PlatformWeb.ChatLive` (`channel_scope/1`).

  ## Collision-safe with the MT/RBAC stack

  `org_id` is also slated to land via the MT/RBAC stack (task 019e3c49). To
  guarantee the two cannot collide, the column add / index use Postgres
  `IF NOT EXISTS` and the backfill only touches rows where `org_id IS NULL`.
  If the MT/RBAC migration lands the column first, this migration is a no-op
  on the DDL and an idempotent top-up on the data; if this lands first, theirs
  becomes the no-op. Either order is safe.

  ## Backfill faithfully reproduces today's `channel_scope/1`

  Each `kind = 'channel'` space is assigned the org whose slug matches its
  current bucket. The CASE encodes the exact map from `chat_live.ex`
  (`@sub_org_slug_to_bucket`), including the `wayne-tech` channel-slug →
  `wayne_tech` org-slug spelling difference and the "everything else → root
  org" fallback (the original operator's root slug, spelled in the SQL). Non-channel spaces (dm/group/execution/system/meeting) are left
  NULL — they don't appear in the sub-org rail.

  Raw SQL (not schema modules) per the data-migration convention established
  by `SeedRootOrgs`: a migration must replay identically years from now,
  independent of how the `Space`/`Org` schemas later evolve.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE chat_spaces
      ADD COLUMN IF NOT EXISTS org_id uuid
      REFERENCES orgs(id) ON DELETE SET NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS chat_spaces_org_id_index
      ON chat_spaces (org_id)
    """)

    execute("""
    UPDATE chat_spaces cs
    SET org_id = o.id
    FROM orgs o
    WHERE cs.kind = 'channel'
      AND cs.org_id IS NULL
      AND CASE lower(cs.slug)
            WHEN 'paragon' THEN o.slug = 'paragon'
            WHEN 'soylent' THEN o.slug = 'soylent'
            WHEN 'wayne-tech' THEN o.slug = 'wayne_tech'
            WHEN 'sxi'      THEN o.slug = 'sxi'
            ELSE encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c'
          END
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS chat_spaces_org_id_index")
    execute("ALTER TABLE chat_spaces DROP COLUMN IF EXISTS org_id")
  end
end
