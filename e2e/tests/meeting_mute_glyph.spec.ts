/**
 * The muted-mic glyph actually PAINTS (task 01a07486-7985-7001-87ce-277681791f52,
 * FE-19 stage 3).
 *
 * WHY THIS FILE EXISTS. `hero-microphone-slash` was used at four call sites
 * in meetings and generated no CSS at all, because Heroicons ships no
 * `microphone-slash.svg` at any of its four sizes. Every muted mic in the
 * product painted an error-tinted well around an empty centre, and had done
 * since the indicator shipped. FE-19 vendors the missing glyph into
 * `apps/platform/assets/icons/24/outline/` and teaches
 * `assets/vendor/heroicons.js` a second icon root.
 *
 * WHAT THIS TEST IS FOR, AND WHAT IT DELIBERATELY IS NOT. A check on the
 * class attribute, on `display`, on `opacity` or on `visibility` passes
 * TODAY, WITH THE BUG: the `<span>` is in the DOM either way, laid out
 * either way, and visible either way. It is the mask that is missing. So
 * every assertion here resolves through `getComputedStyle(el).maskImage`,
 * which is the check FE-3 stage 3 used to confirm the defect in the first
 * place, and none of them resolves through a class name.
 *
 * `maskImage` alone is still not enough on its own, for two reasons this
 * file closes:
 *
 *   1. A run in a browser that reported something non-`none` for every
 *      element would pass vacuously. `assertion 1` is a NEGATIVE CONTROL: a
 *      `hero-*` class that resolves to no icon must report exactly `"none"`.
 *      If that control ever fails, nothing below it means anything.
 *   2. A mask that resolves to the WRONG FILE also reports non-`none`.
 *      Vendoring the plain `microphone.svg` under the slash name would
 *      satisfy a bare `!== "none"` while shipping an unslashed mic to a
 *      muted user, which is the worst possible failure on this control.
 *      `assertion 3` decodes the mask data URI and requires the negation
 *      stroke's own subpath to be in it.
 *
 * PRECONDITION. `e2e/scripts/seed-meeting-mute-fixture.sh` must have run
 * against the server's database. It seeds an active meeting room, two HUMAN
 * participants, and a meeting reachable at `/meetings/<MEETING_SLUG>`. Two
 * humans and not one is load-bearing: `meeting_live.html.heex` folds the
 * roster's off-sets through `MeetingLive.roster_off_set/3`, which OVERRIDES
 * the viewer's own row with the viewer's local `@mic_enabled` boolean, so a
 * `media_states` push naming the viewer is discarded by design. The muted
 * subject therefore has to be somebody other than whoever is logged in.
 *
 * WHY `media_states` IS PUSHED RATHER THAN MUTED FOR REAL. In production
 * the set arrives from LiveKit via `MeetingClient._pushMediaStates`. There
 * is no SFU in this rig, and standing up one to change a CSS mask would be
 * testing LiveKit. The push is the same event, with the same payload shape,
 * into the same `MeetingHooks.apply_media_states/2` the SFU path lands on,
 * so everything downstream of it (the fold, the roster render, the glyph,
 * the mask) is the real thing.
 */

import { test, expect, Page, Locator } from "@playwright/test"

const MEETING_SLUG = process.env.MUTE_GLYPH_MEETING_SLUG ?? "mute-glyph-gate"
const LOGIN_AS = process.env.MUTE_GLYPH_LOGIN_AS ?? "alice"

/** The roster's mic well, which carries the resolved state as a declared
 *  selector contract rather than as a class. */
const MIC_INDICATOR = '[data-role="mic-indicator"]'
const MEDIA_SLOTS = '[data-role="media-slots"]'
const RAIL_PANE = '[data-role="call-rail-pane"]'

/** Read the computed mask, preferring the standard property and falling
 *  back to the WebKit-prefixed one. Both are set by the Tailwind Heroicons
 *  plugin; a browser that only populates the prefixed one must not read as
 *  a missing glyph. */
