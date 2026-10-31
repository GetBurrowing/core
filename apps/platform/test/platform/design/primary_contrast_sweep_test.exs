defmodule Platform.Design.PrimaryContrastSweepTest do
  @moduledoc """
  Measured WCAG contrast sweep over every pairing `--color-primary` feeds, in both
  themes. Task 01a07435 (FE-18) stage 2.

  ## Why a sweep and not an equality check

  Task 01a07435 stage 1 set `--color-primary` and `--color-accent` to `#06D5ED` in
  both themes. Sam Moreno waived the human approval gate for that change on
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

  ## The Burrow recolor (task 01a120c5 stage 1)

  The cyan this file was written around is gone. Primary is now a per-theme
  orange (#ad4b07 light, #f47721 dark), the interactive text colour is #8b3b04
  light and #ff9b55 dark, and the grounds are #fbfaf9 / #f6f4f1 (light) and
  #191b20 / #111214 (dark). Every pin below was re-derived from the new
  declarations; the history in this moduledoc is kept as written, because its
  figures are the only copy and the record guards at the bottom of the file
  assert them. What the recolor changed in the classification:

    * L3 promoted from (b) to (a): the light primary fill now clears 3:1 on
      base-100 (5.3202).
    * F2 and F3 promoted from (c) to (a): the deeper interactive clears AA on
      base-200 (7.0195) and on the near-white nav (7.2791).
    * L8 REGRESSED from (a) to a recorded miss, 2.7251:1: the light no-offset
      ring (#8b3b04) against the focused input's own border, which paints
      --color-base-content (#000000; stage 4 kept main's black over the spec's
      #221f1b, against which it was 2.1293). It was 4.4674 with the darkened
      cyan against black. Same shape as D8: the ring is identified against the page ground,
      L7 at 7.3919. The values that produce it (the light ring slot and the
      interactive hex) are fixed by the spec, so it is recorded, not tuned.
    * The ::before bar REGRESSED on the near-black nav under light tokens,
      2.5444:1 against its 3:1 floor (was 4.1661). F4, the label on the same
      ground, moved from 4.1661 to 2.5444 and stays (c). Both sit on the ground
      that only exists because `.bottom-nav` lacks a prefers-color-scheme light
      background, the defect already filed as the real fix.

  ## Burrow redesign 4: the tab bar left this file (task 01a1557a-7a71 stage 1)

  F3, F4 and the active tab's `::before` bar measured the mobile tab bar on two
  theme-dependent grounds that stage 1 of task 01a1557a-7a71-7000-8580-75565039bffe
  deleted, together with the bar itself. The bar is now one glass surface,
  `--color-base-200` at a per-variant `--glass-alpha`, and its ink is measured on
  PAINTED pixels over pure black and pure white in all ten variants by
  `test/platform/design/bottom_nav_glass_guard_test.exs`. Their three clauses are
  replaced by one pointer clause that fails if any retired surface comes back.
  The rows below are kept as the record; their class reads "retired".

  ## The classification, per pairing

  A threshold is asserted only where the obligation actually attaches. Asserting 3:1
  on a boundary that another cue carries would fail correct code, and asserting a
  threshold a pairing already misses would fail code this ticket did not break.

  Measured on the Burrow tokens (task 01a120c5); the pre-Burrow figure follows
  in brackets.

  | id | pairing                                                   | class | measured  |
  |----|-----------------------------------------------------------|-------|-----------|
  | L1 | primary-content (#fbfaf9) on the primary fill, light      | (a)   | 5.3202 [11.7483] |
  | L2 | accent-content (#fbfaf9) on the accent fill, light        | (a)   | 5.3202 [11.7483] |
  | L3 | primary fill vs base-100, light                           | (a)   | 5.3202 [1.7875]  |
  | L4 | --color-interactive #8b3b04 as text on base-100           | (a)   | 7.3919 [4.7007]  |
  | L5 | .chip-primary label on the 6% .chip-soft fill, light       | (a)   | 6.8125 [4.5524]  |
  | L6 | offset focus ring vs base-100, light                      | (a)   | 7.3919 [4.7007]  |
  | L7 | no-offset focus ring vs base-100, light                   | (a)   | 7.3919 [4.7007]  |
  | L8 | no-offset ring vs the input border it abuts, light        | (c)*  | 2.1293 [4.4674]  |
  | D1 | primary-content (black) on the primary fill, dark         | (a)   | 7.5073 [11.7483] |
  | D2 | accent-content (black) on the accent fill, dark           | (a)   | 7.5073 [11.7483] |
  | D3 | primary fill vs base-100 #191b20, dark                    | (a)   | 6.1588 [9.6304]  |
  | D4 | --color-interactive #ff9b55 as text on #191b20            | (a)   | 8.2625 [10.0015] |
  | D5 | .chip-primary label on the 16% .chip-soft fill, dark       | (a)   | 6.6080 [7.4558]  |
  | D6 | offset focus ring vs #191b20, dark                        | (a)   | 6.1588 [9.6304]  |
  | D7 | no-offset focus ring vs #191b20, dark                     | (a)   | 6.1588 [9.6304]  |
  | D8 | no-offset ring vs the input border it abuts, dark         | (c)   | 2.4313 [1.5447]  |

  (c)* L8 is not a pre-existing miss: the Burrow recolor introduced it. See
  "The Burrow recolor" above.

  Both chip percentages are `--chip-tint-pct`, resolved per tone per theme from the
  stylesheet rather than read as a literal out of the shared formula.

  F1 to F4 are classified as well, in the table under "The cyan-on-light findings"
  below, because their class only reads correctly beside the ground each one sits on:
  F1 (a), F2 (c), F3 (c), F4 (c); F3 and F4 are now retired, see "Burrow redesign 4"
  above. Stage 4 of the ticket below re-read all twenty ids
  against the clauses that carry them. Every id named (a) calls `assert_threshold`;
  every id named (b) or (c) does not, and states its reason at the assertion.

  * **(a)** a real WCAG obligation: 4.5:1 for text, 3:1 for a boundary that is the
    only cue. Asserted as a threshold, and pinned as well wherever the pin adds
    mutation sensitivity the threshold does not.
  * **(b)** no obligation, because another cue carries it. Pinned, with the reason
    stated at the assertion.
  * **(c)** already missed its threshold before this change. Pinned; the threshold is
    deliberately *not* asserted, and the shortfall is recorded below.

  ### L3 and L6 stopped being the same measurement

  Until stage 3 of the ticket below, both were `--color-primary` against light
  `--color-base-100` and this module computed 1.7875 twice. That is why L6 could
  never have caught its own regression: it evaluated `W.contrast(l.primary,
  l.base_100)`, the identical expression F1 evaluated, so reverting the ring alone
  moved neither clause and F1 covered for it. L6 now reads the band's token out of
  the ring rule's own `box-shadow` and looks it up, which is what makes reverting the
  ring red the ring's own clauses instead of nothing.

  Stage 4 measured that revert and it reds **four** clauses, not one: L6, L7, L8 and
  the structural guard on the two rules. That is not a shared assertion. It is one
  site with three different adjacent surfaces (the page ground for the offset variant,
  the page ground for the no-offset outer band, the input's own border for the inner
  band) plus a structural pin on the rule that draws them. All four name the focus
  ring and no clause about any other site moves.

  L3 is unchanged, still (b), still pinned at 1.7875 with its threshold deliberately
  not asserted. It is the primary button's fill edge and owes nothing: the button
  carries a 1px `--color-primary` border of its own, its label is black at 11.75:1,
  and the brand rule already forbids cyan as text on white, so nothing about
  identifying that button rests on the fill/ground boundary.

  ## The cyan-on-light findings, and what happened to them

  Filed as Suite task `01a0785c-bf6f-7001-824d-dd99bcb7db89` (high priority) after
  FE-18 found them. Sam waived the approval gate for FE-18's token change, not for
  re-colouring shipped surfaces, so each of these went through a gate of its own.
  Stage 1 of that ticket pointed the three text sites at `--color-interactive`, the
  slot the brand rule already names for cyan-as-text. Three generations of the same
  measurement, with the class each pairing now carries:

  | site                          | ground                      | FE-18 before | FE-18 after | now     | class |
  |-------------------------------|-----------------------------|--------------|-------------|---------|-------|
  | L6 focus ring                 | --color-base-100 (#FFFFFF)  | 1.6759       | 1.7875      | 4.7007  | (a)   |
  | F1 `.wikilink`                | --color-base-100 (#FFFFFF)  | 1.6759       | 1.7875      | 4.7007  | (a)   |
  | F2 `.code-block-expand`       | --color-base-200 (#F2F2F2)  | 1.4919       | 1.5913      | 4.1847  | (c)   |
  | F3 `.bottom-nav-tab--active`  | light `.bottom-nav` #F9F9F9 | 1.5857       | 1.6913      | 4.4478  | retired (glass guard) |
  | F4 the same tab, default nav  | near-black #0C0C0C on light | N/A          | 10.9561     | 4.1661  | retired (glass guard) |

  The "FE-18 before" column is `oklch(82% 0.12 207)`, the light primary FE-18
  replaced. It cannot be recomputed from the file any more, so it is recorded here
  and guarded as a record rather than asserted. "FE-18 after" is `#06D5ED`, which
  improved each pairing by about 0.11 and resolved none. L6's "now" column is stage
  3's, not stage 1's.

  ### Only F1 clears, and that is the finding stage 1 reports

  `--color-interactive` (#087f93) was derived against pure white, where it measures
  4.7007:1. Two of the three text sites do not sit on white, and on their real
  grounds the slot lands under the floor: 4.1847 on `--color-base-200` and 4.4478 on
  the near-white nav. Both are large improvements (2.6x and 2.6x) and neither is AA.
  Closing them means darkening the slot itself, which repaints every link in the
  product; `#077384` would give 5.5343 / 5.2365 / 4.9268 on the three light grounds.
  That is a palette change with its own census and its own gate, and it is filed as a
  follow-up rather than smuggled into a stage scoped to three declarations.

  ### F3 and F4 are mutually exclusive, which makes the nav the defect

  `.bottom-nav` declares its light background under `[data-theme="light"]` and has no
  `prefers-color-scheme: light` twin, so the same tab has two light-theme grounds:
  #F9F9F9 when the attribute is present, near-black #0C0C0C when it is not. A viewer
  reaches the second only by choosing the "system" theme, which is what removes the
  attribute; `root.html.heex:174` writes `data-theme="dark"` whenever it is absent
  and nothing is stored, so this is not the unset default.

  The two grounds cannot both be satisfied. Clearing 4.5:1 on #F9F9F9 needs a text
  luminance of at most 0.170779; clearing it on #0C0C0C needs at least 0.191270. No
  value of any token sits in both, so F3 and F4 are pinned without thresholds and the
  missing nav variant is filed as the real defect. Stage 1 optimised for the
  `[data-theme="light"]` nav, which is what an explicit-light viewer paints, and F4
  regressed from 10.9561 to 4.1661 as a result. What improved is the worst case
  across both grounds, 1.6913 to 4.1661.

  The `.bottom-nav-tab--active::before` bar moved with the label. It is a non-text
  cue owing 3:1, it measured 1.6913 on the near-white nav as `--color-primary`, and
  as `--color-interactive` it clears on all three nav grounds (4.4478 / 4.1661 /
  12.0046). Unlike the label, it is (a).

  Dark regressed nowhere: 9.6304 to 10.0015 for the wikilink, 11.5762 to 12.0222 for
  the expander, 11.5593 to 12.0046 for the nav tab.

  ### L5 was a fifth miss, and stage 2 closed it by moving the ground

  The `.chip-primary` label (`--color-interactive`, #087f93) on the 12% `.chip-soft`
  fill measured **4.4073:1**, under the 4.5:1 AA floor for text. Stage 1 did not move
  it by a rounding step: the light `--chip-tint` was already the hardcoded literal
  `#06d5ed` before stage 1 pointed it at `var(--color-primary)`, the same colour.

  Stage 2 lowered the tint rather than darkening the label, which is what the design
  canvas attached to the ticket decided. A chip-only darker label would be a second
  action colour with no rule saying when each applies; the tint is decoration and the
  label is information. The percentage became `--chip-tint-pct`, a custom property read
  by the one `background: color-mix(...)` declaration the component has, with
  `.chip-primary` setting 6% in the light theme. **4.5524:1**, now (a).

  The canvas offered 10% as the obvious first try and it does not clear. The measured
  ladder is 4.4073 at 12%, 4.4553 at 10%, 4.4795 at 9%, 4.5037 at 8% and 4.5524 at 6%.
  8% is the first integer that clears and it clears by 0.004, narrower than the
  disagreement between the two quantization conventions this module documents above, so
  an AA claim at 8% would rest on which convention was picked. Chrome, painting the
  `color-mix` and reading the pixel back, gives 4.3930 / 4.4517 / 4.4904 / 4.5062 /
  4.5583 for the same rungs and agrees on which of them clear. 6% clears under both.

  Dark was never in question. D5 keeps the shared 16% and stays at 7.4558:1; the dark
  `.chip-primary` rules declare that percentage outright rather than inheriting it by
  selector weight, and `chip_soft_contrast_test.exs` reds if the two drift apart.

  The cost is recorded in `app.css` as well as here: lowering the tint takes the primary
  fill further from the card surface (1.0666 to 1.0326) and its border composited over
  that fill from 1.2461 to 1.2176. Neither owes 3:1, for the reason the `.chip-soft`
  verdict comment gives, so this closed a real text obligation at the price of a
  boundary that was already weak and owes nothing.

  ### L6 was the one keyboard failure on the ticket, and stage 3 closed it

  The other four misses were text a person could still read badly. This one was a
  keyboard user unable to see where they were, on the theme people use in daylight:
  the ring drew `--color-primary` at **1.7875:1** on light `--color-base-100`, under
  the 3:1 floor WCAG 2.2 SC 1.4.11 sets for a non-text indicator.

  The design canvas attached to the ticket decided the ring does not need one hue:
  darkened action-cyan on light, bright brand cyan on dark. **Its stated reason for
  the split was wrong by the time it was implemented.** The canvas justified it by
  saying `--color-primary` already holds a different value per theme; FE-18 unified
  it to `#06D5ED` in both, and the canvas's own dark mock still draws `#00D1DA`, the
  pre-unification cyan, which dates the figure. The direction survives because a
  theme-split MECHANISM exists — `--color-interactive` is declared in a bare `:root`
  and overridden in both dark selectors — and stage 3 implemented that mechanism
  rather than the premise.

  `--color-focus-ring` is an **alias**, not a sixth cyan: the `@theme inline` mapping
  of `--focus-ring`, which each daisyui-theme block declares outright as
  `var(--color-interactive)` in light and `var(--color-primary)` in dark, so no
  surface gets its ring colour by cascade order. Both rules read the slot; neither
  names a hex. Stage 3 originally declared `--color-focus-ring` itself in `:root`
  and both dark selectors; task 01a0833d (#990) landed first with the `--focus-ring`
  slot and the same two values, and the duplicate was collapsed onto it at merge so
  there is exactly one backing value per theme.

  | variant                        | theme | adjacent surface        | before  | after   |
  |--------------------------------|-------|-------------------------|---------|---------|
  | offset (L6/D6)                 | light | `--color-base-100`      | 1.7875  | 4.7007  |
  | offset (L6/D6)                 | dark  | `--color-base-100`      | 9.6304  | 9.6304  |
  | no-offset (L7/D7)              | light | `--color-base-100`      | 1.7875  | 4.7007  |
  | no-offset (L7/D7)              | dark  | `--color-base-100`      | 9.6304  | 9.6304  |
  | no-offset inner (L8/D8)        | light | the input's own border  | 11.7483 | 4.4674  |
  | no-offset inner (L8/D8)        | dark  | the input's own border  | 1.5447  | 1.5447  |

  The single hue the canvas rejected was measured rather than taken on trust:
  `#087f93` reads **3.6620:1** on the dark panel, which clears the floor. It was
  rejected on quality, in the canvas's words, as "legal and weak. A focus indicator
  is the one element where the floor is not the target." A third option exists and
  is not what shipped: aliasing to `var(--color-interactive)` in BOTH themes needs no
  dark override at all and reads 10.0015 on the dark panel, marginally better than
  the 9.6304 the brand cyan gives. The canvas asked for the brand cyan on dark and
  that is what the human gate approved.

  ### D8 is the one measurement on this ticket left missing

  A focused `.input` paints its border `--color-base-content` — `#000000` light,
  `#EEEEEE` dark — and the no-offset ring is drawn immediately outside it, so that
  border is the ring's inner neighbour. Light clears at 4.4674. Dark reads 1.5447
  under this module's own float-through convention, because the dark border token
  is declared `oklch(95% 0 0)` rather than the `#EEEEEE` shorthand; a browser that
  first rounds the border to that shorthand reads 1.5406 instead. It measured the
  same 1.5447 before this stage.

  A colour that clears 3:1 against both that near-white edge and the near-black page
  ground at once DOES exist. The two grounds separate by 14.8760:1 under this module's
  own float-through convention (14.8369:1 if the border is first rounded to its
  `#EEEEEE` shorthand); either reading clears the 9:1 a shared 3:1 floor needs (`3²`)
  to leave any window open at all, so the window the next test computes is open, not
  empty. Its floor, 0.132988, is invariant across convention: it derives from
  `--color-base-100`'s `#171b25` hex literal alone, with nothing to round. Its
  ceiling, 0.252458, is the token-space figure produced by the border's
  `oklch(95% 0 0)` declaration (0.251664 if that border is rounded to `#EEEEEE`
  first). `#797979` sits in `[0.132988, 0.252458]`, clearing 3:1 against both
  grounds. Wide separation between two grounds is room for a candidate, not an
  obstacle to one; this passage previously had that backwards, and previously named
  the wrong separation (15.5:1, neither convention's figure).

  The miss stands on judgement, not arithmetic: `#797979` reads as the same
  "legal and weak" dark-on-dark indicator the design canvas already rejected in
  writing for the brand cyan's own near-miss above, and it would drop the ring's
  identification against the page ground from D7's 9.6304 to a bare pass at 3.9544.
  A third option is geometric rather than chromatic, uncosted, and nobody's scope
  here: give the dark no-offset variant a spacer so the ring stops abutting the
  input's border and the pairing stops existing at all.
  `docs/design-system/04-accessibility.md:101` already records that option alongside
  the corrected band and witness; nothing here supersedes it. The indicator is
  identified against the page ground, D7 at 9.6304, and the near-white edge is the
  input's own outline rather than a surface the ring must be found against. Pinned
  without a threshold, the way L6 was until this stage promoted it.

  This is not F3/F4's shape of miss. Clearing `@aa_text` (4.5) against both nav
  grounds at once needs them at least 20.25:1 apart (`4.5²`); the nav's actual
  18.5302:1 falls short, so no colour closes that one under any convention. D8's
  grounds clear their shared threshold with room to spare either way the border is
  measured; F3/F4's do not clear theirs at all.

  ### Two findings on the focus ring that stage 3 reported and did not fix

  **`.input:focus { border-color: … }` does not render, and never did.** app.css
  declares it in the `components` layer; the vendored daisyUI sets
  `--input-color: var(--color-base-content)` on `&:focus, &:focus-within` and
  `border-color: var(--input-color)` in the `utilities` layer, which is ordered after
  it, so layer order beats specificity and daisyUI wins whatever app.css says. Read
  off a keyboard-focused input in headless Chrome. The declaration was repointed at
  the ring's slot anyway — a dead line naming the wrong token is how the next reader
  concludes the focused input border is cyan — and its comment now records that it
  paints nothing. Making it live repaints every focused field in the product and is a
  follow-up with its own census.

  **37 call sites still rang in `--color-primary` when stage 3 shipped.** The
  `.focus-visible-ring` class is one of two focus-ring implementations: 58 sites use
  the class this stage fixed, and 37 carried the raw Tailwind utilities (`ring-2`
  plus the `ring-primary` focus modifier), mostly at `/60` opacity, which
  resolved to the brand cyan at 1.7875:1 on white. Converting them was a 37-file
  change with no `ring-focus-ring` utility to convert them to, since a bare `:root`
  property mints nothing and Tailwind v4 only mints utilities from `@theme`. Filed as
  Suite task `01a0833d-ce16-7001-8e9a-73e2240344c2` rather than smuggled into a
  stage scoped to two rules. That task landed as #990 before this branch: it added
  the `--focus-ring` slot to both theme blocks, the `@theme inline` mapping that
  mints `ring-focus-ring`, converted all 37 sites, and pins them in
  `focus_ring_census_test.exs` and `focus_ring_slot_test.exs`. Nothing HERE measures
  those 37 sites; this module measures the class, and a green run of it is a claim
  about the class only.

  **A sixth, smaller drift, reported here and fixed later.** `--color-base-200` in
  the light theme is declared `oklch(96% 0 0)`, which renders `#F2F2F2`, while its
  own trailing comment claimed `#F5F5F5`. F2 is measured against the value that
  ships (`#F2F2F2`, 1.5913); against the value the comment claimed it would read
  1.6396. Same class of defect as the one this task closed, in a different slot.
  Task 01a09333-d374 stage 6 corrected the comment. Every figure in this module
  was already measured against the declaration, so none of them moved.

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

  Those five runs are FE-18's and they are kept as run. Three of their predictions no
  longer hold, because the ticket below repointed the sites they name: L5, L6, F1, F2
  and F3 no longer read `--color-primary` at all, so moving that token leaves them
  where they are. Re-run against today's clauses, M1 and M2 exercise L1/L2/L3/D1/D2/D3
  and the dark ring, and they no longer reach the four text sites or the chip. That is
  the point of the matrix below: after this ticket, the five fixed sites are reached by
  reverting each site, not by moving the brand token.

  ## Mutation results (task 01a0785c-bf6f-7001-824d-dd99bcb7db89 stage 4, 2026-09-08)

  One revert at a time against `mix test apps/platform/test/platform/design/`, 2
  doctests and 187 tests, each restored before the next. The question is attribution,
  not count: does every red clause name the site that was reverted?

  | revert | red | the clauses, and the site each names |
  |--------|-----|--------------------------------------|
  | `.wikilink` to `--color-primary`            | 1 | F1 — `.wikilink` |
  | `.code-block-expand` to `--color-primary`   | 1 | F2 — `.code-block-expand` |
  | `.bottom-nav-tab--active` to `--color-primary` | 2 | F3, F4 — the same tab on its two light grounds |
  | the `::before` bar to `--color-primary`     | 1 | the active-tab bar |
  | `.chip-primary` `--chip-tint-pct` 6% to 12% | 2 | L5 and the chip test's declaration pin — both `.chip-primary` |
  | the focus ring to `--color-primary`         | 4 | L6, L7, L8 and the structural guard — all the ring |

  No revert reds a clause about a different site. The two multi-red rows are one site
  measured against more than one adjacent surface, which the single-red `.wikilink`
  row is the control for: it shares `--color-base-100` with L6/L7 and stays green when
  the ring is reverted, and the ring clauses stay green when it is.

  Two of the six are caught by a **pin moving upward**, not by a threshold: reverting
  the nav label sends F4 from 4.1661 to 10.9561 on the near-black ground, and reverting
  the ring sends L8 from 4.4674 to 11.7483 against the input's black light border. The
  brand cyan is genuinely better on those two surfaces. A suite that asserted only
  floors would have called both reverts an improvement and stayed green.

  Not every clause in this file is reachable by reverting a site. D8 is pinned at
  1.5447 as a recorded miss and does not move, because dark reverts the ring to the
  colour it already had. L3 is pinned at 1.7875 and is not a site this ticket touched.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W

  doctest Platform.Design.WcagContrast

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @daisyui_path Path.expand("../../../assets/vendor/daisyui.js", __DIR__)

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
    {focus_ring_light, focus_ring_dark} = focus_ring_aliases(css)

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
       base_content: color!(light, "--color-base-content"),
       tokens: token_map(light, interactive_light, focus_ring_light),
       block: light
     },
     dark: %{
       primary: color!(dark, "--color-primary"),
       accent: color!(dark, "--color-accent"),
       primary_content: color!(dark, "--color-primary-content"),
       accent_content: color!(dark, "--color-accent-content"),
       base_100: color!(dark, "--color-base-100"),
       base_200: color!(dark, "--color-base-200"),
       interactive: interactive_dark,
       base_content: color!(dark, "--color-base-content"),
       tokens: token_map(dark, interactive_dark, focus_ring_dark),
       block: dark
     }}
  end

  # Every token a rule in this file might name, resolved for one theme. Clauses
  # below read the token OUT OF THE RULE and look it up here, rather than
  # choosing one at the call site: a clause that picked its own token would keep
  # passing after the rule it claims to measure was reverted.
  defp token_map(block, interactive, focus_ring_token) do
    base = %{
      "--color-primary" => color!(block, "--color-primary"),
      "--color-accent" => color!(block, "--color-accent"),
      "--color-base-100" => color!(block, "--color-base-100"),
      "--color-base-200" => color!(block, "--color-base-200"),
      "--color-base-content" => color!(block, "--color-base-content"),
      "--color-interactive" => interactive
    }

    # `--color-focus-ring` is an alias, so it is resolved here rather than read
    # as a value: whichever slot it names for this theme IS its value, and a
    # clause reading it out of a rule gets that resolved colour.
    case Map.fetch(base, focus_ring_token) do
      {:ok, color} ->
        Map.put(base, "--color-focus-ring", color)

      :error ->
        flunk(
          "--color-focus-ring aliases var(#{focus_ring_token}), which this module " <>
            "does not resolve. Add it above before measuring the ring against anything."
        )
    end
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
    test "there are exactly four hex literals, primary == accent within each theme", %{
      css: css,
      light: light,
      dark: dark
    } do
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

      # Since the Burrow recolor (task 01a120c5) the two themes carry DIFFERENT
      # oranges by design. What still holds is that accent follows primary
      # inside each theme.
      for {theme, block} <- [{"light", light.block}, {"dark", dark.block}] do
        p = block |> decl!("--color-primary") |> Map.fetch!(:value) |> String.upcase()
        a = block |> decl!("--color-accent") |> Map.fetch!(:value) |> String.upcase()

        assert p == a,
               "#{theme} --color-accent (#{a}) no longer follows --color-primary (#{p})."
      end
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

      assert_threshold("L1", "the light label on the light primary fill", ratio, @aa_text)
      assert_ratio("L1", ratio, 5.3202)
    end

    test "L2 (a): --color-accent-content is AA text on the accent fill", %{light: l} do
      # Accent moved with primary in stage 1, so it carries its own assertion
      # rather than riding on L1's. If the two are ever re-split this is the
      # clause that notices.
      ratio = W.contrast(l.accent_content, l.accent)

      assert_threshold("L2", "the light label on the light accent fill", ratio, @aa_text)
      assert_ratio("L2", ratio, 5.3202)
    end

    test "L3 (a): the light primary fill clears 3:1 against base-100", %{light: l} do
      # Was (b), pinned at 1.7875 with no threshold, while the light primary was
      # the cyan. The Burrow orange (task 01a120c5) separates from the ground on
      # its own, so the clause is promoted: losing that would now be a
      # regression, not a known property.
      ratio = W.contrast(l.primary, l.base_100)

      assert_threshold("L3", "the light primary fill against base-100", ratio, @non_text)
      assert_ratio("L3", ratio, 5.3202)
    end

    test "L4 (a): --color-interactive is AA text on base-100", %{light: l} do
      # The interactive text colour is its own literal (#8b3b04 since task
      # 01a120c5), not derived from the primary; it is the slot the brand rule
      # points every brand-coloured text at.
      ratio = W.contrast(l.interactive, l.base_100)

      assert_threshold("L4", "--color-interactive as text on light base-100", ratio, @aa_text)
      assert_ratio("L4", ratio, 7.3919)
    end

    test "L5 (a): the light .chip-primary label clears AA on its own fill", %{
      css: css,
      light: l
    } do
      # Promoted from (c) to (a) by stage 2 of ticket #{@followup_ticket}. Both
      # halves of the pairing are resolved from the stylesheet: the label through
      # --color-interactive, which the structural clause below pins to this
      # rule, and the fill through the shared color-mix formula at the percentage
      # `.chip-primary` itself declares. Neither is a token chosen here, so
      # putting the tint back reds this clause rather than leaving it green on a
      # colour that is no longer painted.
      fill = chip_fill!(css, l.primary, l.base_100, ".chip-primary")
      ratio = W.contrast(l.interactive, fill)

      assert_threshold("L5", "the light chip-primary label on its own fill", ratio, @aa_text)
      assert_ratio("L5", ratio, 6.8125)
    end

    test "L6 (a): the light offset focus ring clears the 3:1 indicator floor", %{
      css: css,
      light: l
    } do
      # Promoted from (c) to (a) by stage 3 of ticket #{@followup_ticket}. WCAG
      # 2.2 SC 1.4.11 asks 3:1 of a focus indicator against the surface next to
      # it. `.focus-visible-ring:focus-visible` draws 2px of --color-base-100
      # then 2px of the ring colour, so the outer band's neighbours are base-100
      # on BOTH sides; the structural clause below is what holds the spacer to
      # the ground colour, and this clause depends on it.
      #
      # The band's colour is READ OUT OF THE RULE. Until stage 3 this clause
      # computed `W.contrast(l.primary, l.base_100)`, the identical expression
      # F1 computes, so reverting the ring alone moved neither of them. Now that
      # the ring and `.wikilink` can hold different colours, a token-level read
      # would have left L6 green on a colour the rule no longer names.
      body = rule_body!(css, ".focus-visible-ring:focus-visible")
      ratio = W.contrast(shadow_band_color!(body, "4px", l.tokens), l.base_100)

      assert_threshold("L6", "the light offset focus ring against base-100", ratio, @non_text)
      assert_ratio("L6", ratio, 7.3919)
    end

    test "L7 (a): the light no-offset focus ring clears 3:1 against the page ground", %{
      css: css,
      light: l
    } do
      # The `.input` / `.textarea` / `.select` variant, drawn at the element edge
      # with no spacer. Its OUTER neighbour is the page ground, which is the
      # surface a keyboard user has to find the ring against; its inner
      # neighbour is the control's own border and is L8.
      #
      # Same number as L6 and a different rule. Each resolves its colour from its
      # own body, so reverting one variant reds one clause.
      body = grouped_rule_body!(css, ".input.focus-visible-ring:focus-visible")
      ratio = W.contrast(shadow_band_color!(body, "2px", l.tokens), l.base_100)

      assert_threshold("L7", "the light no-offset focus ring against base-100", ratio, @non_text)
      assert_ratio("L7", ratio, 7.3919)
    end

    test "L8 (c)*: the light no-offset ring vs the border the input paints, a recorded regression",
         %{
           css: css,
           light: l
         } do
      # The no-offset ring's INNER neighbour. Not `.input:focus`'s declared
      # border-color: that declaration does not render, for the layer-order
      # reason recorded beside it in app.css and read back out of the vendored
      # plugin by focused_input_border_token!/0 below. What paints is
      # --color-base-content, #000000 in light (kept by task 01a120c5 stage 4).
      #
      # REGRESSED by the Burrow recolor and recorded, not tuned. History: the
      # cyan against black was 11.7483, the darkened cyan against black 4.4674
      # (stage 3's deliberate trade). The Burrow ring #8b3b04 against black
      # is 2.7251, under 3:1; it was 2.1293 against the spec ink #221f1b, which
      # stage 4 did not ship (black kept for secondary-text AA). The ring is fixed by the spec
      # (the light ring slot reads --color-interactive), so this is the same
      # shape of miss as D8: the ring is identified against the page ground,
      # L7 at 7.3919. A colour clearing 3:1 against both this border and the
      # page ground exists (relative luminance 0.1 to 0.285733), so the
      # disposition is a
      # judgement for the design owner, not an impossibility.
      body = grouped_rule_body!(css, ".input.focus-visible-ring:focus-visible")
      border = Map.fetch!(l.tokens, focused_input_border_token!())
      ratio = W.contrast(shadow_band_color!(body, "2px", l.tokens), border)

      assert_ratio("L8", ratio, 2.7251)

      assert ratio < @non_text,
             "L8 now clears the 3:1 floor against the focused input's own border " <>
               "(#{Float.round(ratio, 4)}). Promote it back to a threshold assertion " <>
               "and close the regression recorded in the moduledoc."
    end

    test "both focus-ring rules draw their band from --color-focus-ring at 2px", %{css: css} do
      # L6/L7/L8 and D6/D7/D8 measure pairings these two rules create. If either
      # rule stops naming the slot, or is quietly widened instead of recoloured,
      # those clauses are measuring something that does not ship.
      offset = rule_body!(css, ".focus-visible-ring:focus-visible")

      assert shadow_band_token!(offset, "4px") == "--color-focus-ring",
             "`.focus-visible-ring:focus-visible` no longer draws its outer 4px band " <>
               "from var(--color-focus-ring). Rule body:\n#{offset}"

      assert shadow_band_token!(offset, "2px") == "--color-base-100",
             "the offset ring's 2px spacer is no longer --color-base-100. L6 and D6 " <>
               "measure the outer band against base-100 ON BOTH SIDES, and that claim " <>
               "holds only because the spacer is drawn in the ground colour. Rule " <>
               "body:\n#{offset}"

      no_offset = grouped_rule_body!(css, ".input.focus-visible-ring:focus-visible")

      assert shadow_band_token!(no_offset, "2px") == "--color-focus-ring",
             "the no-offset focus ring no longer draws its band from " <>
               "var(--color-focus-ring). Rule body:\n#{no_offset}"

      assert Regex.match?(
               ~r/\.input\.focus-visible-ring:focus-visible,\s*\.textarea\.focus-visible-ring:focus-visible,\s*\.select\.focus-visible-ring:focus-visible\s*\{/,
               css
             ),
             "the no-offset ring is no longer one rule over .input, .textarea and " <>
               ".select. L7/L8/D7/D8 measure one rule body and would stop covering " <>
               "whichever selector was split off."

      # Geometry, pinned. The design canvas names the ring at 2px with a 2px
      # offset as the signature element, the offset being what stops it reading
      # as a border on the control. Widening the ring is the way to make an
      # indicator visible WITHOUT fixing its colour, and nothing else in this
      # file would notice.
      assert squish(offset) =~ "box-shadow: 0 0 0 2px var(--color-base-100), 0 0 0 4px",
             "the offset ring is no longer a 2px spacer plus a band ending at 4px, " <>
               "i.e. 2px wide at a 2px offset. Rule body:\n#{offset}"

      assert squish(no_offset) =~ "box-shadow: 0 0 0 2px",
             "the no-offset ring is no longer 2px wide. Rule body:\n#{no_offset}"
    end

    test "--focus-ring is theme-split, aliased, and mapped to --color-focus-ring exactly once",
         %{css: css} do
      # focus_ring_aliases!/1 carries the guards: a --focus-ring declaration in
      # BOTH theme blocks, light differing from dark, each one an alias naming
      # another slot rather than a sixth cyan, and exactly ONE
      # --color-focus-ring declaration in the file (the @theme inline mapping)
      # so the rules measured above have a single backing value per theme.
      # Called here so the failure names this clause rather than taking every
      # test in the module down with the setup.
      {light_token, dark_token} = focus_ring_aliases!(css)

      assert light_token == "--color-interactive",
             "light --focus-ring aliases var(#{light_token}). The action-cyan " <>
               "slot is the one the brand rule already names for interactive colour; " <>
               "if the ring is meant to move off it, L6/L7/L8 need re-deriving first."

      assert dark_token == "--color-primary",
             "dark --focus-ring aliases var(#{dark_token}). The design canvas " <>
               "asked for the brand cyan on dark; var(--color-interactive) also " <>
               "clears there (10.0015 against 9.6304) and is a different decision."
    end

    test ".input:focus names the ring's slot too, even though it does not render", %{css: css} do
      # A dead declaration: this rule is in the `components` layer and daisyUI's
      # `.input` rules are in `utilities`, ordered after it, so daisyUI's
      # `--input-color: var(--color-base-content)` wins on focus whatever this
      # says. Pinned anyway, because a dead declaration naming the WRONG token is
      # how the next reader concludes the focused input border is the ring
      # colour. It is not: it paints --color-base-content (#000000 light,
      # #eeeff1 dark), which is what L8 and D8 measure the no-offset ring
      # against.
      body = grouped_rule_body!(css, ".input:focus")

      assert squish(body) =~ "border-color: var(--color-focus-ring)",
             "`.input:focus` no longer names var(--color-focus-ring). It renders " <>
               "nothing either way, and that is exactly why the token it names has to " <>
               "stay honest. Rule body:\n#{body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Dark theme.
  # ══════════════════════════════════════════════════════════════════════════

  describe "dark theme" do
    test "D1 (a): --color-primary-content is AA text on the primary fill", %{dark: d} do
      ratio = W.contrast(d.primary_content, d.primary)

      assert_threshold("D1", "black on the dark primary fill", ratio, @aa_text)
      assert_ratio("D1", ratio, 7.5073)
    end

    test "D2 (a): --color-accent-content is AA text on the accent fill", %{dark: d} do
      ratio = W.contrast(d.accent_content, d.accent)

      assert_threshold("D2", "black on the dark accent fill", ratio, @aa_text)
      assert_ratio("D2", ratio, 7.5073)
    end

    test "D3 (a): the primary fill clears 3:1 against the dark base-100", %{dark: d} do
      ratio = W.contrast(d.primary, d.base_100)

      assert_threshold("D3", "the dark primary fill against base-100", ratio, @non_text)
      assert_ratio("D3", ratio, 6.1588)
    end

    test "D4 (a): --color-interactive is AA text on the dark base-100", %{dark: d} do
      ratio = W.contrast(d.interactive, d.base_100)

      assert_threshold("D4", "--color-interactive as text on base-100", ratio, @aa_text)
      assert_ratio("D4", ratio, 8.2625)
    end

    test "D5 (a): the dark .chip-primary label clears AA on its 16% fill", %{
      css: css,
      dark: d
    } do
      fill = chip_fill!(css, d.primary, d.base_100, ~s([data-theme="dark"] .chip-primary))
      ratio = W.contrast(d.interactive, fill)

      # Measured, then classified (a): unlike its light counterpart this one
      # clears. It did move — the dark --chip-tint was #00bcd4 before stage 1 and
      # read 7.7729 — so it is pinned as well as thresholded. Stage 2 left the
      # dark percentage alone, and this clause is what notices if a light-only
      # change leaks into dark.
      assert_threshold("D5", "the dark chip-primary label on its own fill", ratio, @aa_text)
      assert_ratio("D5", ratio, 6.608)
    end

    test "D6 (a): the dark offset focus ring clears 3:1 against base-100", %{
      css: css,
      dark: d
    } do
      # Dark rings with the primary: the brand cyan at 9.6304 until the Burrow
      # recolor, #f47721 at 6.1588 since (task 01a120c5). Resolved through the
      # rule the way L6 is, so pointing the ring elsewhere reds this clause
      # instead of leaving it measuring a token.
      body = rule_body!(css, ".focus-visible-ring:focus-visible")
      ratio = W.contrast(shadow_band_color!(body, "4px", d.tokens), d.base_100)

      assert_threshold("D6", "the dark offset focus ring against base-100", ratio, @non_text)
      assert_ratio("D6", ratio, 6.1588)
    end

    test "D7 (a): the dark no-offset focus ring clears 3:1 against the page ground", %{
      css: css,
      dark: d
    } do
      body = grouped_rule_body!(css, ".input.focus-visible-ring:focus-visible")
      ratio = W.contrast(shadow_band_color!(body, "2px", d.tokens), d.base_100)

      assert_threshold("D7", "the dark no-offset focus ring against base-100", ratio, @non_text)
      assert_ratio("D7", ratio, 6.1588)
    end

    test "D8 (c): the dark no-offset ring does not separate from the input's own border", %{
      css: css,
      dark: d
    } do
      # The one measurement on this ticket that misses its floor and is left
      # missing. The focused input's border paints --color-base-content, declared
      # oklch(95% 0 0) in dark (#EEEEEE is that value's 8-bit shorthand), and the
      # ring's #06D5ED reads 1.5447:1 against it under this module's own
      # float-through convention (1.5406:1 if the border is rounded to #EEEEEE
      # first).
      #
      # Unchanged by stage 3: it measured the same 1.5447 before, because dark
      # kept the brand cyan. A candidate DOES exist though: the border and the
      # near-black page ground separate by 14.8760:1 under this module's own
      # float-through convention (14.8369:1 rounded to #EEEEEE first), well
      # past the 9:1 a shared 3:1 floor needs to leave room, so the window the
      # next test computes is open rather than empty. #797979 clears 3:1
      # against both grounds. This comment previously said 15.5:1 and called
      # the window empty; both were wrong, and the direction was backwards —
      # wide separation between two grounds is room, not an obstacle.
      #
      # The miss is refused on quality, not arithmetic: that candidate is the
      # same "legal and weak" dark-on-dark indicator the design canvas already
      # rejected for the brand cyan's own near-miss above, and it drops the
      # ring's identification against the page ground from D7's 9.6304 to a
      # bare 3.9544. A geometric fix (a spacer on the dark no-offset variant,
      # so the ring stops abutting the border) is a third, uncosted
      # alternative, recorded at docs/design-system/04-accessibility.md:101.
      # The indicator is identified against the page ground, which is D7 at
      # 9.6304, and the near-white border is the input's own edge rather than
      # a surface the ring has to be found against.
      #
      # This is not F3/F4's shape of miss (see above): those nav grounds
      # separate by only 18.5302:1 against the 20.25:1 (4.5²) @aa_text needs,
      # so no colour closes that one under any convention.
      #
      # Pinned without a threshold and recorded, exactly as L6 was before this
      # stage promoted it. If a later change closes it, promote this.
      body = grouped_rule_body!(css, ".input.focus-visible-ring:focus-visible")
      border = Map.fetch!(d.tokens, focused_input_border_token!())
      ratio = W.contrast(shadow_band_color!(body, "2px", d.tokens), border)

      # Burrow (task 01a120c5): #f47721 against #eeeff1 is 2.4313. Still a miss,
      # still (c); the history above is the pre-Burrow record.
      assert_ratio("D8", ratio, 2.4313)

      assert ratio < @non_text,
             "D8 now clears the 3:1 floor against the focused input's own border " <>
               "(#{Float.round(ratio, 4)}). Promote this to a threshold assertion and " <>
               "close the finding rather than leaving a fixed miss recorded as open."
    end

    test "D8's window: no colour clears @non_text against both the input border and the page ground",
         %{
           dark: d
         } do
      # D8 is a recorded miss because the two grounds the ring would have to
      # separate from at once — the focused input's own near-white border and
      # the near-black page ground — are close enough together that the band
      # of luminances clearing @non_text against BOTH is empty. That is a
      # claim about the two grounds, not about #06D5ED, so it is checked here
      # independently of D8's own colour via two_ground_window/3.
      border = Map.fetch!(d.tokens, focused_input_border_token!())

      {floor_l, ceiling_l} = W.two_ground_window(@non_text, border, d.base_100)

      assert floor_l <= ceiling_l,
             "the D8 window is now EMPTY: floor #{Float.round(floor_l, 6)} > ceiling " <>
               "#{Float.round(ceiling_l, 6)}. Either the focused input's border token or " <>
               "--color-base-100 moved enough to close off every candidate colour, " <>
               "including the mid-grey one the design canvas already rejected on " <>
               "quality below."

      # Burrow (task 01a120c5): floor 0.132845 from --color-base-100 #191b20,
      # ceiling 0.254203 from --color-base-content #eeeff1; both hex literals
      # now, so neither splits by convention. The pre-Burrow pair, below, was
      # 0.132988 / 0.252458.
      #
      # 0.132988 (the floor) was invariant across convention: it derived solely
      # from --color-base-100's pre-Burrow hex literal, which had nothing to round.
      # 0.252458 (the ceiling) is the token-space figure produced by the border's
      # oklch(95% 0 0) declaration; a browser that first rounds that border to its
      # #EEEEEE shorthand reads a ceiling of 0.251664 instead. The general rule
      # for a figure the comments here don't cover: it is convention-independent
      # iff every operand is declared as a hex literal, and it splits iff any
      # operand is declared in oklch(...).
      assert abs(floor_l - 0.132845) < 0.0001 and abs(ceiling_l - 0.254203) < 0.0001,
             "the D8 window moved: floor #{Float.round(floor_l, 6)} (recorded 0.132845), " <>
               "ceiling #{Float.round(ceiling_l, 6)} (recorded 0.254203). The focused " <>
               "input's border token or --color-base-100 changed value; re-derive D8's " <>
               "disposition rather than re-pinning these bounds blind."

      # The window being non-empty is not the same claim as D8 being an
      # oversight: a colour living in it is exactly what the design canvas
      # already turned down. #797979 (measured here, not quoted) clears
      # @non_text against both grounds and drops the ring's identification
      # against the page ground from D7's 9.6304 to a bare pass — a
      # legal-and-weak dark-on-dark indicator, the disposition the canvas
      # recorded in writing for the brand cyan's own near-miss on the dark
      # panel above. The shortfall stands on that judgement, not because no
      # candidate exists.
      witness = W.hex("#797979")
      witness_vs_border = W.contrast(witness, border)
      witness_vs_page = W.contrast(witness, d.base_100)

      assert witness_vs_border >= @non_text,
             "the #797979 witness no longer clears #{@non_text}:1 against the focused " <>
               "input's border (#{Float.round(witness_vs_border, 4)}); it is cited above " <>
               "as proof the window holds a real, rejected candidate, not just that it " <>
               "is arithmetically non-empty."

      assert witness_vs_page >= @non_text,
             "the #797979 witness no longer clears #{@non_text}:1 against the dark page " <>
               "ground (#{Float.round(witness_vs_page, 4)}); it is cited above as proof " <>
               "the window holds a real, rejected candidate, not just that it is " <>
               "arithmetically non-empty."
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

  describe "the cyan-on-light findings (ticket #{@followup_ticket})" do
    test "F1 (a): .wikilink is AA text on base-100 in both themes", %{
      css: css,
      light: l,
      dark: d
    } do
      body = rule_body!(css, ".wikilink")

      assert squish(body) =~ "color: var(--color-interactive)",
             "`.wikilink` no longer colours from var(--color-interactive). Ticket " <>
               "#{@followup_ticket} stage 1 moved it there because the fill-only brand " <>
               "cyan measured 1.7875:1 as text on white. If it has been moved again, " <>
               "re-derive F1 against whatever it now names. Body:\n#{body}"

      ratio = W.contrast(declared_color!(body, "color", l.tokens), l.base_100)

      assert_threshold("F1", ".wikilink as text on light --color-base-100", ratio, @aa_text)
      assert_ratio("F1 (.wikilink on light --color-base-100)", ratio, 7.3919)

      # The slot is theme-redefined, so one declaration covers both themes. Dark
      # is asserted rather than assumed: a light-only fix that dark inherits is
      # exactly the shape of regression this pairing could hide.
      dark_ratio = W.contrast(declared_color!(body, "color", d.tokens), d.base_100)

      assert_threshold("F1 dark", ".wikilink as text on dark base-100", dark_ratio, @aa_text)
      assert_ratio("F1 dark (.wikilink on dark --color-base-100)", dark_ratio, 8.2625)
    end

    test "F2 (a): .code-block-expand clears AA on base-200 since the Burrow recolor", %{
      css: css,
      light: l,
      dark: d
    } do
      body = rule_body!(css, ".code-block-expand")

      assert squish(body) =~ "background: var(--color-base-200)",
             "`.code-block-expand` no longer sits on --color-base-200; the ground " <>
               "this finding is measured against has changed. Body:\n#{body}"

      assert squish(body) =~ "color: var(--color-interactive)",
             "`.code-block-expand` no longer colours from var(--color-interactive). " <>
               "Body:\n#{body}"

      ratio = W.contrast(declared_color!(body, "color", l.tokens), l.base_200)

      # Promoted from (c) to (a) by the Burrow recolor (task 01a120c5): the
      # interactive #8b3b04 on base-200 #f6f4f1 is 7.0195. The pre-Burrow cyan
      # measured 4.1847 here and was the recorded miss.
      assert_threshold("F2", ".code-block-expand on light base-200", ratio, @aa_text)
      assert_ratio("F2 (.code-block-expand on light --color-base-200)", ratio, 7.0195)

      dark_ratio = W.contrast(declared_color!(body, "color", d.tokens), d.base_200)

      assert_threshold("F2 dark", ".code-block-expand on dark base-200", dark_ratio, @aa_text)
      assert_ratio("F2 dark (.code-block-expand on dark --color-base-200)", dark_ratio, 8.9889)
    end

    test "F3, F4 and the ::before bar are retired; the tab bar is measured by the glass guard",
         %{css: css} do
      # Task 01a1557a-7a71 stage 1 deleted every surface these clauses measured:
      # the `[data-theme="light"] .bottom-nav` ground (F3), the unqualified
      # near-black `oklch(8% 0 0 / 0.96)` ground (F4), and the active tab's
      # `::before` bar. The bar is now one token-driven glass surface whose
      # contrast is measured on PAINTED pixels over pure black and pure white in
      # all ten variants, by test/platform/design/bottom_nav_glass_guard_test.exs.
      # This clause is the pointer, and it fails if any retired surface returns,
      # so none of F3/F4/::before can pass here merely because its rule is gone.
      guard = Path.expand("bottom_nav_glass_guard_test.exs", __DIR__)

      assert File.read!(guard) =~ "defmodule Platform.Design.BottomNavGlassGuardTest",
             "the glass guard that replaced F3, F4 and the ::before clause is missing"

      refute css =~ ~s([data-theme="light"] .bottom-nav),
             "a theme-qualified .bottom-nav ground is back; the glass guard forbids it"

      refute css =~ "oklch(8% 0 0 / 0.96)",
             "the near-black nav literal (F4's ground) is back"

      refute css =~ ".bottom-nav-tab--active::before",
             "the active tab's top bar is back; it was retired with its ::before clause"
    end

    test "no fixed site reached AA by growing or emboldening its text", %{css: css} do
      # The move the design canvas named as gaming: WCAG's 3:1 large-text
      # allowance is real, and reaching for it here would ship the failing colour
      # unchanged while moving the threshold. Weight and size are PINNED to what
      # each rule declared before this ticket rather than forbidden outright,
      # because two of these rules legitimately declare type: `.code-block-expand`
      # shrinks to 0.8em, which puts it further from the allowance rather than
      # nearer, and `.bottom-nav-label` is where the nav tab's type actually
      # lives, so a guard on `.bottom-nav-tab--active` alone would miss an
      # enlargement made one selector away.
      for {selector, expected} <- [
            {".wikilink", %{}},
            {".code-block-expand", %{"font-size" => "0.8em"}},
            {".bottom-nav-tab--active", %{}},
            # Re-pinned by task 01a1557a-7a71 stage 1 to Saru's type note (11px,
            # 400 at rest, 500 active via a separate rule). Not a contrast fix:
            # the glass guard measures flat patches, so size and weight move no
            # ratio there, and the label got lighter, not bolder.
            # Re-pinned by task 01a18d9f's fix round to prototype 01a178d2 v4's
            # `.tab` type (11px, 550 at rest and selected). A genuine type
            # change, not a contrast fix: the colour pairs are unchanged.
            {".bottom-nav-label", %{"font-size" => "11px", "font-weight" => "550"}},
            # Stage 2's site. The chip's type lives on `.chip-soft`, one selector
            # away from the `.chip-primary` rule the fix touched, so pinning only
            # the tone rule would miss a chip made bold to clear 4.5:1.
            {".chip-soft", %{"font-size" => "0.75rem", "font-weight" => "500"}},
            {".chip-primary", %{}}
          ] do
        body = squish(rule_body!(css, selector))

        for property <- ["font-size", "font-weight"] do
          declared =
            case Regex.run(~r/(?:^|;)\s*#{property}:\s*([^;]+)/, body, capture: :all_but_first) do
              [value] -> String.trim(value)
              nil -> nil
            end

          assert declared == Map.get(expected, property),
                 "`#{selector}` declares #{property}: #{inspect(declared)}, and this " <>
                   "clause recorded #{inspect(Map.get(expected, property))} before " <>
                   "ticket #{@followup_ticket} touched these rules. If the change is a " <>
                   "contrast fix it is the wrong one: weight is not a contrast fix, and " <>
                   "enlarging text to reach the 3:1 large-text allowance moves the " <>
                   "threshold instead of the colour. If it is a genuine type change, " <>
                   "re-pin it here and say so. Body:\n#{body}"
        end
      end
    end

    test "the moduledoc still carries the findings record", %{} do
      # A record guard, not a measurement: the numbers above prove themselves,
      # but the history lives only in prose. The pre-change figures cannot be
      # recomputed from app.css at all, and the post-change ones would be
      # recomputed against whatever ships rather than against what was decided.
      doc = squish(@moduledoc)

      assert doc =~ @followup_ticket,
             "the moduledoc no longer names the ticket that closed the four " <>
               "cyan-on-light findings."

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
             "the moduledoc no longer records L5's pre-change value, the fifth " <>
               "miss. It cannot be recomputed from app.css once the tint has moved, " <>
               "so this prose is the only copy."

      for marker <- ["4.5524", "4.5037", "4.4553"] do
        assert doc =~ marker,
               "the moduledoc no longer records `#{marker}`. Those are the rungs of " <>
                 "stage 2's tint ladder: 4.4553 is the 10% the design canvas offered " <>
                 "as a first try and which does NOT clear, 4.5037 is the 8% that " <>
                 "clears by 0.004, and 4.5524 is the 6% that shipped. Without them " <>
                 "the shipped percentage reads as a guess and the next reader has no " <>
                 "way to see that the obvious value was tried and rejected."
      end

      assert doc =~ "3.6620",
             "the moduledoc no longer records the single-hue alternative's dark " <>
               "figure. #087f93 on #171b25 is the option the design canvas rejected " <>
               "on quality while it cleared the floor, and once the ring ships the " <>
               "split there is nothing in app.css to recompute it from. Without the " <>
               "number the rejection reads as taste rather than a measured call."

      assert doc =~ "37 call sites",
             "the moduledoc no longer records that 37 sites still ring in " <>
               "--color-primary through the raw Tailwind utilities. That count comes " <>
               "from a grep of lib/ and assets/, not from app.css, and it is the only " <>
               "note saying this stage fixed one of the two focus-ring " <>
               "implementations."

      for marker <- ["4.7007", "4.1847", "4.4478", "4.1661", "10.9561"] do
        assert doc =~ marker,
               "the moduledoc no longer records `#{marker}`, one of the figures stage 1 " <>
                 "of #{@followup_ticket} measured. Two of the four sites still miss AA " <>
                 "and one regressed on its second ground; deleting the record leaves a " <>
                 "green suite that has forgotten which of its clauses refuse a threshold."
      end
    end

    test "the moduledoc still carries both mutation matrices and the open follow-ups" do
      # The matrices are the only record that these clauses were exercised. Nothing
      # in a green run distinguishes an assertion that would catch its own site's
      # regression from one that has never been made to fail, so deleting the matrix
      # deletes the evidence and leaves the suite looking exactly as trustworthy.
      #
      # Mutating a record guard: edit the moduledoc line ONLY. Every assertion below
      # embeds the exact string it looks for, so a find-and-replace across the whole
      # file rewrites the prose and the assertion together and stays green — the
      # instrument moves with the subject. Stage 4 ran that mutation unscoped first,
      # read the green, and had to redo it line-scoped before the red appeared.
      doc = squish(@moduledoc)

      assert doc =~ "Mutation results (run by hand, 2026-09-06",
             "the moduledoc no longer carries FE-18's mutation runs. They were made " <>
               "against a different clause set and stage 4 of #{@followup_ticket} " <>
               "added its own beneath rather than overwriting them; keep both."

      assert doc =~ "Mutation results (task #{@followup_ticket} stage 4, 2026-09-08)",
             "the moduledoc no longer carries this ticket's mutation matrix. Six " <>
               "reverts, one site at a time, are what proves the five fixed sites are " <>
               "individually pinned. The runs cannot be recovered from the file."

      assert doc =~ "No revert reds a clause about a different site.",
             "the moduledoc no longer states the matrix's actual result. Count is " <>
               "not the test — two of the six reverts red more than one clause, both " <>
               "times because one site is measured against more than one adjacent " <>
               "surface. Attribution is the test, and this sentence is the finding."

      assert doc =~ "01a0833d-ce16-7001-8e9a-73e2240344c2",
             "the moduledoc no longer names the follow-up holding the 37 raw " <>
               "ring-primary focus-utility sites. Without the ticket id, the note " <>
               "that this file measures one focus-ring implementation of two reads " <>
               "as an observation nobody acted on."

      assert doc =~ "--color-base-200",
             "the moduledoc no longer records the --color-base-200 " <>
               "declaration-versus-comment drift. It is deliberately NOT fixed by " <>
               "#{@followup_ticket} and carried as a separate follow-up; this prose " <>
               "is where it stays open."
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

  # The colour a RULE declares for `property`, resolved through the theme's
  # tokens. The token name is read out of the rule body, never chosen here: a
  # clause that named its own token would keep passing after the rule it claims
  # to measure was pointed somewhere else, which is the failure mode that let
  # four of these sites ship below AA in the first place.
  defp declared_color!(body, property, tokens) do
    re = ~r/(?:^|;)\s*#{Regex.escape(property)}:\s*var\((--color-[a-z0-9-]+)\)/

    case Regex.run(re, squish(body), capture: :all_but_first) do
      [token] ->
        Map.get(tokens, token) ||
          flunk(
            "the rule declares `#{property}: var(#{token})`, which this module does " <>
              "not resolve. Add it to token_map/2 before measuring against it."
          )

      nil ->
        flunk(
          "no `#{property}: var(--color-…)` declaration in the rule body, so the " <>
            "colour it renders cannot be resolved from the stylesheet:\n#{body}"
        )
    end
  end

  # The body of the rule whose SELECTOR LIST starts with `selector`. rule_body!/2
  # only matches a selector sitting immediately before its `{`, and both the
  # no-offset focus ring and `.input:focus` are declared over three or four
  # selectors at once.
  defp grouped_rule_body!(css, selector) do
    re = ~r/^[^\S\n]*#{Regex.escape(selector)}[^{}]*\{([^}]*)\}/m

    case Regex.run(re, css, capture: :all_but_first) do
      [body] ->
        body

      nil ->
        flunk(
          "no rule whose selector list starts a line with `#{selector}` in " <>
            "#{@css_path}. The pairing measured against it no longer exists, so the " <>
            "clause is measuring nothing."
        )
    end
  end

  # The token a `box-shadow` band of a given spread names, READ OUT OF the rule
  # body. Never chosen at the call site. This is the vacuity L6 carried until
  # stage 3 of ticket #{@followup_ticket}: it computed the identical expression
  # F1 computed, so reverting the ring alone left it green while F1 covered for
  # it. A band is one `0 0 0 <spread> var(--color-…)` term.
  defp shadow_band_token!(body, spread) do
    re = ~r/0 0 0 #{Regex.escape(spread)} var\((--color-[a-z0-9-]+)\)/

    case Regex.run(re, squish(body), capture: :all_but_first) do
      [token] ->
        token

      nil ->
        flunk(
          "no `0 0 0 #{spread} var(--color-…)` band in this rule, so the colour it " <>
            "paints at that offset cannot be resolved from the stylesheet. A " <>
            "box-shadow the browser rejects drops the whole declaration and the ring " <>
            "disappears, which looks exactly like a control that was never focused. " <>
            "Rule body:\n#{body}"
        )
    end
  end

  defp shadow_band_color!(body, spread, tokens) do
    token = shadow_band_token!(body, spread)

    Map.get(tokens, token) ||
      flunk(
        "the rule draws its #{spread} band from var(#{token}), which this module " <>
          "does not resolve. Add it to token_map/3 before measuring against it."
      )
  end

  # The token a FOCUSED `.input` paints its border from. Read out of the
  # vendored daisyUI source, because app.css cannot answer it: app.css's own
  # `.input:focus { border-color: ... }` sits in the `components` layer and
  # daisyUI's `.input` rules sit in `utilities`, which is ordered after it, so
  # daisyUI wins whatever app.css declares. Confirmed in headless Chrome for
  # ticket #{@followup_ticket} stage 3: a keyboard-focused `.input` paints
  # #000000 in light and #EEEEEE in dark, neither of which is any cyan.
  #
  # L8 and D8 measure the no-offset ring against this. Reading it off the
  # stylesheet instead would measure a declaration that is never painted.
  defp focused_input_border_token!() do
    js = File.read!(@daisyui_path)

    tokens =
      Regex.scan(
        ~r/"&:focus, &:focus-within":\s*\{\s*"--input-color":\s*"var\((--color-[a-z0-9-]+)\)"/,
        js,
        capture: :all_but_first
      )
      |> List.flatten()

    assert tokens != [],
           "the vendored daisyUI no longer sets --input-color on `&:focus, " <>
             "&:focus-within`, so the colour a focused input's border paints cannot " <>
             "be resolved. L8 and D8 measure the ring against it."

    assert Enum.uniq(tokens) |> length() == 1,
           "the vendored daisyUI sets more than one --input-color on focus " <>
             "(#{inspect(Enum.uniq(tokens))}); which one reaches `.input` is no " <>
             "longer decidable from the source."

    hd(tokens)
  end

  # The `--focus-ring` declaration in each daisyui-theme block, light then
  # dark, with no judgement applied. Split out from the guard below so that a
  # malformed slot reds the one clause that judges it and the ring clauses that
  # measure it, instead of killing setup_all and reporting every test in the
  # module as invalid — which is loud and names nothing.
  #
  # History: stage 3 of this ticket declared `--color-focus-ring` itself, in a
  # bare `:root` and in both dark selectors. Task 01a0833d landed first with
  # the bare `--focus-ring` slot in the theme blocks and an `@theme inline`
  # mapping `--color-focus-ring: var(--focus-ring)`, which is what mints the
  # `ring-focus-ring` utility. The two mechanisms agreed on every value and
  # were collapsed onto 01a0833d's when this branch merged, so the rules
  # measured here still read `var(--color-focus-ring)` and there is exactly ONE
  # backing value per theme.
  defp focus_ring_declarations(css) do
    for name <- ["light", "dark"] do
      block = theme_block!(css, name)

      case Regex.run(~r/^[^\S\n]*--focus-ring:[^\S\n]*([^;\n]+);/m, block,
             capture: :all_but_first
           ) do
        [value] -> String.trim(value)
        nil -> ""
      end
    end
  end

  # Best-effort resolution for setup_all: the token each theme's alias names, or
  # `--color-primary` when the declaration cannot be read at all. The fallback is
  # deliberately the value the ring had BEFORE this ticket, so a slot that stops
  # parsing measures the failing colour and reds L6/L7 rather than silently
  # measuring the fixed one.
  defp focus_ring_aliases(css) do
    [light, dark] =
      css
      |> focus_ring_declarations()
      |> Enum.map(fn value ->
        case Regex.run(~r/^var\((--color-[a-z0-9-]+)\)$/, value, capture: :all_but_first) do
          [token] -> token
          nil -> "--color-primary"
        end
      end)

    {light, dark}
  end

  # `--focus-ring` is declared once per daisyui-theme block (the dark block's
  # `prefersdark: true` is what emits the prefers-color-scheme copy, so both
  # dark selectors carry the same declaration by construction), and
  # `--color-focus-ring` exists ONLY as the `@theme inline` mapping of it. Every
  # declaration is an ALIAS naming another slot, never a hex, so this returns
  # the token NAME per theme and the value is resolved in that theme's token
  # map. The ring mints no sixth cyan; it routes to two that already ship.
  defp focus_ring_aliases!(css) do
    values = focus_ring_declarations(css)

    refute "" in values,
           "expected a --focus-ring declaration in BOTH daisyui-theme blocks " <>
             "(light, dark); read #{inspect(values)}. A theme without one gets its " <>
             "ring colour by cascade order, which is the drift this guard exists to " <>
             "refuse."

    [light, dark] = values

    assert light != dark,
           "light and dark --focus-ring now hold the same value (#{light}). " <>
             "The slot is theme-split by mechanism (light rings with the interactive " <>
             "text colour, dark with the primary); if collapsing it is intended, re-derive L6 and D6 " <>
             "first."

    [light_token, dark_token] =
      Enum.map(values, fn value ->
        case Regex.run(~r/^var\((--color-[a-z0-9-]+)\)$/, value, capture: :all_but_first) do
          [token] ->
            token

          nil ->
            flunk(
              "--focus-ring is declared as `#{value}`, not as an alias of " <>
                "another slot. The ring routes to colours that already ship; a " <>
                "literal here is a sixth cyan with nothing holding it to the palette."
            )
        end
      end)

    # Exactly one --color-focus-ring declaration in the whole file, and it is
    # the @theme inline mapping. A second one (a bare :root alias, say — which
    # is what this ticket's stage 3 shipped before the collapse) would be a
    # second backing value that the rules below could paint instead of the
    # slot, and no reader could tell which without running the cascade.
    mappings =
      Regex.scan(~r/^[^\S\n]*--color-focus-ring:[^\S\n]*([^;\n]+);/m, css,
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.map(&String.trim/1)

    assert mappings == ["var(--focus-ring)"],
           "expected exactly one --color-focus-ring declaration, the @theme inline " <>
             "mapping `var(--focus-ring)`; found #{inspect(mappings)}. Two backing " <>
             "values for one ring is the duplication task 01a0833d and this ticket " <>
             "were collapsed to avoid."

    {light_token, dark_token}
  end

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

  # The computed `.chip-soft` fill for one tone in one theme. Two reads, both out
  # of the stylesheet and neither chosen here.
  #
  # The formula lives in exactly one place since ticket #{@followup_ticket} stage
  # 2 replaced the literal percentage with `--chip-tint-pct`; a fork of it flunks
  # rather than letting L5 or D5 measure a colour that is not painted. The
  # percentage comes from the rule named by `pct_selector`, which is the tone's
  # own rule for that theme, so re-tuning it moves the ratio instead of quietly
  # invalidating it.
  defp chip_fill!(css, tint, base, pct_selector) do
    body = rule_body!(css, ".chip-soft")

    assert squish(body) =~
             "background: color-mix(in oklab, var(--chip-tint) var(--chip-tint-pct), " <>
               "var(--color-base-100))",
           "`.chip-soft` no longer computes its background as color-mix(in oklab, " <>
             "var(--chip-tint) var(--chip-tint-pct), var(--color-base-100)). L5 and " <>
             "D5 measure that formula. Body:\n#{body}"

    W.mix_oklab(tint, tint_pct!(css, pct_selector), base)
  end

  # The integer `--chip-tint-pct` a named rule declares.
  defp tint_pct!(css, selector) do
    body = rule_body!(css, selector)

    case Regex.run(~r/--chip-tint-pct:\s*(\d+)%/, squish(body), capture: :all_but_first) do
      [pct] ->
        String.to_integer(pct)

      nil ->
        flunk(
          "`#{selector}` declares no integer --chip-tint-pct, so the percentage the " <>
            "chip actually renders at cannot be resolved from the stylesheet. " <>
            "Body:\n#{body}"
        )
    end
  end
end
