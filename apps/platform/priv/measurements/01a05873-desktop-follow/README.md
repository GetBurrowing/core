# Desktop-follow repro harness — task 01a05873 stage 1

Reproduces the reported failure (Rowan, 2026-08-31: desktop chat does not
autoscroll to the latest message) in the REAL app — real `mix phx.server`,
real Chrome over CDP, real LiveView patches, a second logged-in browser
session posting as another user — records the mechanism with a full
lifecycle trace per arrival, A/Bs the suspected regression window commit by
commit, and checks the ticket's mobile premise at 390x844.

All instrumentation is CDP-side injection into the live `ScrollToBottom`
hook instance. **No product file is patched.**

## Files

* `reseed.exs` — the fixture. Own UUIDs (space id is the task UUIDv7 itself),
  200 messages, one-liners mixed with long rewrapping bodies, ~45min apart so
  day labels render. Ids are generated, SORTED, then assigned in
  `inserted_at` order so id order matches time order by construction (the
  cursor dead-end defect recorded in `../01a0419a-desktop-verify/README.md`).
  Run inside the app container: `mix run priv/measurements/01a05873-desktop-follow/reseed.exs`
* `cdp.mjs` — verbatim copy of `../01a0419a-desktop-verify/cdp.mjs`
  (Node 22 built-in WebSocket; no npm deps).
* `lib.mjs` — session helper: ISOLATED browser context per login (CDP 9222 is
  shared; one Chrome profile is one identity), `Emulation.setDeviceMetricsOverride`.
