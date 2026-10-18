/**
 * The meetings LAYOUT gate (task 01a064fa stage 2).
 *
 * WHY THIS FILE EXISTS. Three rounds of the meetings surface passed their
 * e2e gates and were rejected on sight by the sponsor. Every element the
 * approved canvas called for was PRESENT and every colour token was right —
 * they were wired into the WRONG PARENTS. The gates that passed were
 * PRESENCE checks, and a presence check passes perfectly on a screen that
 * reads as a different design.
 *
 * So: NOTHING here matches on text and NOTHING here matches on a class
 * name. `expect(ring).toHaveClass(/border-info/)` is the same species of
 * check as the one being replaced — it passes on a screen where the ring
 * floats at the row's right edge beside a bare avatar, which is exactly the
 * v1 defect. Every assertion resolves through `getBoundingClientRect()` or
 * DOM ancestry, and every measurement goes through
 * `tests/support/geometry.ts` so there is one implementation of each and it
 * cannot degrade into a class check in one spec.
 *
 * `data-role` / `data-component` / `data-activity-state` ARE used — to
 * locate an element and to read which state the server resolved. Those are
 * declared selector contracts, not presentation. A class name is never used
 * for either purpose.
 */

import { test, expect, Page } from "@playwright/test"
import {
  allRects,
  clippedBy,
  domOrder,
  fillsContainer,
  isAncestor,
  isBelow,
  rect,
  visibleRect,
  type Rect,
} from "./support/geometry"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"

/** The chat space the quickmeet is exercised in, and the meeting slug the
 *  `/meetings` surface is exercised on. Both are seeded by
 *  `e2e/scripts/seed-meeting-layout-fixture.sh`, which is the documented
 *  precondition for this spec. */
const CHAT_SPACE = process.env.GEOMETRY_CHAT_SPACE ?? "general"
const MEETING_SLUG = process.env.GEOMETRY_MEETING_SLUG ?? "geometry-gate"
const LOGIN_AS = process.env.GEOMETRY_LOGIN_AS ?? "alice"

const STAGE = '[data-role="call-stage"]'
const GRID = '[data-role="call-tile-grid"]'
const CONTROLS = '[data-component="call-controls"]'
const AGENT_ROW = '[data-participant-type="agent"]'
const AVATAR = '[data-role="agent-activity-avatar"]'
const FACE = '[data-role="agent-activity-face"]'
const RING = '[data-role="agent-activity-ring"]'
const GLYPH = '[data-role="agent-activity-glyph"]'
const RAIL_TAB = '[data-role="call-rail-tab"]'
const CANDIDATE_CARD = '[data-role="meeting-candidate-card"]'
const CANDIDATE_QUOTE = '[data-role="meeting-candidate-quote"]'
const CANDIDATE_ASSIGNMENT = '[data-role="meeting-candidate-assignment"]'

/** Set on the one laid-out candidate card under measurement. `domOrder`
 *  and `rect` both require a UNIQUE match by design, and every candidate
 *  marker appears once per breakpoint subtree — so a per-card probe
 *  attribute is what makes the shipped helpers usable here at all. */
const PROBE_ATTR = "data-geo-probe"

/** The `/meetings` header control that slides the off-canvas rail in below
 *  `lg`. The quickmeet has its own (`quickmeet-rail-toggle`, already handled
 *  in `QUICKMEET.open`); `/meetings` does not open its drawer on load. */
const CALL_RAIL_TOGGLE = '[data-role="call-rail-toggle"]' 

/**
 * ─── THE RIG PRECHECK ────────────────────────────────────────────────────
 *
 * The hive→moon rsync runs `--delete` and `priv/static` does not exist on
 * hive, so ANY source edit wipes the built assets on moon. `/assets/js/app.js`
 * then 404s, LiveView never connects, and the page renders with NO TILES AT
 * ALL — which reads exactly like the feature being missing and would fail
 * every assertion below for a reason that has nothing to do with layout.
 *
 * `mix assets.build` exits 1 on `mix esbuild excalidraw` while still writing
 * a serving bundle, so its exit code proves nothing. THE CURL DOES. This is
 * a `beforeAll` and not a note in a README precisely so a future run cannot
 * forget it.
 */
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
      `assets 404 — rig fault, not a layout failure. GET ${url} returned ${status}. ` +
        `The hive→moon rsync runs --delete and priv/static does not exist on hive, so a ` +
        `source edit wipes the built assets on moon; the page then renders with no tiles ` +
        `at all. Rebuild assets in the dev container and re-run. Do NOT read the ` +
        `assertions below as layout regressions until this returns 200.`,
    )
  }
})

