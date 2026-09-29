# 06: Dark token diff, live vs the meetings mock

**Decision document, task 01a0cf85.** Every dark-theme token, live Suite
against the meetings desktop mock, with a recommendation per token for Marlowe to
approve or reject row by row. **Nothing here is applied.** No `app.css` value
changes in this task. Any recolour is a separate follow-up task, created only
for the rows that are signed.

| | |
|---|---|
| Measured on | 2026-09-28 |
| Code | `81c5a1e6` (the dark block is byte-identical to `origin/main` `d8d6814f`) |
| Browser | Chrome 154.0.8037.58, headless, `--force-color-profile=srgb`, 800x900 at 1x |
| Instrument | `apps/platform/priv/measurements/01a0cf85-dark-token-diff/probe.mjs` |
| Pinned in | `test/support/dark_token_painted_fixture.ex`, guarded by `test/platform/design/dark_token_diff_test.exs` |

**Which values are painted and which are token-space.** Every hex in this
document, and every figure labelled "painted", is a byte the browser wrote to
the screen (or a ratio computed from those bytes), read back from a screenshot
of a swatch painted from `var(--token)`. None is copied from a CSS
declaration or a comment. The only figures that are NOT painted are the ones
labelled "token-space": the Token-space column of the pairs table and the
token-space figures in landmine (a), computed from the CSS declaration without
rounding to screen bytes. Cross rows are painted only. Ratios in the decision
table and in prose are painted unless labelled otherwise. The instrument checks itself in the same run (white, black and a
planted colour read back exactly; five deliberately broken swatches must come
back "unresolved", never as a colour).

## How to read the numbers

- **Contrast ratio**: how far apart two colours are in brightness, from 1:1
  (identical) to 21:1 (black on white).
- **4.5:1** is the WCAG AA floor for normal text. **3:1** is the floor for
  things that are not text: icons, focus rings, borders you must see.
- **Ground**: the surface something sits on. Live has two: `base-100` (panels,
  the chat pane) and `base-200` (the page behind them). The mock has
  `base-100` panels, a `base-200` body and a hard-coded `#12161f` card.
- **Painted** ratio: measured from the screen bytes. This is what a person
  sees. **Token-space** ratio: computed from the CSS declaration without
  rounding to screen bytes. They differ slightly when a colour is declared in
  `oklch()`; the painted one is the truth for the screen.
- **Muted / faint**: live has no token for secondary text. It uses
  `text-base-content/60` (384 uses in `lib/`) and `/40` (186 uses) as its
  most common recipes. Both are see-through, so they are measured where they
  actually sit, blended over each ground.
- **Cross** rows: a mock value measured against a live ground, to show what
  adopting it would do here.

## Per-token decision table

`base-100` is identical on both sides and `edge` already equals the mock's
border, so two of the twelve rows need no decision.

