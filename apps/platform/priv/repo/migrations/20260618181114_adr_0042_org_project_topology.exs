defmodule Platform.Repo.Migrations.Adr0042OrgProjectTopology do
  @moduledoc """
  ADR 0042 Stage 1 — org/project topology + context inheritance schema.

  Single transactional sweep that:

    1. Adds `projects.org_id` (FK → `orgs(id) ON DELETE RESTRICT`, NOT NULL),
       backfilled by name match (Initech → Initech; Globex Corporation →
       Globex; every other name, e.g. Startup Suite → the root org). Raises if
       any row is left NULL after backfill — a defensive guard against an
       unexpected project name.

    2. Adds `org_id` (NOT NULL, FK → `orgs ON DELETE RESTRICT`) and
       `project_id` (NULL, FK → `projects ON DELETE CASCADE`) to
       `org_wiki_pages` and `org_wiki_journal_entries`. Existing rows backfill
       to the root org. (These tables were renamed from
       `org_context_files` / `org_memory_entries` in 20260515224500.)

    3. Renames the three tenant default `chat_spaces` rows (Initech,
       Vandelay-Ind, Globex) to `{name: "General", slug: "general"}` so the per-org
       general channel is consistently labelled. Idempotent: each row is only
       updated when its current name differs from "General".

  All steps run inside one Ecto migration callback, so a failure rolls back
  the entire schema sweep and the codebase never observes a partial state.

  ## Backfill strategy

  Project name-match is used (over hardcoded ids) because the planner brief
  lists names, prod ids differ from dev ids, and dropping name matching means
  hand-editing this migration per environment. The raise-on-leftover-NULL
  guard catches any divergence.

  The root org is resolved STRUCTURALLY, as the single `orgs` row with
  `parent_org_id IS NULL` (see `root_org_id!/0`), never by slug. The two
  optional tenant orgs are resolved by slug. UUIDs are environment-specific —
  hardcoding prod ids here would break dev/test.

  ## Root org resolved structurally, not by slug (task 01a0dbc4)

  This file used to resolve the root with a raising lookup of the original
  operator's root slug.
  `20260519143620_seed_root_orgs.exs` seeds the root under `ROOT_ORG_SLUG`
  (default `"root"`), so a fresh install whose root was slugged anything but
  that slug crashed here on its first migrate. CI never saw it: `config/test.exs`
  and `config/dev.exs` then pinned `ROOT_ORG_SLUG` to it.

  `root_org_id!/0` returns the id of the one row with `parent_org_id IS NULL`,
  and raises on zero rows (SeedRootOrgs always runs first, so zero roots means
  a broken migration history, not "nothing to do") and on more than one (the
  `orgs_single_root` partial unique index from `20260519143600_create_orgs.exs`
  makes that unreachable, but this file does not pick one silently). On every
  existing install the root already is the org the slug used to name, so the
  resolved id is unchanged there; and this migration is recorded in
  `schema_migrations` on those installs, so the edit never runs on them.
  Topology background: `docs/decisions/0042-org-project-topology-and-context-inheritance.md` § Migration sequence.

  ## Initech/Globex are now OPTIONAL (task 01a068f6 stage 2)

  `20260519143620_seed_root_orgs.exs` no longer seeds the four operator-brand
  tenant orgs, only a root. This migration is already applied (recorded in
  `schema_migrations`) on every install that ever had Initech/Globex rows, so
  rewriting `up/0` is inert there for the same reason `SeedRootOrgs`'
  rewrite is — it only changes behavior for a genuinely fresh database's
  first migrate. `initech_id`/`globex_id` fall back to the root org when those
  slugs don't exist, instead of raising.

  A fresh database's backfill is NOT empty (corrected by task 01a0dbc4; this
  section previously called `projects` the only table the backfill could
  touch). `projects` is empty there, but
  `20260408180100_seed_org_context_files.exs` seeds three rows
  (`org/identity.md`, `org/memory.md`, `org/agents.md`) into what becomes
  `org_wiki_pages`, so the `org_wiki_pages` UPDATE below writes the root
  org's id on every fresh install and the root must resolve there.

  ## chat_space safety

  The existing `chat_spaces_unique_slug` index is `(workspace_id, slug)` —
  the four NULL-workspace tenant default spaces are treated as distinct
  rows because NULLs don't collide under default Postgres semantics. The
  rename to `general` is therefore safe across the three target spaces.
  """

  use Ecto.Migration

  # The two optional tenant orgs and their projects, matched by the sha256 of
  # the stored value so the tree does not spell them (task 01a14dd9 stage 3).
  # Placeholder names (initech, globex) label them in prose only.
  @initech_slug_sha256 "1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b"
  @globex_slug_sha256 "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d"
  @initech_project_name_sha256 "6b94fa4f19a37399a7d396dac2469a84b5118af3115209d8f414acb34d2c1822"
  @globex_project_name_sha256 "2e677ef20cffe096763a542f36f72ef1fbf48a5efa7e2bea38ed48a62c9a3d6c"

  # Verified tenant default chat_spaces from the planner brief.
  @tenant_channel_ids [
    # Initech
    "ec86dd1f-e5ab-45cc-8e69-aadd2847576c",
    # Vandelay-Ind
    "ad2d9748-a94b-4529-b156-362614c86a65",
    # Globex / Globex Corporation
    "019db5f7-9ff5-70c7-b678-54a4d15d1573"
  ]

  def up do
    # ── 1. projects.org_id ────────────────────────────────────────────────
    execute("ALTER TABLE projects ADD COLUMN IF NOT EXISTS org_id uuid")
    flush()

    root_id = root_org_id!()
    initech_id = fetch_org_id(@initech_slug_sha256) || root_id
    globex_id = fetch_org_id(@globex_slug_sha256) || root_id

    # Name-match backfill. CASE returns the root for any other name; the
    # leftover-NULL guard below catches projects whose name *we missed*,
    # not projects that the CASE branched to the root on purpose.
    repo_query!(
      """
      UPDATE projects
      SET org_id = CASE
        WHEN encode(sha256(convert_to(name, 'UTF8')), 'hex') = $4 THEN $1::uuid
        WHEN encode(sha256(convert_to(name, 'UTF8')), 'hex') = $5 THEN $2::uuid
        ELSE $3::uuid
      END
      WHERE org_id IS NULL
      """,
      [
        initech_id,
        globex_id,
        root_id,
        @initech_project_name_sha256,
        @globex_project_name_sha256
      ]
    )

    %{rows: [[leftover]]} = repo_query!("SELECT COUNT(*) FROM projects WHERE org_id IS NULL")

    if leftover != 0 do
      raise "ADR 0042 backfill: #{leftover} project(s) left with NULL org_id after name match"
    end

    execute(
      "ALTER TABLE projects ALTER COLUMN org_id SET NOT NULL",
      "ALTER TABLE projects ALTER COLUMN org_id DROP NOT NULL"
    )

    execute(
      """
      ALTER TABLE projects
        ADD CONSTRAINT projects_org_id_fkey
        FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT
      """,
      "ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_org_id_fkey"
    )

    create_if_not_exists(index(:projects, [:org_id]))

    # ── 2. org_wiki_pages: org_id + project_id ───────────────────────────
    execute("ALTER TABLE org_wiki_pages ADD COLUMN IF NOT EXISTS org_id uuid")
    execute("ALTER TABLE org_wiki_pages ADD COLUMN IF NOT EXISTS project_id uuid")
    flush()

    repo_query!(
      "UPDATE org_wiki_pages SET org_id = $1::uuid WHERE org_id IS NULL",
      [root_id]
    )

    execute(
      "ALTER TABLE org_wiki_pages ALTER COLUMN org_id SET NOT NULL",
      "ALTER TABLE org_wiki_pages ALTER COLUMN org_id DROP NOT NULL"
    )

    execute(
      """
      ALTER TABLE org_wiki_pages
        ADD CONSTRAINT org_wiki_pages_org_id_fkey
        FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT
      """,
      "ALTER TABLE org_wiki_pages DROP CONSTRAINT IF EXISTS org_wiki_pages_org_id_fkey"
    )

    execute(
      """
      ALTER TABLE org_wiki_pages
        ADD CONSTRAINT org_wiki_pages_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
      """,
      "ALTER TABLE org_wiki_pages DROP CONSTRAINT IF EXISTS org_wiki_pages_project_id_fkey"
    )

    create_if_not_exists(index(:org_wiki_pages, [:org_id]))
    create_if_not_exists(index(:org_wiki_pages, [:project_id]))

    # ── 3. org_wiki_journal_entries: same shape ──────────────────────────
    execute("ALTER TABLE org_wiki_journal_entries ADD COLUMN IF NOT EXISTS org_id uuid")
    execute("ALTER TABLE org_wiki_journal_entries ADD COLUMN IF NOT EXISTS project_id uuid")
    flush()

    repo_query!(
      "UPDATE org_wiki_journal_entries SET org_id = $1::uuid WHERE org_id IS NULL",
      [root_id]
    )

    execute(
      "ALTER TABLE org_wiki_journal_entries ALTER COLUMN org_id SET NOT NULL",
      "ALTER TABLE org_wiki_journal_entries ALTER COLUMN org_id DROP NOT NULL"
    )

    execute(
      """
      ALTER TABLE org_wiki_journal_entries
        ADD CONSTRAINT org_wiki_journal_entries_org_id_fkey
        FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT
      """,
      "ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_org_id_fkey"
    )

    execute(
      """
      ALTER TABLE org_wiki_journal_entries
        ADD CONSTRAINT org_wiki_journal_entries_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
      """,
      "ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_project_id_fkey"
    )

    create_if_not_exists(index(:org_wiki_journal_entries, [:org_id]))
    create_if_not_exists(index(:org_wiki_journal_entries, [:project_id]))

    # ── 4. Rename tenant default chat_spaces to "General" ────────────────
    for channel_id <- @tenant_channel_ids do
      repo_query!(
        """
        UPDATE chat_spaces
        SET name = 'General', slug = 'general', updated_at = NOW()
        WHERE id = $1::uuid AND name != 'General'
        """,
        [Ecto.UUID.dump!(channel_id)]
      )
    end
  end

  def down do
    # Reverse rename is lossy — the original names were tenant-specific
    # ("Initech", "Vandelay-Ind", "Globex Corporation"). Rollback restores
    # the schema, not the prior labels; an operator can rename via UI.

    execute(
      "ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_project_id_fkey"
    )

    execute(
      "ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_org_id_fkey"
    )

    drop_if_exists(index(:org_wiki_journal_entries, [:project_id]))
    drop_if_exists(index(:org_wiki_journal_entries, [:org_id]))
    execute("ALTER TABLE org_wiki_journal_entries DROP COLUMN IF EXISTS project_id")
    execute("ALTER TABLE org_wiki_journal_entries DROP COLUMN IF EXISTS org_id")

    execute("ALTER TABLE org_wiki_pages DROP CONSTRAINT IF EXISTS org_wiki_pages_project_id_fkey")
    execute("ALTER TABLE org_wiki_pages DROP CONSTRAINT IF EXISTS org_wiki_pages_org_id_fkey")
    drop_if_exists(index(:org_wiki_pages, [:project_id]))
    drop_if_exists(index(:org_wiki_pages, [:org_id]))
    execute("ALTER TABLE org_wiki_pages DROP COLUMN IF EXISTS project_id")
    execute("ALTER TABLE org_wiki_pages DROP COLUMN IF EXISTS org_id")

    execute("ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_org_id_fkey")
    drop_if_exists(index(:projects, [:org_id]))
    execute("ALTER TABLE projects DROP COLUMN IF EXISTS org_id")
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # The root org, resolved structurally (task 01a0dbc4): the single row with
  # `parent_org_id IS NULL`, whatever its slug. Public only so
  # `test/platform/data_migrations/adr_0042_root_org_resolution_test.exs`
  # can drive it without an `Ecto.Migration` runner.
  @doc false
  def root_org_id! do
    case repo_query!("SELECT id FROM orgs WHERE parent_org_id IS NULL") do
      %{rows: [[id]]} ->
        id

      %{rows: []} ->
        raise "ADR 0042 backfill: no root org (parent_org_id IS NULL). " <>
                "Run migration 20260519143620_seed_root_orgs first."

      %{num_rows: count} ->
        raise "ADR 0042 backfill: expected exactly one root org " <>
                "(parent_org_id IS NULL), found #{count}."
    end
  end

  # `nil` on a missing slug — used for the two OPTIONAL tenant orgs
  # (Initech/Globex), which the seed migration no longer guarantees. Takes
  # the sha256 of the slug, never the slug (task 01a14dd9 stage 3).
  defp fetch_org_id(slug_sha256) do
    case repo_query!(
           "SELECT id FROM orgs WHERE encode(sha256(convert_to(slug, 'UTF8')), 'hex') = $1",
           [slug_sha256]
         ) do
      %{rows: [[id]]} -> id
      %{rows: []} -> nil
    end
  end

  defp repo_query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(Platform.Repo, sql, params)
  end
end
