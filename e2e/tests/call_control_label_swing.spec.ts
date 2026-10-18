/**
 * The call-control LABEL SWING probe (FE-20, task
 * 01a0773e-cea9-7001-98f5-be6c37607e91, stage 1).
 *
 * WHAT THIS MEASURES AND WHY IT IS A PROBE, NOT A GATE.
 *
 * `call_controls/1` renders four buttons in one `justify-center` row inside a
 * box whose width does not change. Two of the four labels change words with
 * state — mic says "Mute"/"Unmute", share says "Share"/"Stop sharing" — and a
 * centred row absorbs a widening label by pushing every sibling outward by
 * HALF the widening. FE-19 measured the mic case and found the glyph moving
 * 7.891px, exactly half of the 15.797px the label grew.
 *
 * Nobody has ever measured the SHARE case, which is the wider of the two by
 * inspection and is therefore the one that governs. Stage 1 exists to produce
 * that number. It CHANGES NOTHING: stage 2 changes code, stage 3 re-runs this
 * file against the fix and against a mutant. That is why every value here is
 * PRINTED rather than asserted against a threshold — a threshold invented
 * before the measurement exists is a threshold fitted to a guess.
 *
 * THE ONE THING THIS FILE DOES ASSERT is that it was able to measure at all.
 * `app.css` collapses `.call-control-label` to a 1px clipped box inside
 * `@container (max-width: 389px)`, and a run against the collapsed state
 * records a pile of zero-width labels and zero deltas — which is
 * INDISTINGUISHABLE FROM A PASS. So the labels are proven laid out (static
 * position, no clip-path, real width) before a single number is recorded, and
 * the proof is printed alongside the numbers.
 *
 * EVERY STATE HERE IS A REAL SERVER RENDER. No `textContent` was swapped to
 * simulate the other string. Both toggles reach the server without an SFU:
 *
 *   - mic: `phx-click="meeting_toggle_mic"` reaches `MeetingHooks.toggle_mic/1`,
 *     which flips `:mic_enabled` unconditionally.
 *   - share: the `MeetingShareButton` hook finds no `window.__livekit_room`
 *     and falls back to pushing `meeting_toggle_screen_share`, which flips
 *     `:screen_share_enabled` server-side. That fallback path does NOT switch
 *     the stage mode (only `meeting_screen_share_state` does), so the share
 *     toggle changes the label and nothing else about the page.
 *
 * RIG PRECONDITION, and it is load-bearing: the dev server must be booted with
 * an EMPTY `LIVEKIT_URL` (api key and secret still set, so token minting is
 * real). With a non-empty URL and no SFU behind it, `room.connect` fails,
 * livekit-client emits `RoomEvent.Disconnected`, `meeting_client.js` pushes
 * `meeting_left`, and the server resets `:in_meeting` about 60ms after the
 * join — which silently drops the Leave button from the row and would have the
 * probe measure a FOUR-item row while reporting it as the five-item one users
 * see. With an empty URL, `meeting_client.js` returns at its own
 * `if (!token || !url)` guard before it ever constructs a `Room`, so there is
 * no connect, no disconnect and no spurious leave. `assertJoined` below fails
 * loudly if this was got wrong.
 */

import { test, expect, Page } from "@playwright/test"
import { allRects, visibleRect, type Rect } from "./support/geometry"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"
const MEETING_SLUG = process.env.SWING_MEETING_SLUG ?? "label-swing"
const LOGIN_AS = process.env.SWING_LOGIN_AS ?? "robin"

/** 1440x900 is FE-19's viewport, kept so the two stages' absolute numbers are
 *  comparable. The width also matters on its own account: the control row must
 *  be at least 390px wide for the labels to exist at all. */
const VIEWPORT = { width: 1440, height: 900 }

const CONTROLS = '[data-component="call-controls"]'
const LABEL = ".call-control-label"

/** The four controls the stage names, in DOM order. `mic` and `share` change
 *  their label with state; `camera` and `leave` do not, and are measured
 *  precisely BECAUSE they do not — a fixed-label control that moves is the
 *  clearest evidence that the row, and not the button, is what reflows. */
const CONTROLS_UNDER_TEST = [
  { key: "mic", selector: '[data-role="meeting-mic"]', labelChanges: true },
  { key: "camera", selector: '[data-role="meeting-camera"]', labelChanges: false },
  { key: "share", selector: '[data-role="meeting-screen-share"]', labelChanges: true },
  { key: "leave", selector: '[data-role="meeting-leave"]', labelChanges: false },
] as const

