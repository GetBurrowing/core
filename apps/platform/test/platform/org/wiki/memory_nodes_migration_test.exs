defmodule Platform.Org.Wiki.MemoryNodesMigrationTest do
  @moduledoc """
  Task 01a1386d-e528 stage 1: the migration that adds `org_memory_nodes` and
  `org_memory_node_paths`.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.down/4` and `up/4`, mirroring
  `test/platform/branding/burrow_defaults_migration_test.exs`. Every step
  runs inside the SQL sandbox transaction and rolls back with the test.

  The claim under test is that the migration alters no existing data: an md5
  over every row of `org_wiki_pages` and `org_memory_feedback` is identical
  before, after `down`, and after `up` again.
  """

  use Platform.DataCase, async: false

  alias Platform.MemoryFeedback
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Nodes
  alias Platform.Repo

  @migration_version 20_261_014_172_223
  @migration_module Platform.Repo.Migrations.CreateOrgMemoryNodes

  setup_all do
    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@migration_version}_*.exs")
      )

    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)

    :ok
  end

  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  defp up! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
    :ok = Ecto.Migrator.up(Repo, @migration_version, @migration_module, @opts)
  end

  defp down! do
    :ok = Ecto.Migrator.down(Repo, @migration_version, @migration_module, @opts)
  end

  defp md5(table) do
    %{rows: [[digest]]} =
      Repo.query!(
        "SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t.id), '')) FROM #{table} t",
        []
      )

    digest
  end

  defp snapshot, do: {md5("org_wiki_pages"), md5("org_memory_feedback")}

  defp table?(name) do
    %{rows: [[present?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    present?
  end

  test "down then up leaves org_wiki_pages and org_memory_feedback unchanged" do
    {:ok, _} = Wiki.upsert_page("org/page/migration-probe.md", %{content: "probe"})
    {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})

    {:ok, _} =
      MemoryFeedback.record_edit(%{
        original_content: "before",
        edited_content: "after",
        path: "org/page/migration-probe.md",
        namespace: "org"
      })

    {:ok, _} = Nodes.ensure("org/page/eng/")
    before = snapshot()

    down!()
    refute table?("org_memory_nodes")
    refute table?("org_memory_node_paths")
    assert snapshot() == before

    up!()
    assert table?("org_memory_nodes")
    assert table?("org_memory_node_paths")
    assert snapshot() == before

    # The rebuilt tables work, including the current-location index.
    assert {:ok, node} = Nodes.ensure("org/page/eng/")
    assert {:ok, again} = Nodes.ensure("org/page/eng/")
    assert again.id == node.id
  end

  test "the current-location index admits one current node per org-scoped path" do
    {:ok, node} = Nodes.ensure("org/page/one.md")

    {:ok, other} =
      Repo.insert(%Platform.Org.Wiki.Node{org_id: node.org_id, workspace_id: nil})

    # NULL workspace_id on both rows: under the default NULLS DISTINCT this
    # second current row would insert. NULLS NOT DISTINCT refuses it.
    assert {:error, changeset} =
             %Platform.Org.Wiki.NodePath{}
             |> Platform.Org.Wiki.NodePath.open_changeset(%{
               node_id: other.id,
               path: "org/page/one.md",
               valid_from: DateTime.utc_now()
             })
             |> Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:workspace_id]
  end
end
