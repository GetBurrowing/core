defmodule Platform.Goals.MigrationTest do
  use Platform.DataCase, async: true

  @version "20261115152203"
  @migration Path.expand(
               "../../../priv/repo/migrations/#{@version}_create_goal_tables.exs",
               __DIR__
             )
  @irreversible Path.expand(
                  "../../../../../deployment/release/irreversible-migrations.txt",
                  __DIR__
                )

  @tables ~w(goals goal_stops goal_grants goal_entries)

  test "the four goal tables exist after the module's test alias migrates" do
    %{rows: rows} =
      Platform.Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = current_schema() AND table_name = ANY($1)",
        [@tables]
      )

    assert Enum.sort(List.flatten(rows)) == Enum.sort(@tables)
  end

  test "the migration ran as this version" do
    %{rows: rows} =
      Platform.Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
        String.to_integer(@version)
      ])

    assert rows == [[String.to_integer(@version)]]
  end

  test "the migration file carries the old-code-compatible waiver as a comment line" do
    source = File.read!(@migration)

    assert source =~
             ~r/^[ \t]*# old-code-compatible: creates four new goal tables only; no existing table changes and the previous release reads none of them$/m
  end

  test "its version is not listed as irreversible" do
    # Positive control: the list is real and is read line by line.
    assert File.exists?(@irreversible)

    listed =
      @irreversible
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    refute @version in listed
  end
end