async function maskImageOf(el: Locator): Promise<string> {
  return await el.evaluate((node) => {
    const cs = getComputedStyle(node as Element)
    const std = cs.maskImage
    if (std && std !== "none" && std !== "") return std
    // `webkitMaskImage` is the legacy alias; older WebKit populates only it.
    const webkit = (cs as unknown as Record<string, string>).webkitMaskImage
    return webkit && webkit !== "" ? webkit : std || "none"
  })
}

/** Log in and open the seeded meeting room with a LIVE LiveView socket.
 *
 *  The socket wait is not optional and is not a timing nicety. Every control
 *  on this screen is in the static markup before LiveView connects, and both
 *  a `phx-click` and a `pushHookEvent` on an unconnected socket are silently
 *  swallowed. Skip the wait and the toggle below becomes a no-op that reads
 *  as "the glyph never changed" — a green-looking measurement of a state the
 *  page never entered. */
async function openMeetingRoom(page: Page): Promise<void> {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))

  await page.goto(`/dev/login?as=${LOGIN_AS}`)
  await page.waitForURL(/\/chat/, { timeout: 20_000 })

  await page.goto(`/meetings/${MEETING_SLUG}`)

  await page.waitForFunction(
    () => !!(window as unknown as { liveSocket?: { isConnected(): boolean } }).liveSocket?.isConnected?.(),
    null,
    { timeout: 30_000 },
  )
}

async function openRosterWithAMutedParticipant(page: Page): Promise<void> {
  await openMeetingRoom(page)

  const pane = page.locator(RAIL_PANE).first()
  await expect(
    pane,
    `no participant rail at /meetings/${MEETING_SLUG}. Run ` +
      `e2e/scripts/seed-meeting-mute-fixture.sh against the server's database ` +
      `before this spec; without the fixture there is no roster to read and ` +
      `this is a MISSING PRECONDITION, not a glyph regression.`,
  ).toBeVisible({ timeout: 30_000 })

  const identities = await page.evaluate(() =>
    Array.from(document.querySelectorAll("[data-participant]")).map((n) =>
      n.getAttribute("data-participant"),
    ),
  )
  expect(
    identities.length,
    "the fixture must seed at least two participants: the viewer's own roster " +
      "row is driven by the local @mic_enabled boolean and cannot be muted " +
      "from a media_states push (MeetingLive.roster_off_set/3)",
  ).toBeGreaterThanOrEqual(2)

  // The same event, payload shape and handler the SFU path lands on.
  await page.evaluate((ids) => {
    const ls = (window as unknown as { liveSocket: { main: { pushHookEvent: Function } } }).liveSocket
    ls.main.pushHookEvent(
      document.querySelector("#meeting-client"),
      null,
      "media_states",
      { muted: ids, camera_off: ids },
      () => {},
    )
  }, identities)

  await expect(page.locator(`${MIC_INDICATOR}[data-mic-state="off"]`).first()).toBeVisible({
    timeout: 15_000,
  })
}

