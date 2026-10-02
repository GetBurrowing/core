defmodule Platform.ReleaseTest do
  @moduledoc """
  `Platform.Release`'s rollback guard, as pure functions (ADR 0055, task
  01a0ee08 stage 3). A rollback that would undo a build-time module's
  migration is refused unless explicitly allowed; the end-to-end refusal
  against a real module's applied migrations runs in the module's own suite
  (apps/game_stream/test/platform/game_stream/release_rollback_test.exs),
  because only a with-module build has them.

  NOT async: one case sets `ALLOW_MODULE_ROLLBACK` (OS env), restored on exit.
  """

  use ExUnit.Case, async: false

  alias Platform.Release

  describe "module_versions_crossed/2" do
    test "every applied module version at or above the target, ascending" do
      assert Release.module_versions_crossed(5, [9, 5, 3, 7]) == [5, 7, 9]
    end

    test "none when the target is above every module version" do
      assert Release.module_versions_crossed(10, [9, 5, 3]) == []
      assert Release.module_versions_crossed(10, []) == []
    end
  end

  describe "allow_module_rollback?/1" do
    setup do
      saved = System.get_env("ALLOW_MODULE_ROLLBACK")

      on_exit(fn ->
        if saved,
          do: System.put_env("ALLOW_MODULE_ROLLBACK", saved),
          else: System.delete_env("ALLOW_MODULE_ROLLBACK")
      end)

      System.delete_env("ALLOW_MODULE_ROLLBACK")
      :ok
    end

    test "off unless asked" do
      refute Release.allow_module_rollback?([])
      refute Release.allow_module_rollback?(allow_module_rollback: false)
    end

    test "on by option, or by ALLOW_MODULE_ROLLBACK=true/1; the option wins" do
      assert Release.allow_module_rollback?(allow_module_rollback: true)

      for value <- ["true", "1"] do
        System.put_env("ALLOW_MODULE_ROLLBACK", value)
        assert Release.allow_module_rollback?([])
      end

      System.put_env("ALLOW_MODULE_ROLLBACK", "true")
      refute Release.allow_module_rollback?(allow_module_rollback: false)

      System.put_env("ALLOW_MODULE_ROLLBACK", "yes")
      refute Release.allow_module_rollback?([])
    end
  end

  test "file_versions/1 reads versions off migration filenames only" do
    dir = Path.join(System.tmp_dir!(), "release-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ~w(20990101000000_a.exs 20990102000000_b.exs notes.md 123.exs) do
      File.write!(Path.join(dir, name), "")
    end

    assert Enum.sort(Release.file_versions([dir])) == [20_990_101_000_000, 20_990_102_000_000]
    assert Release.file_versions([]) == []
  end

  test "a without-modules build's migrations path is core's alone" do
    assert Release.migrations_paths(Platform.Repo) ==
             [Ecto.Migrator.migrations_path(Platform.Repo)]
  end
end
