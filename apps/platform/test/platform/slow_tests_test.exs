defmodule Platform.SlowTestsTest do
  @moduledoc """
  Invariants that make `Platform.SlowTests` a guarantee rather than a comment.

  Two claims, and they are different:

    * The `:slow` tag is **actually excluded** by the running suite. Before this
      registry it was not — `@tag :slow` sat on six tests and did nothing.
    * Something **named** still runs those tests. That something is
      `--include slow` in `.github/workflows/ci.yml`. The assertion below reads
      the workflow's text, so it detects the flag being deleted; it cannot
      prove GitHub executed it. It is a drift alarm, and is labelled as one
      rather than dressed up as proof of execution.

  The registry must also stay in step with the tags in the tree: an
  `@tag :slow` with no entry is a test excluded for an unrecorded reason, which
  is the state this registry exists to end.
  """

  use ExUnit.Case, async: true

  alias Platform.SlowTests

  @test_root Path.expand("..", __DIR__)
  @test_helper Path.join(@test_root, "test_helper.exs")
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  describe "entry schema" do
    test "every entry carries exactly the required keys" do
      required = MapSet.new(SlowTests.required_keys())

      for entry <- SlowTests.entries() do
        assert MapSet.new(Map.keys(entry)) == required,
               "entry #{inspect(entry[:test])} has keys #{inspect(Map.keys(entry))}, " <>
                 "expected #{inspect(SlowTests.required_keys())}"
      end
    end

    test "the registry is non-vacuous and every reason says what the time buys" do
      entries = SlowTests.entries()
      refute Enum.empty?(entries), "the registry may not be empty while `:slow` is excluded"

      for entry <- entries do
        assert is_integer(entry.seconds) and entry.seconds > 0
        assert String.length(String.trim(entry.reason)) > 40, "reason too thin: #{entry.test}"
      end
    end
  end

  describe "exclusion wiring" do
    test ":slow is actually excluded by the running suite" do
      configured = ExUnit.configuration()[:exclude] |> List.wrap() |> MapSet.new()

      for tag <- SlowTests.excluded_tags() do
        assert MapSet.member?(configured, tag),
               "#{inspect(tag)} is in SlowTests.excluded_tags/0 but not in the running " <>
                 "ExUnit exclude config — test_helper.exs has drifted"
      end
    end

    test "test_helper.exs derives the slow exclusion from the registry" do
      source = File.read!(@test_helper)

      assert source =~ "Platform.SlowTests.excluded_tags()",
             "test_helper.exs must derive the slow exclusion from the registry"
    end
  end

  describe "the named thing that still runs them" do
    test "ci.yml runs the excluded tests via --include slow" do
      # Drift alarm, not proof of execution — see the moduledoc.
      source = File.read!(@ci_workflow)

      assert source =~ "mix test --include slow",
             "ci.yml no longer passes --include slow, so every entry in " <>
               "Platform.SlowTests now runs NOWHERE. Restore the flag or delete " <>
               "the registry and its exclusions together."
    end
  end

  describe "registry / tree agreement" do
    test "every @tag :slow in the suite has a registry entry naming its file" do
      tagged_files =
        @test_root
        |> Path.join("**/*_test.exs")
        |> Path.wildcard()
        # Anchored to the start of a line so prose mentioning the tag —
        # including this file's own moduledoc — is not counted as a tagged test.
        |> Enum.filter(&(File.read!(&1) =~ ~r/^[ \t]*@tag :slow[ \t]*$/m))
        |> Enum.map(&Path.relative_to(&1, Path.expand("..", @test_root)))
        |> MapSet.new()

      recorded = SlowTests.entries() |> Enum.map(&(&1.test |> String.split(":") |> hd()))

      for file <- tagged_files do
        assert Enum.any?(recorded, &(&1 == file)),
               "#{file} carries an @tag :slow with no Platform.SlowTests entry — " <>
                 "it is excluded from the default run for an unrecorded reason"
      end
    end
  end
end