test("the muted-mic glyph resolves to a real mask, beside the camera-off glyph", async ({
  page,
}) => {
  await openRosterWithAMutedParticipant(page)

  // ── 1. NEGATIVE CONTROL ────────────────────────────────────────────────
  // Prove the instrument discriminates before trusting anything it says. A
  // `hero-*` class the plugin resolves to nothing must report exactly
  // "none"; if this ever comes back non-"none", every assertion below is
  // vacuous and the run means nothing.
  const controlMask = await page.evaluate(() => {
    const probe = document.createElement("span")
    probe.className = "hero-microphone-slash-this-icon-does-not-exist"
    probe.setAttribute("data-role", "mask-instrument-control")
    document.body.appendChild(probe)
    const cs = getComputedStyle(probe)
    const value = cs.maskImage || (cs as unknown as Record<string, string>).webkitMaskImage || "none"
    probe.remove()
    return value
  })
  expect(
    controlMask,
    "NEGATIVE CONTROL FAILED: a hero-* class that resolves to no icon reported " +
      `${controlMask} instead of "none", so getComputedStyle().maskImage cannot ` +
      "tell a painted glyph from a blank one in this browser and the assertions " +
      "below prove nothing",
  ).toBe("none")

  // ── 2. THE GLYPH PAINTS ────────────────────────────────────────────────
  const mutedWell = page.locator(`${MIC_INDICATOR}[data-mic-state="off"]`).first()
  await expect(mutedWell).toHaveAttribute("aria-label", "Microphone muted")

  const micGlyph = mutedWell.locator("span").first()
  const micMask = await maskImageOf(micGlyph)
  expect(
    micMask,
    "the muted-mic glyph has NO mask image, which is the FE-19 defect itself: " +
      "the well paints its error tint around an empty centre. Check that " +
      "apps/platform/assets/icons/24/outline/microphone-slash.svg exists and " +
      "that assets/vendor/heroicons.js still reads the assets/icons root, then " +
      "re-run mix assets.build",
  ).not.toBe("none")
  expect(micMask.length, "the muted-mic mask resolved to an empty value").toBeGreaterThan(0)

  // ── 3. IT IS THE RIGHT FILE ────────────────────────────────────────────
  // A mask that resolves to the plain microphone would also be non-"none"
  // and would ship an UNSLASHED mic to a muted user. The negation stroke's
  // first subpath is in microphone-slash.svg and in nothing else.
  const decoded = decodeURIComponent(micMask)
  expect(
    decoded,
    "the muted-mic mask resolved to an SVG with no negation stroke in it: " +
      "the glyph is painting, but it is not a SLASHED microphone. Something " +
      "under assets/icons is shadowing hero-microphone-slash with the wrong file",
  ).toContain("M3.75 3.75 7.95 7.95")

  // ── 4. THE PAIR THE DESIGN RESTS ON ────────────────────────────────────
  // The camera-off glyph has shipped since Heroicons vendored it, so it is
  // the reference the new mic has to sit beside. Both in ONE row: a mic
  // that paints in isolation is not the claim being made.
  const slots = page
    .locator(MEDIA_SLOTS)
    .filter({ has: page.locator(`${MIC_INDICATOR}[data-mic-state="off"]`) })
    .first()
  await expect(slots).toBeVisible()

  const cameraWell = slots.locator('[role="img"][aria-label="Camera off"]').first()
  await expect(
    cameraWell,
    "the muted row does not also have its camera off, so this run never put " +
      "the two slash glyphs side by side and cannot speak to the pairing",
  ).toBeVisible()

  const cameraMask = await maskImageOf(cameraWell.locator("span").first())
  expect(
    cameraMask,
    "the ALREADY-SHIPPED camera-off glyph has no mask either, so this is an " +
      "asset-pipeline failure across the board rather than anything specific " +
      "to the new microphone-slash file",
  ).not.toBe("none")

  // Both wells are laid out, non-zero, and the same size: a mask that
  // resolves but paints into a zero box is still a blank indicator.
  for (const [name, box] of [
    ["mic", await micGlyph.boundingBox()],
    ["camera", await cameraWell.locator("span").first().boundingBox()],
  ] as const) {
    expect(box, `the ${name} glyph has no layout box`).not.toBeNull()
    expect(box!.width, `the ${name} glyph laid out at zero width`).toBeGreaterThan(0)
    expect(box!.height, `the ${name} glyph laid out at zero height`).toBeGreaterThan(0)
  }

  console.log(
    `[mute-glyph] mic mask ${micMask.slice(0, 48)}… camera mask ${cameraMask.slice(0, 48)}…`,
  )
})