/** The push-to-talk button sits BETWEEN share and leave (the `:before_leave`
 *  slot, `/meetings` only) and its "Hold to talk" text is `lg:not-sr-only`, so
 *  at 1440 it is laid out and contributes to the row's width. It is not a
 *  `.call-control-label` and the container query does not touch it. Recorded
 *  because a reader reconciling the row's total width against the four buttons
 *  would otherwise find ~90px unaccounted for and have no way to know whether
 *  that was a fifth control or a measurement error. */
const PUSH_TO_TALK = '[data-role="meeting-push-to-talk"]'

type ThemeName = "dark" | "light"
const THEMES: readonly ThemeName[] = ["dark", "light"]

interface ControlReading {
  readonly key: string
  readonly button: Rect
  readonly label: Rect | null
  readonly labelText: string | null
  /** Computed style evidence that the label is genuinely laid out rather than
   *  collapsed by the container query. Recorded on every reading, not just the
   *  first, because a state change could in principle narrow the row. */
  readonly labelPosition: string | null
  readonly labelClipPath: string | null
}

interface StateReading {
  readonly state: string
  readonly theme: ThemeName
  readonly micOn: boolean
  readonly sharing: boolean
  readonly container: Rect
  readonly controls: readonly ControlReading[]
  readonly pushToTalk: Rect | null
}

/** Four decimal places, matching FE-19's record so the two stages' numbers can
 *  be compared without a rounding argument. */
const r4 = (n: number): number => Number(n.toFixed(4))

/** One machine-readable line per record. `measure-call-control-swing.sh` reads
 *  these back out of the playwright log; a human can read them as-is. */
function emit(kind: string, payload: unknown): void {
  console.log(`[fe20] ${kind} ${JSON.stringify(payload)}`)
}

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
        `A fresh worktree needs BOTH \`mix deps.get\` AND \`npm install\` in ` +
        `apps/platform/assets. Without the second, app.js 404s, LiveView never ` +
        `connects, and the page renders but is dead — every rect below would be a ` +
        `measurement of a page that never ran. Do not record this run.`,
    )
  }
})

