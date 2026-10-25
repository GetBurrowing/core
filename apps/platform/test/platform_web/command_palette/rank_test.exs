defmodule PlatformWeb.CommandPalette.RankTest do
  @moduledoc """
  `PlatformWeb.CommandPalette.Rank.rank/2` (Burrow redesign 23, stage 1): the
  tiers, the in-tier order, the cap, the empty query and the archived rule.
  Pure, so every case builds its items by hand.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.CommandPalette.Rank

  defp item(kind, label, terms \\ []) do
    %{
      id: "#{kind}:#{label}",
      kind: kind,
      label: label,
      icon: "hero-x-mark",
      path: "/",
      terms: terms
    }
  end

  defp labels(items), do: Enum.map(items, & &1.label)

  describe "tiers" do
    test "prefix beats word start beats substring" do
      items = [item("space", "alphabet"), item("space", "team-beta"), item("space", "beta")]

      assert labels(Rank.rank(items, "bet")) == ["beta", "team-beta", "alphabet"]
    end

    test "every word break opens a word: space, -, _, #, middle dot, /" do
      for sep <- [" ", "-", "_", "#", "·", "/"] do
        items = [item("space", "zebra"), item("space", "ops#{sep}zeb")]
        assert labels(Rank.rank(items, "zeb")) == ["zebra", "ops#{sep}zeb"], inspect(sep)

        # A word start outranks a plain substring.
        items = [item("space", "ozeb"), item("space", "o#{sep}zeb")]
        assert labels(Rank.rank(items, "zeb")) == ["o#{sep}zeb", "ozeb"], inspect(sep)
      end
    end

    test "a term start counts as a word start" do
      items = [item("space", "matheme"), item("settings", "Appearance", ["theme"])]

      assert labels(Rank.rank(items, "theme")) == ["Appearance", "matheme"]
    end

    test "'alp' gives alpha before alphabet regardless of Sources order" do
      for items <- [
            [item("space", "alphabet"), item("space", "alpha")],
            [item("space", "alpha"), item("space", "alphabet")]
          ] do
        assert labels(Rank.rank(items, "alp")) == ["alpha", "alphabet"]
      end
    end

    test "a kind-only match ranks last" do
      items = [item("space", "Ops"), item("canvas", "Backspace"), item("module", "Spacey")]

      assert labels(Rank.rank(items, "spac")) == ["Spacey", "Backspace", "Ops"]
    end

    test "no match at all is left out" do
      assert Rank.rank([item("space", "general")], "zzz") == []
    end

    test "the query is downcased and trimmed" do
      items = [item("space", "General")]
      assert labels(Rank.rank(items, "  GEN ")) == ["General"]
    end
  end

  describe "within a tier" do
    test "ties follow kind order: module, space, direct, canvas, settings" do
      items =
        for kind <- ~w(settings canvas direct space module), do: item(kind, "Design")

      assert Enum.map(Rank.rank(items, "design"), & &1.kind) ==
               ~w(module space direct canvas settings)
    end

    test "then the shorter label, then the downcased label, then Sources order" do
      items = [
        Map.put(item("space", "Docs"), :id, "first"),
        item("space", "docs-archive"),
        item("space", "doCa"),
        Map.put(item("space", "docs"), :id, "second")
      ]

      ranked = Rank.rank(items, "do")
      assert labels(ranked) == ["doCa", "Docs", "docs", "docs-archive"]
      assert Enum.map(Enum.slice(ranked, 1, 2), & &1.id) == ["first", "second"]
    end
  end

  describe "the cap and the empty query" do
    test "at most 14 come back" do
      items = for n <- 1..20, do: item("space", "room #{n}")

      assert length(Rank.rank(items, "room")) == 14
      assert length(Rank.rank(items, "")) == 14
    end

    test "an empty or blank query returns the first 14 in Sources order" do
      items = for n <- 20..1//-1, do: item("canvas", "c#{n}")

      assert Rank.rank(items, "") == Enum.take(items, 14)
      assert Rank.rank(items, "   ") == Enum.take(items, 14)
      assert Rank.rank(items, nil) == Enum.take(items, 14)
    end
  end

  describe "archived channels" do
    setup do
      %{items: [item("space", "general"), item("archived", "general-2019")]}
    end

    test "stay out while an active item matches", %{items: items} do
      assert labels(Rank.rank(items, "general")) == ["general"]
      assert labels(Rank.rank(items, "nera")) == ["general"]
    end

    test "enter when nothing active matches", %{items: items} do
      assert labels(Rank.rank(items, "2019")) == ["general-2019"]
    end

    test "enter when the only active hit is a kind-only match" do
      items = [item("space", "ops"), item("archived", "space-program")]

      assert labels(Rank.rank(items, "space")) == ["space-program", "ops"]
    end
  end

  test "'theme' ranks Appearance first" do
    items = [
      item("module", "Chat"),
      item("module", "Tasks"),
      item("module", "Settings"),
      item("space", "the-memo"),
      item("canvas", "Pantheme notes"),
      item("settings", "Profile", ["account", "profile"]),
      item("settings", "Appearance", ["theme", "dark", "light", "colour", "color"]),
      item("settings", "Notifications", ["notify", "alerts"])
    ]

    assert [%{label: "Appearance"} | _] = Rank.rank(items, "theme")
  end
end