async function login(page: Page): Promise<void> {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${LOGIN_AS}`)
  await page.waitForURL(/\/chat/, { timeout: 20_000 })
}

interface Surface {
  readonly name: string
  /** Navigate to the surface and get it into the state where the call
   *  shell — stage, grid, controls, rail — is on screen. */
  open(page: Page, viewportWidth: number): Promise<void>
  /** Whether the tile grid is expected to fill the stage's HEIGHT.
   *
   *  `/meetings` centre stage exists to hold the gallery and nothing else,
   *  so the grid fills it on both axes.
   *
   *  The quickmeet stage is a VERTICAL SCROLL COLUMN that also parents the
   *  screen-share slot, the hidden local self-view and the local-video
   *  dock. Its height is not the grid's to fill, and a height assertion
   *  there would be red on correct markup. This is a stated scope
   *  decision, not a loosened threshold: the WIDTH axis — which is the axis
   *  the v1 defect failed on (two participants at ~520px inside a ~745px
   *  stage, wide dead margins) — is asserted on BOTH surfaces. The measured
   *  quickmeet height ratio is PRINTED on every run so the number is on the
   *  record rather than hidden behind the skip. */
  readonly assertGridHeight: boolean
  /** `/meetings` gives each gallery tile a `[data-gallery-cell]` wrapper.
   *  The quickmeet's grid is `phx-update="ignore"` and its children are
   *  built by `meeting_client.js`, which emits NO cell marker — so the
   *  cell-union half of assertion 3 has nothing to measure there. An empty
   *  node list on the quickmeet is NOT a layout failure. Reaching into
   *  `meeting_client.js` to add a marker is out of scope: that region is
   *  JS-owned and stage 1 declined to touch it for the same reason. */
  readonly hasGalleryCells: boolean
}

const MEETINGS: Surface = {
  name: "meetings",
  assertGridHeight: true,
  hasGalleryCells: true,
  async open(page) {
    await page.goto(`/meetings/${MEETING_SLUG}`)
    await page.waitForSelector(STAGE, { timeout: 30_000 })
    await page.waitForSelector(`${AGENT_ROW} ${AVATAR}`, { timeout: 30_000 })
    await settle(page)
    console.log(
      `[prelude] meetings/${page.viewportSize()?.width} meeting_join=not-applicable ` +
        `railToggle=deferred(pressed only by the candidate-card case below lg)`,
    )
  },
}

const QUICKMEET: Surface = {
  name: "quickmeet",
  assertGridHeight: false,
  hasGalleryCells: false,
  async open(page, viewportWidth) {
    await page.goto(`/chat/${CHAT_SPACE}`)
    await page.waitForSelector("#meeting-client", { state: "attached", timeout: 30_000 })

    // NO RAIL EXISTS until `meeting_join` is clicked. A run before this is
    // a false "feature missing", and has already cost review cycles.
    // The button is in the static markup BEFORE LiveView connects, so a
    // click on a visible-but-unbound button is swallowed and the stage
    // never appears — which reads as "the feature is missing". Wait for the
    // socket, then click, and re-click once if the first one was lost.
    await page.waitForFunction(
      () => !!(window as any).liveSocket?.isConnected?.(),
      null,
      { timeout: 30_000 },
    )

    const join = page.locator('[phx-click="meeting_join"]').first()
    await expect(join).toBeVisible({ timeout: 15_000 })

    // BOTH breakpoint subtrees are in the document at all times — CSS, not
    // the server, picks which one is laid out. `waitForSelector` would
    // resolve on the FIRST match (the desktop pane) and then wait forever
    // for it to become visible at 390px, which reads as "the feature never
    // rendered". Wait for SOME stage to have a non-zero box instead.
    const stageLaidOut = () =>
      page.waitForFunction(
        (sel) =>
          Array.from(document.querySelectorAll(sel)).some((n) => {
            const r = n.getBoundingClientRect()
            return r.width > 0 && r.height > 0
          }),
        STAGE,
        { timeout: 15_000 },
      )

    await join.click()
    try {
      await stageLaidOut()
    } catch {
      if ((await join.count()) > 0 && (await join.isVisible())) {
        await join.click()
      }
      await stageLaidOut()
    }

    // Below `lg` the rail is a bottom sheet and stays closed until the
    // header toggle is pressed. Same trap, one breakpoint down.
    if (viewportWidth < 1024) {
      const toggle = page.locator('[data-role="quickmeet-rail-toggle"]')
      await expect(toggle).toBeVisible({ timeout: 15_000 })
      await toggle.click()
    }

    await page.waitForSelector(`${AGENT_ROW} ${AVATAR}`, { timeout: 30_000 })
    await settle(page)

    // ON THE RECORD. The two preludes below are the difference between a
    // measurement and a false "feature missing": no rail exists until
    // `meeting_join` is clicked, and below `lg` none is on screen until the
    // toggle is pressed. `measure-meeting-layout.sh` prints this line in its
    // verdict block so a reader can see the prelude RAN rather than trusting
    // that the caller remembered it.
    console.log(
      `[prelude] quickmeet/${viewportWidth} meeting_join=clicked railToggle=` +
        (viewportWidth < 1024 ? "clicked" : "not-needed(>=1024px)"),
    )
  },
}

/** Let LiveView finish patching and the browser finish laying out before
 *  anything is measured. A rect read mid-patch is a measurement of a
 *  transient, and reporting it either way would be noise. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(1500)
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
  )
}

const VIEWPORTS = [
  { label: "1280x800", width: 1280, height: 800 },
  { label: "390x844", width: 390, height: 844 },
]

/** The visible one of a set of duplicated elements, as a scoped selector
 *  prefix is not always available. Returns the index so callers can build a
 *  `:nth-of-type`-free unique reference through `allRects`. */
async function visibleIndex(page: Page, selector: string): Promise<number> {
  const rects = await allRects(page, selector)
  const idxs = rects
    .map((r, i) => [r, i] as const)
    .filter(([r]) => r.width > 0 && r.height > 0)
    .map(([, i]) => i)
  expect(
    idxs,
    `expected exactly one laid-out element for ${selector}; rects=${JSON.stringify(rects)}`,
  ).toHaveLength(1)
  return idxs[0]
}

function fmt(r: Rect): string {
  return `{l:${Math.round(r.left)} t:${Math.round(r.top)} r:${Math.round(r.right)} b:${Math.round(r.bottom)} w:${Math.round(r.width)} h:${Math.round(r.height)}}`
}

for (const surface of [MEETINGS, QUICKMEET]) {
  for (const vp of VIEWPORTS) {
    test.describe(`${surface.name} @ ${vp.label}`, () => {
      test.use({ viewport: { width: vp.width, height: vp.height } })

      /**
       * ─── ASSERTION 1 — RING PARENTAGE ──────────────────────────────────
       *
       * The approved canvas rings the AVATAR, with the glyph pinned in its
       * corner. v1 rendered an empty 16px ring floated to the ROW'S RIGHT
       * EDGE beside a bare avatar; "a ring exists" passed on both.
       */
      test("ring parentage: the ring wraps the face inside the avatar box", async ({
        page,
      }) => {
        await login(page)
        await surface.open(page, vp.width)

        const rowIds = await page.locator(AGENT_ROW).evaluateAll((ns) =>
          ns.map((n) => n.getAttribute("data-participant-id")),
        )

        // A vacuous pass on zero elements is the SAME failure mode as a
        // presence check. Fail loudly instead.
        expect(
          rowIds.length,
          "no agent rows to measure — seed the fixture (e2e/scripts/seed-meeting-layout-fixture.sh) " +
            "before reading this run. Zero rows is a rig state, not a passing layout.",
        ).toBeGreaterThan(0)

        const statesSeen: string[] = []

        for (const id of rowIds) {
          const row = `${AGENT_ROW}[data-participant-id="${id}"]`
          const avatarSel = `${row} ${AVATAR}`
          const faceSel = `${row} ${FACE}`
          const ringSel = `${row} ${RING}`
          const glyphSel = `${row} ${GLYPH}`

          const state = await page
            .locator(avatarSel)
            .getAttribute("data-activity-state")
          statesSeen.push(String(state))

          // (a) ANCESTRY. Face and ring are co-located INSIDE the avatar
          //     box — not siblings strung along a row.
          expect(
            await isAncestor(page, avatarSel, faceSel),
            `${id}: the face is not a descendant of the avatar wrapper`,
          ).toBe(true)
          expect(
            await isAncestor(page, avatarSel, ringSel),
            `${id}: the ring is not a descendant of the avatar wrapper — this is ` +
              `the v1 defect exactly (ring floated to the row's trailing edge)`,
          ).toBe(true)

          // (b) GEOMETRY. "Wrapped around" as a measurement: the ring's
          //     rect CONTAINS the face's on all four edges, within 4px.
          //     This is what fails when the ring is moved to the row's end
          //     even if some ancestor still happens to contain both.
          const faceR = await rect(page, faceSel)
          const ringR = await rect(page, ringSel)
          const overflow = clippedBy(faceR, ringR)
          const worst = Math.max(
            overflow.top,
            overflow.right,
            overflow.bottom,
            overflow.left,
          )
          console.log(
            `[ring-parentage] ${surface.name}/${vp.label} row=${id} state=${state} ` +
              `ring=${fmt(ringR)} face=${fmt(faceR)} ` +
              `faceOutsideRing=${JSON.stringify(overflow)} worst=${worst.toFixed(1)} tol=4`,
          )
          expect(
            worst,
            `${id}: the face is not contained by the ring — ring=${fmt(ringR)} face=${fmt(faceR)} overflow=${JSON.stringify(overflow)}`,
          ).toBeLessThanOrEqual(4)

          // (c) THE GLYPH. `:idle` renders no glyph, and its ABSENCE is
          //     asserted rather than the row skipped — otherwise "idle
          //     renders nothing at all" passes silently.
          const glyphCount = await page.locator(glyphSel).count()
          if (state === "idle") {
            expect(
              glyphCount,
              `${id}: idle must render NO glyph; found ${glyphCount}`,
            ).toBe(0)
          } else {
            expect(
              glyphCount,
              `${id}: state ${state} must render a glyph`,
            ).toBe(1)
            const glyphR = await rect(page, glyphSel)
            // Overlaps the face's BOTTOM-RIGHT quadrant.
            const qx = faceR.left + faceR.width / 2
            const qy = faceR.top + faceR.height / 2
            const overlapW = Math.min(glyphR.right, faceR.right) - Math.max(glyphR.left, qx)
            const overlapH = Math.min(glyphR.bottom, faceR.bottom) - Math.max(glyphR.top, qy)
            console.log(
              `[ring-glyph] ${surface.name}/${vp.label} row=${id} state=${state} ` +
                `glyph=${fmt(glyphR)} faceBRQuadrant={l:${Math.round(qx)} t:${Math.round(qy)} ` +
                `r:${Math.round(faceR.right)} b:${Math.round(faceR.bottom)}} ` +
                `overlap=${overlapW.toFixed(1)}x${overlapH.toFixed(1)}`,
            )
            expect(overlapW, `${id}: glyph does not overlap the face's right half`).toBeGreaterThan(0)
            expect(overlapH, `${id}: glyph does not overlap the face's bottom half`).toBeGreaterThan(0)
          }
        }

        // ON THE RECORD, on every run: which states this run actually
        // exercised. The three non-idle states have IN-MEMORY-ONLY
        // producers (`IntentQueue` for `:computing`, a transient PubSub
        // broadcast for `:typing`, a queue terminal for `:failed`) and the
        // dev container's serving BEAM runs with no Erlang distribution, so
        // they cannot be seeded from outside the node. A run that saw only
        // `idle` has NOT exercised the glyph-overlap branch, and printing
        // that is the difference between a known gap and a silent one.
        console.log(
          `[ring-parentage] ${surface.name}/${vp.label} rows=${rowIds.length} ` +
            `statesExercised=${JSON.stringify([...new Set(statesSeen)])}`,
        )
      })

      /**
       * ─── ASSERTION 2 — CONTROLS PLACEMENT ──────────────────────────────
       *
       * The canvas puts a centred controls bar UNDER the stage; v1 had them
       * in the header, overflowing, with Leave clipped on the quickmeet.
       */
      test("controls placement: centred, below the stage, and unclipped", async ({
        page,
      }) => {
        await login(page)
        await surface.open(page, vp.width)

        // `visibleRect`, NOT `rect`. Each control exists TWICE in the
        // quickmeet DOM (a hidden `lg`-only copy and the mobile copy);
        // measuring the hidden one returns a zero rect that passes every
        // containment test there is. The full rect list is printed so the
        // disambiguation is SHOWN to have fired rather than assumed.
        const controlsRects = await allRects(page, CONTROLS)
        console.log(
          `[controls] ${surface.name}/${vp.label} allControlsRects=${JSON.stringify(
            controlsRects.map((r) => fmt(r)),
          )}`,
        )
        const controlsR = await visibleRect(page, CONTROLS)
        const stageR = await visibleRect(page, STAGE)

        // (a) BELOW the stage.
        const delta = controlsR.top - stageR.bottom
        console.log(
          `[controls-below] ${surface.name}/${vp.label} controls.top=${controlsR.top.toFixed(1)} ` +
            `stage.bottom=${stageR.bottom.toFixed(1)} delta=${delta >= 0 ? "+" : ""}${delta.toFixed(1)} tol=0`,
        )
        expect(
          isBelow(controlsR, stageR, 0),
          `controls are not below the stage — controls=${fmt(controlsR)} stage=${fmt(stageR)}. ` +
            `A negative delta means the bar is still in the header, which is the v1 defect.`,
        ).toBe(true)

        // (b) CENTRED on the stage, within 8px. Fails on a left- or
        //     right-packed bar even when the bar is correctly below.
        const controlsCx = controlsR.left + controlsR.width / 2
        const stageCx = stageR.left + stageR.width / 2
        const cxDelta = Math.abs(controlsCx - stageCx)
        console.log(
          `[controls-centred] ${surface.name}/${vp.label} controls.cx=${controlsCx.toFixed(1)} ` +
            `stage.cx=${stageCx.toFixed(1)} delta=${cxDelta.toFixed(1)} tol=8`,
        )
        expect(
          cxDelta,
          `controls are not centred on the stage — controls=${fmt(controlsR)} stage=${fmt(stageR)}`,
        ).toBeLessThanOrEqual(8)

        // (c) At 390px, no control may be clipped — by the VIEWPORT or by
        //     THE PANEL THAT PARENTS THE BAR. The v1 failure was Leave cut
        //     off by the PANEL's right edge while still inside the
        //     viewport, so a viewport-only check reproduces the original
        //     miss. The panel is defined by DOM ancestry (the bar's parent
        //     element), not by a class or an id, so it survives a rename.
        if (vp.width < 1024) {
          const idx = await visibleIndex(page, CONTROLS)
          const panelR = (await page.evaluate(
            ({ sel, i }) => {
              const el = document.querySelectorAll(sel)[i] as HTMLElement
              const p = el.parentElement as HTMLElement
              const r = p.getBoundingClientRect()
              return {
                x: r.x, y: r.y, width: r.width, height: r.height,
                top: r.top, right: r.right, bottom: r.bottom, left: r.left,
              }
            },
            { sel: CONTROLS, i: idx },
          )) as Rect
          const viewportR: Rect = {
            x: 0, y: 0, width: vp.width, height: vp.height,
            top: 0, left: 0, right: vp.width, bottom: vp.height,
          }

          const buttons = await page.evaluate(
            ({ sel, i }) => {
              const el = document.querySelectorAll(sel)[i] as HTMLElement
              return Array.from(el.querySelectorAll("button")).map((b) => {
                const r = b.getBoundingClientRect()
                return {
                  // `data-role` LOCATES and LABELS; it is never matched
                  // against an expected string. NOTE: the roles here are
                  // the surface's own overrides (`meeting-mic`,
                  // `meeting-camera`, `meeting-screen-share` /
                  // `meeting-share-button`, `meeting-leave`) — the
                  // `call-control-*` defaults on `call_controls/1` are
                  // never rendered by either surface.
                  role: b.getAttribute("data-role"),
                  rect: {
                    x: r.x, y: r.y, width: r.width, height: r.height,
                    top: r.top, right: r.right, bottom: r.bottom, left: r.left,
                  },
                }
              })
            },
            { sel: CONTROLS, i: idx },
          )

          expect(
            buttons.length,
            "the visible control bar rendered no buttons — rig state, not a layout result",
          ).toBeGreaterThan(0)

          for (const b of buttons) {
            const vClip = clippedBy(b.rect as Rect, viewportR)
            const pClip = clippedBy(b.rect as Rect, panelR)
            console.log(
              `[controls-clip] ${surface.name}/${vp.label} btn=${b.role} rect=${fmt(b.rect as Rect)} ` +
                `panel=${fmt(panelR)} viewportOverflow=${JSON.stringify(vClip)} ` +
                `panelOverflow=${JSON.stringify(pClip)}`,
            )
            expect(
              [vClip.top, vClip.right, vClip.bottom, vClip.left],
              `${b.role} is clipped by the VIEWPORT — rect=${fmt(b.rect as Rect)}`,
            ).toEqual([0, 0, 0, 0])
            expect(
              [pClip.top, pClip.right, pClip.bottom, pClip.left],
              `${b.role} is clipped by the PANEL — rect=${fmt(b.rect as Rect)} panel=${fmt(panelR)}. ` +
                `This is the v1 failure: Leave cut off by the panel's right edge while still ` +
                `inside the viewport.`,
            ).toEqual([0, 0, 0, 0])
          }
        }
      })

      /**
       * ─── ASSERTION 3 — GRID FILL ───────────────────────────────────────
       *
       * v1 put two participants at ~520px inside a ~745px stage, with wide
       * dead margins and no ghost cell.
       *
       * THE TOLERANCE IS DERIVED, NOT GUESSED. It is the stage's OWN
       * padding, read from `getComputedStyle` at capture time: a grid that
       * fills its stage is inset exactly by the stage's padding, so the
       * expected deficit per axis is `padding-start + padding-end` and
       * anything beyond that is dead margin. A hardcoded 40px would have
       * passed the measured v1 case at some viewports — 745-520=225 is
       * caught, but the same defect on a 560px stage is a 40px deficit and
       * would have slipped through. The derivation is printed on every run.
       */
      test("grid fill: the tile grid spans the stage minus its own padding", async ({
        page,
      }) => {
        await login(page)
        await surface.open(page, vp.width)

        const stageIdx = await visibleIndex(page, STAGE)
        const pad = (await page.evaluate(
          ({ sel, i }) => {
            const el = document.querySelectorAll(sel)[i] as HTMLElement
            const cs = getComputedStyle(el)
            return {
              left: parseFloat(cs.paddingLeft),
              right: parseFloat(cs.paddingRight),
              top: parseFloat(cs.paddingTop),
              bottom: parseFloat(cs.paddingBottom),
            }
          },
          { sel: STAGE, i: stageIdx },
        )) as { left: number; right: number; top: number; bottom: number }

        const tolX = pad.left + pad.right
        const tolY = pad.top + pad.bottom
        const stageR = await visibleRect(page, STAGE)
        const gridR = await visibleRect(page, GRID)
        const dx = stageR.width - gridR.width
        const dy = stageR.height - gridR.height

        console.log(
          `[grid-fill] ${surface.name}/${vp.label} stage=${fmt(stageR)} grid=${fmt(gridR)} ` +
            `stagePadding={l:${pad.left} r:${pad.right} t:${pad.top} b:${pad.bottom}} ` +
            `tolX=${tolX}(=padLeft+padRight) tolY=${tolY}(=padTop+padBottom) ` +
            `widthDeficit=${dx.toFixed(1)} heightDeficit=${dy.toFixed(1)} ` +
            `heightAxisAsserted=${surface.assertGridHeight}`,
        )

        expect(
          dx,
          `the grid leaves ${dx.toFixed(1)}px of dead horizontal margin inside the stage, ` +
            `but the stage's own padding accounts for only ${tolX}px. ` +
            `stage=${fmt(stageR)} grid=${fmt(gridR)}`,
        ).toBeLessThanOrEqual(tolX)

        if (surface.assertGridHeight) {
          expect(
            dy,
            `the grid leaves ${dy.toFixed(1)}px of dead vertical margin inside the stage, ` +
              `but the stage's own padding accounts for only ${tolY}px. ` +
              `stage=${fmt(stageR)} grid=${fmt(gridR)}`,
          ).toBeLessThanOrEqual(tolY)
        }

        // The union of the CELLS covers the grid — what catches cells that
        // shrink inside a grid that itself stretches. Scoped to `/meetings`
        // because the quickmeet's grid is `phx-update="ignore"` and
        // `meeting_client.js` emits no cell marker; an empty node list
        // there is a JS-ownership fact, not a layout failure.
        if (surface.hasGalleryCells) {
          const cells = await allRects(page, "[data-gallery-cell]")
          expect(
            cells.length,
            "no [data-gallery-cell] on /meetings — rig state (no participants rendered), " +
              "not a passing layout",
          ).toBeGreaterThan(0)
          const union: Rect = cells.reduce((u, c) => {
            const left = Math.min(u.left, c.left)
            const top = Math.min(u.top, c.top)
            const right = Math.max(u.right, c.right)
            const bottom = Math.max(u.bottom, c.bottom)
            return {
              x: left, y: top, left, top, right, bottom,
              width: right - left, height: bottom - top,
            }
          })
          console.log(
            `[grid-cells] ${surface.name}/${vp.label} cells=${cells.length} ` +
              `union=${fmt(union)} grid=${fmt(gridR)} ` +
              `widthDeficit=${(gridR.width - union.width).toFixed(1)} ` +
              `heightDeficit=${(gridR.height - union.height).toFixed(1)} tolX=${tolX} tolY=${tolY}`,
          )
          expect(
            fillsContainer(union, gridR, Math.max(tolX, tolY)),
            `the union of ${cells.length} cell rect(s) does not cover the grid — ` +
              `union=${fmt(union)} grid=${fmt(gridR)}`,
          ).toBe(true)
        }
      })

      /**
       * ─── ASSERTION 4 — CANDIDATE CARD READING ORDER ────────────────────
       *
       * The assignment must sit BELOW the evidence quote. Flipped, the card
       * reads as though the assignee is who SPOKE — the authorship
       * confusion this component was fixed twice to remove.
       *
       * WHY THIS EXISTS ALONGSIDE THE EXUNIT TEST RATHER THAN INSTEAD OF
       * IT. `candidate_rail_test.exs` catches a TEMPLATE inversion and
       * catches it on every push, which is a cycle earlier than review.
       * This case catches the failure mode ExUnit structurally cannot see:
       * a CSS `order:` or a `flex-col-reverse` that inverts the VISUAL
       * order while leaving the DOM correct. The card body is one utility
       * class away from that, so the two assertions below are deliberately
       * both made — DOM order AND painted geometry — and neither is
       * redundant with the other.
       */
      test("candidate card: the assignment renders below the evidence quote", async ({
        page,
      }) => {
        await login(page)
        await surface.open(page, vp.width)

        // Below `lg` the rail is an OFF-CANVAS drawer: the tab strip is in
        // the document with a non-zero box (so Playwright calls it
        // `:visible`) but sits outside the viewport behind a
        // `translate-x-full`, and the click retries until the test times
        // out — a rig failure that reads as the tab not existing. Open the
        // drawer first, at the same breakpoint the quickmeet needs its own
        // toggle at.
        // `QUICKMEET.open` already presses its own
        // `quickmeet-rail-toggle`; `/meetings` has a different control and
        // does not open its drawer on load.
        if (surface.name === "meetings" && vp.width < 1024) {
          const railToggle = page.locator(CALL_RAIL_TOGGLE)
          await expect(railToggle).toBeVisible({ timeout: 15_000 })
          await railToggle.click()
          await settle(page)
        }

        // `:visible`, not `.first()`. Both breakpoint subtrees carry the
        // tab strip at all times and `.first()` would resolve to the hidden
        // copy.
        await page.locator(`${RAIL_TAB}[data-tab="canvas"]:visible`).first().click()
        await settle(page)

        // Mark the LAID-OUT card that renders both markers. Both
        // breakpoint subtrees are in the document at all times, so a
        // document-wide selector matches the hidden copy too — and a
        // hidden copy's rect is all zeroes, which passes every geometry
        // test there is. `domOrder`/`visibleRect` require a UNIQUE match,
        // so the probe attribute is what makes them usable per card.
        const probed = (await page.evaluate(
          ({ cardSel, quoteSel, assignSel, probeAttr }) => {
            const seen: string[] = []
            for (const card of Array.from(document.querySelectorAll(cardSel))) {
              card.removeAttribute(probeAttr)
              const r = card.getBoundingClientRect()
              const has =
                !!card.querySelector(quoteSel) && !!card.querySelector(assignSel)
              seen.push(
                `${card.getAttribute("data-candidate-id") ?? "?"}:` +
                  `laidOut=${r.width > 0 && r.height > 0}:bothMarkers=${has}`,
              )
              if (r.width > 0 && r.height > 0 && has) {
                card.setAttribute(probeAttr, "1")
                return { found: true, id: card.getAttribute("data-candidate-id"), seen }
              }
            }
            return { found: false, id: null, seen }
          },
          {
            cardSel: CANDIDATE_CARD,
            quoteSel: CANDIDATE_QUOTE,
            assignSel: CANDIDATE_ASSIGNMENT,
            probeAttr: PROBE_ATTR,
          },
        )) as { found: boolean; id: string | null; seen: string[] }

        console.log(
          `[card-order] ${surface.name}/${vp.label} probed=${probed.id ?? "none"} ` +
            `cards=[${probed.seen.join(", ")}]`,
        )

        // A SKIP, STATED, NOT A SILENT PASS. Today the populated card
        // renders its evidence quote as `meeting-candidate-title` and has
        // no `meeting-candidate-quote` element at all; only the `:skeleton`
        // branch spells it that way, and the skeleton carries no
        // assignment. Stage 4 of task `01a05b14` gives the populated card
        // the quote line and moves the assignment to the card's last line,
        // at which point this stops skipping. The card list is printed
        // above either way, so a skip is a reported measurement rather than
        // a green tick over nothing.
        test.skip(
          !probed.found,
          "no laid-out candidate card renders BOTH [data-role=meeting-candidate-quote] " +
            "and [data-role=meeting-candidate-assignment] — this becomes assertable when " +
            "task 01a05b14 stage 4 lands the quote line on the populated card. " +
            `cards=[${probed.seen.join(", ")}]`,
        )

        const quoteSel = `[${PROBE_ATTR}] ${CANDIDATE_QUOTE}`
        const assignSel = `[${PROBE_ATTR}] ${CANDIDATE_ASSIGNMENT}`

        const order = await domOrder(page, quoteSel, assignSel)
        const quoteR = await rect(page, quoteSel)
        const assignR = await rect(page, assignSel)

        console.log(
          `[card-order] ${surface.name}/${vp.label} domOrder(quote,assignment)=${order} ` +
            `quote=${fmt(quoteR)} assignment=${fmt(assignR)}`,
        )

        expect(
          order,
          `the assignment must FOLLOW the evidence quote in the DOM, got ` +
            `domOrder(quote, assignment)=${order} on card ${probed.id}`,
        ).toBe("before")

        // The separate failure mode: a `flex-col-reverse` or a CSS
        // `order:` paints the assignment above the quote while the DOM
        // still reads correctly, and the assertion above stays green.
        // Zero tolerance — these are stacked block siblings, so any
        // overlap at all is the inversion, not a rounding artefact.
        expect(
          isBelow(assignR, quoteR, 0),
          `the assignment is PAINTED above the evidence quote — DOM order is ` +
            `${order} but assignment.top=${assignR.top.toFixed(1)} is not at or below ` +
            `quote.bottom=${quoteR.bottom.toFixed(1)}. A CSS order/flex-direction ` +
            `inversion is invisible to the DOM-order assertion above. ` +
            `quote=${fmt(quoteR)} assignment=${fmt(assignR)}`,
        ).toBe(true)
      })
    })
  }
}


