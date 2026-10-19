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
  (`@sub_org_slug_to_bucket`), including the `vandelay-ind` channel-slug →
  `vandelay_ind` org-slug spelling difference and the "everything else → root
  org" fallback (the original operator's root slug, spelled in the SQL). Non-channel spaces (dm/group/execution/system/meeting) are left
  NULL — they don't appear in the sub-org rail.

  ## Slugs matched by digest (task 01a14dd9 stage 3)

  The CASE used to spell four tenant slugs and the root slug as SQL
  literals. Every one is now compared as
  `encode(sha256(convert_to(<col>, 'UTF8')), 'hex') = '<digest>'`, the form
  the root arm already used (task 01a14b9e stage 5), so the public tree does
  not spell an install's org names. sha256 equality is byte equality, so
  each arm is true for exactly the rows its literal matched, and a NULL slug
  still falls through to ELSE. The SQL comments name each arm by the
  placeholder slug the test fixtures use, not by the real one.

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
      AND CASE
            -- hooli
            WHEN encode(sha256(convert_to(lower(cs.slug), 'UTF8')), 'hex') = 'd0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c'
              THEN encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = 'd0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c'
            -- initech
            WHEN encode(sha256(convert_to(lower(cs.slug), 'UTF8')), 'hex') = '1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b'
              THEN encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b'
            -- vandelay-ind channel -> vandelay_ind org
            WHEN encode(sha256(convert_to(lower(cs.slug), 'UTF8')), 'hex') = 'f80cf60200f6c7c32e92dae3c84a45a76d7cc8468ddb679983582805ac8d4a4b'
              THEN encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '6033c506fee05cd2e9291a63854efcd0357866cb82dd5b6fceac7916f74cfdb3'
            -- globex
            WHEN encode(sha256(convert_to(lower(cs.slug), 'UTF8')), 'hex') = '3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d'
              THEN encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d'
            ELSE encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c'
          END
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS chat_spaces_org_id_index")
    execute("ALTER TABLE chat_spaces DROP COLUMN IF EXISTS org_id")
  end
end