async function login(page: Page): Promise<void> {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${LOGIN_AS}`)
  await page.waitForURL(/\/chat/, { timeout: 30_000 })
}

/** Set the theme and PROVE it took. `data-theme` is written on `<html>` by an
 *  inline script in root.html.heex from `localStorage["phx:theme"]`, defaulting
 *  to dark. Setting only the attribute would be undone by that bootstrap on the
 *  next full navigation, and a light-theme run that silently rendered dark
 *  would produce two identical halves of the table with no sign anything was
 *  wrong. So: seed localStorage, set the attribute, and read it back. */
async function applyTheme(page: Page, theme: ThemeName): Promise<void> {
  await page.evaluate((t) => {
    try {
      localStorage.setItem("phx:theme", t)
    } catch {
      /* private-mode storage; the attribute below still governs this page */
    }
    document.documentElement.setAttribute("data-theme", t)
  }, theme)
  const applied = await page.evaluate(() => document.documentElement.getAttribute("data-theme"))
  expect(
    applied,
    `theme did not take: asked for "${theme}", <html data-theme> reads "${applied}". ` +
      `Measuring the wrong theme silently duplicates the other half of the table.`,
  ).toBe(theme)
}

/** Let LiveView finish patching and the browser finish laying out. A rect read
 *  mid-patch measures a transient. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(600)
  await page.evaluate(
    () => new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res))),
  )
}

/** Open the call surface and get into the JOINED state.
 *
 *  The join is conditional because the joined state PERSISTS in
 *  `meeting_participants` across a page load and a server restart. A run
 *  against a warm database finds no join button and must not treat that as a
 *  failure; a run against the cold database `seed-call-control-fixture.sh`
 *  leaves behind must click it. Which of the two happened is printed, so an
 *  unexercised prelude is visible rather than assumed. */
async function openJoinedCallSurface(page: Page): Promise<void> {
  await page.goto(`/meetings/${MEETING_SLUG}`)
  await page.waitForFunction(() => !!(window as any).liveSocket?.isConnected?.(), null, {
    timeout: 30_000,
  })
  await page.waitForSelector(CONTROLS, { timeout: 30_000 })

  // THE JOIN CLICK IS BEST-EFFORT; THE JOINED STATE IS NOT.
  //
  // Stage 3 rig fix, and it touches NO measurement path — the join is how
  // the surface is reached, not anything this probe records. `count()`,
  // `isVisible()` and `click()` are three round trips and the button can be
  // patched away between any two of them: the joined state persists in
  // `meeting_participants`, so once one test in a run has joined, the server
  // can reconcile the next test's page while this is still deciding whether
  // to click. Observed on the third test of a warm run, hanging the full
  // 180s on a locator that had already gone and reporting a rig timeout as a
  // probe failure.
  //
  // Losing the button is not a failure, because the button is not what is
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

  // `[data-role="meeting-leave"]` renders ONLY under `show_leave={@in_meeting}`,
  // so its appearance IS the joined state — there is no separate flag to read.
  try {
    await page.waitForSelector('[data-role="meeting-leave"]', { timeout: 30_000 })
  } catch {
    throw new Error(
      `NOT JOINED: [data-role="meeting-leave"] never rendered, so @in_meeting is false and ` +
        `the row under measurement has FOUR items where the real call has five. The usual ` +
        `cause is a non-empty LIVEKIT_URL with no SFU behind it: room.connect fails, ` +
        `livekit-client emits Disconnected, meeting_client.js pushes "meeting_left", and the ` +
        `server resets :in_meeting ~60ms after the join. Boot the dev server with ` +
        `LIVEKIT_URL= (empty) and LIVEKIT_API_KEY/LIVEKIT_API_SECRET set.`,
    )
  }

  await settle(page)
  emit("prelude", {
    meetingSlug: MEETING_SLUG,
    joinButtonsFound: joinCount,
    joinClicked: joinCount > 0,
    joinOutcome,
    note:
      joinCount === 0
        ? "warm database: already joined from a previous run, prelude skipped"
        : "cold database: join prelude ran",
  })
}

/**
 * THE GUARD THE WHOLE PROBE RESTS ON.
 *
 * Measuring the collapsed state records zero-width labels and zero deltas,
 * which looks exactly like "the layout is fine". This proves the opposite of
 * a bare pass: it shows the labels are laid out, and prints the three
 * independent facts that establish it, so the guard cannot quietly become a
 * tautology later.
 *
 * `position` and `clip-path` are checked as well as width because the collapse
 * rule sets ALL of `position:absolute; width:1px; clip-path:inset(50%)` — a
 * future edit that drops only the width from that rule would leave a label
 * that is 1px-clipped but not 1px wide, and a width-only guard would wave it
 * through.
 */
async function assertLabelsVisible(page: Page): Promise<void> {
  const evidence = await page.evaluate(
    ({ controlsSel, labelSel }) => {
      const container = document.querySelector(controlsSel)
      if (!container) return null
      const cr = container.getBoundingClientRect()
      const labels = Array.from(container.querySelectorAll(labelSel)).map((el) => {
        const cs = getComputedStyle(el)
        return {
          text: (el.textContent ?? "").trim(),
          width: el.getBoundingClientRect().width,
          position: cs.position,
          clipPath: cs.clipPath,
        }
      })
      return { containerWidth: cr.width, labels }
    },
    { controlsSel: CONTROLS, labelSel: LABEL },
  )

  expect(evidence, `no ${CONTROLS} in the document at all`).not.toBeNull()
  const { containerWidth, labels } = evidence!

  emit("visibility_guard", {
    containerWidth: r4(containerWidth),
    containerQueryThresholdPx: 389,
    aboveThreshold: containerWidth > 389,
    labels: labels.map((l) => ({
      text: l.text,
      width: r4(l.width),
      position: l.position,
      clipPath: l.clipPath,
    })),
  })

  expect(
    containerWidth,
    `the control row is ${containerWidth.toFixed(3)}px wide. app.css:2404 collapses ` +
      `.call-control-label inside @container (max-width: 389px), so at this width the labels ` +
      `are 1px clipped boxes and every delta below would be zero — which reads exactly like a ` +
      `pass. Widen the viewport or measure a surface whose bar exceeds 389px.`,
  ).toBeGreaterThan(389)

  expect(labels.length, "no .call-control-label spans found inside the control row").toBeGreaterThan(
    0,
  )

  for (const l of labels) {
    expect(
      l.position,
      `label "${l.text}" has position:${l.position} — the container-query collapse sets ` +
        `position:absolute. This run is measuring the COLLAPSED state.`,
    ).toBe("static")
    expect(
      l.clipPath,
      `label "${l.text}" has clip-path:${l.clipPath} — the collapse sets inset(50%). ` +
        `This run is measuring the COLLAPSED state.`,
    ).toBe("none")
    expect(
      l.width,
      `label "${l.text}" is ${l.width.toFixed(3)}px wide — the collapse pins it to 1px.`,
    ).toBeGreaterThan(4)
  }
}

/** Read every rect for one state. Uses `visibleRect`, which throws
 *  `SelectorAmbiguityError` rather than silently taking `.first()`: the
 *  meetings DOM carries breakpoint duplicates of several controls, and a
 *  hidden copy's all-zero rect passes every test there is. */
async function readState(
  page: Page,
  state: string,
  theme: ThemeName,
  micOn: boolean,
  sharing: boolean,
): Promise<StateReading> {
  const container = await visibleRect(page, CONTROLS)

  const controls: ControlReading[] = []
  for (const c of CONTROLS_UNDER_TEST) {
    const button = await visibleRect(page, c.selector)
    const labelInfo = await page.evaluate(
      ({ sel, labelSel }) => {
        const btns = Array.from(document.querySelectorAll(sel)).filter((n) => {
          const r = n.getBoundingClientRect()
          return r.width > 0 && r.height > 0
        })
        if (btns.length !== 1) return null
        const el = btns[0].querySelector(labelSel)
        if (!el) return null
        const r = el.getBoundingClientRect()
        const cs = getComputedStyle(el)
        return {
          text: (el.textContent ?? "").trim(),
          rect: {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
            left: r.left,
          },
          position: cs.position,
          clipPath: cs.clipPath,
        }
      },
      { sel: c.selector, labelSel: LABEL },
    )

    controls.push({
      key: c.key,
      button,
      label: labelInfo ? (labelInfo.rect as Rect) : null,
      labelText: labelInfo ? labelInfo.text : null,
      labelPosition: labelInfo ? labelInfo.position : null,
      labelClipPath: labelInfo ? labelInfo.clipPath : null,
    })
  }

  const pttRects = await allRects(page, PUSH_TO_TALK)
  const pttVisible = pttRects.filter((r) => r.width > 0 && r.height > 0)
  const pushToTalk = pttVisible.length === 1 ? pttVisible[0] : null

  const reading: StateReading = {
    state,
    theme,
    micOn,
    sharing,
    container,
    controls,
    pushToTalk,
  }

  emit("reading", {
    state,
    theme,
    micOn,
    sharing,
    containerX: r4(container.x),
    containerWidth: r4(container.width),
    controls: controls.map((c) => ({
      key: c.key,
      buttonX: r4(c.button.x),
      buttonWidth: r4(c.button.width),
      labelText: c.labelText,
      labelX: c.label ? r4(c.label.x) : null,
      labelWidth: c.label ? r4(c.label.width) : null,
      labelPosition: c.labelPosition,
      labelClipPath: c.labelClipPath,
    })),
    pushToTalkX: pushToTalk ? r4(pushToTalk.x) : null,
    pushToTalkWidth: pushToTalk ? r4(pushToTalk.width) : null,
  })

  return reading
}

/** Click a control and wait for the SERVER to confirm the flip via `data-on`.
 *  Waiting on the attribute rather than a fixed timeout means a click that was
 *  swallowed (pushed before the socket connected, say) fails here as a timeout
 *  instead of silently recording the old state under the new state's name. */
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

const MIC = '[data-role="meeting-mic"]'
const SHARE = '[data-role="meeting-screen-share"]'

test.describe("call-control label swing @ 1440x900", () => {
  for (const theme of THEMES) {
    test(`four controls across mic and share toggles — ${theme}`, async ({ page }) => {
      await page.setViewportSize(VIEWPORT)
      await login(page)
      await applyTheme(page, theme)
      await openJoinedCallSurface(page)
      await applyTheme(page, theme)
      await settle(page)

      // The guard runs BEFORE any number is recorded. See its doc comment.
      await assertLabelsVisible(page)

      const readings: StateReading[] = []

      // S1 — baseline. `/meetings` mounts with mic on and share idle.
      const micOn0 = (await page.locator(MIC).getAttribute("data-on")) === "true"
      const sharing0 = (await page.locator(SHARE).getAttribute("data-on")) === "true"
      expect(
        micOn0 && !sharing0,
        `expected the surface to mount at mic-on/share-idle, got mic-on=${micOn0} ` +
          `sharing=${sharing0}. The state sequence below assumes that baseline.`,
      ).toBe(true)
      readings.push(await readState(page, "S1_baseline", theme, true, false))

      // S2 — mic off. "Mute" -> "Unmute".
      await toggle(page, MIC, false)
      readings.push(await readState(page, "S2_mic_off", theme, false, false))

      // S3 — mic back on, share active. "Share" -> "Stop sharing".
      await toggle(page, MIC, true)
      await toggle(page, SHARE, true)
      readings.push(await readState(page, "S3_share_active", theme, true, true))

      // S4 — both changed at once. The two swings are independent; this is the
      // reading that shows whether they simply add.
      await toggle(page, MIC, false)
      readings.push(await readState(page, "S4_mic_off_share_active", theme, false, true))

      // S5 — back to the baseline. FE-19 found unmuted->unmuted at 0.0000 on
      // all eight edges; if S5 does not reproduce S1 exactly then the rig is
      // drifting and none of the deltas above are trustworthy.
      await toggle(page, MIC, true)
      await toggle(page, SHARE, false)
      readings.push(await readState(page, "S5_return_to_baseline", theme, true, false))

      const byState = (s: string) => readings.find((r) => r.state === s)!
      const ctrl = (r: StateReading, k: string) => r.controls.find((c) => c.key === k)!

      const s1 = byState("S1_baseline")
      const s2 = byState("S2_mic_off")
      const s3 = byState("S3_share_active")
      const s5 = byState("S5_return_to_baseline")

      // ── The two label swings, and the shift each one causes ──────────────
      for (const [name, from, to, changed] of [
        ["mic", s1, s2, "mic"],
        ["share", s1, s3, "share"],
      ] as const) {
        const labelFrom = ctrl(from, changed).label!
        const labelTo = ctrl(to, changed).label!
        const swing = labelTo.width - labelFrom.width

        emit("swing", {
          which: name,
          theme,
          fromState: from.state,
          toState: to.state,
          fromText: ctrl(from, changed).labelText,
          toText: ctrl(to, changed).labelText,
          fromLabelWidth: r4(labelFrom.width),
          toLabelWidth: r4(labelTo.width),
          labelWidthDelta: r4(swing),
          halfDelta: r4(swing / 2),
          containerWidthFrom: r4(from.container.width),
          containerWidthTo: r4(to.container.width),
          containerWidthDelta: r4(to.container.width - from.container.width),
          controlShifts: CONTROLS_UNDER_TEST.map((c) => ({
            key: c.key,
            buttonXFrom: r4(ctrl(from, c.key).button.x),
            buttonXTo: r4(ctrl(to, c.key).button.x),
            buttonXDelta: r4(ctrl(to, c.key).button.x - ctrl(from, c.key).button.x),
            buttonWidthDelta: r4(ctrl(to, c.key).button.width - ctrl(from, c.key).button.width),
          })),
        })
      }

      // ── Determinism: S5 must reproduce S1 ────────────────────────────────
      const drift = CONTROLS_UNDER_TEST.map((c) => ({
        key: c.key,
        buttonXDelta: r4(ctrl(s5, c.key).button.x - ctrl(s1, c.key).button.x),
        buttonWidthDelta: r4(ctrl(s5, c.key).button.width - ctrl(s1, c.key).button.width),
        labelWidthDelta: r4((ctrl(s5, c.key).label?.width ?? 0) - (ctrl(s1, c.key).label?.width ?? 0)),
      }))
      emit("determinism", { theme, returnToBaselineDrift: drift })

      for (const d of drift) {
        expect(
          Math.abs(d.buttonXDelta),
          `${d.key} did not return to its baseline x after a full toggle cycle ` +
            `(drift ${d.buttonXDelta}px). Every delta recorded above is then suspect.`,
        ).toBeLessThan(0.0001)
      }
    })
  }
})

/**
 * `[data-bar-mic]` — the persistent mini-bar's mic.
 *
 * The stage asks for this to be ATTEMPTED, and to be recorded as UNMEASURED
 * with a structural reason if it cannot be shown. FE-19 never got it visible
 * (Playwright timed out at 180s), and reasoning alone that "it is icon-only so
 * it cannot exhibit this" is reasoning, not measurement.
 *
 * IT IS MEASURABLE, and here is the trick FE-19 was missing: `#meeting-mini-bar`
 * carries `hidden` when `!@meeting_active || @on_meeting_page`. On the meetings
 * page the second disjunct is true, so the button is in the DOM with an all-zero
 * rect no matter how long anything waits for it. Viewed from a DIFFERENT route
 * while still in the call, the bar lays out and the button has a real box.
 *
 * If a future run cannot get it on screen, this test FAILS rather than skipping.
 * Recording an unmeasured control as clean is the false attestation the stage
 * spec names by name.
 */
test.describe("mini-bar mic @ 1440x900", () => {
  test("[data-bar-mic] across the mic toggle", async ({ page }) => {
    await page.setViewportSize(VIEWPORT)
    await login(page)
    await applyTheme(page, "dark")
    await openJoinedCallSurface(page)

    // Leave the meeting PAGE without leaving the meeting: `on_meeting_page`
    // goes false, `meeting_active` stays true, and the bar unhides.
    await page.goto("/tasks")
    await page.waitForFunction(() => !!(window as any).liveSocket?.isConnected?.(), null, {
      timeout: 30_000,
    })
    await applyTheme(page, "dark")
    await page.waitForFunction(
      () => {
        const bar = document.querySelector("#meeting-mini-bar")
        return !!bar && bar.getBoundingClientRect().width > 0
      },
      null,
      { timeout: 30_000 },
    )
    await settle(page)

    const read = async (tag: string) => {
      const data = await page.evaluate(() => {
        const bar = document.querySelector("#meeting-mini-bar")
        const btn = document.querySelector("[data-bar-mic]")
        const glyph = btn?.querySelector("span")
        const box = (el: Element | null | undefined) => {
          if (!el) return null
          const r = el.getBoundingClientRect()
          return { x: r.x, y: r.y, width: r.width, height: r.height }
        }
        return {
          bar: box(bar),
          button: box(btn),
          glyph: box(glyph),
          title: btn?.getAttribute("title") ?? null,
          glyphClass: glyph?.className ?? null,
          // The structural claim, checked rather than asserted in prose: an
          // icon-only control has no label span to change width.
          labelSpans: btn ? btn.querySelectorAll(".call-control-label").length : null,
        }
      })
      emit("bar_mic", {
        tag,
        barWidth: data.bar ? r4(data.bar.width) : null,
        buttonX: data.button ? r4(data.button.x) : null,
        buttonWidth: data.button ? r4(data.button.width) : null,
        glyphX: data.glyph ? r4(data.glyph.x) : null,
        glyphWidth: data.glyph ? r4(data.glyph.width) : null,
        title: data.title,
        glyphClass: data.glyphClass,
        callControlLabelSpans: data.labelSpans,
      })
      expect(
        data.button && data.button.width > 0,
        `[data-bar-mic] has no laid-out box (${tag}). Record it as UNMEASURED with the ` +
          `structural reason — never as clean.`,
      ).toBe(true)
      return data
    }

    const before = await read("mic_on")

    // The bar's mic has NO phx-click; the MeetingBar JS hook binds the click
    // and pushes `meeting_toggle_mic` to whichever LiveView owns it.
    await page.locator("[data-bar-mic]").click()
    await page.waitForFunction(
      (t) => document.querySelector("[data-bar-mic]")?.getAttribute("title") !== t,
      before.title,
      { timeout: 20_000 },
    )
    await settle(page)
    const after = await read("mic_off")

    emit("bar_mic_swing", {
      titleFrom: before.title,
      titleTo: after.title,
      buttonWidthDelta: r4((after.button?.width ?? 0) - (before.button?.width ?? 0)),
      buttonXDelta: r4((after.button?.x ?? 0) - (before.button?.x ?? 0)),
      glyphWidthDelta: r4((after.glyph?.width ?? 0) - (before.glyph?.width ?? 0)),
      glyphXDelta: r4((after.glyph?.x ?? 0) - (before.glyph?.x ?? 0)),
      callControlLabelSpans: after.labelSpans,
    })
  })
})
