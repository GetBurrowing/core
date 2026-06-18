defmodule Platform.Repo.Adr0042MigrationTest do
  @moduledoc """
  Verifies the post-state of `20260618181114_adr_0042_org_project_topology`.

  Migrations are applied to the test DB by `mix ecto.create + mix ecto.migrate`
  before the suite boots, so by the time this test runs the schema and the
  seed data must satisfy ADR 0042:

    * `projects.org_id` is NOT NULL and FK-enforced against `orgs(id)`
    * `org_wiki_pages` carries `(org_id NOT NULL, project_id NULL)` FKs
    * `org_wiki_journal_entries` carries the same shape
    * The three tenant default chat_spaces (Soylent, Wayne-Tech, SXI) are
      named "General" with slug "general"

  Direct SQL assertions are used (rather than schema reflection) so a future
  schema rename can't silently invalidate the test.
  """

  use Platform.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Platform.Repo

  describe "projects.org_id" do
    test "column is NOT NULL" do
      %{rows: [[is_nullable]]} =
        SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'projects' AND column_name = 'org_id'
          """,
          []
        )

      assert is_nullable == "NO"
    end

    test "FK constraint exists pointing at orgs(id) with ON DELETE RESTRICT" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT rc.delete_rule, ccu.table_name, ccu.column_name
          FROM information_schema.referential_constraints rc
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_name = rc.constraint_name
          WHERE rc.constraint_name = 'projects_org_id_fkey'
          """,
          []
        )

      assert [["RESTRICT", "orgs", "id"]] = rows
    end
  end

  describe "org_wiki_pages topology columns" do
    test "org_id is NOT NULL and FK-enforced" do
      %{rows: [[is_nullable]]} =
        SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'org_wiki_pages' AND column_name = 'org_id'
          """,
          []
        )

      assert is_nullable == "NO"

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT rc.delete_rule, ccu.table_name
          FROM information_schema.referential_constraints rc
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_name = rc.constraint_name
          WHERE rc.constraint_name = 'org_wiki_pages_org_id_fkey'
          """,
          []
        )

      assert [["RESTRICT", "orgs"]] = rows
    end

    test "project_id is nullable and cascades on project delete" do
      %{rows: [[is_nullable]]} =
        SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'org_wiki_pages' AND column_name = 'project_id'
          """,
          []
        )

      assert is_nullable == "YES"

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT rc.delete_rule, ccu.table_name
          FROM information_schema.referential_constraints rc
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_name = rc.constraint_name
          WHERE rc.constraint_name = 'org_wiki_pages_project_id_fkey'
          """,
          []
        )

      assert [["CASCADE", "projects"]] = rows
    end
  end

  describe "org_wiki_journal_entries topology columns" do
    test "org_id is NOT NULL with RESTRICT FK" do
      %{rows: [[is_nullable]]} =
        SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'org_wiki_journal_entries' AND column_name = 'org_id'
          """,
          []
        )

      assert is_nullable == "NO"

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT rc.delete_rule
          FROM information_schema.referential_constraints rc
          WHERE rc.constraint_name = 'org_wiki_journal_entries_org_id_fkey'
          """,
          []
        )

      assert [["RESTRICT"]] = rows
    end

    test "project_id is nullable with CASCADE FK" do
      %{rows: [[is_nullable]]} =
        SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'org_wiki_journal_entries' AND column_name = 'project_id'
          """,
          []
        )

      assert is_nullable == "YES"

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT rc.delete_rule
          FROM information_schema.referential_constraints rc
          WHERE rc.constraint_name = 'org_wiki_journal_entries_project_id_fkey'
          """,
          []
        )

      assert [["CASCADE"]] = rows
    end
  end

  describe "tenant chat_space rename" do
    @tenant_channel_ids [
      # Soylent
      "ec86dd1f-e5ab-45cc-8e69-aadd2847576c",
      # Wayne-Tech
      "ad2d9748-a94b-4529-b156-362614c86a65",
      # SXI / Stark Industries
      "019db5f7-9ff5-70c7-b678-54a4d15d1573"
    ]

    test "the three tenant default chat_spaces are renamed to General when present" do
      # The rename is idempotent and only applies to rows that exist (the
      # migration uses a guarded UPDATE). Tenant default channels may or may
      # not be present in a fresh test DB depending on prior seed migrations;
      # for any row that *does* exist, it must satisfy the post-state.
      for id <- @tenant_channel_ids do
        %{rows: rows} =
          SQL.query!(
            Repo,
            "SELECT name, slug FROM chat_spaces WHERE id = $1::uuid",
            [Ecto.UUID.dump!(id)]
          )

        case rows do
          [] ->
            :ok

          [[name, slug]] ->
            assert name == "General",
                   "expected chat_spaces.id=#{id} to be renamed to 'General', got #{inspect(name)}"

            assert slug == "general",
                   "expected chat_spaces.id=#{id} slug='general', got #{inspect(slug)}"
        end
      end
    end
  end

  describe "backfill produces non-null org_id everywhere" do
    test "no projects row carries NULL org_id" do
      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM projects WHERE org_id IS NULL", [])

      assert count == 0
    end

    test "no org_wiki_pages row carries NULL org_id" do
      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM org_wiki_pages WHERE org_id IS NULL", [])

      assert count == 0
    end

    test "no org_wiki_journal_entries row carries NULL org_id" do
      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM org_wiki_journal_entries WHERE org_id IS NULL", [])

      assert count == 0
    end
  end
end
