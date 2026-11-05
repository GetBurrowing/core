defmodule Platform.People.IdentityTest do
  use ExUnit.Case, async: true

  alias Platform.People.Identity

  # Invented names only.
  @roster [
    %{slug: "marisol-tennebrook", name: "Marisol Tennebrook", aliases: ["Mari"], user_id: "u-1"},
    %{slug: "oskar-vellinghausen", name: "Oskar Vellinghausen", aliases: [], user_id: "u-2"},
    %{slug: "oskar-velinghausen", name: "Oskar Velinghausen", aliases: [], user_id: "u-3"},
    %{slug: "priya-kalloway", name: "Priya Kalloway", aliases: [], user_id: nil}
  ]

  test "a transcription variant resolves to the one person" do
    assert {:match, "marisol-tennebrook"} = Identity.resolve("Marisol Tenebrook", @roster)
    assert {:match, "marisol-tennebrook"} = Identity.resolve("Marisol Tennabrook", @roster)
    assert {:match, "marisol-tennebrook"} = Identity.resolve("Tenebrook", @roster)
    assert {:match, "marisol-tennebrook"} = Identity.resolve("@[Dr. Marisol Tennebrook]", @roster)
    assert {:match, "marisol-tennebrook"} = Identity.resolve("@Mari", @roster)
  end

  test "a first name resolves only when unique" do
    assert {:match, "priya-kalloway"} = Identity.resolve("Priya", @roster)
    assert {:match, "marisol-tennebrook"} = Identity.resolve("marisol", @roster)

    assert {:ambiguous, ["oskar-velinghausen", "oskar-vellinghausen"]} =
             Identity.resolve("Oskar", @roster)
  end

  test "two close candidates are ambiguous, never merged" do
    # 0.981 vs 0.965: both above threshold and inside the 0.03 window.
    assert {:ambiguous, slugs} = Identity.resolve("Oskar Velinghausn", @roster)
    assert Enum.sort(slugs) == ["oskar-velinghausen", "oskar-vellinghausen"]

    # A mention below the threshold is unknown, not guessed between the two
    # (0.69 / 0.687 against the pair).
    assert :unknown = Identity.resolve("Osker Vel", @roster)

    # Tightening the threshold never produces a match out of ambiguity.
    assert {:ambiguous, _} = Identity.resolve("Oskar Velinghausn", @roster, threshold: 0.9)
    refute match?({:match, _}, Identity.resolve("Oskar Velinghausn", @roster, threshold: 0.5))
  end

  test "an unknown name is :unknown" do
    assert :unknown = Identity.resolve("Zephyrine Quoll", @roster)
    assert :unknown = Identity.resolve("", @roster)
    assert :unknown = Identity.resolve(nil, @roster)
    assert :unknown = Identity.resolve("Priya", [])
  end

  test "normalize_key strips wrappers, honorifics, diacritics and punctuation" do
    assert Identity.normalize_key("@[Dr. Marisol  Tennebrook]") == "marisol tennebrook"
    assert Identity.normalize_key("Ms Priya Kálloway") == "priya kalloway"
    assert Identity.normalize_key("  @oskar ") == "oskar"
  end

  test "slug_for is hyphenated and collision-safe" do
    assert Identity.slug_for("Dr. Priya Kalloway") == "priya-kalloway"
    assert Identity.slug_for("Priya Kalloway", ["priya-kalloway"]) == "priya-kalloway-2"

    assert Identity.slug_for("Priya Kalloway", ["priya-kalloway", "priya-kalloway-2"]) ==
             "priya-kalloway-3"
  end
end