<!-- drift-guard:tokens -->
| Token | Mock painted | Live painted | What changes product-wide if adopted | Regresses a fixed pairing? | Recommendation | Flagged live defect (independent of the mock) |
|---|---|---|---|---|---|---|
| `base-100` | `#171B25` | `#171B25` | Nothing: already identical. Chat pane, panels, cards everywhere. | No | **Adopt** (no-op: already identical). Live already paints the mock value `#171B25`. | N/A |
| `base-200` | `#0C1016` | `#000306` | The page ground behind every screen, the sidebar, drawers. | Yes: the 2026-09-06 ground decision (panel separation 1.2011 to 1.1077), and raised fills on the ground drop from 1.1463 to 1.0571. | **Reject** the mock value. Live stays `#000306`: the mock is softer, but it loses panel separation and raised-fill separation; see the ground section. | N/A |
| `base-300` | `#232A38` | `#091821` | Raised fills: the input bar, active pills, selected rows, in every module. | Yes: the fill would equal the border colour (`edge` on fill 1.0000), undoing the edge split of task 01a0740b. | **Reject** the mock value. Live stays `#091821`: as a fill the mock value equals the border; see landmine (b). | N/A |
| `edge` | `#232A38` | `#232A38` | Nothing: live's border slot already paints the mock's border bytes. | No | **Adopt** (no-op: already identical). Live `--edge` already paints the mock border `#232A38`. | N/A |
| `base-content` | `#F2F3F5` | `#EEEEEE` | All body text in dark, product-wide, a touch brighter and cooler. | No: every text pair rises (base-100 14.8369 to 15.5045, base-300 15.5466 to 16.2461). | **Adopt** `#F2F3F5`, low priority. Pure gain, small. | N/A |
| `muted` | `#8F9297` over base-100, `#8D8F94` over card | `#989A9E` over base-100, `#8F9091` over base-200 | Secondary text: timestamps, metadata, labels (384 live sites). | Adopting the mock's 55% lowers every muted pair (base-100 6.1078 to 5.5138). | **Adapt** to `base-content` `#EEEEEE` at 60% as a named token (the value 384 sites already paint), not the mock's 55%. | N/A |
| `faint` | `#5D6068` over base-100, `#5A5D64` over card | `#6D7076` over base-100, `#5F6163` over base-200 | Tertiary text and icons (186 live sites). | The mock's 32% is worse: 2.7366, under even the 3:1 icon floor. | **Reject** the mock value: 32% reads 2.7366, under even the 3:1 icon floor. | **Flagged:** live 40% is under 4.5:1 for text (3.4670, 3.3246). |
| `primary` | `#22C9E0` | `#06D5ED` | The brand cyan: buttons, focus rings, active tabs, product-wide. | Yes: undoes the light/dark unification of task 01a07435 (it would be a fourth cyan). | **Reject** the mock value: both pass 3:1 as a focus ring on every ground; the change buys nothing and adds a fourth cyan. | N/A |
| `info` | `#7AA2F7` | `#6FA7EE` | Info badges, alerts, informational links. | No: both pass AA on every ground. See landmine (a). | **Reject** the mock value: both pass AA on both grounds and sit within 0.1 of each other (6.9168 vs 6.8355 on base-100), so switching is churn. | N/A |
| `success` | `#10B981` | `#15BA81` | Success badges, confirmations, the pipeline "done" state. | No | **Reject** the mock value: near-identical (6.8631 vs 6.7862 on base-100), so switching is churn. | **Flagged:** white text on the live success fill is 2.5082. |
| `warning` | N/A (no token); paints fallback `#F59E0B` | `#F49A00` | Warning badges and alerts. | N/A | **Reject** the mock value: the mock has no warning token (its `#F59E0B` is an inline fallback, not a palette value), so there is nothing to adopt. | N/A |
| `error` | `#EF4444` | `#F1383E` | Error text, destructive buttons, failed states, product-wide. | Mixed: fixes error text on panels (4.4063 to 4.5745) but worsens white on the red fill (3.9067 to 3.7631). | **Adapt** to `#EF4444` plus black text on error fills (black on `#EF4444` is 5.5805). Needs its own follow-up and a re-measure. | **Flagged:** live error text on base-100 is 4.4063; white on the live error fill is 3.9067. |
<!-- /drift-guard:tokens -->

## Flagged findings (live, independent of the mock)

These fail today on live and would fail whether or not anything is adopted.
Reported only; no token changes without sign-off.

1. **Error text on panels: 4.4063:1 on `base-100`**, under 4.5. It passes on
   the page ground (5.2925). The mock's `#EF4444` would read 4.5745.
2. **Faint text (`text-base-content/40`, 186 sites): 3.4670 on `base-100`,
   3.3246 on `base-200`.** Under 4.5 for text. It clears the 3:1 icon floor,
   so the question is which of the 186 sites are text.
3. **White text on the success fill: 2.5082.** Black on the same fill reads
   8.3724.
4. **White text on the error fill: 3.9067.** Black on the same fill reads
   5.3754.

Why error cannot be fixed by one colour: white against the `base-100` panel is
17.2143:1. A colour clearing 4.5:1 against both needs the two to be at least
4.5 x 4.5 = 20.25:1 apart. They are not, so no red can be both AA text on a
panel and an AA fill under white text. The fix has to change the text on the
fill (to black), not only the red.

## The ground decision (2026-09-06, task 01a07435)

The dark block records it: the ground stays `#000306`; the mock's `#0C1016`
was rejected on panel separation, 1.2011:1 against 1.1077:1. The painted
bytes reproduce both figures exactly.

**The mock is softer, and that is conceded:** its panels sit closer to its
page (1.1077 against 1.2011), which is the calmer look it was drawn for.

**New evidence: one data point, pointing the same way.** The original
decision measured panel separation only. Moving the ground alone would also
drop live's raised fill (`base-300`, `#091821`) against the page from 1.1463
to 1.0571. So the recommendation stays: reject the mock value; live stays `#000306`.

## Landmine (a): the dark info-blue AA fix

The dark block records that design review caught an earlier info-blue (L58)
failing AA as dark-theme text; live is now `oklch(72% 0.12 255)`, painted
`#6FA7EE`.

| | on `base-100` | on live `base-200` |
|---|---|---|
| live `#6FA7EE` | 6.9168 painted (6.9412 token-space), pass | 8.3079 painted (8.3436 token-space), pass |
| mock `#7AA2F7` | 6.8355 painted (6.8355 token-space: hex, identical), pass | 8.2102 painted (cross row: no token-space figure), pass |

