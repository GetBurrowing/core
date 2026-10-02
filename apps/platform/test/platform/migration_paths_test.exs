defmodule Platform.MigrationPathsTest do
  @moduledoc """
  Migration versions are unique across EVERY migrations path in the tree:
  core's `apps/platform/priv/repo/migrations` and each build-time module's
  `apps/<module>/priv/repo/migrations` (ADR 0055, task 01a0ee08 stage 3;
  `0055-extension-contract-and-build-time-modules.md § 6. Migrations`).

  Ecto's `schema_migrations` keys on version ONLY. Two files with one version
  in two paths are one migration to every database: whichever ran first is
  "up", and the other silently never runs on that database. Ecto refuses the
  pair only when both paths are passed to one `migrate`, which a
  without-modules build never does, so the collision would ship. The listing
  here is every path on disk, not the configured ones, so it holds for every
  flavour at once. Migration MODULE names are unique across paths for the
  same reason (Ecto refuses a duplicated module name too).

  The CI step "Check for duplicate migration timestamps" runs the same check
  in shell over every path before any build.
  """

  use ExUnit.Case, async: true

  @platform_root Path.expand("../..", __DIR__)
  @apps_root Path.expand("..", @platform_root)

  defp migration_files do
    @apps_root
    |> Path.join("*/priv/repo/migrations/*.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp version(path) do
    case Integer.parse(Path.basename(path)) do
      {version, "_" <> _} -> version
      _ -> {:unparseable, Path.basename(path)}
    end
  end

  @doc false
  def duplicates(files, key_fun) do
    files
    |> Enum.group_by(key_fun)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.sort()
  end

  defp report(dupes) do
    Enum.map_join(dupes, "\n", fn {key, files} ->
      "  #{inspect(key)}:\n" <>
        Enum.map_join(files, "\n", &"    #{Path.relative_to(&1, @apps_root)}")
    end)
  end

  defp module_name(path) do
    case Regex.run(~r/defmodule\s+([\w.]+)/, File.read!(path), capture: :all_but_first) do
      [name] -> name
      _ -> {:no_defmodule, Path.basename(path)}
    end
  end

  test "the listing spans core's path and at least one module's" do
    dirs = migration_files() |> Enum.map(&Path.dirname/1) |> Enum.uniq()
    assert Path.join(@platform_root, "priv/repo/migrations") in dirs
    assert length(dirs) >= 2, "only #{inspect(dirs)}: no module migrations path on disk"
  end

  test "no migration version appears twice, in one path or across paths" do
    dupes = duplicates(migration_files(), &version/1)

    assert dupes == [],
           """
           Duplicate migration version(s), across all migrations paths:

           #{report(dupes)}

           schema_migrations keys on the version alone, so one of each pair
           silently never runs on some database. Regenerate the newer file with
           `mix ecto.gen.migration` (a fresh timestamp); never renumber a
           migration that has shipped.
           """
  end

  test "no migration module name appears twice across paths" do
    dupes = duplicates(migration_files(), &module_name/1)
    assert dupes == [], "Duplicate migration module name(s):\n\n#{report(dupes)}"
  end

  test "POSITIVE CONTROL: a planted duplicate version in another path is reported naming both files" do
    [core | _] = Enum.filter(migration_files(), &String.starts_with?(&1, @platform_root))
    planted = Path.join([@apps_root, "some_module", "priv/repo/migrations", Path.basename(core)])

    assert [{version, files}] = duplicates([core, planted], &version/1)
    assert version == version(core)
    assert report([{version, files}]) =~ Path.relative_to(core, @apps_root)
    assert report([{version, files}]) =~ "some_module/priv/repo/migrations/"
  end
end
