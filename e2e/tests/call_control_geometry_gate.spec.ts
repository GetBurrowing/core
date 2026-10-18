/**
 * The call-control GEOMETRY GATE (FE-20, task
 * 01a0773e-cea9-7001-98f5-be6c37607e91, stage 3).
 *
 * STAGE 1 PRINTED NUMBERS. THIS FILE ASSERTS THEM. Its sibling
 * `call_control_label_swing.spec.ts` is a probe: it emits every rect and
 * asserts only that it was able to measure at all, because a threshold
 * invented before the measurement exists is a threshold fitted to a guess.
 * The measurement now exists, so this file is the gate — same surface, same
 * viewport, same selectors, same `visibleRect` disambiguation, same settle
 * and toggle discipline, same visibility guard. The one thing added is the
 * assertion the defect actually violates.
 *
 * THE ASSERTION. A control's `getBoundingClientRect()` x and width must be
 * unchanged, to within 0.5px, across a toggle of ANY control on the row.
 * That is FE-19's assertion and the tolerance is FE-19's, chosen before this
 * ticket and left alone here: on `main` the mic toggle moves siblings
 * 7.8906px and the share toggle moves them 19.4844px, both more than an
 * order of magnitude outside it, so nothing about this gate's verdict rests
 * on where the tolerance sits. It is NOT tightened to kill a mutant. A
 * threshold tuned until something fails kills everything, including the next
 * honest change.
 *
 * WHY GEOMETRY AND NOT A SNAPSHOT OR A PRESENCE CHECK. "The label renders",
 * "the button has a width", and a pixel snapshot of the row all pass today
 * WITH the defect. The defect is that a rect MOVES, and only a rect read
 * before and after the toggle can see it.
 *
 * BOTH PAIRS, ALWAYS. Mic is "Mute"/"Unmute", a +15.7969px label swing.
 * Share is "Share"/"Stop sharing", +38.9531px, 2.466x the mic case and the
 * one nobody had measured before this ticket. A fix tuned to mic passes a
 * mic-only gate while leaving share broken, which is exactly how this defect
 * would survive its own gate — so every case here drives both.
 *
 * READING THE LABEL: `visibleLabelText` resolves the word a HUMAN sees, by
 * discarding any `.call-control-label-word` whose computed `visibility` is
 * `hidden`. This is deliberately written to work on BOTH shapes — the
 * shipped fix, where the span holds two stacked words, and plain `main`,
 * where it holds one — so the gate is not shaped around the fix and can be
 * pointed at the reverted tree without editing a line. It reads the SPAN and
 * never the page: `aria-label="Stop sharing your screen"` contains the
 * string "Stop sharing" in every state, including idle, so a whole-page
 * substring check here would be satisfied by markup that never changed.
 *
 * RIG PRECONDITION, load-bearing, inherited from stage 1: boot the dev
 * server with an EMPTY `LIVEKIT_URL` and a set `LIVEKIT_API_KEY` /
 * `LIVEKIT_API_SECRET`. With a URL and no SFU behind it, `room.connect`
 * fails, `meeting_client.js` pushes `meeting_left`, and the server drops
 * `:in_meeting` about 60ms after the join — which removes the Leave button
 * and leaves a FOUR-item row masquerading as the five-item one. `joinCall`
 * fails loudly rather than measuring it.
 */

import { test, expect, Page } from "@playwright/test"
import { visibleRect, type Rect } from "./support/geometry"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"
const MEETING_SLUG = process.env.SWING_MEETING_SLUG ?? "label-swing"
const LOGIN_AS = process.env.SWING_LOGIN_AS ?? "robin"

/** FE-19's viewport, kept so this gate's numbers sit beside stage 1's
 *  baseline without a rounding argument. */
const VIEWPORT = { width: 1440, height: 900 }

/** FE-19's tolerance. See the header: it is not tuned here, and the verdict
 *  does not depend on it — the defect is 16x and 39x this size. */
const TOL_PX = 0.5

const CONTROLS = '[data-component="call-controls"]'
const LABEL = ".call-control-label"
const WORD = ".call-control-label-word"
const MIC = '[data-role="meeting-mic"]'
const CAMERA = '[data-role="meeting-camera"]'
const SHARE = '[data-role="meeting-screen-share"]'
const LEAVE = '[data-role="meeting-leave"]'

const CONTROL_KEYS = [
  { key: "mic", selector: MIC },
  { key: "camera", selector: CAMERA },
  { key: "share", selector: SHARE },
  { key: "leave", selector: LEAVE },
] as const

const r4 = (n: number): number => Number(n.toFixed(4))

function emit(kind: string, payload: unknown): void {
  console.log(`[fe20-gate] ${kind} ${JSON.stringify(payload)}`)
}

