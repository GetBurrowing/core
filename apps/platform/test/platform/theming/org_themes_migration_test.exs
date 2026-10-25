defmodule Platform.Theming.OrgThemesMigrationTest do
  @moduledoc """
  The `create_org_themes` migration (task 01a1557a-fe9b stage 1) runs up,
  down and up again. The actual migration file is loaded and run with
  `Ecto.Migrator`, inside the SQL sandbox transaction, so the schema change
  rolls back with the test.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo

  @version 20_261_025_120_000
  @module Platform.Repo.Migrations.CreateOrgThemes
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    [path] =
      Path.wildcard(Path.join(:code.priv_dir(:platform), "repo/migrations/#{@version}_*.exs"))

    unless Code.ensure_loaded?(@module), do: Code.require_file(path)
    :ok
  end

  defp table? do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'org_themes'"
      )

    n == 1
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'org_themes' ORDER BY column_name"
      )

    Map.new(rows, fn [c, nullable] -> {c, nullable} end)
  end

  defp indexes do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'org_themes'")

    rows |> List.flatten() |> MapSet.new()
  end

  defp constraints do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname, confdeltype FROM pg_constraint " <>
          "WHERE conrelid = 'org_themes'::regclass"
      )

    Map.new(rows, fn [name, del] -> {name, del} end)
  end

  test "up, down, up" do
    assert table?()
    before = {columns(), indexes(), constraints()}

    :ok = Ecto.Migrator.down(Repo, @version, @module, @opts)
    refute table?()

    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    :ok = Ecto.Migrator.up(Repo, @version, @module, @opts)
    assert table?()
    assert {columns(), indexes(), constraints()} == before
  end

  test "the table has the planned shape" do
    cols = columns()

    for c <-
          ~w(id org_id name status default_mode light dark shape published_at published_by_id inserted_at updated_at),
        do: assert(Map.has_key?(cols, c), c)

    assert cols["org_id"] == "NO"
    assert cols["name"] == "NO"
    assert cols["published_by_id"] == "YES"

    assert MapSet.subset?(
             MapSet.new(["org_themes_org_id_name_index", "org_themes_org_id_status_index"]),
             indexes()
           )

    c = constraints()
    assert Map.has_key?(c, "org_themes_status_check")
    assert Map.has_key?(c, "org_themes_default_mode_check")
    # 'c' cascade (delete_all) on the org, 'n' set null (nilify_all) on the publisher.
    assert c["org_themes_org_id_fkey"] == "c"
    assert c["org_themes_published_by_id_fkey"] == "n"

    assert_raise Postgrex.Error, ~r/org_themes_status_check/, fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "INSERT INTO org_themes (id, org_id, name, status, inserted_at, updated_at) " <>
            "VALUES (gen_random_uuid(), $1, 'x', 'live', now(), now())",
          [Ecto.UUID.dump!(Platform.TenancyFixtures.acme_org_id())]
        )
      end)
    end
  end
end