* `probe.mjs` — the scenario suite + injected tracer. Scenarios: one-liner,
  tall body, 3-message burst, sender message under a reader draft grown
  toward the composer cap, control (reader scrolled up 400px), window
  resize 1440→1200 then message. Not run on mobile: the window-resize
  scenario (no desktop width to change); a sidebar-drag scenario was
  dropped as unreachable — `#chat-sidebar` renders no `[data-drag-handle]`
  (that affordance is the CANVAS sidebar's, `canvas_sidebar_resize.js`),
  so the rail's width only ever comes from ClientState.
* `results/*.json` — one file per run, each scenario's full event trace.

## Running it

```bash
docker compose up -d postgres        # repo-root compose (postgres-only by design)
cd apps/platform && mix setup && mix phx.server   # on a free port (we used 4000)
docker exec <app> mix run priv/measurements/01a05873-desktop-follow/reseed.exs
# check the returned map says id_order_matches_time_order: true

cd priv/measurements/01a05873-desktop-follow
SPORT=4000 GIT_LABEL=<sha> VW=1440 VH=900 node probe.mjs
SPORT=4000 GIT_LABEL=<sha>-mobile VW=390 VH=844 node probe.mjs
```

Chrome with `--remote-debugging-port=9222` must be reachable
(`curl -s http://127.0.0.1:9222/json/version`). After checking out a
different SHA: the dev esbuild watcher may not pick up root-written
checkouts on this rig — run `mix esbuild platform` and restart the server
(the code reloader refuses requests after dep changes anyway).

## THE VERDICT FIRST: the regression window hypothesis is REFUTED

The failure is **already present at 720f7e2b (post-#837, the "green" desktop
verification)** and at 799eb37b (post-#848), and **absent exactly one commit
earlier**, at 3e27d3c7 (pre-#822).

| SHA | s1 one-liner | s3 burst | s4 long draft | s5 resize+msg |
|---|---|---|---|---|
| 3e27d3c7 (pre-#822) | **follows** (d=0) | **follows** (d=0) | **follows** (d=0) | strands 303 + chip |
| 720f7e2b (#837) | strands 31 | strands 93 + chip | strands 67 | (not recorded¹) |
| 799eb37b (#848) | strands 31 | strands 93 + chip | strands 31 + chip | strands 371 + chip |
| origin/main | strands 67 | strands 93 + chip | strands 31 + chip | strands 491 + chip |
| origin/main @ 390x844 | **follows** (d=0) | **follows** (d=0) | **follows** (d=0) | n/a |

¹ that run hit a one-off page-eval timeout after s4; s1–s4 carry the verdict.

**The carrier is 09bfbce2 — PR #822, "Fix scroll auto-follow measurement and
rework the jump-to-latest chip", 2026-08-27 13:59.** It made the follow
decision read the PRE-patch distance captured in `beforeUpdate()`. Before
#822 the decision read the POST-patch live distance (which for a
bottom-parked reader is just the arriving row's height, ≤ `NEAR_BOTTOM_PX`
→ followed). The #837 desktop verification shipped green the same day
because its probes (gate, centring, hover, layout shift, occlusion,
contrast) never exercised a message arriving from a second session — the
one scenario this defect lives in. Rowan's report four days later is the
first arrival-shaped test of it.

## THE MECHANISM (origin/main, 1440x900, s1; full trace in results/)

Every arriving message, on every failing SHA, shows the same lifecycle:

```
t=185  beforeUpdate      sw=455  sSt=""    cw=761  sh=4315  → preD captured = 460
t=189  updated:enter     sw=224  sSt=224px cw=992  sh=3922
t=223  safeUpdate:enter  ...
t=245  scrollToBottom:enter  arg=460
t=245  scrollToBottom:exit   snapRan=false          ← the follow DECLINES
t=246  reportDistance   arg=460  away=true  deep=false
t=247  mo:sidebar       kinds={"attr:style":2}       ← strip + re-apply
```

1. The LV patch for the arriving message walks `#chat-sidebar` (earlier in
   document order than `#message-list`). The rail's width exists ONLY as a
   client-side inline style (`ResizableSidebar.applyWidth()`, saved to
   ClientState); the server-rendered aside has no `style` attribute, so
   morphdom **strips the inline style** mid-patch. The hook's own
   `updated()` re-applies it — but only AFTER the whole patch.
2. Inside that window the aside is unconstrained: `flex-shrink-0` with no
   CSS width rule, it lays out at its **intrinsic width — 455px** on this
   fixture instead of the configured 224px. The scroller is squeezed
   `clientWidth` 992→761, every message rewraps taller,
   `scrollHeight` 3855→4315.
3. `beforeUpdate` fires when morphdom reaches `#message-list` — INSIDE the
   window — and captures `distanceFromBottom()` against the squeezed,
   inflated layout: **460px** for a reader whose true distance is 0.
4. `scrollToBottom(preD=460)`: 460 > `NEAR_BOTTOM_PX` (150) → the follow
   rule correctly declines, by its own terms, for a reader parked at the
   live edge. When the patch re-unsqueezes, the reader is left exactly one
   arriving row below the edge (67px for a one-liner; 93px + chip for a
   3-message burst).
5. `_reportDistance(460)` latches `away=true` — the same one reading feeds
   the chip predicate (task 01a0419a stage 4) — so the jump-to-latest chip
   appears for a reader who never scrolled. It lags one message: the server
   still had the reader "at the bottom" when the first message arrived, so
   the count rule hides the pill for that first one (observed: s1/s2 no
   chip, s3's later messages chip).

Nothing here is speculative: every number above is a recorded trace event.
The same trace at pre-#822 shows the identical strip (`sSt=""`, sw=455 at
`beforeUpdate`) and a follow anyway — because no capture existed, the
decision read the post-patch distance. The strip hazard itself is old
(`resizable_sidebar.js` re-apply-on-`updated()` was added in #405/#498,
months back); #822 is what let it poison the measurement.

## THE MOBILE PREMISE — CONFIRMED, WITH THE MECHANISM

At 390x844 (origin/main, `Emulation.setDeviceMetricsOverride`), every
arrival scenario **follows** (post-distance 0, no chip). Not luck — the
mobile trace shows the SAME inline-style strip (`sSt=""` at `beforeUpdate`)
but `#chat-sidebar` is `hidden lg:flex`: below `lg` it is `display:none`,
the squeeze has zero layout effect, the capture reads the TRUE distance
(preD=0) and the snap runs (`snapRan=true`). The ticket's "mobile appears
to work" holds, for a structural reason — no sidebar, no strip victim.

## SECONDARY FINDING (recorded, present at ALL SHAs incl. pre-#822)

A 1440→1200 window resize rewraps under an unchanged `scrollTop` and
strands a bottom-parked reader 303–491px from the live edge.
`_onViewportResize`'s width branch returns bare (at pre-#848 there is no
observer at all), and because no scroll event fires, `_reportDistance` is
never called — the server never learns, so the reader is stranded with NO
chip either until the next scroll. Same family, not the ticket's scenario;
the window-resize rows in the A/B table above are the evidence.

## Fix site (stage 2)

`resizable_sidebar.js`: stop storing the width as an inline style that
morphdom can strip mid-patch. Writing a CSS custom property on
`document.documentElement` (consumed by a `#chat-sidebar { width:
var(--suite-sidebar-width, 224px) }` rule in `app.css`) moves the width out
of every element LiveView patches — the mid-patch window closes by
construction, desktop and any future width alike. A width-path snap in
`_onViewportResize` (reconstructing the pre-resize distance from a kept
`_lastScrollHeight`) addresses the secondary window-resize strand.

(Recorded after the fact: concurrent stage-2 work has committed exactly
this pair as 02ab72d6 on the task branch; the harness here independently
reproduces the failure and the bracket it cites.)

## Rig footnotes

* 799eb37b itself commits `apps/platform/deps` as a **symlink to the
  original author's machine** (`/Users/dev/.openclaw/workspace/...`).
  Checking out that SHA silently replaces the real deps directory with a
  dangling symlink and breaks `mix` until deps are re-fetched. Cost this
  run: one rig rebuild. Worth a cleanup commit.
* This harness intentionally lives under `priv/measurements/`, NOT under
  `assets/test/` — CI runs vitest on `assets/test/**/*.test.js` and
  `node --test` on `test/**/*_test.mjs`; these probe scripts must never be
  picked up by a JS suite.