**Verdict: the mock value does not undo the fix.** Both clear AA with room on
both grounds, and they are within 0.1 of each other. Reject the mock value;
adopting would be churn. Text on an info fill: black on live info 8.4380; the mock's held Ask
button (`#0B1220` on `#7AA2F7`) 7.4346. Both pass.

## Landmine (b): the base-300 / edge split

The mock uses `#232A38` for both jobs: raised fill and border. Live split them
in task 01a0740b. Live's border is `--edge`, which already paints `#232A38`,
the same bytes as the mock's border. **The border needs nothing.**

The only open question is the FILL, measured against both grounds it serves:

| fill | on `base-100` (panel) | on live `base-200` (page) |
|---|---|---|
| live `#091821` | 1.0478, darker than the panel | 1.1463 |
| mock `#232A38` | 1.1966, lighter than the panel | 1.4373 (cross) |

The dark block records why the fill was left alone when the border moved: it
"also serves as a raised fill on the near-black `--color-base-200`
(`#000306`), where being darker than what surrounds it is correct (1.1463:1 the
other way)". Moving the fill to `#232A38` would flip its direction against the
panel and, worse, make it the same bytes as `--edge`: a bordered raised
element would draw its border at 1.0000:1, invisible, which is the defect task
01a0740b fixed. **Verdict: reject the fill change.** If the mock's lighter
raised look is wanted, it needs its own value, measured against both grounds
and against `--edge`.

## Neighbour pairs, every measured ratio

Floors: 4.5 for text and text-on-fill, 3.0 for `primary` as a focus ring,
N/A for surface-against-surface separation (no WCAG floor; recorded for the
decisions above). `faint` rows are held to 4.5 because 186 live sites use it
on text; for icon-only uses the floor is 3.0, which live clears and the mock
does not. Cross rows have no token-space figure.

