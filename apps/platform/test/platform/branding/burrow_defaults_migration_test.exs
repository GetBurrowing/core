defmodule Platform.Branding.BurrowDefaultsMigrationTest do
  @moduledoc """
  Task 01a120c5 stage 3: the data migration that moves the still-seeded
  `install_branding` values to Burrow.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.up/4` and `down/4`, not a copy of its SQL: a copy would
  pass against a migration with a different WHERE clause, or none.

  The migration is already applied in the test DB, so each `up` first
  deletes its `schema_migrations` row. That delete, the row edits below and
  the migration's own writes all happen inside the SQL sandbox transaction
  and roll back with the test.

  ## What the mutation detonates

  Drop the WHERE clause from the migration's UPDATE: the customised row's
  name and theme colour are overwritten, and "a customised column is left
  alone" goes red (up: 'Acme' becomes 'Burrow'; down: '#123456' becomes
  '#171b25').
  """
  use Platform.DataCase, async: false

  alias Platform.Repo

  @migration_version 20_261_009_150_000
  @migration_module Platform.Repo.Migrations.RebrandInstallBrandingDefaultsToBurrow

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

  defp put_row!(app_name, theme_color, background_color) do
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE install_branding SET app_name = $1, theme_color = $2, background_color = $3",
        [app_name, theme_color, background_color]
      )
  end

  # Every column, so "no other column changes" is checked, not assumed.
  defp row! do
    %{columns: cols, rows: [row]} = Repo.query!("SELECT * FROM install_branding")
    Enum.zip(cols, row) |> Map.new()
  end

  defp identity(row), do: {row["app_name"], row["theme_color"], row["background_color"]}

  defp others(row), do: Map.drop(row, ["app_name", "theme_color", "background_color"])

  test "the seeded row moves to Burrow, and down moves it back" do
    put_row!("Suite", "#171b25", "#171b25")
    before = row!()

    up!()
    after_up = row!()
    assert identity(after_up) == {"Burrow", "#191b20", "#191b20"}
    assert others(after_up) == others(before)

    down!()
    after_down = row!()
    assert identity(after_down) == {"Suite", "#171b25", "#171b25"}
    assert others(after_down) == others(before)
  end

  test "a customised column is left alone; only the still-seeded one moves" do
    put_row!("Acme", "#123456", "#171b25")
    before = row!()

    up!()
    after_up = row!()
    assert identity(after_up) == {"Acme", "#123456", "#191b20"}
    assert others(after_up) == others(before)

    down!()
    after_down = row!()
    assert identity(after_down) == {"Acme", "#123456", "#171b25"}
    assert others(after_down) == others(before)
  end

  test "down reverses exact matches only" do
    # Not values `up` produces: down must leave them exactly as they are.
    put_row!("Burrow Labs", "#191b21", "#191B20")

    down!()
    assert identity(row!()) == {"Burrow Labs", "#191b21", "#191B20"}
  end
end
