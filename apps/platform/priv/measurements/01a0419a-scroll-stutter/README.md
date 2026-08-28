# Scroll-stutter baseline — task 01a0419a stage 2

Rowan, on the shipped build:

> as we scroll up there is some noticeable ui thrashing as we cross what I
> presume are the near and far thresholds. it makes scrolling through history
> stutter and feel strange.

Captured against **`09bfbce2`** — the tree the branch forked from, and the tree
Rowan's report is about. It is deliberately NOT the branch tip: stage 1
(`e0ee00b7`) had already landed there and removes one of the two candidate
causes, so a "baseline" taken on the branch would be a measurement of the
half-fixed state recorded as if it were the broken one.

`09bfbce2` is not `origin/main` any more — `main` had moved on to `53454b1b` by
the time this ran. The stage brief called `09bfbce2` "origin/main"; the sha is
the thing that matters and the sha is what was used.

## Verdict: CONFIRMED

`holdAnchorThroughReflow()`, called from `_reportDistance()` on every
`away`/`deep` edge, pins a *scrolling* reader in place for `REFLOW_HOLD_MS`
(400ms). It captures `distanceFromBottom()` once and writes it back on every
animation frame for the whole window. That is correct for the stationary reader
it was written for and wrong for a moving one.

## Numbers

400ms windows. Frames on which the scroller's own geometry changed (history
pagination prepending rows) are excluded — a prepend moves `scrollTop` without
moving the reader, and including those frames manufactures a 1587px "reversal"
that is not one.

| viewport | window | frames | net travel | reversals | ratio |
|---|---|---|---|---|---|
| 1440x900 | FLIP away (dist>150) | 24 | -30 px | 11 (45.8%) | 0.043 |
| 1440x900 | FLIP deep (dist>1800) | 18 | -12 px | 8 (44.4%) | 0.024 |
| 1440x900 | CONTROL mid-band #1 | 23 | -570 px | 0 | 1.000 |
| 1440x900 | CONTROL mid-band #2 | 24 | -690 px | 0 | 1.000 |
| 1440x900 | CONTROL mid-band #3 | 24 | -570 px | 0 | 1.000 |
| 390x844 | FLIP away (dist>150) | 25 | -60 px | 11 (44.0%) | 0.083 |
| 390x844 | FLIP deep (dist>1800) | 23 | -30 px | 11 (47.8%) | 0.043 |
| 390x844 | CONTROL mid-band #1 | 24 | -600 px | 0 | 1.000 |
| 390x844 | CONTROL mid-band #2 | 24 | -570 px | 0 | 1.000 |
| 390x844 | CONTROL mid-band #3 | 23 | -540 px | 0 | 1.000 |

The control windows are the whole argument. Same gesture, same window length,
zero reversals and 10-20x the travel. Had they shown the flip windows' profile
the diagnosis would have been refuted and stage 3's deletion would have had to
be justified on its own terms rather than as the stutter fix.

The profile is **width-independent**, which is what points at the hold rather
than at layout: at 390px the jump-to-latest control is a zero-height overlay
and its appearance changes no geometry at all, yet the mobile `away` window is
the worst in the table.

## A caveat on "reversals", recorded because it changed the harness

The brief prescribed sign reversals as the discriminator. They are the wrong
*primary* statistic. The pin writes back the distance it captured, so the
position it leaves is CONSTANT — the reader is frozen, not dragged. A frozen
frame has delta 0, and a series of 0s and -30s is indistinguishable from
healthy monotonic scrolling by any reversal- or monotonicity-based ratio.
Reversals do appear in a real browser, because wheel input lands on the
compositor asynchronously and a rAF sampler does not always run on the same
side of the hold's own animation frame — which makes the reversal COUNT partly
a property of when you looked. **Net travel against an equal-length control
window** is not, and is what the committed unit harness asserts on.

## Re-running

```bash
# 1. a dev server on the tree under test, assets BUILT, its own database
cd apps/platform
mix ecto.create && mix ecto.migrate && mix assets.build
PORT=4021 mix phx.server
# 2. seed: dev_federation_seed.exs, then hit /dev/login once (that is what
#    creates the participant), then insert >= 150 messages into `general`
# 3. capture — needs a Chrome on 127.0.0.1:9222; the probe opens its own
#    isolated browser context so it cannot re-log-in a sibling agent's tab
SPORT=4021 SPACE_ID=<uuid> VW=1440 VH=900 OUT=/tmp/cap.json node probe.mjs
node analyze.mjs /tmp/cap.json
```

The probe refuses to produce numbers unless `#chat-message-scroller` exists AND
`liveSocket.isConnected()` — an inert LiveView makes every interaction
observation meaningless, and this measurement is entirely interaction.

## What stage 3 has to show