/**
 * ═══════════════════════════════════════════════════════════════════════
 * THE SAFE-AREA GATE (task 01a0776a-4c11-7001-ae00-507fadebf462 stage 2)
 * ═══════════════════════════════════════════════════════════════════════
 *
 * WHY THESE CASES EXIST, AND WHY THEY ARE NOT VACUOUS.
 *
 * Headless Chromium resolves `env(safe-area-inset-bottom)` to 0. Every
 * assertion taken at the default inset is taken WHERE THE BUG CANNOT
 * APPEAR, which is precisely how this defect survived: three separate
 * comments in this repo (`apps/platform/assets/css/app.css` at the
 * `video-tile` container query, `video_tile_test.exs`,
 * `meeting_live_test.exs`) record the surface as untestable in a browser
 * rather than testing it.
 *
 * `Emulation.setSafeAreaInsetsOverride` changes the value `env()` resolves
 * to. It does NOT change the expression, so the arithmetic under test stays
 * the arithmetic the template ships. A stand-in custom property, a rewritten
 * padding rule or a synthetic `--inset` variable would test the rewrite
 * instead of the template, and is deliberately not used here.
 *
 * THE INSTRUMENT IS PROVED BEFORE EVERY MEASUREMENT. `readInsetProbe`
 * puts an element styled `height: env(safe-area-inset-bottom)` on the page
 * and measures it. If a future Chromium drops or renames the CDP command,
 * the send resolves without effect, `env()` still reads 0, and every
 * assertion below would then be taken on a page where the broken build
 * passes. The probe is what converts that silent instrument failure into a
 * red case. It is asserted in BOTH directions, 34 after the override and 0
 * without it, because a probe that reads 34 unconditionally is no
 * instrument either.
 *
 * THE TRAP THAT WOULD MAKE ALL FOUR PASS ON NOTHING. `@current_stage_mode`
 * defaults to `:gallery` and the footer carries
 * `:if={@current_stage_mode != :gallery}`, so on a freshly opened meeting
 * THE FOOTER IS NOT IN THE DOM. `openCanvasStage` clicks
 * `[data-stage-mode-button="canvas"]` and waits for the strip; a selector
 * that resolves to zero elements throws through `visibleRect`/`rect`
 * rather than skipping, and `markFirstStripTile` fails loudly on zero
 * tiles the way the `rowIds.length` guards above do.
 *
 * THE EXPECTED NUMBERS, AND WHY 96 AND 120 ARE NOT A CONTRADICTION. The
 * footer's shell branch reserves NO inset below `lg` (the shell's
 * `.bottom-nav` rail is the bottom-most element there and already carries
 * `padding-bottom: env(safe-area-inset-bottom)`; reserving it twice would
 * open a dead band) and DOES add the inset to its height at `lg` and
 * above, where that rail is `display:none` and the footer is bottom-most.
 * So at 390x844 the footer's own height is expected to STAY 96 under an
 * injected inset, and at 1280x800 it is expected to GROW by exactly the
 * inset off a 120 baseline. Two breakpoints, two different correct
 * answers. Each case names its breakpoint in its title for that reason.
 *
 * What must not move at either breakpoint is the TILE. The strip tile is
 * `aspect-video h-full`, so its width is derived from the footer's content
 * box; on the broken build the inset is eaten out of that content box and
 * the tile collapses from 140.44x79 to 80x45 at 390x844.
 */