interface ControlSnapshot {
  readonly key: string
  readonly button: Rect
  readonly labelText: string
}

/** The one thing this gate asserts about the rig before it asserts anything
 *  about the product: that assets are actually being served. Without
 *  `npm install`, app.js 404s, LiveView never connects, no toggle does
 *  anything, and a run reports a row that never moved because nothing ever
 *  happened to it. That failure mode is indistinguishable from a pass. */
test.beforeAll(async ({ request }) => {
  const url = `${BASE_URL}/assets/js/app.js`
  let status: number | string
  try {
    status = (await request.get(url)).status()
  } catch (err) {
    status = `request threw: ${String(err)}`
  }
  if (status !== 200) {
    throw new Error(
      `RIG FAULT, not a measurement: GET ${url} returned ${status}, expected 200. ` +
        `Run \`npm install\` in apps/platform/assets and \`mix assets.build\`. Do not ` +
        `record this run: a dead page's row does not move either.`,
    )
  }
})

async function login(page: Page): Promise<void> {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${LOGIN_AS}`)
  await page.waitForURL(/\/chat/, { timeout: 30_000 })
}

/** Set the theme and prove it took. The bootstrap script in root.html.heex
 *  writes `data-theme` from localStorage on every full navigation, so setting
 *  only the attribute would be undone on the next `goto` and a light run
 *  would silently render dark. */
async function applyTheme(page: Page, theme: "dark" | "light"): Promise<void> {
  await page.evaluate((t) => {
    try {
      localStorage.setItem("phx:theme", t)
    } catch {
      /* private-mode storage; the attribute below still governs this page */
    }
    document.documentElement.setAttribute("data-theme", t)
  }, theme)
  const applied = await page.evaluate(() => document.documentElement.getAttribute("data-theme"))
  expect(applied, `theme did not take: asked for "${theme}", got "${applied}"`).toBe(theme)
}

async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(600)
  await page.evaluate(
    () => new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res))),
  )
}

/** Open `/meetings/:slug` and reach the JOINED state.
 *
 *  The join is conditional because `meeting_participants` persists it across
 *  reloads and restarts; which branch ran is printed so a prelude that never
 *  fired is visible rather than assumed. The Leave button IS the joined
 *  state — it renders only under `show_leave={@in_meeting}` — so its absence
 *  is a hard failure, never a four-item measurement. */
async function joinCall(page: Page): Promise<void> {
  await page.goto(`/meetings/${MEETING_SLUG}`)
  await page.waitForFunction(() => !!(window as any).liveSocket?.isConnected?.(), null, {
    timeout: 30_000,
  })
  await page.waitForSelector(CONTROLS, { timeout: 30_000 })

  // THE JOIN CLICK IS BEST-EFFORT, AND THE JOINED STATE IS NOT.
  //
  // `count()` / `isVisible()` / `click()` are three round trips, and the
  // button can be patched away between any two of them: the joined state
  // persists in `meeting_participants`, so a warm run can auto-join while
  // this is still deciding whether to click. Stage 1's probe clicks
  // unconditionally on a visible button and that raced here, hanging on a
  // locator that had already gone — a rig timeout reported as a gate failure.
  //
  // Losing the button is not a failure, because the button is not the thing
  // being asserted. The joined state is, and it is asserted immediately
  // below with no tolerance at all: no Leave button, no measurement.
  const join = page.locator('[phx-click="meeting_join"]')
  const joinCount = await join.count()
  let joinOutcome = "no join button (warm: already joined)"
  if (joinCount > 0) {
    try {
      await join.first().click({ timeout: 15_000 })
      joinOutcome = "clicked"
    } catch {
      joinOutcome = "join button vanished before the click; relying on the state assertion below"
    }
  }

  try {
    await page.waitForSelector(LEAVE, { timeout: 30_000 })
  } catch {
    throw new Error(
      `NOT JOINED: ${LEAVE} never rendered, so @in_meeting is false and this row has FOUR ` +
        `items where the real call has five. Usual cause: a non-empty LIVEKIT_URL with no SFU ` +
        `behind it. Boot with LIVEKIT_URL= (empty) and the key/secret set.`,
    )
  }
  await settle(page)
  emit("prelude", { meetingSlug: MEETING_SLUG, joinButtonsFound: joinCount, joinOutcome })
}

/** WHICH TREE AM I MEASURING. Emitted at the top of every case so a record
 *  can never be mistaken for the other variant's. The fix nests
 *  `.call-control-label-word` spans inside each toggling label and makes the
 *  label an `inline-grid`; `main` and the stage-5 mutant have neither. A
 *  mutation run whose provenance says `words: 4, display: inline-grid` did
 *  not actually revert anything, and its red would be a lie. */
async function emitVariant(page: Page, tag: string): Promise<{ words: number; display: string }> {
  const info = await page.evaluate(
    ({ controlsSel, labelSel, wordSel }) => {
      const row = document.querySelector(controlsSel)
      if (!row) return { words: -1, display: "NO ROW", labels: -1 }
      const label = row.querySelector(labelSel)
      return {
        words: row.querySelectorAll(wordSel).length,
        display: label ? getComputedStyle(label).display : "NO LABEL",
        labels: row.querySelectorAll(labelSel).length,
      }
    },
    { controlsSel: CONTROLS, labelSel: LABEL, wordSel: WORD },
  )
  emit("variant", {
    tag,
    labelWordSpans: info.words,
    labelDisplay: info.display,
    labelSpans: info.labels,
    reading:
      info.words > 0
        ? "FIXED tree: toggling labels reserve both words"
        : "UNFIXED tree: plain single-word labels (main, or the stage-5 mutant)",
  })
  return { words: info.words, display: info.display }
}

/**
 * THE GUARD THE WHOLE GATE RESTS ON, inherited verbatim in intent from
 * stage 1.
 *
 * `app.css` collapses `.call-control-label` to a 1px clipped box inside
 * `@container (max-width: 389px)`. Measured there, every label is 1px, no
 * button width can change, and every delta this gate computes is zero — a
 * PASS produced by measuring a state in which the defect cannot exist.
 *
 * All three of position, clip-path and width are checked because the
 * collapse sets all three: a future edit that drops only `width` from that
 * rule would leave a clipped-but-not-1px label that a width-only guard waves
 * through.
 */
async function assertLabelsVisible(page: Page): Promise<number> {
  const evidence = await page.evaluate(
    ({ controlsSel, labelSel }) => {
      const container = document.querySelector(controlsSel)
      if (!container) return null
      const labels = Array.from(container.querySelectorAll(labelSel)).map((el) => {
        const cs = getComputedStyle(el)
        return {
          text: (el.textContent ?? "").trim(),
          width: el.getBoundingClientRect().width,
          position: cs.position,
          clipPath: cs.clipPath,
        }
      })
      return { containerWidth: container.getBoundingClientRect().width, labels }
    },
    { controlsSel: CONTROLS, labelSel: LABEL },
  )

  expect(evidence, `no ${CONTROLS} in the document`).not.toBeNull()
  const { containerWidth, labels } = evidence!

  emit("visibility_guard", {
    containerWidth: r4(containerWidth),
    containerQueryThresholdPx: 389,
    labelCount: labels.length,
    labels: labels.map((l) => ({
      width: r4(l.width),
      position: l.position,
      clipPath: l.clipPath,
    })),
  })

  expect(
    containerWidth,
    `the control row is ${containerWidth.toFixed(3)}px. Below 390px app.css collapses every ` +
      `label out of flow, so no button can change width and every delta below would be zero — ` +
      `which reads exactly like a pass.`,
  ).toBeGreaterThan(389)

  for (const l of labels) {
    expect(l.position, `label "${l.text}" is position:${l.position}; the collapse uses absolute`).toBe(
      "static",
    )
    expect(l.clipPath, `label "${l.text}" is clip-path:${l.clipPath}; the collapse uses inset(50%)`).toBe(
      "none",
    )
    expect(l.width, `label "${l.text}" is ${l.width.toFixed(3)}px; the collapse pins it to 1px`).toBeGreaterThan(4)
  }
  return containerWidth
}

/** The word a human sees. Discards any stacked word held by
 *  `visibility: hidden`; falls back to the span's own text when there are no
 *  word spans, which is the shape `main` and the mutant render. Works on
 *  both trees unchanged — that is the point. */
const VISIBLE_LABEL_TEXT = ({ sel, labelSel, wordSel }: { sel: string; labelSel: string; wordSel: string }) => {
  const btns = Array.from(document.querySelectorAll(sel)).filter((n) => {
    const r = n.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  })
  if (btns.length !== 1) return `AMBIGUOUS(${btns.length})`
  const label = btns[0].querySelector(labelSel)
  if (!label) return "NO LABEL"
  const words = Array.from(label.querySelectorAll(wordSel))
  if (words.length === 0) return (label.textContent ?? "").trim()
  return words
    .filter((w) => getComputedStyle(w).visibility !== "hidden")
    .map((w) => (w.textContent ?? "").trim())
    .join(" ")
}

async function visibleLabelText(page: Page, selector: string): Promise<string> {
  return (await page.evaluate(VISIBLE_LABEL_TEXT, {
    sel: selector,
    labelSel: LABEL,
    wordSel: WORD,
  })) as string
}

async function snapshotRow(page: Page, tag: string): Promise<ControlSnapshot[]> {
  const out: ControlSnapshot[] = []
  for (const c of CONTROL_KEYS) {
    out.push({
      key: c.key,
      button: await visibleRect(page, c.selector),
      labelText: await visibleLabelText(page, c.selector),
    })
  }
  emit("snapshot", {
    tag,
    controls: out.map((c) => ({
      key: c.key,
      x: r4(c.button.x),
      width: r4(c.button.width),
      visibleLabel: c.labelText,
    })),
  })
  return out
}

/** Click and wait for the SERVER to confirm via `data-on`. A click swallowed
 *  before the socket connected then fails here as a timeout instead of
 *  recording the old state under the new state's name. */
async function toggle(page: Page, selector: string, expected: boolean): Promise<void> {
  await page.locator(selector).click()
  await page.waitForFunction(
    ({ sel, want }) => {
      const el = Array.from(document.querySelectorAll(sel)).find((n) => {
        const r = n.getBoundingClientRect()
        return r.width > 0 && r.height > 0
      })
      return !!el && el.getAttribute("data-on") === String(want)
    },
    { sel: selector, want: expected },
    { timeout: 20_000 },
  )
  await settle(page)
}

/**
 * The gate proper.
 *
 * `expectedFrom` / `expectedTo` are asserted on the VISIBLE label of the
 * toggled control, and they are asserted BEFORE the rects are compared. A
 * toggle that did not change the word has not exercised the defect at all,
 * and its zero deltas are a measurement of nothing — the stage calls that
 * inconclusive, so it fails here with that word in the message rather than
 * passing quietly.
 */
function assertRowUnmoved(
  before: readonly ControlSnapshot[],
  after: readonly ControlSnapshot[],
  which: string,
  expectedFrom: string,
  expectedTo: string,
): void {
  const b = (k: string) => before.find((c) => c.key === k)!
  const a = (k: string) => after.find((c) => c.key === k)!

  const deltas = CONTROL_KEYS.map(({ key }) => ({
    key,
    xDelta: r4(a(key).button.x - b(key).button.x),
    widthDelta: r4(a(key).button.width - b(key).button.width),
  }))

  emit("gate", {
    which,
    tolerancePx: TOL_PX,
    labelFrom: b(which).labelText,
    labelTo: a(which).labelText,
    deltas,
    worstXDelta: r4(Math.max(...deltas.map((d) => Math.abs(d.xDelta)))),
    worstWidthDelta: r4(Math.max(...deltas.map((d) => Math.abs(d.widthDelta)))),
  })

  expect(
    b(which).labelText,
    `INCONCLUSIVE, not a pass: the ${which} label read "${b(which).labelText}" before the ` +
      `toggle, expected "${expectedFrom}". Nothing below measured the state this gate exists ` +
      `to check.`,
  ).toBe(expectedFrom)
  expect(
    a(which).labelText,
    `INCONCLUSIVE, not a pass: the ${which} label read "${a(which).labelText}" after the ` +
      `toggle, expected "${expectedTo}". The visible word did not change, so the row was never ` +
      `asked to reflow and its zero deltas mean nothing.`,
  ).toBe(expectedTo)

  // SOFT, AND THE REASON MATTERS. A hard `expect` throws on the first
  // failure, so a case that drives mic and then share reports only mic and
  // says nothing about whether the share assertion works at all — which is
  // the precise shape of the defect this gate exists to stop (a fix tuned to
  // mic passing a mic-only test while share stays broken). Soft assertions
  // record every failure and still fail the test, so a mutation run shows
  // BOTH pairs going red instead of the first one masking the second.
  //
  // The label preconditions above stay HARD on purpose: if the toggle did
  // not happen, the deltas below are a measurement of nothing and there is
  // nothing to report about them.
  for (const d of deltas) {
    expect
      .soft(
        Math.abs(d.xDelta),
        `${d.key} MOVED ${d.xDelta}px when ${which} was toggled ("${expectedFrom}" -> ` +
          `"${expectedTo}"). On main this delta is 7.8906px for the mic toggle and 19.4844px for ` +
          `share, because the row is justify-center inside a box that does not resize and absorbs ` +
          `a widening label by pushing every sibling out by half of it.`,
      )
      .toBeLessThanOrEqual(TOL_PX)
    expect
      .soft(
        Math.abs(d.widthDelta),
        `${d.key} CHANGED WIDTH by ${d.widthDelta}px when ${which} was toggled. The pressed ` +
          `control widening under its own cursor is the half of this defect a row-layout fix ` +
          `would leave in place.`,
      )
      .toBeLessThanOrEqual(TOL_PX)
  }
}

// ─── Cases 1 and 2: mic and share, dark, /meetings @ 1440x900 ───────────────
//
// SEPARATE TESTS, NOT ONE TEST WITH TWO HALVES, and this is a correction to
// how this file was first written. Run together, a mic failure aborted the
// body before the share half executed, so a mutation run reported mic red
// and said NOTHING about whether the share assertion works — which is the
// exact failure mode the stage names: a fix tuned to mic passes a mic-only
// test while share stays broken. Two tests fail independently and report
// independently.

test.describe("call-control geometry gate — dark @ 1440x900", () => {
  test("case 1: the mic toggle moves nothing", async ({ page }) => {
    await page.setViewportSize(VIEWPORT)
    await login(page)
    await applyTheme(page, "dark")
    await joinCall(page)
    await applyTheme(page, "dark")
    await settle(page)

    await emitVariant(page, "case1_dark_mic")
    await assertLabelsVisible(page)

    // "Mute" -> "Unmute", a +15.7969px label swing on main that pushed every
    // sibling 7.8906px.
    const before = await snapshotRow(page, "case1_mic_on")
    await toggle(page, MIC, false)
    const after = await snapshotRow(page, "case1_mic_off")
    assertRowUnmoved(before, after, "mic", "Mute", "Unmute")

    await toggle(page, MIC, true)
  })

  test("case 2: the share toggle moves nothing", async ({ page }) => {
    await page.setViewportSize(VIEWPORT)
    await login(page)
    await applyTheme(page, "dark")
    await joinCall(page)
    await applyTheme(page, "dark")
    await settle(page)

    await emitVariant(page, "case2_dark_share")
    await assertLabelsVisible(page)

    // "Share" -> "Stop sharing", +38.9531px on main — 2.466x the mic case,
    // pushing every sibling 19.4844px. The wider pair, and the one nobody
    // had measured before this ticket.
    const before = await snapshotRow(page, "case2_share_idle")
    await toggle(page, SHARE, true)
    const after = await snapshotRow(page, "case2_share_active")
    assertRowUnmoved(before, after, "share", "Share", "Stop sharing")

    await toggle(page, SHARE, false)
  })
})

// ─── Case 3: light theme, plus the red-token check ──────────────────────────

/** WHY THE COLOUR COMPARISON IS NOT A STRING COMPARISON.
 *
 *  Chromium hands these back in whatever space the author wrote:
 *  `--color-error` computes to `oklch(0.63 0.22 25)`, while the same token at
 *  15% opacity computes to `oklab(0.63 0.199388 0.092976 / 0.15)`. Those are
 *  the SAME COLOUR — polar and cartesian forms of one point, one of them
 *  alphaed — and they share not one character. A string compare therefore
 *  finds a solid red and misses a tinted one, which is precisely the shape
 *  `bg-error/15` takes. A detector blind to the tint would pass a muted mic
 *  painted error-red at 15% and report that red still means Leave.
 *
 *  So every colour is normalised the only way that survives the space
 *  difference: alpha is stripped syntactically, the opaque remainder is
 *  painted into a canvas, and the sRGB bytes are read back. Two spellings of
 *  one colour then produce one triple.
 *
 *  This runs in the page, not here, because only the browser can do the
 *  conversion. `stripAlpha` handles the three shapes Chromium actually emits
 *  on this row; anything else is returned untouched and will simply fail to
 *  match, which is the safe direction for a detector. */
const NORMALISE_COLOURS_IN_PAGE = (values: string[]): string[] => {
  const stripAlpha = (v: string): string => {
    const fn = v.match(/^(oklab|oklch|lab|lch|color|rgba?|hsla?)\(([^)]*)\)$/)
    if (!fn) return v
    const [, name, body] = fn
    if (body.includes("/")) return `${name}(${body.split("/")[0].trim()})`
    if (name === "rgba" || name === "hsla") {
      const parts = body.split(",").map((p) => p.trim())
      if (parts.length === 4) return `${name.slice(0, 3)}(${parts.slice(0, 3).join(", ")})`
    }
    return v
  }

  const canvas = document.createElement("canvas")
  canvas.width = 1
  canvas.height = 1
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!

  return values.map((v) => {
    const opaque = stripAlpha(v)
    ctx.clearRect(0, 0, 1, 1)
    ctx.fillStyle = "#000000"
    ctx.fillStyle = opaque
    // A value the canvas cannot parse leaves fillStyle at the previous
    // value, so an unparseable colour would silently normalise to black and
    // collide with every other unparseable colour. Refuse instead.
    if (ctx.fillStyle === "#000000" && !/^(#000000|black|rgb\(0, 0, 0\))$/i.test(opaque)) {
      return `UNPARSEABLE(${v})`
    }
    ctx.fillRect(0, 0, 1, 1)
    const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
    return `${r},${g},${b}`
  })
}

test.describe("call-control geometry gate — light @ 1440x900", () => {
  test("case 3: light theme holds, and red still means Leave", async ({ page }) => {
    await page.setViewportSize(VIEWPORT)
    await login(page)
    await applyTheme(page, "light")
    await joinCall(page)
    await applyTheme(page, "light")
    await settle(page)

    await emitVariant(page, "light")
    await assertLabelsVisible(page)

    const beforeMic = await snapshotRow(page, "case3_mic_on")
    const micOnColours = await readColours(page)
    await toggle(page, MIC, false)
    const afterMic = await snapshotRow(page, "case3_mic_off")
    const micOffColours = await readColours(page)
    assertRowUnmoved(beforeMic, afterMic, "mic", "Mute", "Unmute")

    await toggle(page, MIC, true)
    const beforeShare = await snapshotRow(page, "case3_share_idle")
    await toggle(page, SHARE, true)
    const afterShare = await snapshotRow(page, "case3_share_active")
    const shareOnColours = await readColours(page)
    assertRowUnmoved(beforeShare, afterShare, "share", "Share", "Stop sharing")
    await toggle(page, SHARE, false)

    // ── The off states are still legible ────────────────────────────────
    // Read as a rendered difference rather than asserted in prose: the word
    // a human sees changes, in the light theme, on both controls.
    expect(
      beforeMic.find((c) => c.key === "mic")!.labelText,
      "mic-on and mic-off render the same visible word in light theme, so the muted state is " +
        "not distinguishable from the active one",
    ).not.toBe(afterMic.find((c) => c.key === "mic")!.labelText)
    expect(
      beforeShare.find((c) => c.key === "share")!.labelText,
      "share-idle and share-active render the same visible word in light theme",
    ).not.toBe(afterShare.find((c) => c.key === "share")!.labelText)

    // ── Red is Leave's, and only Leave's ────────────────────────────────
    //
    // TWO POSITIVE CONTROLS COME FIRST, and they are the reason this check
    // means anything. "No control uses the error token" passes perfectly on
    // a detector that matches nothing at all, so the detector is made to
    // find red where red demonstrably IS before it is trusted to report red
    // absent elsewhere:
    //
    //   1. Leave's TEXT colour is `text-error`, solid. Catching it proves
    //      the resolver reads the token.
    //   2. Leave's GROUND is `bg-error/15`, the same token alphaed, which
    //      Chromium emits in a different colour space entirely. Catching
    //      THAT proves the alpha-stripping normalisation works — and a
    //      tinted ground is exactly the shape a red muted-mic would take,
    //      so without this control the whole check would be blind in the
    //      one dimension it is meant to police.
    for (const [state, snap] of [
      ["mic_on", micOnColours],
      ["mic_off", micOffColours],
      ["share_active", shareOnColours],
    ] as const) {
      emit("colours", { state, ...snap })

      expect(
        snap.leave.color.rgb,
        `POSITIVE CONTROL 1 FAILED (${state}): Leave's text colour ${snap.leave.color.raw} ` +
          `normalises to ${snap.leave.color.rgb}, not the error token ${snap.errorToken.raw} ` +
          `(${snap.errorToken.rgb}). A detector that cannot find red on the button that is red ` +
          `cannot be trusted to report it absent on the others.`,
      ).toBe(snap.errorToken.rgb)

      expect(
        snap.leave.backgroundColor.rgb,
        `POSITIVE CONTROL 2 FAILED (${state}): Leave's ground ${snap.leave.backgroundColor.raw} ` +
          `normalises to ${snap.leave.backgroundColor.rgb}, not the error token ` +
          `${snap.errorToken.rgb}. That ground is bg-error/15 — the token at 15% — so this is ` +
          `the check that the ALPHA-STRIPPING works. Without it the sweep below would miss a ` +
          `tinted red ground, which is the only form a red muted state would take.`,
      ).toBe(snap.errorToken.rgb)

      for (const key of ["mic", "camera", "share"] as const) {
        for (const prop of ["color", "backgroundColor", "borderTopColor"] as const) {
          const c = snap[key][prop]
          expect(
            c.rgb,
            `${key} uses the error token in its ${prop} (${c.raw}) in state ${state}. Red is ` +
              `already Leave's on this row and FE-7 is adding a red recording dot to the header; ` +
              `a third red meaning here makes the recording indicator read as chrome. Muted is a ` +
              `state the user chose, not an error.`,
          ).not.toBe(snap.errorToken.rgb)
        }
      }
    }
  })
})

