defmodule Platform.Chat.SidebarMaskTest do
  # Pure functions — no DB, no DataCase.
  use ExUnit.Case, async: true

  alias Platform.Chat.SidebarMask

  defp section(id, name), do: %{id: id, name: name}
  defp resolved(id, name), do: %{section: section(id, name), channels: []}

  describe "placeholders/1" do
    test "letters follow the given display order, not id order or name order" do
      # Ids and names are both deliberately anti-sorted against display order.
      sections = [
        resolved("zzz", "Cyberdyne"),
        resolved("aaa", "Wayne-Tech"),
        resolved("mmm", "SXI")
      ]

      assert SidebarMask.placeholders(sections) == %{
               "zzz" => "Workspace A",
               "aaa" => "Workspace B",
               "mmm" => "Workspace C"
             }
    end

    test "a section keeps its letter across repeated calls" do
      sections = [resolved("a", "Wayne-Tech"), resolved("b", "SXI")]

      assert SidebarMask.placeholders(sections) == SidebarMask.placeholders(sections)
      assert SidebarMask.placeholders(sections)["b"] == "Workspace B"
    end

    test "rolls over past 26 sections" do
      sections = for i <- 1..30, do: resolved("s#{i}", "Org #{i}")
      placeholders = SidebarMask.placeholders(sections)

      assert placeholders["s26"] == "Workspace Z"
      assert placeholders["s27"] == "Workspace AA"
      assert placeholders["s28"] == "Workspace AB"
      assert placeholders["s30"] == "Workspace AD"
    end

    test "empty list yields an empty map" do
      assert SidebarMask.placeholders([]) == %{}
    end
  end

  describe "label/4" do
    setup do
      sections = [resolved("a", "Wayne-Tech"), resolved("b", "SXI")]
      %{placeholders: SidebarMask.placeholders(sections), sections: sections}
    end

    test "returns the real name when masking is off", %{placeholders: p} do
      assert SidebarMask.label(p, section("a", "Wayne-Tech"), false, MapSet.new()) == "Wayne-Tech"
    end

    test "returns the placeholder when masking is on", %{placeholders: p} do
      assert SidebarMask.label(p, section("a", "Wayne-Tech"), true, MapSet.new()) == "Workspace A"
      assert SidebarMask.label(p, section("b", "SXI"), true, MapSet.new()) == "Workspace B"
    end

    test "returns the real name for a revealed id while masking is still on", %{placeholders: p} do
      revealed = MapSet.new(["a"])

      assert SidebarMask.label(p, section("a", "Wayne-Tech"), true, revealed) == "Wayne-Tech"
      # One reveal must not leak the rest.
      assert SidebarMask.label(p, section("b", "SXI"), true, revealed) == "Workspace B"
    end

    test "an unknown section falls back to the generic placeholder, never the real name" do
      assert SidebarMask.label(%{}, section("ghost", "Cyberdyne"), true, MapSet.new()) ==
               "Workspace"
    end
  end

  # ── Stage 6 regression: derived channel names ────────────────────────────
  #
  # Stages 2-5 matched by EXACT normalised equality, so `#cyberdyne`
  # masked and `#cyberdyne-builds` rendered verbatim — in the rail, the
  # drawer, the drawer's SEARCH results, the composer placeholder and the
  # browser tab. The tab read `# cyberdyne-builds` directly above a chat
  # header reading `Workspace F`. These tests go red against a53c7e6f.
  describe "names_org?/2 — leading-token match (stage 6)" do
    test "matches a channel derived from the org name by a leading token" do
      cyberdyne = section("w", "Cyberdyne")

      # The pre-stage-6 behaviour, still correct.
      assert SidebarMask.names_org?("cyberdyne", cyberdyne)

      # The leak stage 6 closes.
      assert SidebarMask.names_org?("cyberdyne-builds", cyberdyne)
      assert SidebarMask.names_org?("Cyberdyne Builds", cyberdyne)
      assert SidebarMask.names_org?("cyberdyne_builds_qa", cyberdyne)
    end

    test "matches against the colour slug too, not only the display name" do
      section = %{id: "s", name: "Small Business Solutions", color: "sxi"}

      assert SidebarMask.names_org?("sxi-crosspost", section)
    end

    test "is a LEADING token only — not a free substring match" do
      cyberdyne = section("w", "Cyberdyne")

      refute SidebarMask.names_org?("builds-cyberdyne", cyberdyne)
      refute SidebarMask.names_org?("retro-cyberdyne-notes", cyberdyne)
      # No token boundary: `cyberdyneery` is a different word, not a
      # channel derived from the org.
      refute SidebarMask.names_org?("cyberdyneery", cyberdyne)
    end

    test "an empty candidate never matches — a section with no colour is not a wildcard" do
      refute SidebarMask.names_org?("anything", %{id: "s", name: "", color: nil})
    end

    test "#orion stays unmasked — pinning the named limitation against a keyword list" do
      # `#orion` is a PROJECT CODE. It shares no token with any org name, so
      # no inference rule reaches it, and the documented residual says so. If
      # this ever goes green, someone has added the hardcoded keyword list the
      # moduledoc refuses — which reads as coverage the feature does not have
      # and is stale the day a new client arrives.
      for org <- ["Cyberdyne", "Wayne-Tech", "SXI", "Soylent", "Paragon"] do
        refute SidebarMask.names_org?("orion", section("s", org)),
               "#orion must not mask under #{org} — no rule can infer it"

        refute SidebarMask.names_org?("stark-industries", section("s", org))
      end
    end

    test "channel_label/3 renders the derived channel as the section placeholder" do
      sections = [resolved("a", "Wayne-Tech"), resolved("w", "Cyberdyne")]
      ctx = SidebarMask.context(sections, true, MapSet.new())

      assert SidebarMask.channel_label(ctx, section("w", "Cyberdyne"), "cyberdyne-builds") ==
               "workspace-b"

      # …and #orion in that same section still renders verbatim.
      assert SidebarMask.channel_label(ctx, section("w", "Cyberdyne"), "orion") == "orion"
    end

    test "space_label/3 masks the derived name for the tab title and chat header" do
      sections = [resolved("a", "Wayne-Tech"), resolved("w", "Cyberdyne")]
      ctx = SidebarMask.context(sections, true, MapSet.new())

      assert SidebarMask.space_label(ctx, sections, "cyberdyne-builds") == "workspace-b"
      assert SidebarMask.space_label(ctx, sections, "orion") == "orion"
    end
  end
end
