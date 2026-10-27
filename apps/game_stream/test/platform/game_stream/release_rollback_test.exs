defmodule Platform.GameStream.ReleaseRollbackTest do
  @moduledoc """
  `Platform.Release` with Play present (ADR 0055, task 01a0ee08 stage 3):
  both of Play's migrations run from Play's path, after core's, and a
  rollback that would cross either of them is REFUSED, running nothing,
  unless explicitly allowed
  (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).

  The refused call is made against this suite's real, migrated test
  database: the refusal is decided before any `:down` runs, so the database
  is untouched, and the schema check afterwards proves it.
  """

  use Platform.DataCase, async: false

  alias Platform.Release

  @play_versions [20_260_926_030_000, 20_260_928_200_000, 20_261_027_040_000]

  test "the release migrates core's path first, then Play's" do
    [core, play] = Release.migrations_paths(Repo)
    assert core == Ecto.Migrator.migrations_path(Repo)
    assert play == Application.app_dir(:game_stream, "priv/repo/migrations")

    assert play |> File.ls!() |> Enum.map(&(&1 |> Integer.parse() |> elem(0))) |> Enum.sort() ==
             @play_versions

    # And the moved files keep their versions: this database ran them from
    # Play's path and both are recorded as up, each with its file found.
    # (`migrations/2` also lists every other applied version, as
    # "** FILE NOT FOUND **", which is why the release guard reads the files.)
    listed = Ecto.Migrator.migrations(Repo, [play])

    for version <- @play_versions do
      assert [{:up, ^version, name}] = Enum.filter(listed, &(elem(&1, 1) == version))
      refute name =~ "FILE NOT FOUND"
    end

    assert Release.file_versions([play]) |> Enum.sort() == @play_versions
  end

  test "a rollback across Play's migrations is refused and runs nothing" do
    System.delete_env("ALLOW_MODULE_ROLLBACK")
    before = table_columns("game_stream_sessions")
    assert before != []

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Release.rollback(Repo, hd(@play_versions)) ==
                 {:error, {:crosses_module_migrations, @play_versions}}
      end)

    assert log =~ "refusing to roll"
    assert table_columns("game_stream_sessions") == before
    assert Enum.count(Ecto.Migrator.migrations(Repo), &(elem(&1, 0) == :down)) == 0
  end

  test "a rollback to a version above all of Play's crosses none of them" do
    assert Release.module_versions_crossed(20_261_027_040_001, @play_versions) == []

    assert Release.module_versions_crossed(20_260_928_200_000, @play_versions) == [
             20_260_928_200_000,
             20_261_027_040_000
           ]
  end

  defp table_columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1 ORDER BY 1",
        [table]
      )

    List.flatten(rows)
  end
end