/** One computed colour, kept as BOTH the raw string the browser emitted and
 *  the sRGB triple it normalises to. The raw string is what a reader needs
 *  to check the verdict by hand; the triple is what the verdict is computed
 *  from. Recording only the triple would make a normalisation bug invisible. */
interface Colour {
  readonly raw: string
  readonly rgb: string
}

interface ButtonColours {
  readonly color: Colour
  readonly backgroundColor: Colour
  readonly borderTopColor: Colour
}

interface ColourSnapshot {
  readonly errorToken: Colour
  readonly mic: ButtonColours
  readonly camera: ButtonColours
  readonly share: ButtonColours
  readonly leave: ButtonColours
}

/** Resolve `--color-error` by painting it on a throwaway element INSIDE the
 *  row, so the token resolves through the same cascade the controls sit in
 *  and under the theme actually applied. Reading the custom property's
 *  declared value instead would hand back whatever text the author wrote,
 *  which is not what any control computes to. */
async function readColours(page: Page): Promise<ColourSnapshot> {
  return (await page.evaluate(
    ({ controlsSel, keys, normaliseSrc }) => {
      // eslint-disable-next-line no-new-func
      const normalise = new Function(`return (${normaliseSrc})`)() as (v: string[]) => string[]

      const row = document.querySelector(controlsSel)!
      const probe = document.createElement("span")
      probe.style.color = "var(--color-error)"
      probe.style.position = "absolute"
      row.appendChild(probe)
      const errorRaw = getComputedStyle(probe).color
      probe.remove()

      const read = (sel: string) => {
        const el = Array.from(document.querySelectorAll(sel)).find((n) => {
          const r = n.getBoundingClientRect()
          return r.width > 0 && r.height > 0
        })
        if (!el) return { color: "MISSING", backgroundColor: "MISSING", borderTopColor: "MISSING" }
        const cs = getComputedStyle(el)
        return {
          color: cs.color,
          backgroundColor: cs.backgroundColor,
          borderTopColor: cs.borderTopColor,
        }
      }

      const raws = {
        mic: read(keys.mic),
        camera: read(keys.camera),
        share: read(keys.share),
        leave: read(keys.leave),
      }

      const flat = [
        errorRaw,
        ...(["mic", "camera", "share", "leave"] as const).flatMap((k) => [
          raws[k].color,
          raws[k].backgroundColor,
          raws[k].borderTopColor,
        ]),
      ]
      const rgbs = normalise(flat)
      let i = 0
      const next = (raw: string) => ({ raw, rgb: rgbs[i++] })

      const errorToken = next(errorRaw)
      const pack = (k: "mic" | "camera" | "share" | "leave") => ({
        color: next(raws[k].color),
        backgroundColor: next(raws[k].backgroundColor),
        borderTopColor: next(raws[k].borderTopColor),
      })

      return {
        errorToken,
        mic: pack("mic"),
        camera: pack("camera"),
        share: pack("share"),
        leave: pack("leave"),
      }
    },
    {
      controlsSel: CONTROLS,
      keys: { mic: MIC, camera: CAMERA, share: SHARE, leave: LEAVE },
      normaliseSrc: NORMALISE_COLOURS_IN_PAGE.toString(),
    },
  )) as ColourSnapshot
}