/**
 * THE TOGGLE CASE (task 01a07486-7985-7001-87ce-277681791f52, FE-19 stage 4).
 *
 * WHAT IT ASSERTS AND WHY IT STOPS WHERE IT DOES. The claim the vendored
 * `microphone-slash.svg` makes is a GEOMETRY REUSE claim: it opens with a
 * byte-identical 138-character prefix of the shipped `microphone.svg`, so
 * swapping one mask for the other must not change the box the glyph paints
 * into. Width, height and y are therefore asserted equal across
 * unmuted -> muted -> unmuted, to within 0.5px. All three were measured at
 * 0.0000 delta.
 *
 * HORIZONTAL POSITION IS DELIBERATELY NOT ASSERTED HERE. When this case
 * was first measured (2026-09-06, branch head 0f872760) the glyph's x moved
 * on mute by a deterministic 7.8906px, and the cause was not this icon and
 * not anything in FE-19's diff:
 *
 *   `call_shell.ex` rendered a `.call-control-label` sibling whose text
 *   went "Mute" (28.625px) -> "Unmute" (44.422px), +15.797px. The
 *   `[data-component="call-controls"]` row is `flex justify-center` inside
 *   a box that stays x=240 w=872, so the row re-centred and every control
 *   left of centre slid half the widening: 15.797 / 2 = 7.899, which is the
 *   7.8906px observed. The same class also serves "Share" / "Stop sharing",
 *   whose swing is wider, so the naive `min-width` fix was wrong.
 *
 * That shift PRE-DATED this ticket and was filed as FE-20
 * (`01a0773e-cea9-7001-98f5-be6c37607e91`), which SHIPPED on main as #951
 * (08f1e7ad): every toggling label now reserves its widest word via
 * `toggling_label/1`, so on the tree this file lives in the x delta on mute
 * is expected to be ~0. It is still not asserted here, on purpose: x on
 * this row is a label-width invariant, and `call_control_label_swing.spec.ts`
 * and `call_control_geometry_gate.spec.ts` (FE-20) own it for every control
 * and both label pairs. An x assertion here would be a second, narrower copy
 * of that test that fails on a defect this test has no business owning.
 *
 * WHAT IS ASSERTED ABOUT x INSTEAD, because "unconstrained" must not mean
 * "unmeasured": the round trip must be REVERSIBLE. unmuted-1 and unmuted-2
 * must land on the same x (measured 0.0000 delta on all eight edges), so a
 * toggle that leaked a pixel of drift per cycle would still be caught. The
 * muted-state delta is logged, not asserted.
 *
 * ANTI-VACUITY. A width/height/y equality check passes trivially if the
 * button never actually toggled — three reads of one unchanged state agree
 * with each other perfectly. Two guards make that impossible to mistake for
 * a pass: the `aria-label` must flip, and the muted mask must DIFFER from
 * both unmuted masks. If the click is swallowed, those go red before any
 * geometry is compared.
 */

/** The call-shell mute button, by its declared selector contract
 *  (`meeting_live.html.heex:1483` passes `mic_role="meeting-mic"`). Stable
 *  across both states, unlike the class and unlike the aria-label. */
const MEETING_MIC_BUTTON = '[data-role="meeting-mic"]'

type GlyphBox = { x: number; y: number; width: number; height: number }

async function readGlyph(page: Page): Promise<{ mask: string; box: GlyphBox }> {
  // The glyph is the aria-hidden span; the other span is the text label.
  const glyph = page.locator(`${MEETING_MIC_BUTTON} span[aria-hidden="true"]`).first()
  const mask = await maskImageOf(glyph)
  const box = await glyph.evaluate((node) => {
    const r = (node as Element).getBoundingClientRect()
    return { x: r.x, y: r.y, width: r.width, height: r.height }
  })
  return { mask, box }
}