const BOTTOM_STRIP = '[data-pane="bottom-strip"]'
const STAGE_MODE_CANVAS = '[data-stage-mode-button="canvas"]'
const VIDEO_TILE = "[data-meeting-video-tile]"
const TILE_NAME = '[data-role="tile-name"]'

/** Marks the first laid-out strip tile. `rect()` requires a UNIQUE match by
 *  design and the strip holds one tile per participant, so a per-tile probe
 *  attribute is what makes the shipped helper usable here: the same device
 *  the candidate-card case above uses, for the same reason. */
const TILE_PROBE_ATTR = "data-safe-area-tile"
const TILE_PROBE = `[${TILE_PROBE_ATTR}]`

/** The iOS home-indicator inset. Burrow mobile is an installed PWA, so this
 *  is the ordinary case on a phone, not an edge one. */
const INJECTED_INSET = 34

/** Measured on the fixed build, one browser, both breakpoints. Border-box
 *  sizing: the content box is the footer height less `pt-2`, `pb-2` and the
 *  1px top border, and the `aspect-video` tile takes its width from that. */
const MOBILE_FOOTER_H = 96
const MOBILE_TILE_H = 79
const MOBILE_TILE_W = 140.4
const DESKTOP_FOOTER_H = 120
const DESKTOP_TILE_H = 103