// ─── Case 4: the narrow bar still degrades ──────────────────────────────────

/**
 * WHAT THIS CASE CAN AND CANNOT PROVE, stated up front because the rect
 * clause here is weaker than it looks.
 *
 * Below a 390px bar the container query pulls every label out of flow and
 * pins it to 1px. No label can then change width, so no button can, so the
 * row's rects are unchanged across both toggles — WITH the fix and WITHOUT
 * it. The rect assertion in this case therefore cannot fail on the defect
 * and is not evidence for the fix. It is here to catch a mechanism that
 * somehow moves the row in the collapsed state.
 *
 * The load-bearing clauses are the other three, and they are what the fix
 * could plausibly have broken: the labels must still collapse, there must
 * still be exactly FOUR `.call-control-label` elements (the count
 * `partials_meeting_panel_test.exs` asserts, and the reason the fix nests
 * its words inside the existing span instead of adding a sibling), and
 * Leave's right edge must still sit inside the bar. Reserving the widest
 * word adds 54.75px to the row, so clipping Leave is the specific way this
 * fix could have made the narrow bar worse.
 */
test.describe("call-control geometry gate — narrow bar", () => {
  test("case 4: labels collapse, four remain, Leave is not clipped, rects hold", async ({
    page,
  }) => {
    // A viewport whose /meetings bar lands below the 389px container-query
    // threshold. The bar runs about 32px narrower than the viewport, so 390
    // (iPhone 12/13/14) gives ~358px — one of the four widths stage 2
    // measured the collapse at. 430 does NOT work: it gives a ~398px bar,
    // above the threshold, where the labels show and Leave clips. That band
    // is stage 2's reported finding and it is not what this case is for.
    await page.setViewportSize({ width: 390, height: 844 })
    await login(page)
    await applyTheme(page, "dark")
    await joinCall(page)
    await applyTheme(page, "dark")
    await settle(page)

    await emitVariant(page, "narrow")

    const collapsed = await page.evaluate(
      ({ controlsSel, labelSel, leaveSel }) => {
        const row = document.querySelector(controlsSel)!
        const rowRect = row.getBoundingClientRect()
        const labels = Array.from(row.querySelectorAll(labelSel)).map((el) => {
          const cs = getComputedStyle(el)
          return {
            width: el.getBoundingClientRect().width,
            position: cs.position,
            clipPath: cs.clipPath,
          }
        })
        const leave = row.querySelector(leaveSel)
        const leaveRect = leave ? leave.getBoundingClientRect() : null
        return {
          rowWidth: rowRect.width,
          rowRight: rowRect.right,
          rowLeft: rowRect.left,
          labelCount: labels.length,
          labels,
          leaveRight: leaveRect ? leaveRect.right : null,
          leaveLeft: leaveRect ? leaveRect.left : null,
        }
      },
      { controlsSel: CONTROLS, labelSel: LABEL, leaveSel: LEAVE },
    )

    emit("narrow_bar", {
      ...collapsed,
      rowWidth: r4(collapsed.rowWidth),
      leaveOverhangPx: collapsed.leaveRight === null ? null : r4(collapsed.leaveRight - collapsed.rowRight),
    })

    expect(
      collapsed.rowWidth,
      `the bar is ${collapsed.rowWidth.toFixed(3)}px, at or above the 389px threshold, so the ` +
        `container query is NOT engaged and this case is measuring the wide layout under a ` +
        `narrow name. Narrow the viewport.`,
    ).toBeLessThanOrEqual(389)

    expect(
      collapsed.labelCount,
      `the bar holds ${collapsed.labelCount} .call-control-label elements, not 4. ` +
        `partials_meeting_panel_test.exs asserts exactly 4; a mechanism that adds a second ` +
        `span carrying that class per control makes it 6.`,
    ).toBe(4)

    for (const l of collapsed.labels) {
      expect(l.position, "a label is still in flow on a narrow bar; the collapse did not engage").toBe(
        "absolute",
      )
      expect(l.width, "a label is wider than the 1px the collapse pins it to").toBeLessThanOrEqual(1.5)
    }

    expect(
      collapsed.leaveRight,
      "Leave is missing from the narrow bar entirely; the degradation exists to keep it on screen",
    ).not.toBeNull()
    expect(
      collapsed.leaveRight! - collapsed.rowRight,
      `Leave's right edge overhangs the bar by ` +
        `${(collapsed.leaveRight! - collapsed.rowRight).toFixed(3)}px. Reserving the widest label ` +
        `adds 54.75px to the row, and clipping Leave is the specific way this fix could have made ` +
        `the narrow bar worse.`,
    ).toBeLessThanOrEqual(TOL_PX)

    // The weak clause, run for completeness and labelled as weak in the
    // record so nobody reads its zeros as evidence for the fix.
    const beforeMic = await snapshotRow(page, "case4_mic_on")
    await toggle(page, MIC, false)
    const afterMic = await snapshotRow(page, "case4_mic_off")
    await toggle(page, MIC, true)
    const beforeShare = await snapshotRow(page, "case4_share_idle")
    await toggle(page, SHARE, true)
    const afterShare = await snapshotRow(page, "case4_share_active")
    await toggle(page, SHARE, false)

    for (const [which, b, a] of [
      ["mic", beforeMic, afterMic],
      ["share", beforeShare, afterShare],
    ] as const) {
      const deltas = CONTROL_KEYS.map(({ key }) => ({
        key,
        xDelta: r4(a.find((c) => c.key === key)!.button.x - b.find((c) => c.key === key)!.button.x),
        widthDelta: r4(
          a.find((c) => c.key === key)!.button.width - b.find((c) => c.key === key)!.button.width,
        ),
      }))
      emit("narrow_gate", {
        which,
        tolerancePx: TOL_PX,
        deltas,
        weakness:
          "labels are out of flow here, so these deltas are zero with OR without the fix. " +
          "Not evidence for the fix; a guard against a mechanism that moves the collapsed row.",
      })
      for (const d of deltas) {
        expect(Math.abs(d.xDelta), `${d.key} moved ${d.xDelta}px on the collapsed bar`).toBeLessThanOrEqual(
          TOL_PX,
        )
        expect(
          Math.abs(d.widthDelta),
          `${d.key} changed width by ${d.widthDelta}px on the collapsed bar`,
        ).toBeLessThanOrEqual(TOL_PX)
      }
    }
  })
})
