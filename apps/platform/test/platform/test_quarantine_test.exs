defmodule Platform.TestQuarantineTest do
  @moduledoc """
  Invariants that make `Platform.TestQuarantine` load-bearing rather than a
  document that rots.

  The central claim under test is narrow and worth stating plainly: **a
  `:deterministic` or `:unexplained` entry cannot be excluded from `mix test`,
  and the thing that stops it is its CLASS.**

  That distinction matters because there are two ways an entry can fail to
  reach the exclusion list — its class forbids it, or it simply has no ExUnit
  tag. Only the first is a guarantee. So the discrimination tests below drive
  `excluded_tags/1` with synthetic entries that hold the tag fixed and vary
  ONLY the class, rather than asserting over whichever entries the registry
  happens to contain today. The real registry is then checked for
  non-vacuity — it must actually hold a tagged `:deterministic` entry — so the
  guarantee is exercised against live data too.
  """

  use ExUnit.Case, async: true

  alias Platform.TestQuarantine

  @test_root Path.expand("..", __DIR__)
  @test_helper Path.join(@test_root, "test_helper.exs")

  describe "entry schema" do
    test "every entry carries exactly the required keys" do
      required = MapSet.new(TestQuarantine.required_keys())

      for entry <- TestQuarantine.entries() do
        assert MapSet.new(Map.keys(entry)) == required,
               "entry #{inspect(entry[:test])} has keys #{inspect(Map.keys(entry))}, " <>
                 "expected exactly #{inspect(TestQuarantine.required_keys())}"
      end
    end

    test "every :class is one of the recognised classes" do
      for entry <- TestQuarantine.entries() do
        assert entry.class in TestQuarantine.classes(),
               "#{entry.test} has unknown class #{inspect(entry.class)}"
      end
    end

    test "every :deterministic entry carries a non-empty ticket" do
      for entry <- TestQuarantine.classified(:deterministic) do
        assert is_binary(entry.ticket) and String.trim(entry.ticket) != "",
               "#{entry.test} is :deterministic — a broken test needs an owner, " <>
                 "got ticket #{inspect(entry.ticket)}"
      end
    end

    test "every entry carries a substantive reason and a Date" do
      for entry <- TestQuarantine.entries() do
        assert is_binary(entry.reason) and String.length(String.trim(entry.reason)) > 60,
               "#{entry.test} needs a reason that explains the failure, not a label"

        assert %Date{} = entry.added_on
      end
    end

    test "test locators are unique and non-empty" do
      locators = Enum.map(TestQuarantine.entries(), & &1.test)

      assert Enum.all?(locators, &(is_binary(&1) and String.trim(&1) != ""))
      assert length(Enum.uniq(locators)) == length(locators), "duplicate :test locator"
    end

    test "tags are unique where present" do
      tags = TestQuarantine.entries() |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1)

      assert Enum.all?(tags, &is_atom/1)
      assert length(Enum.uniq(tags)) == length(tags), "duplicate :tag"
    end

    test "every declared tag exists as a real ExUnit tag in the test tree" do
      # A fabricated tag would make an entry look gated when it gates nothing.
      sources =
        Path.wildcard(Path.join(@test_root, "**/*.exs"))
        |> Enum.reject(&(&1 == Path.join(@test_root, "platform/test_quarantine_test.exs")))
        |> Enum.map_join("\n", &File.read!/1)

      for entry <- TestQuarantine.entries(), entry.tag != nil do
        assert sources =~ ~r/@(module)?tag\s+#{Regex.escape(inspect(entry.tag))}\b/,
               "#{entry.test} declares tag #{inspect(entry.tag)}, " <>
                 "but no test in the tree carries `@tag #{inspect(entry.tag)}`"
      end
    end
  end

  describe "excluded_tags/1 — the rule the registry exists for" do
    test "class, not the presence of a tag, is what decides excludability" do
      # Same tag in every row. Only :class varies. If the class filter is
      # removed or reordered after the nil-tag filter, this table goes red.
      for {class, expected} <- [
            {:intermittent, [:probe]},
            {:environment, [:probe]},
            {:deterministic, []},
            {:unexplained, []}
          ] do
        entry = %{
          tag: :probe,
          test: "synthetic",
          class: class,
          ticket: "probe",
          reason: "synthetic probe",
          added_on: ~D[2026-07-26]
        }

        assert TestQuarantine.excluded_tags([entry]) == expected,
               "a #{inspect(class)} entry with tag :probe should " <>
                 if(expected == [], do: "NOT be excludable", else: "be excludable")
      end
    end

    test ":deterministic and :unexplained are absent from excludable_classes/0" do
      refute :deterministic in TestQuarantine.excludable_classes()
      refute :unexplained in TestQuarantine.excludable_classes()
      assert :intermittent in TestQuarantine.excludable_classes()
      assert :environment in TestQuarantine.excludable_classes()
    end

    test "an untagged excludable entry is recorded but not gated" do
      untagged = %{
        tag: nil,
        test: "synthetic",
        class: :intermittent,
        ticket: nil,
        reason: "synthetic probe",
        added_on: ~D[2026-07-26]
      }

      assert TestQuarantine.excluded_tags([untagged]) == []
    end
  end

  describe "the live registry" do
    test "no tag of a :deterministic or :unexplained entry reaches excluded_tags/0" do
      excluded = TestQuarantine.excluded_tags()

      for class <- [:deterministic, :unexplained],
          entry <- TestQuarantine.classified(class),
          entry.tag != nil do
        refute entry.tag in excluded,
               "#{entry.test} is #{inspect(class)} but its tag #{inspect(entry.tag)} " <>
                 "is on the exclusion list — a #{inspect(class)} entry must stay loud"
      end
    end

    test "a tagged :intermittent entry IS on the exclusion list" do
      tagged = Enum.filter(TestQuarantine.classified(:intermittent), &(&1.tag != nil))

      refute tagged == [],
             "registry holds no tagged :intermittent entry, so the positive half " <>
               "of the exclusion rule is untested against live data"

      excluded = TestQuarantine.excluded_tags()

      for entry <- tagged do
        assert entry.tag in excluded, "#{entry.test} should be excluded"
      end
    end

    test "the registry holds a TAGGED :deterministic entry" do
      # Non-vacuity guard for the refute above. Without a tagged :deterministic
      # entry, "no deterministic tag is excluded" is true because there are no
      # deterministic tags — which proves nothing about the class filter.
      tagged = Enum.filter(TestQuarantine.classified(:deterministic), &(&1.tag != nil))

      refute tagged == [],
             "no :deterministic entry carries a tag, so the exclusion rule is " <>
               "vacuously satisfied against live data. Tag one (a tag never " <>
               "excludes a :deterministic entry) or accept that this invariant " <>
               "is only exercised synthetically."
    end

    test "every class has at least one live entry" do
      for class <- TestQuarantine.classes() do
        refute TestQuarantine.classified(class) == [],
               "class #{inspect(class)} has no entries — either it is not earning " <>
                 "its place in the taxonomy, or an entry was misfiled"
      end
    end

    test "recorded_only/0 holds every entry that does not gate anything" do
      excluded = TestQuarantine.excluded_tags()
      recorded = TestQuarantine.recorded_only()

      assert Enum.all?(recorded, &(&1.tag not in excluded))

      for entry <- TestQuarantine.entries(), entry.tag == nil do
        assert entry in recorded
      end
    end
  end

  describe "test_helper wiring" do
    test "every excluded tag is actually excluded by the running suite" do
      configured = ExUnit.configuration()[:exclude] |> List.wrap() |> MapSet.new()

      for tag <- TestQuarantine.excluded_tags() do
        assert MapSet.member?(configured, tag),
               "#{inspect(tag)} is in excluded_tags/0 but not in the running " <>
                 "ExUnit exclude config — test_helper.exs has drifted"
      end
    end

    test "test_helper.exs derives its exclusion list and hardcodes nothing" do
      # Subset above cannot catch a revert to a hardcoded list that happens to
      # match today's registry contents. This can.
      source = File.read!(@test_helper)

      assert source =~ "Platform.TestQuarantine.excluded_tags()",
             "test_helper.exs must call Platform.TestQuarantine.excluded_tags()"

      refute source =~ ~r/exclude:\s*\[/,
             "test_helper.exs contains a literal exclusion list — the list must " <>
               "be derived from the registry, not duplicated beside it"
    end
  end
end
