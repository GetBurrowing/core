defmodule Platform.Tenancy.ScopeColorPaintedTest do
  @moduledoc """
  Task 01a09333-d374 stage 1: `ScopeColor.composite_painted/3`, the 8-bit
  sibling of `composite_ground/3`, and the fixtures that pin its conventions.

  Three kinds of fixture, kept apart on purpose:

    * the conventions, each asserted where the alternative gives a
      DIFFERENT answer (a convention test that both conventions pass
      proves nothing);
    * PIN 1 and PIN 2, where float and 8-bit give opposite AA verdicts;
    * the calibration table: bytes MEASURED in a browser, pasted, never
      re-derived.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast
  alias Platform.Tenancy.ScopeColor
  alias Platform.Tenancy.ScopeColorPaintedFixture

  @base_100 "oklch(100% 0 0)"
  @base_200 "oklch(96% 0 0)"

  # The six shipped orgs, as `app.css` declares them: `.bg-<slug>` fill and
  # the light `.text-<slug>-label`.
  @orgs %{
    "legacy" => {"oklch(72% 0.16 50)", "oklch(55% 0.16 50)"},
    "soylent" => {"oklch(65% 0.20 295)", "oklch(55% 0.20 295)"},
    "wayne-tech" => {"oklch(68% 0.15 240)", "oklch(52% 0.15 240)"},
    "sxi" => {"oklch(70% 0.15 162)", "oklch(51% 0.15 162)"},
    "paragon" => {"oklch(80% 0.16 95)", "oklch(54% 0.16 95)"},
    "cyberdyne" => {"oklch(66% 0.19 340)", "oklch(55.5% 0.19 340)"}
  }

  defp fill(slug), do: @orgs |> Map.fetch!(slug) |> elem(0)
  defp label(slug), do: @orgs |> Map.fetch!(slug) |> elem(1)

  defp hex({r, g, b}) do
    "#" <>
      Enum.map_join([r, g, b], "", fn c ->
        c |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
      end)
  end

  defp unit({r, g, b}), do: {r / 255, g / 255, b / 255}

  describe "composite_painted/3: shape" do
    test "returns integer bytes and the matching lowercase #rrggbb" do
      painted = ScopeColor.composite_painted(fill("legacy"), 0.12, @base_100)

      assert %{rgb: {r, g, b}, hex: hex} = painted
      assert Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255))
      assert hex == hex({r, g, b})
      assert hex =~ ~r/^#[0-9a-f]{6}$/
    end

    test "alpha 1.0 is the fill alone, and alpha 0.0 is the surface alone" do
      assert ScopeColor.composite_painted(label("sxi"), 1.0, @base_100).rgb == {0, 127, 74}
      assert ScopeColor.composite_painted(fill("sxi"), 0.0, @base_200).rgb == {242, 242, 242}
    end
  end

  describe "composite_painted/3: the three conventions" do
    test "1. composites in gamma-encoded sRGB, and linear light gives different bytes" do
      # Cross-check against the test-only float path, which composites in
      # the encoded space by construction. Every one of the twelve 12% cells
      # has to agree.
      for slug <- Map.keys(@orgs), surface <- [@base_100, @base_200] do
        float_hex =
          WcagContrast.composite(
            WcagContrast.parse!(fill(slug)),
            0.12,
            WcagContrast.parse!(surface)
          )
          |> WcagContrast.to_hex()
          |> String.downcase()

        assert ScopeColor.composite_painted(fill(slug), 0.12, surface).hex == float_hex,
               "#{slug} over #{surface}"
      end

      # And the alternative must be distinguishable, or the check above
      # passes for a linear-light compositor too.
      linear_hex = fn slug ->
        {fr, fg, fb} = WcagContrast.parse!(fill(slug))
        mix = fn c -> c |> max(0.0) |> min(1.0) |> Kernel.*(0.12) |> Kernel.+(0.88) end
        WcagContrast.to_hex({mix.(fr), mix.(fg), mix.(fb)}) |> String.downcase()
      end

      for slug <- Map.keys(@orgs) do
        refute ScopeColor.composite_painted(fill(slug), 0.12, @base_100).hex == linear_hex.(slug),
               "#{slug}: linear-light compositing gives the same bytes, so this test cannot tell them apart"
      end
    end

    test "2. quantises once, at the end: fill-first rounding moves wayne-tech and only wayne-tech" do
      fill_first = fn slug ->
        fill_bytes = ScopeColor.composite_painted(fill(slug), 1.0, @base_100).rgb
        ScopeColor.composite_painted(hex(fill_bytes), 0.12, @base_100).hex
      end

      once = fn slug -> ScopeColor.composite_painted(fill(slug), 0.12, @base_100).hex end

      # wayne-tech's float red is 227.465 and rounds to E3. Rounding the fill
      # first (red 25.54 -> 26) lands on 227.52 and rounds to E4.
      assert once.("wayne-tech") == "#e3f4fd"
      assert fill_first.("wayne-tech") == "#e4f4fd"

      moved = for slug <- Map.keys(@orgs), once.(slug) != fill_first.(slug), do: slug
      assert moved == ["wayne-tech"]
    end

    test "3. clips each linear channel, then encodes (the Chrome-measured bytes)" do
      # oklch(51% 0.15 162) has linear red -0.041996. Chrome 152 paints
      # rgb(0,127,74); a sign-folding encode gives red 58.
      {r, _g, _b} = ScopeColor.linear_srgb(0.51, 0.15, 162)
      assert r < 0

      assert ScopeColor.composite_painted("oklch(51% 0.15 162)", 1.0, @base_100).rgb ==
               {0, 127, 74}
    end
  end

  describe "PIN 1 and PIN 2: the quantisation straddles" do
    # Both pins have fill AND label inside sRGB, so nothing here depends on
    # the gamut convention: the fixture isolates quantisation.
    #
    # Assert the MARGIN, not the threshold. Figures are recorded to four
    # decimals, so each ratio is held to one unit in the fourth decimal and
    # the straddle (a difference of two such figures) to two units. A guard
    # pinned only on the fail direction is satisfied by an implementation
    # that always rounds one way, which is why both directions are carried.
    @ratio_tolerance 0.0001
    @straddle_tolerance 0.0002

    @pins [
      # PIN 1: dangerous. Float passes, the browser fails.
      %{
        name: "PIN 1",
        hue: 10,
        chroma: 0.165,
        fill: "oklch(72% 0.165 10)",
        label: "oklch(56.1% 0.165 10)",
        label_l: 0.561,
        float: 4.5192,
        painted: 4.4959,
        straddle: 0.0233
      },
      # PIN 2: harmless. Float fails, the browser passes.
      %{
        name: "PIN 2",
        hue: 10,
        chroma: 0.155,
        fill: "oklch(72% 0.155 10)",
        label: "oklch(56.3% 0.155 10)",
        label_l: 0.563,
        float: 4.4655,
        painted: 4.5008,
        straddle: -0.0353
      }
    ]

    defp ratios(pin) do
      float =
        ScopeColor.contrast(pin.label, ScopeColor.composite_ground(pin.fill, 0.12, @base_100))

      tint = ScopeColor.composite_painted(pin.fill, 0.12, @base_100)
      label = ScopeColor.composite_painted(pin.label, 1.0, @base_100)
      {float, ScopeColor.contrast(label.hex, tint.hex)}
    end

    test "both pins are inside sRGB, so they isolate quantisation" do
      for pin <- @pins do
        assert ScopeColor.in_gamut?(0.72, pin.chroma, pin.hue), "#{pin.name} fill"
        assert ScopeColor.in_gamut?(pin.label_l, pin.chroma, pin.hue), "#{pin.name} label"
      end
    end

    test "the float and 8-bit ratios match the recorded figures" do
      for pin <- @pins do
        {float, painted} = ratios(pin)
        assert_in_delta float, pin.float, @ratio_tolerance, "#{pin.name} float"
        assert_in_delta painted, pin.painted, @ratio_tolerance, "#{pin.name} 8-bit"
      end
    end

    test "the float figure agrees with the independent float path" do
      for pin <- @pins do
        {float, _} = ratios(pin)

        independent =
          WcagContrast.contrast(
            WcagContrast.parse!(pin.label),
            WcagContrast.composite(
              WcagContrast.parse!(pin.fill),
              0.12,
              WcagContrast.parse!(@base_100)
            )
          )

        assert_in_delta float, independent, 1.0e-6, pin.name
      end
    end

    test "PIN 1: float passes AA and the painted bytes fail it" do
      [pin | _] = @pins
      {float, painted} = ratios(pin)

      assert float >= 4.5
      assert painted < 4.5
    end

    test "PIN 2: float fails AA and the painted bytes pass it" do
      [_, pin] = @pins
      {float, painted} = ratios(pin)

      assert float < 4.5
      assert painted >= 4.5
    end

    test "the straddle has the recorded sign and size in both directions" do
      for pin <- @pins do
        {float, painted} = ratios(pin)
        straddle = float - painted

        assert_in_delta straddle, pin.straddle, @straddle_tolerance, pin.name

        assert sign(straddle) == sign(pin.straddle),
               "#{pin.name}: straddle #{straddle} has the wrong sign"
      end

      assert Enum.map(@pins, &sign(&1.straddle)) == [1, -1],
             "the pins must carry BOTH directions"
    end

    defp sign(x) when x > 0, do: 1
    defp sign(x) when x < 0, do: -1
  end

  describe "calibration: what the browser painted" do
    # MEASURED bytes: DOM swatches painted and read back pixel-wise,
    # reproduced byte for byte on two rigs. Pasted, never re-derived:
    # pinning a derived value against the same derivation asserts nothing.
    #
    # {slug, surface} => {painted 12% tint, recorded label-vs-tint ratio}
    #
    # Kept in `Platform.Tenancy.ScopeColorPaintedFixture` since stage 5, which
    # holds the emitted tints of the six against the same bytes.
    @painted_tints ScopeColorPaintedFixture.tints()

    @painted_labels ScopeColorPaintedFixture.labels()

    @surfaces %{"base-100" => @base_100, "base-200" => @base_200}

    # The recorded divergence, per channel, as computed minus painted.
    #
    # (a) The spec for this stage expected a different set: ten exact and
    #     two misses, wayne-tech over base-100 (`#E4F4FD` computed) and
    #     soylent over base-100. wayne-tech's `#E4F4FD` is what you get by
    #     quantising the FILL first (red 25.54 -> 26, then 227.52 -> 228),
    #     which convention 2 forbids. Composited in float and rounded once,
    #     wayne-tech's red is 227.465 and matches the painted `E3`.
    # (b) The 10+2 figure was corrected to 7+5 on 2026-09-21, on two
    #     independent float paths agreeing on all twelve cells (this module
    #     and `Platform.Design.WcagContrast`), and the CSS Color 4 matrices
    #     agreeing with Ottosson's on the fill channels to four decimals.
    # (c) Every miss is computed one byte HIGH of painted, never more.
    # (d) Mechanisms proposed for the byte and refuted out of sample; do not
    #     re-run them:
    #       * plain, floor, or round-half-even rounding of the float: fails
    #         within a single colour (soylent red 243 fits, green 237 does
    #         not);
    #       * 8-bit quantisation of the ALPHA before compositing: fit 18/18
    #         channels over base-100, then 5/12 on held-out alphas (22% and
    #         30%) and 9/18 on the held-out base-200 ground;
    #       * sub-unit oklch -> sRGB conversion error amplified by alpha:
    #         refuted by an opaque-fill test, 17/18 exact at alpha 1.0,
    #         where that account predicts the LARGEST divergence.
    #     No surviving mechanism. Do not "fix" the compositor to match.
    #
    # This test goes red if the divergence CHANGES in either direction: a
    # new miss, a miss that closes, or a delta that moves.
    @known_divergences ScopeColorPaintedFixture.known_divergences()

    defp painted_bytes("#" <> hex) do
      <<r::binary-2, g::binary-2, b::binary-2>> = hex
      {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
    end

    defp deltas do
      for {{slug, surface} = cell, {painted_hex, _ratio}} <- @painted_tints, into: %{} do
        {cr, cg, cb} = ScopeColor.composite_painted(fill(slug), 0.12, @surfaces[surface]).rgb
        {pr, pg, pb} = painted_bytes(painted_hex)
        {cell, {cr - pr, cg - pg, cb - pb}}
      end
    end

    test "the population is twelve cells: six orgs over two grounds" do
      assert map_size(@painted_tints) == 12

      assert @painted_tints |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() ==
               6
    end

    test "seven tints match exactly and the other five carry the recorded one-byte deltas" do
      misses = deltas() |> Enum.reject(fn {_cell, d} -> d == {0, 0, 0} end) |> Map.new()

      assert misses == @known_divergences,
             """
             The compositor's divergence from the painted tints changed.
             recorded: #{inspect(@known_divergences)}
             now:      #{inspect(misses)}
             """

      exact = deltas() |> Enum.filter(fn {_cell, d} -> d == {0, 0, 0} end)
      assert length(exact) == 7
    end

    test "every recorded miss is one byte HIGH, never low and never more" do
      for {cell, {r, g, b}} <- @known_divergences do
        assert Enum.all?([r, g, b], &(&1 in [0, 1])), inspect(cell)
        assert r + g + b >= 1, inspect(cell)
      end
    end

    test "all six painted label bytes are reproduced exactly" do
      for {slug, painted} <- @painted_labels do
        assert ScopeColor.composite_painted(label(slug), 1.0, @base_100).rgb == painted, slug
      end
    end

    test "the recorded ratios are the painted label against the painted tint" do
      for {{slug, _surface} = cell, {painted_hex, ratio}} <- @painted_tints do
        computed = ScopeColor.contrast(hex(@painted_labels[slug]), painted_hex)
        assert_in_delta computed, ratio, 0.00005, inspect(cell)
      end
    end
  end

  describe "the one-byte rule: floor_contrast/2 against the margin table" do
    # The moduledoc's margin table: painted label vs painted 12% tint over
    # base-100, and the worst single +-1 move. `floor_contrast/2` is the
    # green-channel move, so it is asserted against the table only where
    # green IS the worst axis. cyberdyne's worst axis is not green; the
    # table says 4.5854 and the green floor is 4.5920. That figure is pinned
    # separately so the moduledoc's claim about it stays true.
    @green_worst %{
      "legacy" => 4.5804,
      "soylent" => 4.6042,
      "wayne-tech" => 4.6224,
      "sxi" => 4.4974,
      "paragon" => 4.6265
    }

    @painted_base_100 (for {slug, label} <- ScopeColorPaintedFixture.labels(), into: %{} do
                         {tint, _ratio} =
                           Map.fetch!(ScopeColorPaintedFixture.tints(), {slug, "base-100"})

                         {slug, {label, tint}}
                       end)

    defp green_floor(slug) do
      {label, tint_hex} = Map.fetch!(@painted_base_100, slug)
      ScopeColor.floor_contrast(unit(label), [%{ground: unit(painted_bytes(tint_hex))}])
    end

    test "floor_contrast/2 reproduces the worst-single column where green is the worst axis" do
      assert map_size(@green_worst) == 5

      for {slug, expected} <- @green_worst do
        assert_in_delta green_floor(slug), expected, 0.00005, slug
      end
    end

    test "sxi crosses AA under a single one-unit move up on the label's green" do
      assert green_floor("sxi") < 4.5
      assert ScopeColor.contrast(hex({0, 128, 74}), "#E3F7F0") < 4.5
      assert ScopeColor.contrast(hex({0, 127, 74}), "#E3F7F0") >= 4.5
    end

    test "cyberdyne: the green-only floor is 4.5920, above the table's non-green 4.5854" do
      assert_in_delta green_floor("cyberdyne"), 4.5920, 0.00005
      assert green_floor("cyberdyne") > 4.5854
    end
  end
end
