defmodule Platform.Tenancy.ScopeColorTest do
  @moduledoc """
  Task 01a09287 stage 1.

  The load-bearing test here is the hue sweep: it is what turns "a colour
  must be legible in both themes" from a comment in `app.css` into a
  property the build enforces for every hue an operator can pick, not just
  the six somebody happened to hand-author.
  """
  use ExUnit.Case, async: true

  alias Platform.Tenancy.ScopeColor

  # The four light-theme grounds for a fill, in the shape `floor_contrast/2`
  # wants. Built from `cells/1` so it cannot drift from what the solver uses.
  defp light_grounds(fill) do
    Enum.map(ScopeColor.cells(:light), fn cell ->
      Map.put(cell, :ground, ScopeColor.composite_ground(fill, cell.alpha, cell.color))
    end)
  end

  # Parses the L back out of an `oklch(L% C H)` string, as a percentage.
  defp lightness(oklch) do
    [l | _] =
      oklch
      |> String.replace(~r/^oklch\(|\)$/, "")
      |> String.split(" ")

    {value, _} = Float.parse(l)
    value
  end

  describe "derive/2 — the AA-on-both-themes property" do
    test "every hue 0..359 clears AA as label text on BOTH theme grounds" do
      failures =
        for hue <- 0..359,
            chroma <- [0.15, 0.16, 0.19, 0.20],
            ramp = ScopeColor.derive(hue, chroma),
            ramp.contrast_light < 4.5 or ramp.contrast_dark < 4.5 do
          {hue, chroma, Float.round(ramp.contrast_light, 3), Float.round(ramp.contrast_dark, 3)}
        end

      assert failures == [],
             """
             Hues whose derived label pair fails WCAG AA (4.5:1) on at least
             one theme ground, as {hue, chroma, contrast_light, contrast_dark}:

               #{inspect(failures, limit: :infinity)}

             The two grounds are 17.21:1 apart and AA-on-both would need
             4.5^2 = 20.25, so a SINGLE value cannot satisfy this — if this
             went red after a change that collapsed `label_light` and
             `label_dark` into one value, that is the cause.
             """
    end

    test "the sweep is non-vacuous — it examines 1440 hue/chroma pairs" do
      # `Enum.all?([])` is true and so is a comprehension filter that matches
      # nothing. Pin the population the assertion above ranges over.
      count =
        for(hue <- 0..359, chroma <- [0.15, 0.16, 0.19, 0.20], do: {hue, chroma}) |> length()

      assert count == 1440
    end
  end

  describe "the cell enumeration the solver and the picker share" do
    test "cells/1 is four cells per theme and tuned_cells/1 is exactly one of them" do
      # The population every assertion below ranges over. A cell set that
      # came back EMPTY would make `floor_contrast/2` raise rather than pass
      # vacuously, but an enumeration that silently lost the hovered rows
      # would just quietly restore the defect this stage fixed.
      for theme <- [:light, :dark] do
        cells = ScopeColor.cells(theme)
        assert length(cells) == 4, "#{theme}: #{inspect(cells)}"

        assert Enum.sort(Enum.map(cells, &{&1.tint, &1.surface})) ==
                 [
                   {"hovered", "base-100"},
                   {"hovered", "base-200"},
                   {"rest", "base-100"},
                   {"rest", "base-200"}
                 ]

        assert ScopeColor.tuned_cells(theme) ==
                 Enum.filter(cells, &(&1.tint == "rest" and &1.surface == "base-100"))
      end
    end

    test "the tuned cell is never the WORST, and in light it is the most generous of the four" do
      # The whole reason 3.74 was printed: the solver aimed at a cell that
      # flatters, and the panel read the cell that does not.
      #
      # The two themes are NOT symmetric and an earlier draft of this test
      # asserted they were. In light, more tint and a darker surface both
      # move the ground AWAY from white and toward the dark label, so
      # rest-on-base-100 is strictly the best. In dark, base-200 is DARKER
      # than base-100, so a light label gains contrast there and the most
      # generous cell is rest-on-base-200 — the tuned cell is second. What
      # holds in both, and is the property the argument actually needs, is
      # that the tuned cell is never the worst one.
      fill = "oklch(72% 0.15 200)"
      label = "oklch(50% 0.15 200)"

      ratios = fn theme ->
        for cell <- ScopeColor.cells(theme),
            into: %{},
            do:
              {{cell.tint, cell.surface},
               ScopeColor.contrast(
                 label,
                 ScopeColor.composite_ground(fill, cell.alpha, cell.color)
               )}
      end

      for theme <- [:light, :dark] do
        [tuned] = ScopeColor.tuned_cells(theme)
        all = ratios.(theme)
        tuned_ratio = Map.fetch!(all, {tuned.tint, tuned.surface})

        assert tuned_ratio > all |> Map.values() |> Enum.min(),
               "#{theme}: the tuned cell IS the worst — #{inspect(all)}"
      end

      light = ratios.(:light)
      assert Map.fetch!(light, {"rest", "base-100"}) == light |> Map.values() |> Enum.max()

      dark = ratios.(:dark)
      assert Map.fetch!(dark, {"rest", "base-200"}) == dark |> Map.values() |> Enum.max()
    end

    test "AdminOrgsLive prints from the same enumeration the solver walks" do
      # The two used to be separate tables and drifted into a constant
      # offset. Delegation is the fix; this is the assertion that it stays
      # delegation and does not grow a second copy.
      ramp = ScopeColor.derive(200, 0.15)

      assert PlatformWeb.AdminOrgsLive.worst_cell(ramp.fill, ramp.label_light, :light) ==
               ramp.worst_light

      assert PlatformWeb.AdminOrgsLive.worst_cell(ramp.fill, ramp.label_dark, :dark) ==
               ramp.worst_dark
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
      "fabrikam" => {{"oklch(72% 0.16 50)"}, {241, 228, 219}},
      "soylent" => {{"oklch(65% 0.20 295)"}, {231, 225, 242}},
      "wayne-tech" => {{"oklch(68% 0.15 240)"}, {215, 232, 241}},
      "sxi" => {{"oklch(70% 0.15 162)"}, {215, 235, 228}},
      "paragon" => {{"oklch(80% 0.16 95)"}, {239, 235, 215}},
      "cyberdyne" => {{"oklch(66% 0.19 340)"}, {239, 223, 234}}
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
      # concession: five of eighteen channels differ by exactly 1 and none by
      # more. That measured noise floor is WHY the solver targets a margin
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
      {{fill}, painted} = Map.fetch!(@painted_rail_chips, "fabrikam")
      {r, g, b} = byte(ScopeColor.composite_ground(fill, 0.22, "oklch(96% 0 0)"))
      {pr, pg, pb} = painted

      assert Enum.max([abs(r - pr), abs(g - pg), abs(b - pb)]) > 1,
             "the 22% chip is within one byte of the 12% painted value — the pin proves nothing"
    end
  end

  describe "derive/2 — the solved label clears AA in EVERY cell, with margin" do
    test "every hue 0..359 holds 4.5 in all four cells of BOTH themes, under +/-1 on green" do
      # The property the picker's printed figure depends on. It asserts the
      # FLOOR, not the nominal ratio: solving to exactly 4.5 ships labels
      # that fail on a one-byte rounding difference, and a derived sRGB byte
      # in this codebase has been wrong by one unit more than once. Three of
      # the six shipped hues flip below 4.5 under +1 on green.
      failures =
        for hue <- 0..359,
            chroma <- [0.15, 0.16, 0.19, 0.20],
            ramp = ScopeColor.derive(hue, chroma),
            ramp.floor_light < 4.5 or ramp.floor_dark < 4.5 do
          {hue, chroma, Float.round(ramp.floor_light, 4), Float.round(ramp.floor_dark, 4)}
        end

      assert failures == [],
             """
             Hues whose solved label drops below AA in at least one of the
             four cells, or does under a one-byte green perturbation, as
             {hue, chroma, floor_light, floor_dark}:

               #{inspect(failures, limit: :infinity)}
             """
    end

    test "the worst cell is the HOVERED chip, which is the one a per-surface fix omits" do
      # Load-bearing for the design argument, not just trivia. A remedy
      # aimed at the RESTING chip on base-200 — the obvious reading of "the
      # rail is where it fails" — lands 0.015-0.03 L too light and still
      # fails on hover, which is the same shape of error as solving against
      # the tuned cell. Every clickable chip has a hover state and the rail
      # chips are clickable.
      for hue <- [0, 95, 200, 240, 300, 330, 350], theme <- [:light, :dark] do
        ramp = ScopeColor.derive(hue, 0.15)
        worst = if theme == :light, do: ramp.worst_light, else: ramp.worst_dark

        assert worst.tint == "hovered",
               "hue #{hue} #{theme}: worst cell was #{worst.cell}, not a hovered one"
      end
    end

    test "the band the reviewer measured as 3.74-3.81 is reproduced, and is now gone" do
      # What the gate failed on. The reviewer swept 14 hues under the OLD
      # solver and got 3.74-3.81 in light with not one hue clearing 4.50;
      # the value of that observation was never the individual figures but
      # the flatness — a shortfall that does not move with hue is a constant
      # offset between two definitions, not a property of any colour.
      #
      # Reproduced here over the whole circle rather than 14 samples. The
      # minimum lands at 3.7397 (hue 356), which is their lower bound to
      # four figures. Their UPPER bound does not reproduce: my band runs to
      # 3.8964 at hue 136, and their per-hue figures (95 -> 3.78,
      # 240 -> 3.77) sit 0.05-0.08 below mine at every chroma I tried
      # (0.15/0.16/0.17/0.19/0.20 — no single chroma reproduces all three).
      # That delta is UNEXPLAINED. It does not touch the conclusion, which
      # is the second assertion: no hue cleared 4.50, so "pick a better hue"
      # was never an available remedy.
      old_worst = fn hue ->
        old = ScopeColor.derive(hue, 0.15, 0.72, &ScopeColor.tuned_cells/1)
        ScopeColor.worst_cell(old.fill, old.label_light, :light).contrast
      end

      band = Enum.map(0..359, old_worst)

      assert_in_delta Enum.min(band), 3.7397, 0.001
      assert Enum.max(band) < 4.5, "some hue cleared AA under the old solver"

      # And the same hues under the shipped solver.
      now = for hue <- 0..359, do: ScopeColor.derive(hue, 0.15).contrast_light
      assert Enum.min(now) >= 4.5, "a hue still fails: #{Enum.min(now)}"
    end

    test "the solved L is pinned, so a change to the solver has to explain itself" do
      # Three agents' float pipelines disagreed on derived colour values in
      # this task. A pinned L means the next change to the walk shows up as
      # a named diff rather than as a silently different colour.
      assert ScopeColor.derive(50, 0.16).label_light == "oklch(50.5% 0.16 50)"
      assert ScopeColor.derive(50, 0.16).label_dark == "oklch(72% 0.16 50)"
      assert ScopeColor.derive(200, 0.15).label_light == "oklch(45.5% 0.15 200)"
    end

    test "the margin is real — one step LIGHTER than the solved L breaks the floor" do
      # Without this the sweep above passes for a solver that walks to pure
      # black. Asserts the solver stops at the LIGHTEST qualifying L, which
      # is the other half of the contract: the label should stay as close to
      # the fill as the constraint allows.
      for hue <- [0, 95, 200, 240, 300, 330, 350] do
        ramp = ScopeColor.derive(hue, 0.15)
        l = lightness(ramp.label_light) / 100.0
        grounds = light_grounds(ramp.fill)

        assert ScopeColor.floor_contrast(
                 ScopeColor.oklch_to_srgb(l + 0.005, 0.15, hue),
                 grounds
               ) < 4.5,
               "hue #{hue}: L #{l + 0.005} also clears the floor, so the walk overshot"
      end
    end

    test "floor_contrast/2 is strictly below the nominal ratio, i.e. the perturbation bites" do
      # An assertion that the margin machinery is not a no-op. If
      # `floor_contrast/2` ever equals the nominal worst for every hue, the
      # perturbation has stopped perturbing.
      ratios =
        for hue <- 0..359 do
          ramp = ScopeColor.derive(hue, 0.15)
          ramp.contrast_light - ramp.floor_light
        end

      assert Enum.min(ratios) > 0.0, "the green perturbation changed nothing at some hue"
      assert Enum.max(ratios) < 0.2, "an implausibly large one-byte delta: #{Enum.max(ratios)}"
    end
  end

  describe "derive/4 — reproduces the shipped ramp" do
    # `&ScopeColor.tuned_cells/1` is not decoration here. The six shipped
    # ramps in app.css were solved against the RESTING chip on base-100 and
    # that cell alone — the best of the four `cells/1` enumerates — so
    # `derive/2`, which now targets the worst of four, does NOT reproduce
    # them and must not be expected to. Naming the narrower cell set at the
    # call site is what makes these tests a statement about the shipped
    # values rather than a pin that quietly re-defines what the solver does.
    # Re-solving the six against all four cells is task 01a09333-d374.
    @tuned &ScopeColor.tuned_cells/1

    # app.css: .text-cyberdyne-label oklch(55.5% 0.19 340)
    #          [data-theme=dark] .text-cyberdyne-label oklch(67.5% 0.19 340)
    # fill .text-cyberdyne oklch(66% 0.19 340)
    test "cyberdyne (hue 340, chroma 0.19) reproduces the shipped pair" do
      ramp = ScopeColor.derive(340, 0.19, 0.66, @tuned)

      assert_in_delta lightness(ramp.label_light), 55.5, 0.5
      assert_in_delta lightness(ramp.label_dark), 67.5, 0.5
      assert ramp.contrast_light >= 4.5
      assert ramp.contrast_dark >= 4.5
    end

    # app.css: .text-fabrikam-label oklch(55% 0.16 50)
    #          [data-theme=dark] .text-fabrikam-label oklch(72% 0.16 50)
    # fabrikam's fill lightness IS the module default, passed explicitly so the
    # tuned cell set can be too.
    test "fabrikam (hue 50, chroma 0.16) reproduces the shipped pair" do
      ramp = ScopeColor.derive(50, 0.16, 0.72, @tuned)

      assert ramp.fill == "oklch(72% 0.16 50)"
      assert_in_delta lightness(ramp.label_light), 55.0, 0.5
      assert_in_delta lightness(ramp.label_dark), 72.0, 0.5
      assert ramp.contrast_light >= 4.5
      assert ramp.contrast_dark >= 4.5
    end

    test "the half-percent step is load-bearing, not cosmetic" do
      # app.css records cyberdyne needing 55.5% "because whole-percent steps
      # at hue 340 overshoot" the band. Asserting merely that some L ends in
      # .5 would pass for a solver that rounds — an integer is a half-percent
      # too. So assert the thing the note actually claims: at a hue where the
      # solver lands on a half-percent, the NEXT whole percent up fails AA,
      # i.e. a whole-percent solver would ship an illegible label.
      ramp = ScopeColor.derive(20, 0.15, 0.72, @tuned)
      l = lightness(ramp.label_light)

      assert l == 55.5, "expected the solver to land off a whole percent, got #{l}"
      assert ramp.contrast_light >= 4.5

      ground = ScopeColor.tint_ground(ramp.fill, :light)
      rounded_up = ScopeColor.contrast("oklch(56% 0.15 20)", ground)

      assert rounded_up < 4.5,
             """
             Rounding the solved 55.5% up to 56% should FAIL AA (got #{rounded_up}).
             If this is >= 4.5 the half-percent step is buying nothing here and
             this test has stopped testing what it claims.
             """
    end
  end

  describe "contrast/2 — recorded figures" do
    # Full-saturation scope colours as text on white. These five figures are
    # recorded in the design canvas 01a0928d ("Full-saturation values fail as
    # text on white"), which is also WHY the fill is never used as a light
    # label.
    @recorded [
      {"oklch(72% 0.16 50)", 2.61, "fabrikam"},
      {"oklch(65% 0.20 295)", 3.50, "soylent"},
      {"oklch(68% 0.15 240)", 2.83, "wayne-tech"},
      {"oklch(80% 0.16 95)", 1.87, "paragon"},
      {"oklch(66% 0.19 340)", 3.43, "cyberdyne"}
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

    test "the shipped sxi label is OUT of the sRGB gamut" do
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

    test "the sxi light figure agrees with the painted one, on both sides of 4.5" do
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

    test "re-run under the PAINTED convention, the sweep's conclusion still holds" do
      # The honest version of the 0..359 sweep: same solved lightnesses, but
      # every colour resolved the way Chrome resolves it. This is the
      # assertion the sweep above was TRYING to make, and it passes — so the
      # `encode/1` defect makes that sweep a bad instrument without making
      # its answer wrong. Recording the distinction, because "the guard was
      # vacuous" and "the code is broken" are different findings and only the
      # first one is true here.
      white = {1.0, 1.0, 1.0}
      dark = {0x17 / 255, 0x1B / 255, 0x25 / 255}

      for chroma <- [0.15, 0.20], hue <- 0..359 do
        ramp = ScopeColor.derive(hue, chroma)
        fill = clip_encode(linear_srgb(pct(ramp.fill), chroma, hue))

        light =
          wcag(
            clip_encode(linear_srgb(pct(ramp.label_light), chroma, hue)),
            composite(fill, 0.12, white)
          )

        dark_c =
          wcag(
            clip_encode(linear_srgb(pct(ramp.label_dark), chroma, hue)),
            composite(fill, 0.12, dark)
          )

        assert light >= 4.5, "hue #{hue} C=#{chroma}: painted light contrast #{light} < 4.5"
        assert dark_c >= 4.5, "hue #{hue} C=#{chroma}: painted dark contrast #{dark_c} < 4.5"
      end
    end

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
