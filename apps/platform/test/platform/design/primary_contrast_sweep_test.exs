defmodule Platform.Design.PrimaryContrastSweepTest do
  @moduledoc """
  Measured WCAG contrast sweep over every pairing `--color-primary` feeds, in both
  themes. Task 01a07435 (FE-18) stage 2.

  ## Why a sweep and not an equality check

  Task 01a07435 stage 1 set `--color-primary` and `--color-accent` to `#06D5ED` in
  both themes. Harper Parker waived the human approval gate for that change on
  2026-09-06, so nothing between the token and production looks at the result with
  an eye. This file is the substitute, which is the whole reason it computes ratios
  instead of comparing strings. `assert primary == "#06D5ED"` would prove the
  assignment and say nothing about whether the assigned colour is legible anywhere
  it lands.

  Every colour below is resolved **from `app.css` itself** through
  `Platform.Design.WcagContrast` — hex parsed, `oklch()` converted,
  `color-mix(in oklab, ...)` computed, alpha composited. No resolved value is typed
  in at a call site. Change a token and these numbers move.

  ## Convention: float-through, no 8-bit quantization

  Documented in `Platform.Design.WcagContrast`, and it is the repo's existing
  convention rather than a preference: the `.chip-soft` alpha-ceiling figures already
  recorded in `app.css` (4.87868930 / 3.23613436 / 2.21457697 / 3.89478250) reproduce
  to the last digit under it and are wrong in the third decimal under the other one.
  For most of the primary sweep it changes nothing at all, because both endpoints are
  hex literals and there is nothing to round. It bites only where an intermediate
  exists: the two chip fills (L5, D5), the two pairs whose ground is an `oklch()`
  token (F2, F3), and the superseded "before" figure for D3.

  ## Independent cross-check

  The design canvas for this ticket carried five figures computed elsewhere. This
  module's arithmetic reproduces all five before it is trusted with anything new:
  `#06D5ED` 9.6304 on `#171b25` and 1.7875 on white; `#00D1DA` 9.1257 / 1.8864;
  `#22C9E0` 8.6063 / 2.0002; `#000306` 1.2011 against the `#171b25` panel and
  `#0C1016` 1.1077. Those are asserted in the first describe block. If the luminance
  code is ever wrong, it is wrong there first, and every number below is void.

  ## The classification, per pairing

  A threshold is asserted only where the obligation actually attaches. Asserting 3:1
  on a boundary that another cue carries would fail correct code, and asserting a
  threshold a pairing already misses would fail code this ticket did not break.

  | id | pairing                                                   | class | measured  |
  |----|-----------------------------------------------------------|-------|-----------|
  | L1 | primary-content (black) on the primary fill, light        | (a)   | 11.7483   |
  | L2 | accent-content (black) on the accent fill, light          | (a)   | 11.7483   |
  | L3 | primary fill vs base-100, light                           | (b)   | 1.7875    |
  | L4 | --color-interactive #087f93 as text on base-100           | (a)   | 4.7007    |
  | L5 | .chip-primary label on the 12% .chip-soft fill, light      | (c)   | 4.4073    |
  | L6 | focus ring, primary vs base-100, light                    | (c)   | 1.7875    |
  | D1 | primary-content (black) on the primary fill, dark         | (a)   | 11.7483   |
  | D2 | accent-content (black) on the accent fill, dark           | (a)   | 11.7483   |
  | D3 | primary fill vs base-100 #171b25, dark                    | (a)   | 9.6304    |
  | D4 | --color-interactive #4dd7e8 as text on #171b25            | (a)   | 10.0015   |
  | D5 | .chip-primary label on the 16% .chip-soft fill, dark       | (a)   | 7.4558    |
  | D6 | focus ring, primary vs #171b25, dark                      | (a)   | 9.6304    |

  * **(a)** a real WCAG obligation: 4.5:1 for text, 3:1 for a boundary that is the
    only cue. Asserted as a threshold, and pinned as well wherever the pin adds
    mutation sensitivity the threshold does not.
  * **(b)** no obligation, because another cue carries it. Pinned, with the reason
    stated at the assertion.
  * **(c)** already missed its threshold before this change. Pinned; the threshold is
    deliberately *not* asserted, and the shortfall is recorded below.

  ### L3 and L6 are the same measurement with different duties

  Both are `--color-primary` against light `--color-base-100`, 1.7875:1. L3 is the
  primary button's fill edge and owes nothing: the button carries a 1px
  `--color-primary` border of its own, its label is black at 11.75:1, and the brand
  rule already forbids cyan as text on white, so nothing about identifying that
  button rests on the fill/ground boundary. L6 is the focus indicator, which does owe
  3:1 under WCAG 2.2 SC 1.4.11 and misses. Same number, one classified (b) and one
  (c), because the classification is about the duty and not about the arithmetic.

  ## Findings recorded here, deliberately NOT fixed

  Filed as Suite task `01a0785c-bf6f-7001-824d-dd99bcb7db89` (high priority). Harper
  waived the approval gate for a token change, not for re-colouring shipped surfaces;
  each of these is a visible change to a live component and needs its own gate.

  Four light-theme sites render `--color-primary` as text or as a lone indicator on a
  near-white surface, against both the brand rule and the `--color-interactive`
  comment that records it. All four are pre-existing. This ticket improves each by
  about 0.11 and resolves none:

  | site                          | ground                      | before  | after   |
  |-------------------------------|-----------------------------|---------|---------|
  | L6 focus ring                 | --color-base-100 (#FFFFFF)  | 1.6759  | 1.7875  |
  | F1 `.wikilink`                | --color-base-100 (#FFFFFF)  | 1.6759  | 1.7875  |
  | F2 `.code-block-expand`       | --color-base-200 (#F2F2F2)  | 1.4919  | 1.5913  |
  | F3 `.bottom-nav-tab--active`  | light `.bottom-nav` surface | 1.5857  | 1.6913  |

  The "before" column is `oklch(82% 0.12 207)`, the light primary this task replaced.
  It cannot be recomputed from the file any more, so it is recorded here and guarded
  as a record rather than asserted as a measurement.

  **L5 is a fifth miss and a different one.** The `.chip-primary` label
  (`--color-interactive`, #087f93) on the 12% `.chip-soft` fill is 4.4073:1, under the
  4.5:1 AA floor for text. This ticket does not move it by even a rounding step: the
  light `--chip-tint` was already the hardcoded literal `#06d5ed` before stage 1
  pointed it at `var(--color-primary)`, which is the same colour. It is pre-existing,
  it is out of scope here, and it is not in the ticket above because the ticket was
  filed against the four cyan-on-near-white sites. Reported to the execution space so
  it gets filed rather than absorbed.

  **A sixth, smaller drift, reported not fixed.** `--color-base-200` in the light
  theme is declared `oklch(96% 0 0)`, which renders `#F2F2F2`, while its own trailing
  comment claims `#F5F5F5`. F2 is measured against the value that ships (`#F2F2F2`,
  1.5913); against the value the comment claims it would read 1.6396. Same class of
  defect as the one this task closed, in a different slot.

  ## Mutation results (run by hand, 2026-09-06, recorded here for the next reader)

  * **M1**, `--color-primary` to `#B8F2FA` (much lighter cyan), both themes: 12 red.
    L3, L5, L6, F1, F2, F3, D3, D5 and D6 move, and L1/D1 move on their **pins**
    (11.7483 to 17.1193) rather than their thresholds — a lighter fill only makes
    black text more readable, which is exactly why M1 alone cannot prove the light
    threshold clauses live. L2 and D2 stay green because accent is untouched.
  * **M2**, `--color-primary` to `#0A5A66` (dark teal), both themes: 12 red, and this
    time L1 and D1 fail on the **threshold** at 2.6672:1, with D3 and D6 failing 3:1.
    This is the run that exercises the light threshold half.
  * **M2 light block only** (the review protocol's exact form): 8 red, every one of
    them light — L1 on its threshold, L3/L5/L6/F1/F2/F3 on their pins. No dark clause
    moves. That is the proof the light half is measured independently of the dark.
  * **M3**, `--color-accent` to `#0A5A66`, both themes: L2 and D2 red. Neither named
    mutation touches accent, so without this the two accent clauses were never
    exercised at all. Added rather than reported, because the gap was one run to close.
  * **C1**, one declaration's comment falsified with its value left correct: exactly
    one failure, naming that declaration.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  # Pins are stated to 4 decimals. The tolerance absorbs float noise only: every
  # pinned pair here resolves deterministically from the stylesheet, so a real
  # change to any token moves the value by orders of magnitude more than this.
  # Verified: the smallest movement any named mutation produces is D5 under M1,
  # 7.4558 -> 6.9447.
  @tolerance 0.001

  @aa_text 4.5
  @non_text 3.0

  @followup_ticket "01a0785c-bf6f-7001-824d-dd99bcb7db89"

  setup_all do
    css = File.read!(@css_path)

    light = theme_block!(css, "light")
    dark = theme_block!(css, "dark")
    {interactive_light, interactive_dark} = interactive_values!(css)

    {:ok,
     css: css,
     light: %{
       primary: color!(light, "--color-primary"),
       accent: color!(light, "--color-accent"),
       primary_content: color!(light, "--color-primary-content"),
       accent_content: color!(light, "--color-accent-content"),
       base_100: color!(light, "--color-base-100"),
       base_200: color!(light, "--color-base-200"),
       interactive: interactive_light,
       block: light
     },
     dark: %{
       primary: color!(dark, "--color-primary"),
       accent: color!(dark, "--color-accent"),
       primary_content: color!(dark, "--color-primary-content"),
       accent_content: color!(dark, "--color-accent-content"),
       base_100: color!(dark, "--color-base-100"),
       interactive: interactive_dark,
       block: dark
     }}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 0. The instrument, before anything is measured with it.
  # ══════════════════════════════════════════════════════════════════════════

  describe "the luminance arithmetic itself" do
    test "reproduces every figure the design canvas computed independently" do
      # Five figures produced outside this repo. If the code below disagrees with
      # them, the code is wrong and every ratio in this file is void. Fix the
      # code, never the expectation.
      dark_panel = W.hex("#171b25")
      white = W.hex("#FFFFFF")

      assert_ratio("canvas: #06D5ED on #171b25", W.contrast(W.hex("#06D5ED"), dark_panel), 9.6304)
      assert_ratio("canvas: #06D5ED on white", W.contrast(W.hex("#06D5ED"), white), 1.7875)
      assert_ratio("canvas: #00D1DA on #171b25", W.contrast(W.hex("#00D1DA"), dark_panel), 9.1257)
      assert_ratio("canvas: #00D1DA on white", W.contrast(W.hex("#00D1DA"), white), 1.8864)
      assert_ratio("canvas: #22C9E0 on #171b25", W.contrast(W.hex("#22C9E0"), dark_panel), 8.6063)
      assert_ratio("canvas: #22C9E0 on white", W.contrast(W.hex("#22C9E0"), white), 2.0002)

      assert_ratio(
        "canvas: ground #000306 vs the #171b25 panel",
        W.contrast(W.hex("#000306"), dark_panel),
        1.2011
      )

      assert_ratio(
        "canvas: rejected ground #0C1016 vs the #171b25 panel",
        W.contrast(W.hex("#0C1016"), dark_panel),
        1.1077
      )
    end

    test "reproduces the float-through figures already recorded in app.css" do
      # These four sit in the .chip-soft alpha-ceiling comment and were computed
      # before this file existed. They pin the quantization convention: rounding
      # the oklch tint to 8 bits first gives 4.88756921 / 3.23171346 / 2.21779607
      # / 3.90669772, wrong in the third decimal on all four.
      white = W.hex("#FFFFFF")

      for {tone, {l, c, h}, expected} <- [
            {"neutral", {0.55, 0.01, 0}, 4.87868930},
            {"success", {0.62, 0.17, 162}, 3.23613436},
            {"warning", {0.76, 0.17, 70}, 2.21457697},
            {"error", {0.63, 0.22, 25}, 3.89478250}
          ] do
        actual = W.contrast(W.oklch(l, c, h), white)

        assert abs(actual - expected) < 0.0001,
               "the recorded .chip-soft ceiling for `#{tone}` (#{expected}) does not " <>
                 "reproduce; this module computed #{Float.round(actual, 8)}. Either the " <>
                 "tone token moved or the quantization convention in " <>
                 "Platform.Design.WcagContrast has changed. Both invalidate every " <>
                 "figure in this file."
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. The declarations the sweep rests on.
  # ══════════════════════════════════════════════════════════════════════════

  describe "the four --color-primary / --color-accent declarations" do
    test "there are exactly four, and all four hold the same hex", %{css: css} do
      decls =
        Regex.scan(~r/^[^\S\n]*--color-(?:primary|accent):[^\S\n]*([^;\n]+);/m, css,
          capture: :all_but_first
        )
        |> List.flatten()
        |> Enum.map(&String.trim/1)

      assert length(decls) == 4,
             "expected exactly four --color-primary / --color-accent declarations in " <>
               "app.css (light primary, light accent, dark primary, dark accent); found " <>
               "#{length(decls)}: #{inspect(decls)}. A fifth copy is a fifth place for " <>
               "the cyan to drift."

      for value <- decls do
        assert Regex.match?(~r/^#[0-9a-fA-F]{6}$/, value),
               "the declaration `#{value}` is not a plain hex literal. Task 01a07435 " <>
                 "wrote these as hex on purpose: a hex cannot drift from the comment " <>
                 "beside it, which is the defect this whole task closed."
      end

      assert decls |> Enum.map(&String.upcase/1) |> Enum.uniq() |> length() == 1,
             "the four declarations no longer agree: #{inspect(decls)}. Primary and " <>
               "accent have held one value in both themes since task 01a07435; a split " <>
               "is how the three-cyan drift started."
    end

    test "each declaration's own trailing comment names the value it sits on", %{
      light: light,
      dark: dark
    } do
      # The exact defect this ticket corrected was a comment reading `#06D5ED`
      # sitting on a value that rendered `#4EDAEB`. Nothing else in the suite
      # catches that recurring.
      #
      # The comment is taken from the declaration's OWN line, not searched for in
      # the file: a matching hex anywhere in 5000 lines would otherwise satisfy
      # this without the comment being right. Whitespace is collapsed first so a
      # reflow cannot green a broken one.
      for {theme, block} <- [{"light", light.block}, {"dark", dark.block}],
          token <- ["--color-primary", "--color-accent"] do
        %{value: value, comment: comment} = decl!(block, token)

        assert comment,
               "`#{token}` in the #{theme} theme block carries no trailing comment. " <>
                 "Each of the four declarations must state the hex it renders on its " <>
                 "own line so the comment cannot drift from the value unnoticed."

        named =
          case Regex.run(~r/#[0-9a-fA-F]{6}/, squish(comment)) do
            [hex] ->
              hex

            nil ->
              flunk(
                "the trailing comment on `#{token}` in the #{theme} theme names no " <>
                  "six-digit hex. It reads: #{inspect(squish(comment))}"
              )
          end

        assert String.upcase(named) == String.upcase(String.trim(value)),
               "the trailing comment on `#{token}` in the #{theme} theme claims " <>
                 "#{named} but the declaration is #{value}. That mismatch, in this " <>
                 "exact slot, is what task 01a07435 was filed to fix."
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Light theme.
  # ══════════════════════════════════════════════════════════════════════════

  describe "light theme" do
    test "L1 (a): --color-primary-content is AA text on the primary fill", %{light: l} do
      ratio = W.contrast(l.primary_content, l.primary)

      assert_threshold("L1", "black on the light primary fill", ratio, @aa_text)
      assert_ratio("L1", ratio, 11.7483)
    end

    test "L2 (a): --color-accent-content is AA text on the accent fill", %{light: l} do
      # Accent moved with primary in stage 1, so it carries its own assertion
      # rather than riding on L1's. If the two are ever re-split this is the
      # clause that notices.
      ratio = W.contrast(l.accent_content, l.accent)

      assert_threshold("L2", "black on the light accent fill", ratio, @aa_text)
      assert_ratio("L2", ratio, 11.7483)
    end

    test "L3 (b): the primary fill against base-100 is pinned, not thresholded", %{light: l} do
      # No 3:1 obligation attaches to this edge, and asserting one would fail
      # correct code. The primary button draws a 1px --color-primary border of
      # its own (app.css `.btn-primary`), its label is black at 11.75:1, and the
      # brand rule forbids cyan as text on white, so nothing about identifying
      # the button rests on fill-vs-ground. Pinned so the number cannot move
      # unwatched.
      ratio = W.contrast(l.primary, l.base_100)

      assert_ratio("L3", ratio, 1.7875)

      refute ratio >= @non_text,
             "L3 now clears 3:1 (#{Float.round(ratio, 4)}). That is not a failure of " <>
               "the code, but this clause was written on the premise that the light " <>
               "primary fill does NOT separate from white and that another cue carries " <>
               "the button. Re-read the classification before editing the number."
    end

    test "L4 (a): --color-interactive is AA text on base-100", %{light: l} do
      # #087f93 is hardcoded, not derived from the token, so this change does not
      # move it. Asserted anyway: a future edit to the source cyan that reached
      # this slot is exactly what would, and it is the slot the brand rule points
      # every cyan-as-text at.
      ratio = W.contrast(l.interactive, l.base_100)

      assert_threshold("L4", "--color-interactive as text on light base-100", ratio, @aa_text)
      assert_ratio("L4", ratio, 4.7007)
    end

    test "L5 (c): the light .chip-primary label misses AA, pre-existing", %{
      css: css,
      light: l
    } do
      fill = chip_fill!(css, l.primary, l.base_100, ".chip-soft")
      ratio = W.contrast(l.interactive, fill)

      # (c), so the 4.5:1 threshold is deliberately NOT asserted. The shortfall
      # predates this task and this task does not move it: the light --chip-tint
      # was already the literal #06d5ed before stage 1 pointed it at
      # var(--color-primary), which is the same colour.
      assert_ratio("L5", ratio, 4.4073)

      assert ratio < @aa_text,
             "L5 now clears 4.5:1 (#{Float.round(ratio, 4)}) on fill " <>
               "#{W.to_hex(fill)}. If that is deliberate, promote this clause from a " <>
               "(c) pin to an (a) threshold and close the finding in the moduledoc — " <>
               "do not leave a resolved miss recorded as open."
    end

    test "L6 (c): the focus ring misses the 3:1 indicator floor, pre-existing", %{light: l} do
      # WCAG 2.2 SC 1.4.11 asks 3:1 of a focus indicator against the adjacent
      # surface. `.focus-visible-ring:focus-visible` draws 2px of
      # --color-base-100 then 2px of --color-primary, so the outer band's
      # neighbours are base-100 on both sides. 1.7875:1, up from 1.6759:1 before
      # this task. The improvement is real and it does not resolve the miss, so
      # the threshold is not asserted; the number is pinned and the finding is in
      # the moduledoc and in ticket #{@followup_ticket}.
      ratio = W.contrast(l.primary, l.base_100)

      assert_ratio("L6", ratio, 1.7875)

      assert ratio < @non_text,
             "L6 now clears the 3:1 focus-indicator floor (#{Float.round(ratio, 4)}). " <>
               "Promote this to a threshold assertion and close the finding rather " <>
               "than leaving a fixed miss recorded as open."
    end

    test "the focus ring still draws its outer band from --color-primary", %{css: css} do
      # L6 measures a pairing this rule creates. If the rule stops using the
      # token, L6 is measuring a colour that no longer renders.
      body = rule_body!(css, ".focus-visible-ring:focus-visible")

      assert squish(body) =~ "0 0 0 4px var(--color-primary)",
             "`.focus-visible-ring:focus-visible` no longer draws its outer 4px band " <>
               "from var(--color-primary). L6 above measures that pairing and is now " <>
               "measuring something that does not ship. Rule body:\n#{body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Dark theme.
  # ══════════════════════════════════════════════════════════════════════════

  describe "dark theme" do
    test "D1 (a): --color-primary-content is AA text on the primary fill", %{dark: d} do
      ratio = W.contrast(d.primary_content, d.primary)

      assert_threshold("D1", "black on the dark primary fill", ratio, @aa_text)
      assert_ratio("D1", ratio, 11.7483)
    end

    test "D2 (a): --color-accent-content is AA text on the accent fill", %{dark: d} do
      ratio = W.contrast(d.accent_content, d.accent)

      assert_threshold("D2", "black on the dark accent fill", ratio, @aa_text)
      assert_ratio("D2", ratio, 11.7483)
    end

    test "D3 (a): the primary fill clears 3:1 against the dark base-100", %{dark: d} do
      ratio = W.contrast(d.primary, d.base_100)

      assert_threshold("D3", "the dark primary fill against #171b25", ratio, @non_text)
      assert_ratio("D3", ratio, 9.6304)
    end

    test "D4 (a): --color-interactive is AA text on the dark base-100", %{dark: d} do
      ratio = W.contrast(d.interactive, d.base_100)

      assert_threshold("D4", "--color-interactive as text on #171b25", ratio, @aa_text)
      assert_ratio("D4", ratio, 10.0015)
    end

    test "D5 (a): the dark .chip-primary label clears AA on its 16% fill", %{
      css: css,
      dark: d
    } do
      fill = chip_fill!(css, d.primary, d.base_100, ~s([data-theme="dark"] .chip-soft))
      ratio = W.contrast(d.interactive, fill)

      # Measured, then classified (a): unlike its light counterpart this one
      # clears. It did move — the dark --chip-tint was #00bcd4 before stage 1 and
      # read 7.7729 — so it is pinned as well as thresholded.
      assert_threshold("D5", "the dark chip-primary label on its own fill", ratio, @aa_text)
      assert_ratio("D5", ratio, 7.4558)
    end

    test "D6 (a): the focus ring clears 3:1 against the dark base-100", %{dark: d} do
      ratio = W.contrast(d.primary, d.base_100)

      assert_threshold("D6", "the dark focus ring against #171b25", ratio, @non_text)
      assert_ratio("D6", ratio, 9.6304)
    end

    test ".chip-primary in both themes still takes its tint from --color-primary", %{css: css} do
      # L5 and D5 measure a fill computed from the token. If .chip-primary is
      # given a literal of its own again, those two clauses go on passing while
      # measuring a colour that is no longer the chip's.
      base = rule_body!(css, ".chip-primary")

      assert squish(base) =~ "--chip-tint: var(--color-primary)",
             "the base `.chip-primary` rule no longer takes --chip-tint from " <>
               "var(--color-primary). Body:\n#{base}"

      assert squish(base) =~ "--chip-label: var(--color-interactive)",
             "the base `.chip-primary` rule no longer takes --chip-label from " <>
               "var(--color-interactive). L5 and D5 measure that label. Body:\n#{base}"

      dark = rule_body!(css, ~s([data-theme="dark"] .chip-primary))

      assert squish(dark) =~ "--chip-tint: var(--color-primary)",
             "the dark `.chip-primary` override no longer takes --chip-tint from " <>
               "var(--color-primary). Body:\n#{dark}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. The known findings: measured, pinned, deliberately not fixed.
  # ══════════════════════════════════════════════════════════════════════════

  describe "pre-existing light-theme misses (ticket #{@followup_ticket})" do
    test "F1: .wikilink renders primary as text on base-100", %{css: css, light: l} do
      body = rule_body!(css, ".wikilink")

      assert squish(body) =~ "color: var(--color-primary)",
             "`.wikilink` no longer colours from var(--color-primary). If it was " <>
               "moved to --color-interactive this finding is FIXED — close it in the " <>
               "moduledoc and in ticket #{@followup_ticket} rather than deleting the " <>
               "clause. Body:\n#{body}"

      ratio = W.contrast(l.primary, l.base_100)
      assert_ratio("F1 (.wikilink on --color-base-100)", ratio, 1.7875)

      assert ratio < @aa_text,
             "F1 now clears AA. Close the finding rather than leaving it recorded."
    end

    test "F2: .code-block-expand renders primary as text on base-200", %{css: css, light: l} do
      body = rule_body!(css, ".code-block-expand")

      assert squish(body) =~ "background: var(--color-base-200)",
             "`.code-block-expand` no longer sits on --color-base-200; the ground " <>
               "this finding is measured against has changed. Body:\n#{body}"

      assert squish(body) =~ "color: var(--color-primary)",
             "`.code-block-expand` no longer colours from var(--color-primary). " <>
               "Body:\n#{body}"

      ratio = W.contrast(l.primary, l.base_200)

      # Measured against what --color-base-200 actually renders, oklch(96% 0 0)
      # = #F2F2F2. Its own trailing comment claims #F5F5F5, which would give
      # 1.6396. That comment drift is itself reported, not fixed here.
      assert_ratio("F2 (.code-block-expand on --color-base-200)", ratio, 1.5913)

      assert ratio < @aa_text,
             "F2 now clears AA. Close the finding rather than leaving it recorded."
    end

    test "F3: .bottom-nav-tab--active renders primary on the light nav surface", %{
      css: css,
      light: l
    } do
      body = rule_body!(css, ".bottom-nav-tab--active")

      assert squish(body) =~ "color: var(--color-primary)",
             "`.bottom-nav-tab--active` no longer colours from var(--color-primary). " <>
               "Body:\n#{body}"

      nav = rule_body!(css, ~s([data-theme="light"] .bottom-nav))

      surface =
        case Regex.run(
               ~r/background:\s*oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)\s*\/\s*([\d.]+)\)/,
               squish(nav),
               capture: :all_but_first
             ) do
          [lum, chroma, hue, alpha] ->
            W.composite(
              W.oklch(to_f(lum) / 100, to_f(chroma), to_f(hue)),
              to_f(alpha),
              l.base_100
            )

          nil ->
            flunk(
              "the light `.bottom-nav` background is no longer a translucent oklch() " <>
                "over the page ground, so F3's surface cannot be computed. " <>
                "Body:\n#{nav}"
            )
        end

      ratio = W.contrast(l.primary, surface)
      assert_ratio("F3 (.bottom-nav-tab--active on #{W.to_hex(surface)})", ratio, 1.6913)

      assert ratio < @aa_text,
             "F3 now clears AA. Close the finding rather than leaving it recorded."
    end

    test "the moduledoc still carries the findings record", %{} do
      # A record guard, not a measurement: the numbers above prove themselves,
      # but the fact that four misses were found, classified pre-existing and
      # deliberately left alone lives only in prose. Deleting that prose while
      # keeping the tests would leave a green suite that has forgotten why half
      # its clauses refuse to assert a threshold.
      doc = squish(@moduledoc)

      assert doc =~ @followup_ticket,
             "the moduledoc no longer names the follow-up ticket for the four " <>
               "pre-existing light-theme misses."

      for marker <- [
            ".wikilink",
            ".code-block-expand",
            ".bottom-nav-tab--active",
            "1.6759",
            "1.4919",
            "1.5857"
          ] do
        assert doc =~ marker,
               "the moduledoc no longer records `#{marker}`. The pre-change figures " <>
                 "cannot be recomputed from app.css — this prose is the only copy."
      end

      assert doc =~ "4.4073",
             "the moduledoc no longer records L5's measured value, the fifth " <>
               "pre-existing miss and the one that is not on the ticket."
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp assert_threshold(id, description, ratio, floor) do
    assert ratio >= floor,
           "#{id}: #{description} measures #{Float.round(ratio, 4)}:1, under the " <>
             "#{floor}:1 floor this pairing owes. This pairing is classified (a) — a " <>
             "real WCAG obligation — so the fix is the colour, not the assertion."
  end

  defp assert_ratio(label, actual, expected) do
    assert abs(actual - expected) <= @tolerance,
           "#{label} is pinned at #{expected}:1 (±#{@tolerance}) and measures " <>
             "#{Float.round(actual, 4)}:1. The pin is a drift detector: if the change " <>
             "that moved it is intended, re-derive the number and update the pin AND " <>
             "the table in this file's moduledoc together."
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp to_f(text) do
    {value, ""} = Float.parse(if String.contains?(text, "."), do: text, else: text <> ".0")
    value
  end

  # The body of a `@plugin "../vendor/daisyui-theme" { ... }` block, chosen by its
  # `name:` line. Split on a `}` at column 0, which is how this file closes them.
  defp theme_block!(css, name) do
    css
    |> String.split(~s(@plugin "../vendor/daisyui-theme" {))
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split(~r/^\}/m, parts: 2) |> hd()))
    |> Enum.find(&Regex.match?(~r/name:\s*"#{name}"/, &1))
    |> case do
      nil -> flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
      block -> block
    end
  end

  # A declaration and the comment on its OWN line. Not a file-wide search.
  defp decl!(block, token) do
    re =
      ~r/^[^\S\n]*#{Regex.escape(token)}:[^\S\n]*([^;\n]+);(?:[^\S\n]*\/\*([^\n]*?)\*\/)?[^\S\n]*$/m

    case Regex.run(re, block, capture: :all_but_first) do
      [value] -> %{value: String.trim(value), comment: nil}
      [value, ""] -> %{value: String.trim(value), comment: nil}
      [value, comment] -> %{value: String.trim(value), comment: comment}
      nil -> flunk("no `#{token}:` declaration in the theme block being read.")
    end
  end

  defp color!(block, token), do: block |> decl!(token) |> Map.fetch!(:value) |> W.parse!()

  defp rule_body!(css, selector) do
    re = ~r/^[^\S\n]*#{Regex.escape(selector)}\s*\{([^}]*)\}/m

    case Regex.run(re, css, capture: :all_but_first) do
      [body] ->
        body

      nil ->
        flunk(
          "no `#{selector} { ... }` rule starting a line in #{@css_path}. The pairing " <>
            "measured against it no longer exists, so the clause is measuring nothing."
        )
    end
  end

  # `--color-interactive` is declared three times: once in `:root` (light) and
  # twice for dark (the [data-theme="dark"] block and the prefers-color-scheme
  # copy). Both dark copies must agree, or one surface renders a colour this
  # sweep never measured.
  defp interactive_values!(css) do
    values =
      Regex.scan(~r/^[^\S\n]*--color-interactive:[^\S\n]*([^;\n]+);/m, css,
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.map(&String.trim/1)

    assert length(values) == 3,
           "expected exactly three --color-interactive declarations (light :root, " <>
             "[data-theme=\"dark\"], and the prefers-color-scheme copy); found " <>
             "#{length(values)}: #{inspect(values)}."

    [light, dark_a, dark_b] = values

    assert dark_a == dark_b,
           "the two dark --color-interactive declarations disagree (#{dark_a} vs " <>
             "#{dark_b}). One of the two dark surfaces renders a colour D4 and D5 " <>
             "never measured."

    assert light != dark_a,
           "light and dark --color-interactive now hold the same value (#{light}). " <>
             "The slot exists precisely because the AA-safe action cyan differs by " <>
             "theme; if that is intended, re-derive L4 and D4 before collapsing it."

    root = rule_body!(css, ":root")

    assert squish(root) =~ "--color-interactive: #{light}",
           "the first --color-interactive declaration (#{light}) is not the one in " <>
             "`:root`, so the light/dark order this helper assumes has changed."

    dark_block = rule_body!(css, ~s([data-theme="dark"]))

    assert squish(dark_block) =~ "--color-interactive: #{dark_a}",
           "the second --color-interactive declaration (#{dark_a}) is not the one in " <>
             "the [data-theme=\"dark\"] block."

    {W.parse!(light), W.parse!(dark_a)}
  end

  # The computed `.chip-soft` fill for the primary tone: the tint mixed into the
  # theme's base-100 at the percentage the rule declares. The percentage is read
  # from the stylesheet rather than hardcoded, so re-tuning 12% or 16% moves L5
  # and D5 instead of quietly invalidating them.
  defp chip_fill!(css, tint, base, selector) do
    body = rule_body!(css, selector)

    case Regex.run(
           ~r/color-mix\(in oklab, var\(--chip-tint\) (\d+)%, var\(--color-base-100\)\)/,
           squish(body),
           capture: :all_but_first
         ) do
      [pct] ->
        W.mix_oklab(tint, String.to_integer(pct), base)

      nil ->
        flunk(
          "`#{selector}` no longer computes its background as " <>
            "color-mix(in oklab, var(--chip-tint) N%, var(--color-base-100)). L5/D5 " <>
            "measure that formula. Body:\n#{body}"
        )
    end
  end
end
