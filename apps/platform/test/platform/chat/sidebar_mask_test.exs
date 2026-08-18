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

  # ── Task 01a00cf1: the id/prefix arities the Tasks rail needs ────────────
  #
  # The Tasks rail has no section struct: its org identity is a SLUG STRING
  # and its display name comes from a function call. It also carries TWO
  # entity kinds (orgs and projects) in one rail. Hence `placeholders/2` and
  # `label/5` rather than a forked module.
  describe "placeholders/2 — id + prefix" do
    test "letters follow given display order under a caller-supplied prefix" do
      entries = [{"zzz", "Cyberdyne"}, {"aaa", "Wayne-Tech"}, {"mmm", "SXI"}]

      assert SidebarMask.placeholders(entries, "Workspace") == %{
               "zzz" => "Workspace A",
               "aaa" => "Workspace B",
               "mmm" => "Workspace C"
             }

      assert SidebarMask.placeholders(entries, "Project") == %{
               "zzz" => "Project A",
               "aaa" => "Project B",
               "mmm" => "Project C"
             }
    end

    test "accepts %{id: _, name: _} maps as well as two-tuples" do
      tuples = [{"a", "One"}, {"b", "Two"}]
      maps = [%{id: "a", name: "One"}, %{id: "b", name: "Two"}]

      assert SidebarMask.placeholders(maps, "Project") ==
               SidebarMask.placeholders(tuples, "Project")
    end

    test "rolls over past 26 entries" do
      entries = for i <- 1..30, do: {"e#{i}", "Name #{i}"}
      placeholders = SidebarMask.placeholders(entries, "Project")

      assert placeholders["e26"] == "Project Z"
      assert placeholders["e27"] == "Project AA"
      assert placeholders["e30"] == "Project AD"
    end

    test "empty list yields an empty map" do
      assert SidebarMask.placeholders([], "Workspace") == %{}
    end

    test "agrees with placeholders/1 for the chat shape" do
      sections = [resolved("a", "Wayne-Tech"), resolved("b", "SXI")]
      entries = [{"a", "Wayne-Tech"}, {"b", "SXI"}]

      assert SidebarMask.placeholders(sections) ==
               SidebarMask.placeholders(entries, "Workspace")
    end
  end

  describe "label/5 — id + name" do
    setup do
      %{
        workspace: SidebarMask.placeholders([{"a", "Wayne-Tech"}, {"b", "SXI"}], "Workspace"),
        project: SidebarMask.placeholders([{"p1", "Orbit"}, {"p2", "Ascent"}], "Project")
      }
    end

    test "returns the real name when masking is off", %{workspace: p} do
      assert SidebarMask.label(p, "a", "Wayne-Tech", false, MapSet.new()) == "Wayne-Tech"
    end

    test "returns the prefixed placeholder when masking is on", %{workspace: w, project: pr} do
      assert SidebarMask.label(w, "a", "Wayne-Tech", true, MapSet.new()) == "Workspace A"
      assert SidebarMask.label(w, "b", "SXI", true, MapSet.new()) == "Workspace B"
      assert SidebarMask.label(pr, "p1", "Orbit", true, MapSet.new()) == "Project A"
      assert SidebarMask.label(pr, "p2", "Ascent", true, MapSet.new()) == "Project B"
    end

    test "a revealed id shows its real name; the rest stay masked", %{workspace: p} do
      revealed = MapSet.new(["a"])

      assert SidebarMask.label(p, "a", "Wayne-Tech", true, revealed) == "Wayne-Tech"
      assert SidebarMask.label(p, "b", "SXI", true, revealed) == "Workspace B"
    end

    test "a plain LIST of revealed ids behaves like the MapSet", %{workspace: p} do
      assert SidebarMask.label(p, "a", "Wayne-Tech", true, ["a"]) == "Wayne-Tech"
      assert SidebarMask.label(p, "b", "SXI", true, ["a"]) == "Workspace B"
    end

    test "FAIL CLOSED: an unknown id returns the bare prefix, never the real name",
         %{workspace: w, project: pr} do
      assert SidebarMask.label(w, "ghost", "Cyberdyne", true, MapSet.new()) == "Workspace"
      assert SidebarMask.label(pr, "ghost", "Cyberdyne", true, MapSet.new()) == "Project"
    end

    test "FAIL CLOSED against an empty placeholder map too" do
      assert SidebarMask.label(%{}, "ghost", "Cyberdyne", true, MapSet.new()) == "Workspace"
    end

    test "agrees with label/4 for the chat shape" do
      sections = [resolved("a", "Wayne-Tech"), resolved("b", "SXI")]
      p = SidebarMask.placeholders(sections)

      for masked? <- [true, false], id_name <- [{"a", "Wayne-Tech"}, {"b", "SXI"}] do
        {id, name} = id_name

        assert SidebarMask.label(p, section(id, name), masked?, MapSet.new()) ==
                 SidebarMask.label(p, id, name, masked?, MapSet.new())
      end
    end
  end
end
