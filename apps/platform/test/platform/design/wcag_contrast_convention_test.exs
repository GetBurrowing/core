defmodule Platform.Design.WcagContrastConventionTest do
  @moduledoc """
  The two contrast quantities `Platform.Design.WcagContrast` computes, pinned
  without parsing the stylesheet — task `01a08d90` stage 2.

  `contrast/2` carries float-through arithmetic: an oklch conversion or a mix
  lands between two 8-bit steps and the float goes straight into the luminance
  sum. `contrast_painted/2` quantizes both endpoints to 8-bit sRGB first — the
  quantity a painted-pixel read measures, because the compositor writes an 8-bit
  buffer before anything can sample it. The two agree exactly when both endpoints
  are already 8-bit hex, and disagree in the third decimal wherever a conversion
  is involved. `app.css` records its `.chip-soft` ceilings under the first
  convention and its candidate-rail figures under the second ("MEASURED in a
  browser ... painted pixels"), so a reproduction must pick the quantity the
  recording used. Stage 1 scoped the module's moduledoc to exactly that; this
  file pins the BEHAVIOUR the prose describes — a test asserting the moduledoc's
  text is explicitly not wanted here.

  ## The discriminator, and which response each failure wants

  Every clause computes its figure BOTH ways, and every failure message names
  which response it wants — the two-group anchor pattern of
  `candidate_closed_row_contrast_test.exs`:

  * **Convention** — the converter-exactness clauses and the pure-hex anchor are
    green, but a conversion-involved figure misses: the reproduction used the
    wrong quantity. The response is to measure the painted figure with
    `contrast_painted/2`, never to widen a tolerance.
  * **Real fault** — the exact converter clause or the pure-hex anchor misses
    too: the converter or its arithmetic is broken. The response is fixing code,
    not re-pinning figures.

  The clauses are built so that aliasing `contrast_painted/2` to `contrast/2`
  (the named mutation from the plan) reds the differ clause and the
  conversion-involved reproduction clauses while the converter-exactness and
  pure-hex bit-identity clauses stay green.

  Anchors pair against `--cc-bg-closed` (`#F4F5F7` light / `#12151C` dark), the
  grounds `app.css` records its rail figures against — not the rail's
  double-composited `bg-base-200/40` grounds, which belong to the AA gates, not
  these reproductions. The dark anchor is the DARK theme's `oklch(40% 0.01 0)`
  (app.css:238): pairing against the light 45% token gives ~2.44 and "disproves"
  the table — the wrong-anchor error the plan warns about.
  """

  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W

  # Exactness tolerance for the converter identity clauses (21.0, 1.0) and the
  # pure-hex bit-identity assert.
  @exact 0.0000001
  # Four-decimal figure pins.
  @pin 0.0001
  # Reproduction tolerance against app.css's recorded two-decimal figures: the
  # SAME 0.005 the computed-contrast guards use (half the last recorded digit),
  # not wider.
  @tolerance 0.005

  # ── anchor table ──────────────────────────────────────────────────────────
  # One entry per recorded figure `app.css` carries for the candidate rail: the
  # colour forms, the hex each form must resolve to, the two figures to four
  # decimals (float-through first), and the two-decimal figure app.css records.
  # Pins verified at plan time against origin/main token values and re-proven
  # at stage 1; the resolve asserts re-prove them on every run, so a stylesheet
  # token retune reds at RESOLUTION instead of silently drifting a ratio.
  @anchors [
    %{
      name: "title-dead light",
      pure_hex?: true,
      fg: W.hex("#767D8D"),
      fg_hex: "#767D8D",
      bg: W.hex("#F4F5F7"),
      bg_hex: "#F4F5F7",
      float_through: 3.7833,
      painted: 3.7833,
      recorded: 3.78,
      provenance: "light --cc-title-dead on --cc-bg-closed (app.css ~6603 / ~6599); pure hex"
    },
    %{
      name: "neutral light",
      pure_hex?: false,
      fg: W.parse!("oklch(45% 0.01 0)"),
      fg_hex: "#5A5355",
      bg: W.hex("#F4F5F7"),
      bg_hex: "#F4F5F7",
      float_through: 6.8579,
      painted: 6.8674,
      recorded: 6.87,
      provenance: "light --color-neutral (app.css:148) on --cc-bg-closed (app.css:6599)"
    },
    %{
      name: "neutral dark",
      pure_hex?: false,
      fg: W.parse!("oklch(40% 0.01 0)"),
      fg_hex: "#4D4647",
      bg: W.hex("#12151C"),
      bg_hex: "#12151C",
      float_through: 1.9724,
      painted: 1.9853,
      recorded: 1.99,
      provenance:
        "DARK --color-neutral (app.css:238 — 40%, NOT the light 45%) on dark --cc-bg-closed (app.css:6770)"
    },
    %{
      name: "spent-fg light",
      pure_hex?: false,
      fg: W.mix_oklab(W.parse!("oklch(45% 0.01 0)"), 90, W.hex("#FFFFFF")),
      fg_hex: "#696364",
      bg: W.hex("#F4F5F7"),
      bg_hex: "#F4F5F7",
      float_through: 5.4101,
      painted: 5.3932,
      recorded: 5.39,
      provenance:
        "color-mix(in oklch, var(--color-neutral) 90%, white) (app.css:6750); both endpoints hue-0, so the oklab mix equals the oklch mix exactly"
    }
  ]

  describe "converter exactness (a miss here is a REAL FAULT, never a convention response)" do
    test "white/black is exactly 21.0 and self-contrast is exactly 1.0" do
      white_black = W.contrast(W.hex("#FFFFFF"), W.hex("#000000"))

      assert abs(white_black - 21.0) <= @exact,
             "REAL FAULT: white/black measured #{white_black}, must be exactly 21.0. The " <>
               "luminance arithmetic or its inputs are broken — fix the converter; do not " <>
               "re-pin figures or widen tolerances."

      self_ratio = W.contrast(W.hex("#777777"), W.hex("#777777"))

      assert abs(self_ratio - 1.0) <= @exact,
             "REAL FAULT: a colour against itself measured #{self_ratio}, must be exactly 1.0."
    end

    test "oklch endpoints land on the 8-bit extremes" do
      white = W.to_hex(W.parse!("oklch(100% 0 0)"))

      assert white == "#FFFFFF",
             "REAL FAULT, not a convention gap: oklch(100% 0 0) rendered #{inspect(white)}; " <>
               "the oklch conversion is broken."

      black = W.to_hex(W.parse!("oklch(0% 0 0)"))

      assert black == "#000000",
             "REAL FAULT, not a convention gap: oklch(0% 0 0) rendered #{inspect(black)}; " <>
               "the oklch conversion is broken."
    end
  end

  describe "per-anchor resolution (a token retune must red HERE, not drift a ratio)" do
    test "every anchor's fg and bg resolve to their pinned app.css hex" do
      for anchor <- @anchors do
        fg_resolved = W.to_hex(anchor.fg)

        assert fg_resolved == anchor.fg_hex,
               "TOKEN RETUNE, not a converter fault: #{anchor.name} foreground " <>
                 "(#{anchor.provenance}) now resolves to #{fg_resolved}, pinned " <>
                 "#{anchor.fg_hex}. Re-pin this anchor from the re-tuned token — the recorded " <>
                 "figures below describe the OLD token."

        bg_resolved = W.to_hex(anchor.bg)

        assert bg_resolved == anchor.bg_hex,
               "TOKEN RETUNE, not a converter fault: #{anchor.name} background (#{anchor.provenance}) " <>
                 "now resolves to #{bg_resolved}, pinned #{anchor.bg_hex}. Re-pin this anchor from " <>
                 "the re-tuned token."
      end
    end
  end

  describe "the both-ways discriminator" do
    test "the pure-hex pair is BIT-IDENTICAL under contrast/2 and contrast_painted/2" do
      for anchor <- @anchors, anchor.pure_hex? do
        float = W.contrast(anchor.fg, anchor.bg)
        painted = W.contrast_painted(anchor.fg, anchor.bg)

        assert abs(float - painted) <= @exact,
               "REAL FAULT, not a convention gap: #{anchor.name} is pure hex " <>
                 "(#{anchor.fg_hex} on #{anchor.bg_hex}), so float-through #{float} and painted " <>
                 "#{painted} must be bit-identical — there is nothing to quantize. If a pure-hex " <>
                 "anchor misses, the converter or its arithmetic is broken."
      end
    end

    test "every conversion-involved pair DIFFERS by more than 0.005 between the conventions" do
      for anchor <- @anchors, not anchor.pure_hex? do
        gap = abs(W.contrast(anchor.fg, anchor.bg) - W.contrast_painted(anchor.fg, anchor.bg))

        assert gap > @tolerance,
               "CONVENTION COLLAPSE: #{anchor.name} measured a #{Float.round(gap, 6)} gap between " <>
                 "contrast/2 and contrast_painted/2; conversion-involved pairs measure " <>
                 "0.0095 / 0.0129 / 0.0169. Either contrast_painted/2 was aliased to contrast/2 " <>
                 "(restore the quantize step) or the conversion arithmetic changed — fix the code, " <>
                 "do not widen."
      end
    end
  end

  describe "four-decimal figure pins" do
    test "both conventions land on their pinned four-decimal figures" do
      for anchor <- @anchors do
        float = W.contrast(anchor.fg, anchor.bg)

        assert abs(float - anchor.float_through) <= @pin,
               "FIGURE PIN MOVED: #{anchor.name} float-through now #{Float.round(float, 6)}, " <>
                 "pinned #{anchor.float_through} (±#{@pin}). If the conversion arithmetic changed " <>
                 "this is a REAL FAULT to fix; if the pin itself is stale, re-derive it — never " <>
                 "widen the pin."

        painted = W.contrast_painted(anchor.fg, anchor.bg)

        assert abs(painted - anchor.painted) <= @pin,
               "FIGURE PIN MOVED: #{anchor.name} painted now #{Float.round(painted, 6)}, pinned " <>
                 "#{anchor.painted} (±#{@pin}). If contrast_painted/2 has been aliased to " <>
                 "contrast/2 this is where the quantize step died — restore it; never widen the pin."
      end
    end
  end

  describe "reproduction of app.css's recorded figures" do
    test "contrast_painted lands within 0.005 of every recorded two-decimal figure" do
      for anchor <- @anchors do
        painted = W.contrast_painted(anchor.fg, anchor.bg)

        assert abs(painted - anchor.recorded) <= @tolerance,
               "CONVENTION (most likely) or real fault: #{anchor.name} painted " <>
                 "#{Float.round(painted, 4)} vs recorded #{anchor.recorded}. The recorded figure is " <>
                 "a PAINTED-pixel read, so it compares against contrast_painted/2. If the " <>
                 "converter-exactness and pure-hex clauses are green, the gap is the convention — " <>
                 "check the fg form against app.css's actual declaration and measure the painted " <>
                 "quantity. If the pure-hex anchor misses too, that is a REAL FAULT in the converter."
      end
    end

    test "float-through MISSES every conversion-involved recorded figure by more than 0.005" do
      for anchor <- @anchors, not anchor.pure_hex? do
        float = W.contrast(anchor.fg, anchor.bg)

        assert abs(float - anchor.recorded) > @tolerance,
               "ALIAS CHECK FAILED: contrast/2's float-through figure #{Float.round(float, 4)} now " <>
                 "lands within 0.005 of #{anchor.name}'s recorded #{anchor.recorded}; the measured " <>
                 "float-through figures miss by 0.0121 / 0.0176 / 0.0201. If contrast_painted/2 has " <>
                 "been aliased to contrast/2, restore it — the two quantities must stay distinct."
      end
    end
  end
end