<!-- drift-guard:pairs -->
| Side | Foreground | Ground | Painted | Token-space | Floor | Verdict |
|---|---|---|---|---|---|---|
| live | `base-content` | `base-100` | 14.8369 | 14.8760 | 4.5 | pass |
| live | `base-content` | `base-200` | 17.8209 | 17.8816 | 4.5 | pass |
| live | `primary` | `base-100` | 9.6304 | 9.6304 | 3.0 | pass |
| live | `primary` | `base-200` | 11.5672 | 11.5762 | 3.0 | pass |
| live | `info` | `base-100` | 6.9168 | 6.9412 | 4.5 | pass |
| live | `info` | `base-200` | 8.3079 | 8.3436 | 4.5 | pass |
| live | `success` | `base-100` | 6.8631 | 6.8919 | 4.5 | pass |
| live | `success` | `base-200` | 8.2434 | 8.2844 | 4.5 | pass |
| live | `warning` | `base-100` | 7.7619 | 7.7732 | 4.5 | pass |
| live | `warning` | `base-200` | 9.3229 | 9.3437 | 4.5 | pass |
| live | `error` | `base-100` | 4.4063 | 4.4198 | 4.5 | FAIL |
| live | `error` | `base-200` | 5.2925 | 5.3128 | 4.5 | pass |
| live | `muted@base-100` | `base-100` | 6.1078 | 6.0972 | 4.5 | pass |
| live | `muted@base-200` | `base-200` | 6.4649 | 6.4779 | 4.5 | pass |
| live | `faint@base-100` | `base-100` | 3.4670 | 3.4490 | 4.5 | FAIL |
| live | `faint@base-200` | `base-200` | 3.3246 | 3.3305 | 4.5 | FAIL |
| live | `base-100` | `base-200` | 1.2011 | 1.2020 | N/A | N/A |
| live | `edge` | `base-100` | 1.1966 | 1.1966 | N/A | N/A |
| live | `base-300` | `base-100` | 1.0478 | 1.0493 | N/A | N/A |
| live | `base-300` | `base-200` | 1.1463 | 1.1456 | N/A | N/A |
| mock | `base-content` | `base-100` | 15.5045 | 15.5045 | 4.5 | pass |
| mock | `base-content` | `card` | 16.3016 | 16.3016 | 4.5 | pass |
| mock | `primary` | `base-100` | 8.6063 | 8.6063 | 3.0 | pass |
| mock | `primary` | `card` | 9.0488 | 9.0488 | 4.5 | pass |
| mock | `info` | `base-100` | 6.8355 | 6.8355 | 4.5 | pass |
| mock | `info` | `card` | 7.1869 | 7.1869 | 4.5 | pass |
| mock | `success` | `base-100` | 6.7862 | 6.7862 | 4.5 | pass |
| mock | `success` | `card` | 7.1351 | 7.1351 | 4.5 | pass |
| mock | `warning-fallback` | `base-100` | 8.0153 | 8.0153 | 4.5 | pass |
| mock | `warning-fallback` | `card` | 8.4274 | 8.4274 | 4.5 | pass |
| mock | `error` | `base-100` | 4.5745 | 4.5745 | 4.5 | pass |
| mock | `error` | `card` | 4.8096 | 4.8096 | 4.5 | pass |
| mock | `muted@base-100` | `base-100` | 5.5138 | 5.5124 | 4.5 | pass |
| mock | `muted@card` | `card` | 5.5928 | 5.6282 | 4.5 | pass |
| mock | `faint@base-100` | `base-100` | 2.7366 | 2.7395 | 4.5 | FAIL |
| mock | `faint@card` | `card` | 2.7446 | 2.7317 | 4.5 | FAIL |
| mock | `base-100` | `base-200` | 1.1077 | 1.1077 | N/A | N/A |
| mock | `edge` | `base-100` | 1.1966 | 1.1966 | N/A | N/A |
| mock | `base-300` | `base-100` | 1.1966 | 1.1966 | N/A | N/A |
| mock | `base-300` | `base-200` | 1.3254 | 1.3254 | N/A | N/A |
| live | `base-content` | `base-300` | 15.5466 | 15.6090 | 4.5 | pass |
| live | `primary` | `base-300` | 10.0911 | 10.1049 | 3.0 | pass |
| live | `primary-content` | `primary` | 11.7483 | 11.7483 | 4.5 | pass |
| live | `info-content` | `info` | 8.4380 | 8.4677 | 4.5 | pass |
| live | `success-content` | `success` | 2.5082 | 2.4978 | 4.5 | FAIL |
| live | `warning-content` | `warning` | 9.4689 | 9.4826 | 4.5 | pass |
| live | `error-content` | `error` | 3.9067 | 3.8948 | 4.5 | FAIL |
| mock | `base-content` | `base-200` | 17.1739 | 17.1739 | 4.5 | pass |
| mock | `primary` | `base-200` | 9.5330 | 9.5330 | 3.0 | pass |
| mock | `info` | `base-200` | 7.5715 | 7.5715 | 4.5 | pass |
| mock | `success` | `base-200` | 7.5169 | 7.5169 | 4.5 | pass |
| mock | `warning-fallback` | `base-200` | 8.8784 | 8.8784 | 4.5 | pass |
| mock | `error` | `base-200` | 5.0670 | 5.0670 | 4.5 | pass |
| mock | `base-content` | `base-300` | 12.9571 | 12.9571 | 4.5 | pass |
| mock | `primary` | `base-300` | 7.1923 | 7.1923 | 3.0 | pass |
| mock | `info-content` | `info` | 7.4346 | 7.4346 | 4.5 | pass |
| cross | `mock:info` | `live:base-200` | 8.2102 | N/A | 4.5 | pass |
| cross | `mock:primary` | `live:base-200` | 10.3372 | N/A | 3.0 | pass |
| cross | `mock:primary` | `live:base-300` | 9.0180 | N/A | 3.0 | pass |
| cross | `mock:base-content` | `live:base-200` | 18.6227 | N/A | 4.5 | pass |
| cross | `mock:base-content` | `live:base-300` | 16.2461 | N/A | 4.5 | pass |
| cross | `mock:error` | `live:base-200` | 5.4945 | N/A | 4.5 | pass |
| cross | `mock:success` | `live:base-200` | 8.1510 | N/A | 4.5 | pass |
| cross | `live:error-content` | `mock:error` | 3.7631 | N/A | 4.5 | FAIL |
| cross | `live:primary-content` | `live:error` | 5.3754 | N/A | 4.5 | pass |
| cross | `live:primary-content` | `mock:error` | 5.5805 | N/A | 4.5 | pass |
| cross | `live:primary-content` | `live:success` | 8.3724 | N/A | 4.5 | pass |
| cross | `live:base-300` | `mock:base-200` | 1.0571 | N/A | N/A | N/A |
| cross | `mock:base-300` | `live:base-200` | 1.4373 | N/A | N/A | N/A |
| cross | `live:edge` | `mock:base-300` | 1.0000 | N/A | N/A | N/A |
| cross | `live:success-content` | `live:base-100` | 17.2143 | N/A | 4.5 | pass |
<!-- /drift-guard:pairs -->

## Keeping this document honest

`test/platform/design/dark_token_diff_test.exs` parses both tables above
between their `drift-guard` markers and fails if any hex or ratio differs
from the painted fixture, if a measured ratio is missing from the pairs table,
or if a verdict disagrees with its floor. It also fails with "re-measure" when
any dark-block declaration a live reading was taken from changes. To refresh:
re-run the probe (see the README next to it), paste the new bytes into the
fixture, then update this file until the test is green.

The guard covers this file only. It does NOT cover the sign-off canvas
(01a0eb40-0490-7001-a183-9272f42bcaba), which is a hand-made copy: after any
change here, update the canvas table to match.
