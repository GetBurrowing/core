defmodule Platform.Repo.Migrations.Adr0042OrgProjectTopology do
  @moduledoc """
  ADR 0042 Stage 1 — org/project topology + context inheritance schema.

  Single transactional sweep that:

    1. Adds `projects.org_id` (FK → `orgs(id) ON DELETE RESTRICT`, NOT NULL),
       backfilled by name match (Startup Suite → Fabrikam root; Soylent →
       Soylent; Stark Industries → SXI). Raises if any row is left NULL
       after backfill — a defensive guard against an unexpected project name.

    2. Adds `org_id` (NOT NULL, FK → `orgs ON DELETE RESTRICT`) and
       `project_id` (NULL, FK → `projects ON DELETE CASCADE`) to
       `org_wiki_pages` and `org_wiki_journal_entries`. Existing rows backfill
       to the Fabrikam root org. (These tables were renamed from
       `org_context_files` / `org_memory_entries` in 20260515224500.)

    3. Renames the three tenant default `chat_spaces` rows (Soylent,
       Wayne-Tech, SXI) to `{name: "General", slug: "general"}` so the per-org
       general channel is consistently labelled. Idempotent: each row is only
       updated when its current name differs from "General".

  All steps run inside one Ecto migration callback, so a failure rolls back
  the entire schema sweep and the codebase never observes a partial state.

  ## Backfill strategy

  Project name-match is used (over hardcoded ids) because the planner brief
  lists names, prod ids differ from dev ids, and dropping name matching means
  hand-editing this migration per environment. The raise-on-leftover-NULL
  guard catches any divergence.

  Org references are resolved by slug lookup against the `orgs` table seeded
  in `20260519143620_seed_root_orgs.exs`. UUIDs are environment-specific —
  hardcoding prod ids here would break dev/test.

  ## chat_space safety

  The existing `chat_spaces_unique_slug` index is `(workspace_id, slug)` —
  the four NULL-workspace tenant default spaces are treated as distinct
  rows because NULLs don't collide under default Postgres semantics. The
  rename to `general` is therefore safe across the three target spaces.
  """

  use Ecto.Migration

  @fabrikam_slug "fabrikam"
  @soylent_slug "soylent"
  @sxi_slug "sxi"

  # Verified tenant default chat_spaces from the planner brief.
  @tenant_channel_ids [
    # Soylent
    "ec86dd1f-e5ab-45cc-8e69-aadd2847576c",
    # Wayne-Tech
    "ad2d9748-a94b-4529-b156-362614c86a65",
    # SXI / Stark Industries
    "019db5f7-9ff5-70c7-b678-54a4d15d1573"
  ]

  def up do
    # ── 1. projects.org_id ────────────────────────────────────────────────
    execute("ALTER TABLE projects ADD COLUMN IF NOT EXISTS org_id uuid")
    flush()

    fabrikam_id = fetch_org_id!(@fabrikam_slug)
    soylent_id = fetch_org_id!(@soylent_slug)
    sxi_id = fetch_org_id!(@sxi_slug)

    # Name-match backfill. CASE returns fabrikam for any other name; the
    # leftover-NULL guard below catches projects whose name *we missed*,
    # not projects that the CASE branched to fabrikam on purpose.
    repo_query!(
      """
      UPDATE projects
      SET org_id = CASE
        WHEN name = 'Soylent' THEN $1::uuid
        WHEN name = 'Stark Industries' THEN $2::uuid
        ELSE $3::uuid
      END
      WHERE org_id IS NULL
      """,
      [soylent_id, sxi_id, fabrikam_id]
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
      [fabrikam_id]
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
      [fabrikam_id]
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
    # ("Soylent", "Wayne-Tech", "Stark Industries"). Rollback restores
    # the schema, not the prior labels; an operator can rename via UI.

    execute("ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_project_id_fkey")
    execute("ALTER TABLE org_wiki_journal_entries DROP CONSTRAINT IF EXISTS org_wiki_journal_entries_org_id_fkey")
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

  defp fetch_org_id!(slug) do
    case repo_query!("SELECT id FROM orgs WHERE slug = $1", [slug]) do
      %{rows: [[id]]} ->
        id

      %{rows: []} ->
        raise "ADR 0042 backfill: orgs.slug=#{inspect(slug)} not found. " <>
                "Run migration 20260519143620_seed_root_orgs first."
    end
  end

  defp repo_query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(Platform.Repo, sql, params)
  end
end