test("toggling mute swaps the mask without resizing or reflowing the glyph", async ({ page }) => {
  await openMeetingRoom(page)

  const button = page.locator(MEETING_MIC_BUTTON).first()
  await expect(
    button,
    `no mute button at /meetings/${MEETING_SLUG}. Run ` +
      `e2e/scripts/seed-meeting-mute-fixture.sh against the server's database ` +
      `first; this is a MISSING PRECONDITION, not a glyph regression.`,
  ).toBeVisible({ timeout: 30_000 })
  await expect(button).toHaveAttribute("aria-label", "Mute microphone")

  const unmuted1 = await readGlyph(page)

  await button.click()
  // The label flip is the proof the click landed. Without it the two reads
  // below are the same state twice and every equality assertion is vacuous.
  await expect(
    button,
    "the mute button never flipped to its muted state, so this run measured " +
      "one state three times and proves nothing about the toggle",
  ).toHaveAttribute("aria-label", "Unmute microphone", { timeout: 15_000 })
  const muted = await readGlyph(page)

  await button.click()
  await expect(button).toHaveAttribute("aria-label", "Mute microphone", { timeout: 15_000 })
  const unmuted2 = await readGlyph(page)

  // ── 1. ALL THREE PAINT ─────────────────────────────────────────────────
  for (const [name, read] of [
    ["unmuted-1", unmuted1],
    ["muted", muted],
    ["unmuted-2", unmuted2],
  ] as const) {
    expect(
      read.mask,
      `the ${name} mute-button glyph has NO mask image. For "muted" this is ` +
        "the FE-19 defect itself: hero-microphone-slash generating no CSS.",
    ).not.toBe("none")
    expect(read.mask.length, `the ${name} mask resolved to an empty value`).toBeGreaterThan(0)
  }

  // ── 2. THE MUTED BRANCH IS A DIFFERENT GLYPH ───────────────────────────
  // This is the anti-vacuity guard AND the substantive claim: the muted
  // branch is the one that resolved to nothing before this ticket.
  expect(
    muted.mask,
    "the muted state resolved to the SAME mask as the unmuted state, so the " +
      "button is painting a plain microphone at a muted user",
  ).not.toBe(unmuted1.mask)
  expect(muted.mask).not.toBe(unmuted2.mask)
  expect(
    unmuted2.mask,
    "unmuting did not restore the unmuted mask, so the toggle is not reversible",
  ).toBe(unmuted1.mask)

  // ── 3. GEOMETRY REUSE: w / h / y ONLY ──────────────────────────────────
  // The 0.5px tolerance is the criterion's, not a hedge: sub-pixel layout
  // rounding is real, a resize is not sub-pixel.
  const TOLERANCE = 0.5
  for (const [from, to, label] of [
    [unmuted1, muted, "unmuted-1 -> muted"],
    [muted, unmuted2, "muted -> unmuted-2"],
    [unmuted1, unmuted2, "unmuted-1 -> unmuted-2"],
  ] as const) {
    for (const edge of ["width", "height", "y"] as const) {
      expect(
        Math.abs(from.box[edge] - to.box[edge]),
        `${label}: the glyph's ${edge} changed by ` +
          `${Math.abs(from.box[edge] - to.box[edge]).toFixed(4)}px. The slashed ` +
          "path reuses the shipped microphone.svg geometry byte for byte, so " +
          "swapping the mask must not resize or reflow the box. Check that " +
          "assets/icons/24/outline/microphone-slash.svg still opens with the " +
          "same viewBox, stroke-width and 138-character prefix as " +
          "deps/heroicons/optimized/24/outline/microphone.svg.",
      ).toBeLessThanOrEqual(TOLERANCE)
    }
  }

  // ── 4. x: REVERSIBLE, NOT FIXED ────────────────────────────────────────
  // See the block comment above. The muted-state x delta was 7.89px before
  // FE-20 (01a0773e-cea9-7001-98f5-be6c37607e91, shipped as #951) and is
  // expected ~0 after it; either way it belongs to FE-20's specs, not here.
  // What must hold here is that a full toggle cycle leaves the glyph exactly
  // where it started.
  expect(
    Math.abs(unmuted1.box.x - unmuted2.box.x),
    "a mute/unmute round trip left the glyph at a different x, so the toggle " +
      "leaks horizontal drift. This is NOT the FE-20 label-width shift (fixed " +
      "in #951, and symmetric even before that, returning to zero over a full cycle).",
  ).toBeLessThanOrEqual(TOLERANCE)

  console.log(
    `[mute-glyph] w/h/y stable; x delta on mute ` +
      `${(muted.box.x - unmuted1.box.x).toFixed(4)}px ` +
      `(FE-20 01a0773e-cea9-7001-98f5-be6c37607e91 / #951 owns x; not asserted here)`,
  )
})