`test/hooks/scroll_to_bottom_reflow_hold_stutter.test.js` passes on this tree
and encodes the pre-fix behaviour. Removing the `_reportDistance` -> hold call
must flip its three `describes the pre-fix stutter` / `width-independent` cases
to failing (verified here by mutating the call to a no-op: exactly those three
fail, the control and the release case stay green). Stage 3 rewrites them to
assert the cure, and re-runs this probe against the fixed tree for the numbers.

---

# Stage 3 re-run: the same probe on the fixed tree

Captured at **`51a07c08`** (task branch, stage 3) with the SAME `probe.mjs` and
the SAME `analyze.mjs` as the baseline above — the analyzer was not re-derived,
and its N/N+1 prepend mask is used as committed. Fresh dev DB
(`platform_dev_01a0419a_s3`), 200 seeded messages in `general`, assets built,
live LiveView, real `mouseWheel` input, 400ms windows.

| viewport | window | clean frames | NET TRAVEL | reversals | ratio |
|---|---|---|---|---|---|
| 1440x900 | FLIP away @150ms | 24 | **-660 px** | 0 | 1.000 |
| 1440x900 | FLIP deep @1097ms | 19 | **-480 px** | 0 | 1.000 |
| 1440x900 | FLIP deep @1104ms | 20 | **-480 px** | 0 | 1.000 |
| 1440x900 | FLIP deep @1519ms | 19 | **-506 px** | 0 | 1.000 |
| 1440x900 | FLIP deep @1719ms | 22 | **-540 px** | 0 | 1.000 |
| 1440x900 | FLIP deep @1750ms | 24 | **-600 px** | 0 | 1.000 |
| 1440x900 | CONTROL @615ms | 24 | -585 px | 0 | 1.000 |
| 1440x900 | CONTROL @2215ms | 24 | -541 px | 0 | 1.000 |
| 1440x900 | CONTROL @2665ms | 19 | -510 px | 0 | 1.000 |
| 390x844 | FLIP away @108ms | 25 | **-690 px** | 0 | 1.000 |
| 390x844 | FLIP deep @1123ms | 23 | **-630 px** | 0 | 1.000 |
| 390x844 | CONTROL @606ms | 24 | -660 px | 0 | 1.000 |
| 390x844 | CONTROL @1606ms | 24 | -630 px | 0 | 1.000 |
| 390x844 | CONTROL @2056ms | 16 | -420 px | 0 | 1.000 |

## Side by side, on the statistic that was actually asserted on

| viewport | window | PRE-FIX (09bfbce2) | POST-FIX (51a07c08) | control band, post-fix |
|---|---|---|---|---|
| 1440x900 | flip away | -30 px | **-660 px** | -510 to -585 px |
| 1440x900 | flip deep | -12 px | **-480 to -600 px** | -510 to -585 px |
| 390x844 | flip away | -60 px | **-690 px** | -420 to -660 px |
| 390x844 | flip deep | -30 px | **-630 px** | -420 to -660 px |

**Every flip window now sits inside its own run's control band.** That is the
whole claim, and it is the same claim in the same units as the baseline: a
window after a boolean flip is no longer distinguishable from a window where
nothing flipped. Pre-fix the separation was an order of magnitude.

## WHAT THIS DOES NOT SAY — attribution

**Stage 1 (the overlay widening, which deleted the desktop in-flow chip) and
stage 3 (this call-site deletion) both plausibly remove the stutter, and they
ship together in one PR. We did not isolate which change removed it — no A/B
was run.** No build exists with one applied and not the other, and none was
constructed. The baseline above and the measurement above are both honest, and
placing them next to each other *reads* as a causal result. It is not one.

What IS isolated is the unit-level attribution, and only that: reverting the
`_reportDistance` -> `holdAnchorThroughReflow()` call on this tree turns the
three `CURED:` cases in
`assets/test/hooks/scroll_to_bottom_reflow_hold_stutter.test.js` red and leaves
the rest green. That says the call is *sufficient* to produce the pinned
profile in the unit harness. It does not say it was the *only* cause of what
Rowan saw in the browser.

## Two things observed in the post-fix run, recorded rather than smoothed over

**1. `deep` still flips repeatedly, and hysteresis is not what would stop it.**
The 1440x900 run shows `deep` going true at dist 2006 then false at dist 1250
6.6ms later. That is a **756px** jump, produced by a history-pagination prepend
changing `scrollHeight` — three orders of magnitude past the 24px band, so no
plausible margin suppresses it. `THRESHOLD_HYSTERESIS_PX` targets boundary
jitter, which is a different phenomenon. **If the pagination-prepend flip churn
matters it is a separate ticket and it is not fixed here.**

**2. The seeded fixture is not stage 2's fixture.** Stage 2 used a channel
seeded by hand at the time; this run reseeded from scratch (200 messages,
mixed short and long bodies). Row heights are therefore similar but not
identical, which is why the control windows do not reproduce stage 2's numbers
exactly either (-510 to -585 here against -570 to -690 then). **The comparison
that is safe is each run's flip windows against ITS OWN controls**, which is
how both tables are built and why the controls are re-measured every run rather
than carried over.