/** The `@container video-tile (max-width: 120px)` threshold in `app.css`
 *  that hides `[data-role="tile-name"]`. Read here, never written: this
 *  spec measures against that constant and does not own it. */
const NAME_HIDE_THRESHOLD = 120

/** Every geometry assertion in this block is a two-sided window, in px. */
const TOL = 1

const INSET_PROBE_ID = "safe-area-inset-probe"

/**
 * Put the env() probe on the page and measure it.
 *
 * The element is appended to `document.body`, OUTSIDE the LiveView root
 * container, so a morphdom patch cannot remove it mid-run. `height:
 * env(safe-area-inset-bottom)` with no fallback is deliberate: if `env()`
 * were unsupported the declaration would be invalid, the empty div would
 * lay out at 0, and the injected-inset assertion would go red, which is
 * the correct direction for an instrument that cannot see.
 */
async function readInsetProbe(page: Page): Promise<number> {
  return (await page.evaluate((id) => {
    let el = document.getElementById(id)
    if (!el) {
      el = document.createElement("div")
      el.id = id
      el.style.cssText =
        "position:fixed;left:0;bottom:0;width:1px;opacity:0;pointer-events:none;" +
        "height:env(safe-area-inset-bottom);"
      document.body.appendChild(el)
    }
    return el.getBoundingClientRect().height
  }, INSET_PROBE_ID)) as number
}

