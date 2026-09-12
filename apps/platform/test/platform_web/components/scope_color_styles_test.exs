defmodule PlatformWeb.Components.ScopeColorStylesTest do
  @moduledoc """
  Task 01a09287 stage 3.

  Three things are under test, and only the third is about a bug anyone has
  seen: that a coloured org gets declarations, that an uncoloured one gets
  NOTHING (so the `text-muted` fallback survives), and that a slug which
  never passed `Org.changeset/2` cannot break out of the selector it is
  interpolated into.

  The hostile-slug case constructs its row as a bare map, bypassing the
  changeset, because that is the only way the dangerous value can exist:
  the point of the guard is that it does not trust the writer.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PlatformWeb.Components.ScopeColorStyles

  defp render(entries) do
    render_component(&ScopeColorStyles.scope_color_styles/1, entries: entries)
  end

  describe "an org with a colour" do
    test "emits a light rule with an oklch fill and a dark label override" do
      html = render([%{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}])

      assert html =~ ~s([data-scope="acme"]{)
      assert html =~ ~s([data-theme=dark] [data-scope="acme"]{)
      assert html =~ "--scope-fill:oklch("
      assert html =~ "--scope-active-content:oklch("

      # Both label values are present and they DIFFER: the two theme grounds
      # are 17.21:1 apart, below the 4.5^2 = 20.25 a single colour would
      # need, so a light/dark pair that coincided would mean the solver was
      # not being consulted per-ground. See ScopeColor's moduledoc.
      ramp = Platform.Tenancy.ScopeColor.derive(15, 0.15)
      refute ramp.label_light == ramp.label_dark
      assert html =~ "--scope-label:#{ramp.label_light}"
      assert html =~ "--scope-label:#{ramp.label_dark}"
    end

    test "sxi, the shipped hue, is emitted at AA on both grounds" do
      # sxi is called out by name because it is where a recomputation went
      # wrong: at oklch(51% 0.15 162) the linear-sRGB red channel is
      # -0.041996, i.e. outside the sRGB gamut, and `ScopeColor`'s private
      # `encode/1` used to fold that sign with `abs/1` instead of clipping
      # it, reporting 4.37 where Chrome 152 paints rgb(0,127,74) and
      # measures 4.56. Stage 4 fixed it to clip; 4.37 is withdrawn and is
      # asserted against in ScopeColorTest.
      ramp = Platform.Tenancy.ScopeColor.derive(162, 0.15)

      html = render([%{slug: "sxi", label: "SXI", hue: 162, chroma: 0.15}])
      assert html =~ "--scope-label:#{ramp.label_light}"
      assert ramp.contrast_light >= 4.5
      assert ramp.contrast_dark >= 4.5
    end

    test "both solved labels clear WCAG AA against the tint they sit on" do
      ramp = Platform.Tenancy.ScopeColor.derive(15, 0.15)
      assert ramp.contrast_light >= 4.5
      assert ramp.contrast_dark >= 4.5
    end
  end

  describe "an org with no colour" do
    test "emits no rule for its slug" do
      html = render([%{slug: "colourless", label: "Colourless", hue: nil, chroma: 0.15}])

      refute html =~ "colourless"
      refute html =~ "--scope-fill"
    end

    test "does not suppress a coloured sibling in the same list" do
      html =
        render([
          %{slug: "colourless", label: "Colourless", hue: nil, chroma: 0.15},
          %{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}
        ])

      refute html =~ "colourless"
      assert html =~ ~s([data-scope="acme"]{)
    end
  end

  describe "a slug that never passed the changeset" do
    test "is dropped, and neither quote nor brace reaches the stylesheet" do
      hostile = ~s(evil"]{color:red}body{display:none)

      html =
        render([
          %{slug: hostile, label: "Evil", hue: 200, chroma: 0.15},
          %{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}
        ])

      refute html =~ "evil"
      refute html =~ "display:none"

      # The legitimate sibling still renders — the guard drops a row, it does
      # not abandon the block. Without this the test would pass on a
      # component that emitted nothing at all.
      assert html =~ ~s([data-scope="acme"]{)

      # Nothing inside any selector but the one slug we authorised. Strip the
      # known-good rules and assert what is left carries no CSS punctuation
      # from the hostile string.
      selectors = Regex.scan(~r/\[data-scope="([^"]*)"\]/, html) |> Enum.map(&Enum.at(&1, 1))
      assert selectors == ["acme", "acme"]
    end

    test "drops the other CSS-breaking characters too" do
      for bad <- [
            ~s(a"b),
            "a}b",
            "a{b",
            "a;b",
            "a<b",
            "A-upper",
            "1leading",
            "has space",
            "",
            "acme\n",
            "\nacme"
          ] do
        assert ScopeColorStyles.css_for([%{slug: bad, label: "x", hue: 15, chroma: 0.15}]) == "",
               "slug #{inspect(bad)} was not dropped"
      end
    end

    test "accepts every character the changeset's own regex allows" do
      refute ScopeColorStyles.css_for([%{slug: "a-b_c9", label: "x", hue: 15, chroma: 0.15}]) ==
               ""
    end
  end
end
