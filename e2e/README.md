# core E2E tests

Playwright tests that exercise flows no unit or integration test can — browser
permissions, WebRTC transport, JS-owned DOM subtrees.

## Prereqs

- A running dev server: `cd apps/platform && mix phx.server` (port 4000).
- Dev server must have `MIX_ENV=dev` so `/dev/login` is registered.
- LiveKit creds in the dev server env (`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`).

## Install

```bash
cd e2e
npm install
npm run install-browsers   # one-time: fetches full Chromium
```

The meeting A/V test requires the **full** Chromium build, not the
default `chromium-headless-shell`. `install-browsers` fetches both — the
spec explicitly opts into `channel: "chromium"` so canvas.captureStream
and AudioContext actually emit frames.

## Run

```bash
npm test                   # all tests, headless
npm run test:meeting       # just the meeting A/V test
npm run test:headed        # see the two browser windows
```

## Meeting A/V test

`tests/meeting_av.spec.ts` launches two browser contexts (Alice, Bob), logs each
in through `/dev/login?as=<slug>`, joins the same "general" meeting, enables
camera + mic, and asserts that **each side receives the other's video and audio**
tracks via LiveKit.

This is the test to reach for when someone reports "I joined but the other
person said they couldn't see/hear me" — it pins down whether the break is in
transport (this test fails) or in perception/UX (this test passes).

Chromium is launched with `--use-fake-device-for-media-stream` so the tests
don't touch the host camera/mic; synthetic tracks carry a spinning color wheel
(video) and a tone (audio).

## Tips

- Set `BASE_URL=http://build-host:4000` to run against a different host.
- Failure traces land in `test-results/`; open the `.zip` with
  `npx playwright show-trace <path>` for step-by-step DOM + network replay.

## The meetings layout gate — run it BEFORE every meetings capture

**Why, in one sentence: presence checks pass on a screen wired into the wrong
parents, and three rounds of the meetings surface were rejected on sight by the
sponsor because every element the approved canvas called for was present and
every colour token was right while the ring, the controls, the grid and the
card's reading order were assembled into different parents.**

So a meetings visual stage does not ship a screenshot alone. Immediately before
the capture, run:

```bash
e2e/scripts/measure-meeting-layout.sh \
  --base-url http://192.0.2.10:4046 \
  --surface meetings|quickmeet \
  --viewport 1280x800|390x844
```

It drives `tests/meeting_layout_geometry.spec.ts` and prints a machine-readable
verdict block: one line per assertion with the assertion name, the **measured
numbers**, the tolerance, and PASS or FAIL. The numbers are printed on PASS as
well as on FAIL — a bare PASS is indistinguishable from an assertion that could
not fail, which is the whole reason this gate exists.

**Paste the verdict block into the evidence canvas alongside the screenshot. A
`manual_approval` submitted with a screenshot and no verdict block is an
INCOMPLETE REVIEW and should be sent back.**

### Exit codes are distinct on purpose

| Code | Meaning |
|---|---|
| 0 | every assertion PASSed |
| 1 | a real layout FAIL |
| 2 | usage error |
| 3 | **rig fault** — `/assets/js/app.js` did not return 200 |
| 4 | **rig fault** — the spec crashed/timed out and produced no measurements |

Exit **3** is the one to know. The build-host→test-host rsync runs `--delete` and
`priv/static` does not exist on build-host, so any source edit wipes the built assets
on test-host; the page then renders with **no tiles at all**, which reads exactly
like the feature being missing and would turn every assertion red for a reason
that has nothing to do with layout. `mix assets.build` exits 1 on
`mix esbuild excalidraw` while still writing a serving bundle, so its exit code
proves nothing — the curl does. Never record an exit 3 as a layout regression.

### What the runner handles for you

- **The quickmeet prelude.** No rail exists until `meeting_join` is clicked, and
  below `lg` none is on screen until `[data-role="quickmeet-rail-toggle"]` is
  pressed. Both are encoded in the surface path and the verdict block prints a
  `prelude` line showing they ran, so a false "feature missing" is visible as a
  rig state rather than reported as a layout result.
- **Duplicate-element disambiguation.** Each control exists twice in the DOM (a
  hidden `lg`-only copy and the mobile copy) and a zero-rect element passes
  every containment test there is. The verdict block prints ALL matching rects
  so the disambiguation is shown to have fired.
- **Derived tolerances.** The grid tolerance is the stage's own measured padding
  (`padLeft+padRight`), not a hardcoded pixel count — a hardcoded 40px catches a
  520-in-745 grid but misses the same defect on a 560px stage.

### Preconditions

`e2e/scripts/seed-meeting-layout-fixture.sh <task-slug>` first — the dev DB
starts with no agents, projects or meetings, and `/meetings` creation silently
no-ops because `project_id` is NOT NULL.

### Known gaps the verdict block names rather than hides

- `statesExercised=["idle"]`: `:computing` / `:typing` / `:failed` have
  in-memory-only producers and the dev container's serving BEAM has no
  distribution, so the glyph-overlap branch is never exercised on this rig.
- `card.domorder` SKIPs until task `01a05b14` stage 4 lands the populated card's
  quote line; the card list is printed so the skip is a measurement, not a tick.
- The rig fingerprint (`app.js` sha) narrows but does not prove which of the
  shared 400x dev servers was measured — two servers on the same branch
  fingerprint identically.

## The canvas search snippet gate (task 01a077e6)

`tests/canvas_search_snippet_geometry.spec.ts`. At 375px the canvases drawer's
search snippet used to clip the matched term off the right edge entirely — the
box ended at x=286 and the `<mark>` sat at x=317-377, so a phone reader got
context without the word they searched for. Nine passing LiveView tests missed
it, because `Phoenix.LiveViewTest` does no layout. This spec measures rects.

Seed first, then run against the SAME database:

```bash
cd apps/platform && mix run priv/scripts/seed_canvas_search_snippet_fixture.exs
scripts/run-e2e.sh tests/canvas_search_snippet_geometry.spec.ts
```

The seed prints `SPACE_SLUG` and `PHRASE`; override with `FIXTURE_SPACE_SLUG` /
`FIXTURE_PHRASE`. It is idempotent — an earlier fixture canvas is soft-deleted,
which is what keeps the search returning exactly one hit and the `<mark>`
selector unambiguous.

Every case prints its rects on PASS as well as on FAIL. A run that does not show
the two rects is not evidence that anything was measured.

Two things about this file worth knowing before you change it:

- **The mark is resolved as `[data-role="canvas-result-snippet"] mark`, not by
  the sub-role the fix introduced.** The same selector has to resolve on the
  PRE-FIX single-span markup or the mutation probe fails on a missing element
  instead of on geometry, and a mutant that dies of a `SelectorAmbiguityError`
  has demonstrated nothing about where the mark lands.
- **Case 2 is read against the leading run's WIDTH, not its text length.** The
  plan asked for text "strictly longer at 1440px"; measured in the real app the
  DOM text is identical at both widths, because the server emits one fragment
  and CSS does the yielding. The clause that separates this fix from a global
  `ts_headline` MaxWords reduction is the PAIR: the leading run must be genuinely
  clipped at 375px (`scrollWidth > clientWidth`) and must widen with the
  viewport. A MaxWords reduction fails both — the fragment would fit at 375px.