/** Apply the real safe-area inset. Chromium-only, and typed by the pinned
 *  protocol definitions, so a rename in a future Playwright fails at
 *  `tsc --noEmit` rather than at runtime. A rename on the BROWSER side
 *  resolves silently, which is what the probe catches. */
async function injectSafeAreaInset(page: Page, bottom: number): Promise<void> {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send("Emulation.setSafeAreaInsetsOverride", {
    insets: { bottom, bottomMax: bottom },
  })
  await settle(page)
}

/**
 * Open the meeting and put it in a stage mode that HAS a bottom strip.
 *
 * Two failure modes this exists to avoid, both of which read exactly like
 * "the gate is broken": the footer is gated out of the DOM in the default
 * `:gallery` mode, and a click sent before LiveView connects lands in a
 * static DOM and dies silently. Wait for the socket, click, and re-click
 * once if the first one was lost. Same shape as `QUICKMEET.open`.
 */
async function openCanvasStage(page: Page): Promise<void> {
  await page.goto(`/meetings/${MEETING_SLUG}`)
  await page.waitForSelector(STAGE, { timeout: 30_000 })
  await page.waitForFunction(
    () => !!(window as any).liveSocket?.isConnected?.(),
    null,
    { timeout: 30_000 },
  )

  const canvasButton = page.locator(`${STAGE_MODE_CANVAS}:visible`).first()
  await expect(
    canvasButton,
    `the canvas stage-mode control is missing. Without it the footer never enters ` +
      `the DOM (it carries :if={@current_stage_mode != :gallery}) and every ` +
      `measurement below would be taken on nothing.`,
  ).toBeVisible({ timeout: 15_000 })

  await canvasButton.click()
  try {
    await page.waitForSelector(BOTTOM_STRIP, { timeout: 15_000 })
  } catch {
    await canvasButton.click()
    await page.waitForSelector(BOTTOM_STRIP, { timeout: 15_000 })
  }
  await settle(page)
}

/**
 * Tag the first laid-out tile in the strip and report how many there were.
 *
 * ZERO TILES IS A RIG STATE, NOT A PASSING LAYOUT. A hidden or absent tile
 * has an all-zero rect, and a zero rect satisfies every containment test
 * there is, so the count is asserted by the caller before any number below
 * is read.
 */
async function markFirstStripTile(page: Page): Promise<number> {
  return (await page.evaluate(
    ({ stripSel, tileSel, attr }) => {
      for (const stale of Array.from(document.querySelectorAll(`[${attr}]`))) {
        stale.removeAttribute(attr)
      }
      const tiles = Array.from(
        document.querySelectorAll(`${stripSel} ${tileSel}`),
      ).filter((t) => {
        const r = t.getBoundingClientRect()
        return r.width > 0 && r.height > 0
      })
      if (tiles.length > 0) tiles[0].setAttribute(attr, "1")
      return tiles.length
    },
    { stripSel: BOTTOM_STRIP, tileSel: VIDEO_TILE, attr: TILE_PROBE_ATTR },
  )) as number
}

