defmodule Platform.Tenancy.ScopeColorTest do
  @moduledoc """
  Task 01a09287 stage 1; per-surface solve from task 01a09333-d374 stage 2.

  The load-bearing tests here are the sweeps: they turn "a chip label must be
  legible where it sits, in both themes" from a comment in `app.css` into a
  property the build enforces for every hue an operator can pick, not just
  the six somebody happened to hand-author.

  Since task 01a09333-d374 each label has exactly ONE ground, its own
  surface's opaque tint, so a sweep over hue x chroma x surface x theme is
  the complete set of conditions a label is solved for rather than a sample
  of them.
  """
  use ExUnit.Case, async: true

  alias Platform.Tenancy.ScopeColor

  # Parses the L back out of an `oklch(L% C H)` string, as a percentage.
  defp lightness(oklch) do
    [l | _] =
      oklch
      |> String.replace(~r/^oklch\(|\)$/, "")
      |> String.split(" ")

    {value, _} = Float.parse(l)
    value
  end

  # The chroma and hue of an `oklch(L% C H)` string, as written.
  defp chroma_hue(oklch) do
    [_l, c, h] =
      oklch
      |> String.replace(~r/^oklch\(|\)$/, "")
      |> String.split(" ")

    {c, h}
  end

  # A colour as the browser paints it, in 0..1. `composite_painted/3` at
  # alpha 1.0 is the colour alone; the surface argument is ignored there.
  defp painted(color) do
    {r, g, b} = ScopeColor.composite_painted(color, 1.0, "#000000").rgb
    {r / 255, g / 255, b / 255}
  end

  defp floor_on(label, tint_hex),
    do: ScopeColor.floor_contrast(painted(label), [%{ground: painted(tint_hex)}])

  defp painted_hex(color), do: ScopeColor.composite_painted(color, 1.0, "#000000").hex

  defp hex_bytes("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  # ── The sweep population ─────────────────────────────────────────────
  #
  # The four shipped chromas, PLUS two chromas relative to what is reachable
  # at the fill lightness. One chroma sampled round the circle is not a
  # representative sample: reachable chroma at L 72% runs from 0.1224 at hue
  # 200 to 0.2966 at hue 328 (measured with `max_chroma/2`), so 0.20 is
  # clipped hard in the low-chroma arc and barely a third of the gamut in the
  # magenta one. Half-reach and full-reach put a point in-gamut at every hue.
  @shipped_chromas [0.15, 0.16, 0.19, 0.20]

  defp chromas(hue) do
    reach = ScopeColor.max_chroma(0.72, hue)
    @shipped_chromas ++ [Float.round(reach * 0.5, 4), Float.round(reach, 4)]
  end

  defp sweep do
    for hue <- 0..359,
        chroma <- chromas(hue),
        ramp = ScopeColor.derive(hue, chroma),
        theme <- [:light, :dark],
        cell <- Map.fetch!(ramp.cells, theme) do
      Map.merge(cell, %{
        hue: hue,
        chroma: chroma,
        theme: theme,
        fill: ramp.fill,
        name: "hue #{hue} C=#{chroma} #{theme} #{cell.cell}"
      })
    end
  end

  setup_all do
    %{sweep: sweep()}
  end

  describe "derive/2 — the AA-on-both-themes property" do
    test "every hue 0..359 clears AA on BOTH themes, on every surface" do
      failures =
        for hue <- 0..359,
            chroma <- @shipped_chromas,
            ramp = ScopeColor.derive(hue, chroma),
            ramp.contrast_light < 4.5 or ramp.contrast_dark < 4.5 do
          {hue, chroma, ramp.worst_light.cell, Float.round(ramp.contrast_light, 3),
           ramp.worst_dark.cell, Float.round(ramp.contrast_dark, 3)}
        end

      assert failures == [],
             """
             Hues whose worst solved cell fails WCAG AA (4.5:1) in at least
             one theme, as {hue, chroma, worst light cell, contrast, worst
             dark cell, contrast}:

               #{inspect(failures, limit: :infinity)}

             The two grounds are 17.21:1 apart and AA-on-both would need
             4.5^2 = 20.25, so a SINGLE value cannot satisfy this. If this
             went red after a change that collapsed a light and a dark label
             into one value, that is the cause.
             """
    end

    test "the sweep is non-vacuous — it examines 1440 hue/chroma pairs" do
      # `Enum.all?([])` is true and so is a comprehension filter that matches
      # nothing. Pin the population the assertion above ranges over.
      count =
        for(hue <- 0..359, chroma <- @shipped_chromas, do: {hue, chroma}) |> length()

      assert count == 1440
    end
  end

  describe "the cell enumeration the solver and the picker share" do
    test "cells/1 is one cell per surface, two per theme, all at the resting 12% tint" do
      # The population every per-surface assertion below ranges over. The
      # hovered 22% cells are GONE on purpose: the largest alpha that keeps
      # all twelve shipped cells at AA is 0.130, so hover cannot stay on the
      # fill and is not a ground any label is solved for. A cell set that
      # came back EMPTY would make `floor_contrast/2` raise; one that lost a
      # surface would make `derive/3`'s named fields raise.
      assert ScopeColor.cells(:light) == [
               %{surface: "base-100", color: "oklch(100% 0 0)", alpha: 0.12},
               %{surface: "base-200", color: "oklch(96% 0 0)", alpha: 0.12}
             ]

      assert ScopeColor.cells(:dark) == [
               %{surface: "base-100", color: "#171b25", alpha: 0.12},
               %{surface: "base-200", color: "oklch(9% 0.018 240)", alpha: 0.12}
             ]

      for theme <- [:light, :dark], do: assert(length(ScopeColor.cells(theme)) == 2)
    end

    test "derive/3 solves exactly the enumerated cells, and the named fields ARE those solves" do
      ramp = ScopeColor.derive(200, 0.15)

      for theme <- [:light, :dark] do
        assert Enum.map(ramp.cells[theme], & &1.surface) ==
                 Enum.map(ScopeColor.cells(theme), & &1.surface)
      end

      [l100, l200] = ramp.cells.light
      [d100, d200] = ramp.cells.dark

      assert {ramp.tint_light_100, ramp.label_light_100} == {l100.tint, l100.label}
      assert {ramp.tint_light_200, ramp.label_light_200} == {l200.tint, l200.label}
      assert {ramp.tint_dark_100, ramp.label_dark_100} == {d100.tint, d100.label}
      assert {ramp.tint_dark_200, ramp.label_dark_200} == {d200.tint, d200.label}
    end

    test "worst_* is the minimum of the theme's solves, and the admin panel prints exactly that" do
      # The panel and the solver used to keep separate cell tables and
      # drifted into a constant offset (3.74-3.81 at every hue in light).
      # The panel now prints the solver's own output; this is the assertion
      # that it stays that way and does not grow a second copy.
      for hue <- [0, 95, 162, 200, 240, 300, 330, 350] do
        ramp = ScopeColor.derive(hue, 0.15)

        for {theme, worst, contrast, floor} <- [
              {:light, ramp.worst_light, ramp.contrast_light, ramp.floor_light},
              {:dark, ramp.worst_dark, ramp.contrast_dark, ramp.floor_dark}
            ] do
          cells = ramp.cells[theme]
          assert worst == Enum.min_by(cells, & &1.contrast)
          assert contrast == worst.contrast
          assert floor == cells |> Enum.map(& &1.floor) |> Enum.min()

          ground = PlatformWeb.AdminOrgsLive.preview_ground(ramp, theme, "x")
          assert ground.worst == worst
          assert ground.cells == cells
        end
      end
    end

    test "floor_contrast/2 RAISES on an empty ground list instead of passing vacuously" do
      # A walk handed no ground would otherwise stop on its first step and
      # return the fill lightness at a contrast of 1.0.
      assert_raise Enum.EmptyError, fn -> ScopeColor.floor_contrast({0.5, 0.5, 0.5}, []) end
    end
  end

  describe "opaque tints — the bytes the browser will paint" do
    test "each tint is its fill at 12% over its OWN surface, quantised once, as #rrggbb" do
      for hue <- [0, 95, 162, 200, 240, 295, 340], chroma <- [0.15, 0.20] do
        ramp = ScopeColor.derive(hue, chroma)

        for theme <- [:light, :dark], cell <- ramp.cells[theme] do
          assert cell.tint =~ ~r/\A#[0-9a-f]{6}\z/
          assert cell.tint == ScopeColor.composite_painted(ramp.fill, 0.12, cell.color).hex
        end
      end
    end

    test "legacy's pane tint is the painted #FDF0E7, and its rail tint carries stage 1's recorded byte" do
      # Provenance against PAINTED bytes (`ScopeColorPaintedTest`), not
      # against the derivation. legacy over base-100 is one of the seven cells
      # the compositor matches exactly. legacy over base-200 is one of the five
      # it computes one byte HIGH (red and blue; painted #F1E4DB). Once a tint
      # ships as opaque hex the browser paints these bytes, so the byte no
      # longer matters for contrast; it matters to anyone expecting today's
      # painted rail colour byte for byte.
      ramp = ScopeColor.derive(50, 0.16, 0.72)

      assert ramp.tint_light_100 == "#fdf0e7"
      assert ramp.tint_light_200 == "#f2e4dc"
    end

    test "the rail tint is darker than the pane tint, channel for channel, in BOTH themes" do
      # Why the two themes need opposite surfaces (see the ordering test
      # below). Until task 01a09333-d374 stage 3 this also justified the one
      # shared label per theme (the rail label in light, the pane label in
      # dark); `ScopeColorStyles` now emits a label per surface.
      for hue <- 0..359//5, chroma <- [0.15, 0.20] do
        ramp = ScopeColor.derive(hue, chroma)

        for {pane, rail} <- [
              {ramp.tint_light_100, ramp.tint_light_200},
              {ramp.tint_dark_100, ramp.tint_dark_200}
            ] do
          {pr, pg, pb} = hex_bytes(pane)
          {rr, rg, rb} = hex_bytes(rail)

          assert rr <= pr and rg <= pg and rb <= pb,
                 "hue #{hue} C=#{chroma}: rail #{rail} is not darker than pane #{pane}"
        end
      end
    end
  end

  describe "compositing — provenance, asserted SEPARATELY from any ratio" do
    # Deliberately not folded into the AA tests above, and that separation is
    # the point rather than tidiness. Every derivation hazard in this work
    # lives in the compositing step: it is where the one-byte discrepancies
    # were, and four proposed mechanisms for them died without a survivor. If
    # a wrong chip byte can only surface as a contrast failure, it gets
    # diagnosed as a contrast problem. These tests answer "is this the right
    # chip", which is a different question from "is this ratio right".
    #
    # Reference bytes are PAINTED — read out of a browser, reproduced on two
    # machines — not derived. Pinning a derived value against the same
    # derivation would assert nothing.
    @painted_base_200_light {242, 242, 242}

    # The resting 12% chip over the light rail ground, painted.
    @painted_rail_chips %{
      "legacy" => {{"oklch(72% 0.16 50)"}, {241, 228, 219}},
      "initech" => {{"oklch(65% 0.20 295)"}, {231, 225, 242}},
      "vandelay-ind" => {{"oklch(68% 0.15 240)"}, {215, 232, 241}},
      "globex" => {{"oklch(70% 0.15 162)"}, {215, 235, 228}},
      "hooli" => {{"oklch(80% 0.16 95)"}, {239, 235, 215}},
      "wonka" => {{"oklch(66% 0.19 340)"}, {239, 223, 234}}
    }

    defp byte({r, g, b}), do: {round(r * 255), round(g * 255), round(b * 255)}

    test "the light rail ground resolves to the painted (242,242,242)" do
      # The surface every chip below composites over. If THIS is wrong every
      # chip is wrong for one reason, and the six assertions below would all
      # go red and read as six problems.
      assert byte(ScopeColor.oklch_to_srgb(0.96, 0.0, 0.0)) == @painted_base_200_light
    end

    test "every shipped chip composites to within one byte of the painted value" do
      # One byte, not zero, and the tolerance is the finding rather than a
      # concession: six of eighteen channels differ by exactly 1 and none by
      # more (legacy red and blue, initech green and blue, vandelay-ind red,
      # hooli blue; every one computed one HIGH. Re-counted 2026-09-21,
      # task 01a09333-d374, see `ScopeColorPaintedTest`). That measured
      # noise floor is WHY the solver targets a margin
      # (`floor_contrast/2` perturbs green by +/-1) instead of a bare 4.5 —
      # the tolerance here and the margin there are the same number, taken
      # from the same measurement.
      deltas =
        for {slug, {{fill}, painted}} <- @painted_rail_chips do
          {cr, cg, cb} = byte(ScopeColor.composite_ground(fill, 0.12, "oklch(96% 0 0)"))
          {pr, pg, pb} = painted
          {slug, {cr - pr, cg - pg, cb - pb}}
        end

      worst =
        deltas
        |> Enum.flat_map(fn {_slug, {r, g, b}} -> [abs(r), abs(g), abs(b)] end)
        |> Enum.max()

      assert worst <= 1, "compositing is off by more than one byte: #{inspect(deltas)}"
    end

    test "the comparison is non-vacuous — an obviously wrong chip is rejected" do
      # Without this the test above passes for a `byte/1` that returns the
      # painted tuple, or a tolerance wide enough to swallow anything. A 22%
      # chip is the same colour at the wrong alpha, which is exactly the
      # confusion a one-byte tolerance must NOT absorb.
      {{fill}, painted} = Map.fetch!(@painted_rail_chips, "legacy")
      {r, g, b} = byte(ScopeColor.composite_ground(fill, 0.22, "oklch(96% 0 0)"))
      {pr, pg, pb} = painted

      assert Enum.max([abs(r - pr), abs(g - pg), abs(b - pb)]) > 1,
             "the 22% chip is within one byte of the 12% painted value — the pin proves nothing"
    end
  end

  describe "derive/2 — each label clears AA against its OWN tint, with margin" do
    test "every cell of the sweep holds 4.5 under +/-1 on green, and the worst cell is named",
         %{sweep: cells} do
      # The FLOOR, not the nominal ratio: solving to exactly 4.5 ships labels
      # that fail on a one-byte rounding difference, and a derived sRGB byte
      # in this codebase has been wrong by one unit more than once. Both
      # sides are painted bytes: the tint as emitted, the label as the
      # browser quantises its oklch() string.
      failures = for c <- cells, c.floor < 4.5, do: {c.name, Float.round(c.floor, 4)}

      assert failures == [],
             """
             Cells whose solved label drops below AA against its own opaque
             tint under a one-byte green perturbation, as {cell, floor}:

               #{inspect(failures, limit: :infinity)}
             """

      # Reported BY NAME, not as a boolean. The walk stops at the first L
      # whose floor reaches 4.5, so the worst floor sits just above it by
      # construction; pinned so a solver change has to explain itself.
      worst = Enum.min_by(cells, & &1.floor)
      assert worst.name == "hue 235 C=0.15 light chip on base-100"
      assert_in_delta worst.floor, 4.5000, 0.0001
      assert_in_delta worst.contrast, 4.5503, 0.0001

      # The worst NOMINAL figure, which is what a browser reading reports.
      # It sits in the magenta arc at full reachable chroma, where green is
      # a small share of the label's luminance, so a one-byte green move
      # costs little (0.0048 at its thinnest) and the nominal figure lands
      # close to the floor. `floor_contrast/2` is green-only by design; its
      # doc records the same limit for wonka.
      thinnest = Enum.min_by(cells, & &1.contrast)
      assert thinnest.name == "hue 338 C=0.247 light chip on base-100"
      assert_in_delta thinnest.contrast, 4.5061, 0.0001
    end

    test "the population is 8640 cells and reaches the low-chroma arc", %{sweep: cells} do
      assert length(cells) == 360 * 6 * 4

      # The spread is only representative if it actually includes the
      # low-chroma arc near hue 200 and the high-chroma arc near 328.
      assert Enum.min(chromas(200)) < 0.07
      assert Enum.max(chromas(328)) > 0.29
      assert Enum.any?(cells, &(&1.hue == 200 and &1.chroma < 0.125))
    end

    test "each label stops at the first L that holds: one step back toward the fill breaks the floor" do
      # Without this the sweep passes for a solver that walks to pure black.
      # The label stays as close to the fill as its ONE ground allows. A
      # label that IS the fill (common in dark, where the fill already
      # clears its tint) has no step back to take.
      for hue <- [0, 95, 162, 200, 240, 300, 330, 350],
          chroma <- [0.15, Float.round(ScopeColor.max_chroma(0.72, hue), 4)],
          ramp = ScopeColor.derive(hue, chroma),
          {theme, back} <- [light: 0.5, dark: -0.5],
          cell <- ramp.cells[theme],
          lightness(cell.label) != lightness(ramp.fill) do
        l = lightness(cell.label) + back
        {c, h} = chroma_hue(cell.label)
        previous = "oklch(#{l}% #{c} #{h})"

        assert floor_on(previous, cell.tint) < 4.5,
               "hue #{hue} C=#{chroma} #{theme} #{cell.cell}: #{previous} also holds, so the walk overshot"
      end
    end

    test "the green perturbation bites on every cell, by a plausible amount", %{sweep: cells} do
      deltas = Enum.map(cells, &(&1.contrast - &1.floor))

      assert Enum.min(deltas) > 0.0, "the green perturbation changed nothing somewhere"
      assert Enum.max(deltas) < 0.2, "an implausibly large one-byte delta: #{Enum.max(deltas)}"
    end

    test "the themes need opposite surfaces: light's rail label is darker, dark's pane label is lighter" do
      # The rail tint is darker than the pane tint in both themes. A light
      # label sits BELOW its tint, so the darker (rail) tint pushes it
      # darker; a dark label sits ABOVE its tint, so the lighter (pane) tint
      # pushes it lighter. This is the per-theme shape of the defect the
      # ticket measured: light failed in the rail, dark only over base-100.
      for hue <- 0..359, chroma <- @shipped_chromas do
        ramp = ScopeColor.derive(hue, chroma)

        assert lightness(ramp.label_light_200) <= lightness(ramp.label_light_100),
               "hue #{hue} C=#{chroma}: #{ramp.label_light_200} vs #{ramp.label_light_100}"

        assert lightness(ramp.label_dark_100) >= lightness(ramp.label_dark_200),
               "hue #{hue} C=#{chroma}: #{ramp.label_dark_100} vs #{ramp.label_dark_200}"
      end
    end

    test "only L moves: every label keeps the fill's chroma and hue" do
      # The `app.css` label-block decision: "same hue + chroma as
      # text-<slug>, lower L". A label with free chroma clears every hue by
      # going achromatic and stops being the org's colour.
      for hue <- 0..359//7, chroma <- chromas(hue) do
        ramp = ScopeColor.derive(hue, chroma)

        for theme <- [:light, :dark], cell <- ramp.cells[theme] do
          assert chroma_hue(cell.label) == chroma_hue(ramp.fill), "#{cell.label} vs #{ramp.fill}"
        end
      end
    end

    test "the solved values are pinned, so a change to the solver has to explain itself" do
      legacy = ScopeColor.derive(50, 0.16)
      assert legacy.label_light_100 == "oklch(55% 0.16 50)"
      assert legacy.label_light_200 == "oklch(52.5% 0.16 50)"
      assert legacy.label_dark_100 == "oklch(72% 0.16 50)"
      assert legacy.label_dark_200 == "oklch(72% 0.16 50)"

      cyan = ScopeColor.derive(200, 0.15)
      assert cyan.label_light_100 == "oklch(50% 0.15 200)"
      assert cyan.label_light_200 == "oklch(47.5% 0.15 200)"
      assert cyan.label_dark_100 == "oklch(72% 0.15 200)"
      assert cyan.label_dark_200 == "oklch(72% 0.15 200)"

      assert {cyan.tint_light_100, cyan.tint_light_200, cyan.tint_dark_100, cyan.tint_dark_200} ==
               {"#e0f7f9", "#d5eced", "#142f39", "#00191d"}
    end
  end

  describe "derive/2 — the edge clears 3:1 against its page ground, with margin (task 01a09333-d374 stage 4)" do
    # WCAG 1.4.11 asks 3:1 for the visual boundary of an interactive
    # component. The chip's fill is 1.07-1.14:1 against its ground and the
    # old 30% alpha border 1.17-1.41:1, so the edge is a solved value: the
    # fill's hue and chroma at a lower L, walked from the fill until the
    # green-perturbed floor against the PAGE GROUND (the surface, not the
    # tint) reaches 3.0. Same population as the label sweep: 360 hues x 6
    # chromas x 2 surfaces x 2 themes, including the low-chroma arc near
    # hue 200 (see "the population is 8640 cells" above).

    test "every cell holds 3:1 under +/-1 on green, rest AND hover, and the worst cells are named",
         %{sweep: cells} do
      failures =
        for c <- cells, c.edge_floor < 3.0 or c.edge_hover_floor < 3.0 do
          {c.name, Float.round(c.edge_floor, 4), Float.round(c.edge_hover_floor, 4)}
        end

      assert failures == [],
             """
             Cells whose edge drops below 3:1 against the page ground under
             a one-byte green perturbation, as {cell, rest floor, hover floor}:

               #{inspect(failures, limit: :infinity)}
             """

      # Reported BY NAME, per theme and surface. Light walks down from a
      # 72% fill that never holds on its own, so its worst floor sits just
      # above 3.0 by construction. Dark never walks: see the next test.
      worst =
        for theme <- [:light, :dark], surface <- ["base-100", "base-200"], into: %{} do
          group = Enum.filter(cells, &(&1.theme == theme and &1.surface == surface))
          assert length(group) == 2160
          cell = Enum.min_by(group, & &1.edge_floor)
          {{theme, surface}, {cell.name, Float.round(cell.edge_floor, 4)}}
        end

      assert worst == %{
               {:light, "base-100"} => {"hue 40 C=0.0901 light chip on base-100", 3.0},
               {:light, "base-200"} => {"hue 128 C=0.16 light chip on base-200", 3.0001},
               {:dark, "base-100"} => {"hue 21 C=0.2 dark chip on base-100", 5.9457},
               {:dark, "base-200"} => {"hue 21 C=0.2 dark chip on base-200", 7.1415}
             }

      overall = Enum.min_by(cells, & &1.edge_floor)
      assert overall.name == "hue 40 C=0.0901 light chip on base-100"
      assert overall.edge_floor >= 3.0
      assert_in_delta overall.edge_floor, 3.0000, 0.0001
      assert_in_delta overall.edge_contrast, 3.0236, 0.0001

      hover = Enum.min_by(cells, & &1.edge_hover_floor)
      assert hover.name == "hue 26 C=0.2 light chip on base-100"
      assert_in_delta hover.edge_hover_floor, 3.0221, 0.0001
    end

    test "only L moves, and only down: every edge keeps the fill's hue and chroma at or below its L",
         %{sweep: cells} do
      # The `app.css` label-block invariant, "same hue + chroma, lower L",
      # applied to the edge. The hover edge is exactly one 0.5% step below.
      for c <- cells do
        assert chroma_hue(c.edge) == chroma_hue(c.fill), "#{c.name}: #{c.edge} vs #{c.fill}"
        assert chroma_hue(c.edge_hover) == chroma_hue(c.fill), c.name
        assert lightness(c.edge) <= lightness(c.fill), "#{c.name}: #{c.edge} above #{c.fill}"
        assert_in_delta lightness(c.edge_hover), lightness(c.edge) - 0.5, 1.0e-9
      end
    end

    test "every dark edge IS the fill: a 72% fill already clears 3:1 on both dark grounds",
         %{sweep: cells} do
      # Walking from the fill, as the label does, stops at once in dark.
      # This is the same convention that makes legacy's dark label its fill
      # (see the moduledoc), and it makes the dark edge the full-saturation
      # fill at 5.9-10.0:1. Pinned so a change to the walk has to say so.
      dark = Enum.filter(cells, &(&1.theme == :dark))
      assert length(dark) == 4320
      assert Enum.all?(dark, &(&1.edge == &1.fill))
    end

    test "each light edge stops at the first L that holds: one step back toward the fill breaks it" do
      # Without this the sweep passes for a solver that walks every edge to
      # black. Light only: dark edges are the fill and have no step back.
      for hue <- [0, 40, 95, 128, 162, 200, 240, 300, 328, 350],
          chroma <- [0.15, Float.round(ScopeColor.max_chroma(0.72, hue), 4)],
          ramp = ScopeColor.derive(hue, chroma),
          cell <- ramp.cells.light,
          lightness(cell.edge) != lightness(ramp.fill) do
        {c, h} = chroma_hue(cell.edge)
        previous = "oklch(#{lightness(cell.edge) + 0.5}% #{c} #{h})"

        assert floor_on(previous, painted_hex(cell.color)) < 3.0,
               "hue #{hue} C=#{chroma} #{cell.cell}: #{previous} also holds, so the walk overshot"
      end
    end

    test "rest and hover paint different bytes on every cell; the step between them is pinned",
         %{sweep: cells} do
      # A state carried by colour owes two figures: each state against its
      # ground (above) and the states against each other (here). One 0.5%
      # step of L moves the edge by 1.0055-1.0266:1, well under what a
      # reader perceives as a change. The step size is `@hover_step` in
      # ScopeColor, set by the stage 4 decision; this pin makes any change
      # to it restate these figures.
      same = for c <- cells, painted_hex(c.edge) == painted_hex(c.edge_hover), do: c.name
      assert same == []

      {least, most} = Enum.min_max_by(cells, & &1.edge_rest_to_hover)
      assert least.name == "hue 23 C=0.2 light chip on base-100"
      assert_in_delta least.edge_rest_to_hover, 1.0055, 0.0001
      assert most.name == "hue 291 C=0.079 light chip on base-200"
      assert_in_delta most.edge_rest_to_hover, 1.0266, 0.0001
    end

    test "the edge against its own tint is reported, not solved, and dips below 3:1", %{
      sweep: cells
    } do
      # The edge's outer neighbour is the page, which is what it is solved
      # against. Its inner neighbour is the chip's tint, and nothing is
      # solved to that. Recorded so nobody reads the 3:1 above as covering
      # both sides of the line.
      thinnest = Enum.min_by(cells, & &1.edge_on_tint)
      assert thinnest.name == "hue 328 C=0.2966 light chip on base-200"
      assert_in_delta thinnest.edge_on_tint, 2.6190, 0.0001
    end

    test "the solved edges are pinned, so a change to the solver has to explain itself" do
      legacy = ScopeColor.derive(50, 0.16)

      assert {legacy.edge_light_100, legacy.edge_light_200, legacy.edge_dark_100,
              legacy.edge_dark_200} ==
               {"oklch(68% 0.16 50)", "oklch(65% 0.16 50)", "oklch(72% 0.16 50)",
                "oklch(72% 0.16 50)"}

      assert {legacy.edge_hover_light_100, legacy.edge_hover_light_200} ==
               {"oklch(67.5% 0.16 50)", "oklch(64.5% 0.16 50)"}

      cyan = ScopeColor.derive(200, 0.15)

      assert {cyan.edge_light_100, cyan.edge_light_200, cyan.edge_dark_100, cyan.edge_dark_200} ==
               {"oklch(63.5% 0.15 200)", "oklch(60.5% 0.15 200)", "oklch(72% 0.15 200)",
                "oklch(72% 0.15 200)"}

      assert Enum.map(
               [cyan.edge_light_100, cyan.edge_light_200, cyan.edge_dark_100],
               &painted_hex/1
             ) == ["#00a4ae", "#009aa5", "#00bfc9"]
    end

    # Measured 2026-09-21 in headless Chrome 153 (--force-color-profile=srgb,
    # DPR 1): each value painted as a DOM swatch AND as a 1px chip border
    # on the ground it ships against, read back out of a PNG screenshot,
    # instrument checked on #ffffff / #000000 / #7f3a12 first. Pasted, never
    # re-derived. The six design-direction values (canvas 01a09775), every
    # solver slot for the six at their shipped fills (what stage 5 will
    # ship), and every slot of two var-path orgs (hue 200 C 0.15 on the
    # low-chroma arc, hue 328 C 0.20).
    #
    # The same page painted each value's EMITTED hex too, swatch and border,
    # and read back exactly that hex in 76 of 76 rows: an opaque #rrggbb is
    # painted as given, which is why the edge ships as hex.
    @chrome_painted_edges [
      # design direction, light, the one L per slug the canvas derived
      {"oklch(65% 0.16 50)", "#da6c1e"},
      {"oklch(65% 0.2 295)", "#9b6efa"},
      {"oklch(63% 0.15 240)", "#0092da"},
      {"oklch(61% 0.15 162)", "#009e67"},
      {"oklch(63% 0.16 95)", "#a88600"},
      {"oklch(66% 0.19 340)", "#da5ab6"},
      # the six at their shipped fills, solver edges and hover edges
      {"oklch(68% 0.16 50)", "#e4762c"},
      {"oklch(67.5% 0.16 50)", "#e27429"},
      {"oklch(64.5% 0.16 50)", "#d86b1c"},
      {"oklch(72% 0.16 50)", "#f2823b"},
      {"oklch(71.5% 0.16 50)", "#f08139"},
      {"oklch(64.5% 0.2 295)", "#996df8"},
      {"oklch(66% 0.15 240)", "#069ce4"},
      {"oklch(65.5% 0.15 240)", "#009ae2"},
      {"oklch(62.5% 0.15 240)", "#0091d8"},
      {"oklch(68% 0.15 240)", "#19a2eb"},
      {"oklch(67.5% 0.15 240)", "#16a1e9"},
      {"oklch(64.5% 0.15 162)", "#00a971"},
      {"oklch(64% 0.15 162)", "#00a76f"},
      {"oklch(61.5% 0.15 162)", "#009f68"},
      {"oklch(70% 0.15 162)", "#15ba81"},
      {"oklch(69.5% 0.15 162)", "#0fb980"},
      {"oklch(66.5% 0.16 95)", "#b39000"},
      {"oklch(66% 0.16 95)", "#b18f00"},
      {"oklch(63.5% 0.16 95)", "#a98700"},
      {"oklch(80% 0.16 95)", "#debb19"},
      {"oklch(79.5% 0.16 95)", "#dcba14"},
      {"oklch(65.5% 0.19 340)", "#d859b4"},
      # var path: hue 200 C 0.15 and hue 328 C 0.20, every slot
      {"oklch(63.5% 0.15 200)", "#00a4ae"},
      {"oklch(63% 0.15 200)", "#00a2ad"},
      {"oklch(60.5% 0.15 200)", "#009aa5"},
      {"oklch(60% 0.15 200)", "#0099a3"},
      {"oklch(72% 0.15 200)", "#00bfc9"},
      {"oklch(71.5% 0.15 200)", "#00bec8"},
      {"oklch(69% 0.2 328)", "#da66d9"},
      {"oklch(68.5% 0.2 328)", "#d964d7"},
      {"oklch(66.5% 0.2 328)", "#d25dd0"},
      {"oklch(66% 0.2 328)", "#d05ccf"},
      {"oklch(72% 0.2 328)", "#e56fe3"},
      {"oklch(71.5% 0.2 328)", "#e36ee1"}
    ]

    test "Chrome's own oklch() conversion of the edges: 38 of 40 exact, two one byte low on red" do
      # Diagnostic of the browser, not a gate on the shipped bytes: the page
      # never asks Chrome to convert an edge, it paints the solver's hex. The
      # two misses are both dark slots, both on red, and both one byte BELOW
      # the solver, which is the one-byte rule in the moduledoc again. Had
      # the edge shipped as oklch(), these two would paint bytes the solver
      # never checked.
      misses =
        for {oklch, chrome} <- @chrome_painted_edges,
            (derived = painted_hex(oklch)) != chrome,
            do: {oklch, derived, chrome}

      assert length(@chrome_painted_edges) == 40

      assert misses == [
               {"oklch(68% 0.15 240)", "#1aa2eb", "#19a2eb"},
               {"oklch(69.5% 0.15 162)", "#10b980", "#0fb980"}
             ]

      for {_oklch, derived, chrome} <- misses do
        {dr, dg, db} = hex_bytes(derived)
        {cr, cg, cb} = hex_bytes(chrome)
        assert {dr - cr, dg - cg, db - cb} == {1, 0, 0}
      end
    end

    test "at the shipped six fills the rail edge lands on the design direction's L, or one step lighter" do
      # Canvas 01a09775 derived one edge L per slug, solved on the rail
      # (base-200, the harder light ground) in whole-percent steps. The
      # half-percent walk reproduces four exactly; for globex and hooli the
      # half step between already holds. Stage 5 moves the six onto this
      # path; these are the values it will ship.
      design = %{
        "legacy" => {{72, 0.16, 50}, 65.0},
        "initech" => {{65, 0.20, 295}, 65.0},
        "vandelay-ind" => {{68, 0.15, 240}, 63.0},
        "globex" => {{70, 0.15, 162}, 61.0},
        "hooli" => {{80, 0.16, 95}, 63.0},
        "wonka" => {{66, 0.19, 340}, 66.0}
      }

      solved =
        for {slug, {{fill, chroma, hue}, _}} <- design, into: %{} do
          {slug, lightness(ScopeColor.derive(hue, chroma, fill / 100).edge_light_200)}
        end

      assert solved == %{
               "legacy" => 65.0,
               "initech" => 65.0,
               "vandelay-ind" => 63.0,
               "globex" => 61.5,
               "hooli" => 63.5,
               "wonka" => 66.0
             }

      for {slug, {_, l}} <- design, do: assert((solved[slug] - l) in [0.0, 0.5], slug)
    end
  end

  describe "derive/3 — the shipped six, on the cell they were tuned for" do
    # The six shipped labels in app.css were solved against the resting chip
    # on base-100, which is now exactly the `base-100` cell. So `derive/3` at
    # each shipped fill lightness reproduces the shipped pair on that cell,
    # without any narrower cell set passed in.
    #
    # {slug, hue, chroma, fill L, shipped light label L, shipped dark label L}
    @shipped [
      {"legacy", 50, 0.16, 0.72, 55.0, 72.0},
      {"initech", 295, 0.20, 0.65, 55.0, 67.0},
      {"vandelay-ind", 240, 0.15, 0.68, 52.0, 68.0},
      {"globex", 162, 0.15, 0.70, 51.0, 70.0},
      {"hooli", 95, 0.16, 0.80, 54.0, 80.0},
      {"wonka", 340, 0.19, 0.66, 55.5, 67.5}
    ]

    test "all twelve shipped base-100 values reproduce to within one 0.5% step" do
      for {slug, hue, chroma, fill_l, light, dark} <- @shipped do
        ramp = ScopeColor.derive(hue, chroma, fill_l)
        assert_in_delta lightness(ramp.label_light_100), light, 0.5, slug
        assert_in_delta lightness(ramp.label_dark_100), dark, 0.5, slug
        assert ramp.cells.light |> hd() |> Map.fetch!(:floor) >= 4.5
      end
    end

    test "nine are exact; globex moves darker for margin, initech and vandelay-ind lighter" do
      # Pinned so the moduledoc's count stays true. globex's shipped 51% has a
      # floor of 4.4974 under +1 green (no margin), so the solver takes one
      # step darker. initech's and vandelay-ind's lighter step already holds
      # with margin against the bytes emitted here, so the walk from the
      # fill stops there first. Every dark value is exact.
      moved =
        for {slug, hue, chroma, fill_l, light, dark} <- @shipped,
            ramp = ScopeColor.derive(hue, chroma, fill_l),
            {theme, solved, shipped} <- [
              {:light, lightness(ramp.label_light_100), light},
              {:dark, lightness(ramp.label_dark_100), dark}
            ],
            solved != shipped do
          {slug, theme, shipped, solved}
        end

      assert Enum.sort(moved) == [
               {"globex", :light, 51.0, 50.5},
               {"initech", :light, 55.0, 55.5},
               {"vandelay-ind", :light, 52.0, 52.5}
             ]
    end

    test "legacy reproduces its shipped fill and pair exactly" do
      ramp = ScopeColor.derive(50, 0.16, 0.72)

      assert ramp.fill == "oklch(72% 0.16 50)"
      assert ramp.label_light_100 == "oklch(55% 0.16 50)"
      assert ramp.label_dark_100 == "oklch(72% 0.16 50)"
    end

    test "the half-percent step is load-bearing, not cosmetic" do
      # app.css records wonka needing 55.5% "because whole-percent steps
      # at hue 340 overshoot" the band. Asserting merely that some L ends in
      # .5 would pass for a solver that rounds; an integer is a half-percent
      # too. So assert the claim itself: where the solver lands on a
      # half-percent, the NEXT whole percent up does not hold the margin.
      ramp = ScopeColor.derive(20, 0.15, 0.72)

      assert lightness(ramp.label_light_100) == 55.5
      assert floor_on(ramp.label_light_100, ramp.tint_light_100) >= 4.5

      rounded_up = floor_on("oklch(56% 0.15 20)", ramp.tint_light_100)

      assert rounded_up < 4.5,
             """
             Rounding the solved 55.5% up to 56% should NOT hold the margin
             (got #{rounded_up}). If this is >= 4.5 the half-percent step is
             buying nothing here and this test has stopped testing what it
             claims.
             """
    end
  end

  describe "contrast/2 — recorded figures" do
    # Full-saturation scope colours as text on white. These five figures are
    # recorded in the design canvas 01a0928d ("Full-saturation values fail as
    # text on white"), which is also WHY the fill is never used as a light
    # label.
    @recorded [
      {"oklch(72% 0.16 50)", 2.61, "legacy"},
      {"oklch(65% 0.20 295)", 3.50, "initech"},
      {"oklch(68% 0.15 240)", 2.83, "vandelay-ind"},
      {"oklch(80% 0.16 95)", 1.87, "hooli"},
      {"oklch(66% 0.19 340)", 3.43, "wonka"}
    ]

    for {color, expected, slug} <- @recorded do
      test "#{slug} full-saturation on #FFFFFF matches the recorded #{expected}:1" do
        assert_in_delta ScopeColor.contrast(unquote(color), "#ffffff"), unquote(expected), 0.05
      end
    end

    test "the two theme grounds are 17.21:1 apart" do
      # The number the whole design rests on: 17.21 < 4.5^2 = 20.25, which is
      # why derive/2 must return a pair.
      assert_in_delta ScopeColor.contrast("oklch(100% 0 0)", "#171b25"), 17.21, 0.05
    end

    test "contrast/2 is symmetric and 1.0 against itself" do
      assert_in_delta ScopeColor.contrast("#171b25", "#171b25"), 1.0, 0.0001

      assert_in_delta ScopeColor.contrast("oklch(72% 0.16 50)", "#ffffff"),
                      ScopeColor.contrast("#ffffff", "oklch(72% 0.16 50)"),
                      0.0001
    end
  end

  # ── Positive control for the hue sweep (task 01a09287 stage 3) ─────────
  #
  # The sweep above asserts >= 4.5:1 for every hue 0..359. That assertion is
  # only as good as the OKLCH -> sRGB conversion underneath it, and a
  # conversion has no version field it can print: clip, chroma-map and
  # sign-fold all return three numbers in 0..1 and none of them announces
  # which convention it is. So the sweep needs a case that pins the
  # convention, or it reports a clean result whichever one is in force.
  #
  # The facts these tests encode, measured 2026-09-11:
  #
  #   * More than half the hue circle is OUTSIDE sRGB at the chromas this
  #     module is used with. At L=55%: 181/360 hues at C=0.15, 224/360 at
  #     C=0.20. At the lightnesses `derive/2` actually emits, 186/360 of the
  #     light labels are out of gamut at C=0.15.
  #   * Chrome 152 CLIPS. `oklch(51% 0.15 162)` has linear red -0.041996;
  #     Chrome paints rgb(0,127,74), both as a canvas fillStyle and as a
  #     painted DOM background read back out of a screenshot. Clip-then-
  #     encode reproduces that byte-for-byte.
  #   * `ScopeColor`'s private `encode/1` used to do NEITHER. It applied the
  #     sRGB transfer function to `abs(x)`, so a negative channel came back
  #     POSITIVE (0.2266 for that red, where Chrome paints 0.0) and the
  #     `max(0.0)` clamp downstream never fired. **Stage 4 fixed it to clip**,
  #     because the admin colour picker prints these contrast figures to an
  #     operator and 186 of 360 light labels at C=0.15 are out of gamut.
  #
  # These tests now pin the clip convention, and they go red the moment
  # somebody changes it in either direction — which is the only property
  # that makes the sweep above mean anything.
  describe "gamut: which sRGB the sweep is really measuring" do
    # Independent of the module under test, on purpose.
    defp linear_srgb(l, c, h) do
      hr = h * :math.pi() / 180.0
      a = c * :math.cos(hr)
      b = c * :math.sin(hr)
      l_ = cube(l + 0.3963377774 * a + 0.2158037573 * b)
      m_ = cube(l - 0.1055613458 * a - 0.0638541728 * b)
      s_ = cube(l - 0.0894841775 * a - 1.2914855480 * b)

      {4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
       -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
       -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_}
    end

    defp cube(x), do: x * x * x

    # Clip to [0,1] FIRST, then encode — the Chrome-matching convention.
    defp clip_encode({r, g, b}), do: {enc(r), enc(g), enc(b)}

    defp enc(x) do
      x = x |> max(0.0) |> min(1.0)
      if x > 0.0031308, do: 1.055 * :math.pow(x, 1 / 2.4) - 0.055, else: 12.92 * x
    end

    defp bytes({r, g, b}), do: {round(r * 255), round(g * 255), round(b * 255)}

    test "the shipped globex label is OUT of the sRGB gamut" do
      {r, _g, _b} = linear_srgb(0.51, 0.15, 162)

      assert r < 0,
             "expected oklch(51% 0.15 162) to have a negative linear red channel; " <>
               "if this is no longer true the premise of the tests below is gone"

      assert_in_delta r, -0.041996, 0.000001
    end

    # The four probes below were read out of Chrome 152 over CDP: three via a
    # canvas fillStyle + getImageData, and the first ALSO as a painted DOM
    # background read back from a screenshot, which agreed. Hard-coded here
    # because a test cannot drive a browser, and a figure nobody can check is
    # worth less than a figure with its provenance written beside it.
    @chrome_152 %{
      {0.51, 0.15, 162} => {0, 127, 74},
      {0.70, 0.15, 162} => {21, 186, 129},
      {0.50, 0.15, 162} => {0, 124, 71},
      {0.72, 0.15, 162} => {36, 193, 135}
    }

    test "clip-then-encode reproduces what Chrome paints, byte for byte" do
      for {{l, c, h}, expected} <- @chrome_152 do
        assert bytes(clip_encode(linear_srgb(l, c, h))) == expected,
               "clip-then-encode disagrees with Chrome 152 at oklch(#{l * 100}% #{c} #{h})"
      end
    end

    test "ScopeColor CLIPS out of gamut, so the sweep measures what Chrome paints" do
      # Stage 4 fixed `encode/1`: it used to feed `abs(x)` to the transfer
      # function, so this colour's negative red came back as byte 58 where
      # Chrome paints 0. The assertion below is the inverse of the one that
      # stood here, and it is the property the sweep depends on.
      out_of_gamut = {0.51, 0.15, 162}
      in_gamut = {0.72, 0.15, 162}

      # In gamut the two conventions CANNOT disagree — nothing is out of
      # range to treat differently — so this half cannot distinguish clip
      # from sign-fold and is not evidence on its own. It is here as the
      # control on the control: a module returning constants would fail it.
      {l, c, h} = in_gamut
      assert bytes(ScopeColor.oklch_to_srgb(l, c, h)) == bytes(clip_encode(linear_srgb(l, c, h)))

      # Out of gamut is where the conventions separate, so this is the line
      # that carries the claim. It goes red for sign-fold (58,127,74), for
      # chroma-reduction mapping, and for no clamp at all.
      {l, c, h} = out_of_gamut
      assert bytes(ScopeColor.oklch_to_srgb(l, c, h)) == {0, 127, 74}
      assert bytes(clip_encode(linear_srgb(l, c, h))) == {0, 127, 74}
    end

    test "the globex light figure agrees with the painted one, on both sides of 4.5" do
      # The figure this cost: under the old sign-fold `encode/1` the module
      # reported 4.37 for a colour Chrome paints at 4.56 — an AA failure
      # that does not exist. Both are computed here, the second through an
      # implementation that shares no code with the module.
      ground = clip_encode(linear_srgb(0.70, 0.15, 162))
      ground = composite(ground, 0.12, {1.0, 1.0, 1.0})

      painted = wcag(clip_encode(linear_srgb(0.51, 0.15, 162)), ground)

      module =
        ScopeColor.contrast(
          "oklch(51% 0.15 162)",
          ScopeColor.tint_ground("oklch(70% 0.15 162)", :light)
        )

      assert_in_delta painted, 4.56, 0.01
      assert_in_delta module, 4.56, 0.01
      assert_in_delta module, painted, 0.0001
      assert module >= 4.5

      refute_in_delta module,
                      4.37,
                      0.05,
                      "the module is reporting the withdrawn sign-fold figure again"
    end

    test "re-run through an independent implementation, every cell still clears AA" do
      # The honest version of the sweep: same solved lightnesses, but every
      # colour resolved by code that shares nothing with the module, the way
      # Chrome resolves it, and every surface converted here too. This
      # started as the check that the old sign-fold `encode/1` made the sweep
      # a bad instrument without making its answer wrong. Since task
      # 01a09333-d374 it covers all four per-surface cells.
      #
      # Both sides are rounded to bytes, because bytes are what gets painted:
      # the tint ships as `#rrggbb` and the browser quantises the label's
      # oklch(). Left in float this does NOT pass everywhere: at hue 1,
      # C=0.2, the rail tint's green is 224.50005 before rounding and the
      # float figure is 4.4983 where the painted one is 4.5225. A pass that
      # rides on a rounding edge is exactly why the tint must reach the
      # browser as bytes rather than as an alpha the browser composites.
      grounds = %{
        light: %{
          "base-100" => {1.0, 1.0, 1.0},
          "base-200" => clip_encode(linear_srgb(0.96, 0.0, 0.0))
        },
        dark: %{
          "base-100" => {0x17 / 255, 0x1B / 255, 0x25 / 255},
          "base-200" => clip_encode(linear_srgb(0.09, 0.018, 240.0))
        }
      }

      for chroma <- [0.15, 0.20], hue <- 0..359 do
        ramp = ScopeColor.derive(hue, chroma)
        fill = clip_encode(linear_srgb(pct(ramp.fill), chroma, hue))

        for theme <- [:light, :dark], cell <- ramp.cells[theme] do
          ratio =
            wcag(
              to_bytes(clip_encode(linear_srgb(pct(cell.label), chroma, hue))),
              to_bytes(composite(fill, 0.12, grounds[theme][cell.surface]))
            )

          assert ratio >= 4.5,
                 "hue #{hue} C=#{chroma} #{theme} #{cell.cell}: independent contrast #{ratio} < 4.5"
        end
      end
    end

    defp to_bytes({r, g, b}),
      do: {round(r * 255) / 255, round(g * 255) / 255, round(b * 255) / 255}

    defp pct(oklch) do
      {value, _} = Regex.run(~r/oklch\(([\d.]+)%/, oklch) |> Enum.at(1) |> Float.parse()
      value / 100.0
    end

    defp composite({r, g, b}, a, {br, bg, bb}),
      do: {r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a)}

    defp wcag(a, b) do
      la = lum(a)
      lb = lum(b)
      {hi, lo} = if la >= lb, do: {la, lb}, else: {lb, la}
      (hi + 0.05) / (lo + 0.05)
    end

    defp lum({r, g, b}), do: 0.2126 * linz(r) + 0.7152 * linz(g) + 0.0722 * linz(b)
    defp linz(c) when c <= 0.04045, do: c / 12.92
    defp linz(c), do: :math.pow((c + 0.055) / 1.055, 2.4)
  end
end
