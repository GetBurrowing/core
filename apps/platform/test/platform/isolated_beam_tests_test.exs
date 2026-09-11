defmodule Platform.IsolatedBeamTestsTest do
  @moduledoc """
  Invariants that make `Platform.IsolatedBeamTests` a guarantee rather than a
  comment. Mirrors `Platform.SlowTestsTest`, because the failure mode is the
  same shape: a tag that excludes tests, and a separate named thing that is
  supposed to still run them.

  Three claims, and they are different:

    * The `:isolated_beam` tag is actually excluded by the running suite.
    * Something NAMED still runs those tests — a second `mix test --only
      isolated_beam` invocation in `.github/workflows/ci.yml`. The assertion
      below reads the workflow's text, so it detects that invocation being
      deleted; it cannot prove GitHub executed it. Drift alarm, not proof of
      execution, and labelled as one.
    * That invocation must NOT carry `--include slow`. `--only X` expands to
      `--include X --exclude test`, so a second `--include` ADDS tests to the
      run rather than narrowing it — measured, it turned 3 tests into 9 by
      re-running every `Platform.SlowTests` entry in the isolated BEAM.

  The registry must also stay in step with the tree: an `@moduletag
  :isolated_beam` with no entry is a module excluded for an unrecorded reason,
  which is the state this registry exists to end.
  """

  use ExUnit.Case, async: true

  alias Platform.IsolatedBeamTests

  @test_root Path.expand("..", __DIR__)
  @test_helper Path.join(@test_root, "test_helper.exs")
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)
  @tag_source "@moduletag :isolated_beam"

  describe "entry schema" do
    test "every entry carries exactly the required keys" do
      required = MapSet.new(IsolatedBeamTests.required_keys())

      for entry <- IsolatedBeamTests.entries() do
        assert MapSet.new(Map.keys(entry)) == required,
               "entry #{inspect(entry[:test])} has keys #{inspect(Map.keys(entry))}, " <>
                 "expected #{inspect(IsolatedBeamTests.required_keys())}"
      end
    end

    test "the registry is non-vacuous and every reason names the global it mutates" do
      entries = IsolatedBeamTests.entries()

      refute Enum.empty?(entries),
             "an empty registry with a live exclusion in test_helper.exs means the " <>
               "tag hides tests for no recorded reason"

      for entry <- entries do
        assert is_binary(entry.global) and entry.global != "",
               "entry #{inspect(entry.test)} does not name the global state it mutates"

        assert String.length(entry.reason) > 40,
               "entry #{inspect(entry.test)} has no substantive reason"
      end
    end
  end

  describe "the exclusion is real" do
    test "the tag is excluded by the running suite" do
      excluded = ExUnit.configuration()[:exclude]

      for tag <- IsolatedBeamTests.excluded_tags() do
        assert tag in excluded,
               "#{inspect(tag)} is in excluded_tags/0 but not in the running ExUnit " <>
                 "exclude config — test_helper.exs has drifted"
      end
    end

    test "test_helper.exs derives the exclusion from the registry" do
      source = File.read!(@test_helper)

      assert source =~ "Platform.IsolatedBeamTests.excluded_tags()",
             "test_helper.exs must derive the isolated-BEAM exclusion from the registry"
    end
  end

  describe "the named thing that still runs them" do
    test "ci.yml runs the excluded tests in their own invocation" do
      # Drift alarm, not proof of execution — see the moduledoc.
      source = File.read!(@ci_workflow)

      assert source =~ "mix test --only isolated_beam",
             "ci.yml no longer carries a `mix test --only isolated_beam` invocation, " <>
               "so every entry in Platform.IsolatedBeamTests now runs NOWHERE — " <>
               "including the only test that demonstrates HandlerGuardian repairing " <>
               "a real VM-wide detach. Restore the step or delete the registry and " <>
               "its exclusions together."
    end

    test "that invocation does not carry --include slow" do
      source = File.read!(@ci_workflow)

      refute source =~ "mix test --only isolated_beam --include slow",
             "`--only X --include slow` ADDS the slow tests to the isolated run " <>
               "instead of narrowing it (measured: 3 tests became 9). Drop the flag; " <>
               "nothing in this partition is :slow-tagged."
    end
  end

  describe "registry / tree agreement" do
    test "every @moduletag :isolated_beam in the suite has a registry entry naming its file" do
      tagged_files =
        @test_root
        |> Path.join("**/*_test.exs")
        |> Path.wildcard()
        # Anchored to a line of its own, exactly as `Platform.SlowTestsTest` does,
        # so prose mentioning the tag — including this file's own moduledoc and
        # its `@tag_source` literal — is not counted as a tagged module.
        |> Enum.filter(&(File.read!(&1) =~ ~r/^[ \t]*@moduletag :isolated_beam[ \t]*$/m))
        |> Enum.map(&Path.relative_to(&1, Path.expand("..", @test_root)))
        |> MapSet.new()

      recorded =
        IsolatedBeamTests.entries() |> Enum.map(&(&1.test |> String.split(":") |> hd()))

      for file <- tagged_files do
        assert Enum.any?(recorded, &(&1 == file)),
               "#{file} carries an @moduletag :isolated_beam with no " <>
                 "Platform.IsolatedBeamTests entry — it is excluded from the default " <>
                 "run for an unrecorded reason"
      end
    end
  end
end