/** Mark, guard the count, and hand back the first tile's rect. */
async function firstStripTileRect(page: Page): Promise<Rect> {
  const tileCount = await markFirstStripTile(page)
  expect(
    tileCount,
    `no laid-out ${VIDEO_TILE} inside ${BOTTOM_STRIP}. Seed the meeting fixture ` +
      `(the room must be status:"active" or get_active_room/1 returns nil and the ` +
      `strip renders empty) before reading this run. Zero tiles is a rig state, ` +
      `not a passing layout.`,
  ).toBeGreaterThan(0)
  return await rect(page, TILE_PROBE)
}

/** The computed `display` of the name bar inside the marked tile. Read
 *  through `getComputedStyle`, never off a class list: the container query
 *  that hides it lives in the stylesheet and no class changes when it
 *  fires. */
async function markedTileNameDisplay(page: Page): Promise<string> {
  return (await page.evaluate(
    ({ probeSel, nameSel }) => {
      const tile = document.querySelector(probeSel)
      if (!tile) return "NO-MARKED-TILE"
      const name = tile.querySelector(nameSel)
      if (!name) return "NO-NAME-ELEMENT"
      return getComputedStyle(name).display
    },
    { probeSel: TILE_PROBE, nameSel: TILE_NAME },
  )) as string
}

test.describe("meeting bottom strip: safe-area inset @ 390x844", () => {
  test.use({ viewport: { width: 390, height: 844 } })

  /**
   * ─── CASE 1 · THE INJECTED INSET, MOBILE ──────────────────────────────
   *
   * The whole ticket in one measurement. On the broken build the fixed
   * `h-[96px]` swallows the inset inside its own padding, the content box
   * drops from 79px to 45px, and the `aspect-video` tile narrows from
   * 140.44px to 80px. On the fixed build the tile is untouched.
   *
   * The footer's OWN height staying at 96 is intended, not a miss: below
   * `lg` the shell's `.bottom-nav` is bottom-most and already reserves the
   * inset once.
   */
  test("case 1: a 34px inset leaves the strip tile full size (footer stays 96)", async ({
    page,
  }) => {
    await login(page)
    await openCanvasStage(page)

    await injectSafeAreaInset(page, INJECTED_INSET)

    const probe = await readInsetProbe(page)
    expect(
      probe,
      `the CDP safe-area override did not land: an element styled ` +
        `height:env(safe-area-inset-bottom) measured ${probe}, not ${INJECTED_INSET}. ` +
        `Emulation.setSafeAreaInsetsOverride resolved without effect, so every ` +
        `measurement below would be taken at inset 0, where the broken build ` +
        `passes. This is an INSTRUMENT failure, not a layout failure.`,
    ).toBeCloseTo(INJECTED_INSET, 1)

    const footR = await visibleRect(page, BOTTOM_STRIP)
    const tileR = await firstStripTileRect(page)

    console.log(
      `[safe-area] 390x844 inset=${probe} footer=${fmt(footR)} tile=${fmt(tileR)}`,
    )

    expect(
      Math.abs(tileR.height - MOBILE_TILE_H) <= TOL,
      `the strip tile's height collapsed under the inset: ${tileR.height.toFixed(2)}, ` +
        `expected ${MOBILE_TILE_H} +/- ${TOL}. This is the defect: the inset was eaten ` +
        `out of the footer's content box instead of extending the footer. ` +
        `tile=${fmt(tileR)} footer=${fmt(footR)}`,
    ).toBe(true)

    expect(
      Math.abs(tileR.width - MOBILE_TILE_W) <= TOL,
      `the strip tile's width collapsed under the inset: ${tileR.width.toFixed(2)}, ` +
        `expected ${MOBILE_TILE_W} +/- ${TOL}. The tile is aspect-video h-full, so its ` +
        `width follows the footer's content-box height. tile=${fmt(tileR)}`,
    ).toBe(true)

    expect(
      Math.abs(footR.height - MOBILE_FOOTER_H) <= TOL,
      `the footer's own height is ${footR.height.toFixed(2)}, expected ` +
        `${MOBILE_FOOTER_H} +/- ${TOL}. Below lg the shell's .bottom-nav already ` +
        `reserves the inset, so the footer must NOT reserve it a second time. ` +
        `A footer at ${MOBILE_FOOTER_H + INJECTED_INSET} here is the dead-band ` +
        `alternative this fix deliberately rejected. footer=${fmt(footR)}`,
    ).toBe(true)
  })

  /**
   * ─── CASE 2 · THE CONTROL, MOBILE ─────────────────────────────────────
   *
   * GREEN ON BOTH THE FIXED AND THE REVERTED BUILD, DELIBERATELY. This is
   * the control half of the mutation contract: its job is to show that
   * case 1 fails FOR THE INSET and not for some unrelated change to the
   * page. If this ever goes red the rig or the fixture moved and no other
   * case in this block can be trusted.
   *
   * It also asserts the probe reads 0 with no override, which is the other
   * half of the instrument check: a probe that reported 34
   * unconditionally would make case 1 pass on a browser that ignores the
   * command.
   */
  test("case 2 (control): at inset 0 the footer is 96 and the tile is full size", async ({
    page,
  }) => {
    await login(page)
    await openCanvasStage(page)

    const probe = await readInsetProbe(page)
    expect(
      probe,
      `expected env(safe-area-inset-bottom) to resolve to 0 with no override applied, ` +
        `got ${probe}. A non-zero reading here means an override leaked in from ` +
        `another case and this control is measuring something else.`,
    ).toBeCloseTo(0, 1)

    const footR = await visibleRect(page, BOTTOM_STRIP)
    const tileR = await firstStripTileRect(page)

    console.log(
      `[safe-area] 390x844 inset=${probe} (control) footer=${fmt(footR)} tile=${fmt(tileR)}`,
    )

    expect(
      Math.abs(footR.height - MOBILE_FOOTER_H) <= TOL,
      `control footer height ${footR.height.toFixed(2)}, expected ${MOBILE_FOOTER_H} ` +
        `+/- ${TOL}. footer=${fmt(footR)}`,
    ).toBe(true)
    expect(
      Math.abs(tileR.height - MOBILE_TILE_H) <= TOL,
      `control tile height ${tileR.height.toFixed(2)}, expected ${MOBILE_TILE_H} ` +
        `+/- ${TOL}. tile=${fmt(tileR)}`,
    ).toBe(true)
    expect(
      Math.abs(tileR.width - MOBILE_TILE_W) <= TOL,
      `control tile width ${tileR.width.toFixed(2)}, expected ${MOBILE_TILE_W} ` +
        `+/- ${TOL}. tile=${fmt(tileR)}`,
    ).toBe(true)
  })

  /**
   * ─── CASE 4 · THE USER-VISIBLE LOSS ───────────────────────────────────
   *
   * Asserted separately from case 1's geometry because it is the
   * consequence a person actually sees. `@container video-tile (max-width:
   * 120px)` hides `[data-role="tile-name"]`, so on the broken build a real
   * phone inset shrinks the tile to 80px, the query fires, and EVERY
   * participant name in the strip disappears.
   *
   * The display is read through `getComputedStyle`. No class changes when
   * a container query fires, so a class assertion could not see this at
   * all.
   */
  test("case 4: under a 34px inset the tile stays above the name-hide threshold", async ({
    page,
  }) => {
    await login(page)
    await openCanvasStage(page)

    await injectSafeAreaInset(page, INJECTED_INSET)

    const probe = await readInsetProbe(page)
    expect(
      probe,
      `the CDP safe-area override did not land (probe measured ${probe}, expected ` +
        `${INJECTED_INSET}). Instrument failure, not a layout failure.`,
    ).toBeCloseTo(INJECTED_INSET, 1)

    const tileR = await firstStripTileRect(page)
    const nameDisplay = await markedTileNameDisplay(page)

    console.log(
      `[safe-area] 390x844 inset=${probe} tile=${fmt(tileR)} tileName.display=${nameDisplay}`,
    )

    expect(
      tileR.width,
      `the strip tile is ${tileR.width.toFixed(2)}px wide under a ${INJECTED_INSET}px ` +
        `inset, at or below the ${NAME_HIDE_THRESHOLD}px container-query threshold in ` +
        `app.css. tile=${fmt(tileR)}`,
    ).toBeGreaterThan(NAME_HIDE_THRESHOLD)

    expect(
      nameDisplay,
      `[data-role="tile-name"] computed display is ${nameDisplay} under a ` +
        `${INJECTED_INSET}px inset. The container query fired because the tile ` +
        `collapsed to ${tileR.width.toFixed(2)}px, which is the user-visible loss ` +
        `this ticket names: every participant name in the strip disappears on a ` +
        `real phone.`,
    ).not.toBe("none")
    // Both sentinels are asserted away. `firstStripTileRect` above already
    // throws on zero tiles and on a non-unique marker, but a morphdom patch
    // between the two reads could drop the attribute, and a sentinel string
    // satisfies `not.toBe("none")` perfectly. A measurement that cannot fail
    // is not a measurement.
    expect(
      ["NO-MARKED-TILE", "NO-NAME-ELEMENT"],
      `expected to measure a real name element inside the marked tile, got ` +
        `"${nameDisplay}". A missing tile or a missing name element would make ` +
        `the display assertion above unfalsifiable.`,
    ).not.toContain(nameDisplay)
  })
})

test.describe("meeting bottom strip: safe-area inset @ 1280x800", () => {
  test.use({ viewport: { width: 1280, height: 800 } })

  /**
   * ─── CASE 3 · THE FOOTER GROWS, DESKTOP ───────────────────────────────
   *
   * At this width the shell's `.bottom-nav` is `display:none`, so the
   * footer IS the bottom-most element and the inset is added to its
   * height. The opposite expectation to case 1, at the other breakpoint,
   * and both are correct.
   *
   * TWO CLAUSES, NOT ONE. Asserting only the tile size would let a fix
   * that keeps the tile by shrinking something ELSE inside the footer pass,
   * so the footer's own delta is asserted as its own clause. Both are
   * measured on ONE page, before and after the override, which is what
   * makes the delta a delta rather than a comparison across two runs that
   * could differ for any reason.
   */
  test("case 3: a 34px inset grows the footer by exactly 34 and leaves the tiles alone", async ({
    page,
  }) => {
    await login(page)
    await openCanvasStage(page)

    const probe0 = await readInsetProbe(page)
    expect(
      probe0,
      `expected env(safe-area-inset-bottom) to be 0 before the override, got ${probe0}.`,
    ).toBeCloseTo(0, 1)

    const foot0 = await visibleRect(page, BOTTOM_STRIP)
    const tile0 = await firstStripTileRect(page)

    await injectSafeAreaInset(page, INJECTED_INSET)

    const probe34 = await readInsetProbe(page)
    expect(
      probe34,
      `the CDP safe-area override did not land: the probe measured ${probe34}, not ` +
        `${INJECTED_INSET}. Both measurements would then be taken at inset 0, the ` +
        `delta below would be 0 on the FIXED build too, and the case would be ` +
        `asserting nothing. Instrument failure, not a layout failure.`,
    ).toBeCloseTo(INJECTED_INSET, 1)

    const foot34 = await visibleRect(page, BOTTOM_STRIP)
    const tile34 = await firstStripTileRect(page)

    const delta = foot34.height - foot0.height
    console.log(
      `[safe-area] 1280x800 h0=${foot0.height.toFixed(2)} h34=${foot34.height.toFixed(2)} ` +
        `delta=${delta.toFixed(2)} tile0=${fmt(tile0)} tile34=${fmt(tile34)}`,
    )

    expect(
      Math.abs(foot0.height - DESKTOP_FOOTER_H) <= TOL,
      `baseline footer height ${foot0.height.toFixed(2)}, expected ${DESKTOP_FOOTER_H} ` +
        `+/- ${TOL}. Every clause below is a delta off this number, so a wrong ` +
        `baseline makes them meaningless. footer=${fmt(foot0)}`,
    ).toBe(true)

    expect(
      Math.abs(delta - INJECTED_INSET) <= TOL,
      `the footer grew by ${delta.toFixed(2)}px under a ${INJECTED_INSET}px inset, ` +
        `expected ${INJECTED_INSET} +/- ${TOL}. A delta of 0 is the broken build: the ` +
        `inset was consumed inside a fixed height instead of extending it. ` +
        `h0=${foot0.height.toFixed(2)} h34=${foot34.height.toFixed(2)}`,
    ).toBe(true)

    expect(
      Math.abs(tile0.height - DESKTOP_TILE_H) <= TOL,
      `baseline tile height ${tile0.height.toFixed(2)}, expected ${DESKTOP_TILE_H} ` +
        `+/- ${TOL} (${DESKTOP_FOOTER_H} - 8 pt - 8 pb - 1 border). tile=${fmt(tile0)}`,
    ).toBe(true)

    expect(
      Math.abs(tile34.height - DESKTOP_TILE_H) <= TOL,
      `the tile row is ${tile34.height.toFixed(2)}px tall under the inset, expected ` +
        `${DESKTOP_TILE_H} +/- ${TOL}. The growth must land in the FOOTER, not come ` +
        `out of the tiles. tile=${fmt(tile34)}`,
    ).toBe(true)

    expect(
      Math.abs(tile34.width - tile0.width) <= TOL,
      `the tile width moved from ${tile0.width.toFixed(2)} to ${tile34.width.toFixed(2)} ` +
        `under the inset. The tile is aspect-video, so a width change means the ` +
        `content box moved even though the height clause passed.`,
    ).toBe(true)
  })
})
