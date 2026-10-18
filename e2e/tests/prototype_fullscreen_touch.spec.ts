/**
 * Prototype fullscreen overlay under a press on iPhone (task 01a1389f).
 *
 * THE REPORT. On an iPhone PWA, a prototype canvas put into the in-app
 * fullscreen overlay (PR #1236) falls behind the chat while a finger is down
 * on it: chat rows, the header and the composer show through or over it.
 *
 * THE HYPOTHESIS UNDER TEST. The overlay is the PrototypeFrame root restyled
 * in place to `fixed inset-0 z-50` (prototype_frame.ex). It still sits inside
 * its chat row, and `.message-row-inner` (chat_message.ex) carries
 * `active:scale-[0.99]`. While the row is `:active`, that scale makes the
 * row the containing block AND a stacking context for every `position: fixed`
 * descendant, so the "fullscreen" box collapses to the row's box, is clipped
 * by `#chat-message-scroller`, and its z-50 only counts inside the row.
 *
 * WHAT THIS ASSERTS, and why each piece is here:
 *
 *   1. FIVE-POINT HIT TEST, not a class check. `document.elementFromPoint` at
 *      the four viewport corners (8px inset) and the centre must land on the
 *      fullscreen frame root or inside it (an iframe hit counts: the iframe is
 *      a descendant). This is the measurable form of "nothing of the chat is
 *      visible over the prototype". A class or computed `position` check
 *      would pass on the broken build, because the classes are right and only
 *      the containing block is wrong.
 *
 *   2. THE ROOT'S RECT EQUALS THE VIEWPORT. A trapped root reports the row's
 *      box. The hit test alone could pass by luck if a trapped box happened to
 *      cover the five points; the rect cannot.
 *
 *   3. A HELD PRESS, as close as Playwright gets. Playwright has no held-touch
 *      API (`touchscreen.tap` is down+up) and a synthetic `touchstart` does
 *      not set `:active`, so the held press is `mouse.down()` held >= 600ms,
 *      which WebKit does turn into `:active`. Two presses: (i) on the
 *      prototype's own `#hold` button INSIDE the iframe (what the report
 *      describes) and (ii) on the bar's version stamp, a PARENT-document
 *      element. Whether (i) puts the parent row into `:active` at all is an
 *      open question this spec measures and logs (`rowActive`); it is not
 *      assumed in either direction.
 *
 *   4. A FORCED-TRANSFORM STRUCTURAL PROBE. `row.style.transform =
 *      'scale(0.99)'` on the enclosing `.message-row-inner`, and then the
 *      individual `scale: 0.99` property, which is what `:active` actually
 *      applies (Tailwind v4 compiles `active:scale-[0.99]` to `scale`, not
 *      `transform`; both make the row a containing block), minus the input
 *      model. It isolates the containment
 *      question from "does a press reach :active" and is deterministic. Its
 *      own positive control runs first: the same five points and rect with NO
 *      transform must pass, or a failure under the transform would mean
 *      nothing.
 *
 *   5. NO RELOAD. The overlay is a restyle of the existing tree, so the
 *      iframe must never reload: a parent-side capture-phase `load` listener
 *      counts iframe loads inside `[data-role=prototype-canvas]`, and the
 *      count must not move across enter, hold, release and exit.
 *
 * WHY THE ELEMENT FULLSCREEN API IS REMOVED BEFORE THE PAGE LOADS. iPhone
 * Safari has no Fullscreen API for non-video elements; that is the reason the
 * in-app overlay exists (prototype_fullscreen.js). Linux WebKit may expose
 * one. If it does and the hook takes the native path, the element goes to the
 * browser's top layer, which no ancestor transform can trap, and every probe
 * here would pass for a reason an iPhone never has. So the init script records
 * what the engine exposed (`__nativeFullscreenBeforeStub`, logged) and then
 * removes it, leaving the hook on the overlay path an iPhone takes.
 *
 * HONEST LIMIT. This is Linux WebKit under an iPhone descriptor, not iOS
 * Safari. It can show that the containing-block trap exists in WebKit and
 * that a mouse-held press reaches it; the touch input model on a real device
 * is confirmed only on the device.
 *
 * Stage 1 recorded this spec RED on the unfixed tree (positive control for
 * the fix). STAGE 2's FIX: the PrototypeFullscreen hook promotes the frame
 * root to the browser top layer (`popover="manual"` + showPopover()), whose
 * containing block is the viewport whatever an ancestor's transform; the
 * render keeps every conditional sibling after the keyed room element, so
 * morphdom never re-appends it (the reload). Two probes here exist only to
 * keep the TOP LAYER honest: app.css also neutralises the row's transform
 * and scale while a prototype in it is fullscreen (the iOS < 17 fallback),
 * which on its own would turn the forced-row probes green. So:
 *
 *   6. `:popover-open` is asserted on entry, and the forced-transform probe
 *      is repeated on the root's PARENT element, an ancestor the CSS
 *      fallback does not touch. Only the top layer survives that one.
 *   7. A LiveView patch while fullscreen (a message posted by the second
 *      member, and a version-menu toggle that re-renders the component root)
 *      must leave the popover open, its attribute in place, and the iframe
 *      unreloaded: the attribute is a client-side sticky set through the
 *      hook's js() API, and stripping it from an open popover would hide it.
 *
 * Seed the fixture first, in the dev container, from apps/platform:
 *   mix run priv/scripts/seed_prototype_fullscreen_fixture.exs
 * It prints SPACE_SLUG= and USER_SLUG=; pass them as FIXTURE_SPACE_SLUG and
 * FIXTURE_USER_SLUG. Runs only under the `webkit-iphone` project.
 */

import { test, expect, Browser, Page, TestInfo } from "@playwright/test"
import * as fs from "fs"
import * as path from "path"

const SPACE_SLUG = process.env.FIXTURE_SPACE_SLUG ?? ""
const USER_SLUG = process.env.FIXTURE_USER_SLUG ?? "protofs-a"
const SECOND_SLUG = process.env.FIXTURE_SECOND_SLUG ?? "protofs-b"
/**
 * DIAGNOSTIC ONLY, unset in every normal run. Each knob removes one half of
 * the stage-2 fix so a run can show which half carries which probe (the
 * positive controls behind the header's point 6):
 *   no-popover       delete HTMLElement.prototype.showPopover before load:
 *                    the hook stays on the plain overlay (iOS < 17 path).
 *   no-css-fallback  delete app.css's `.message-row-inner:has(...)` rule
 *                    after load: only the top layer stands between the row's
 *                    scale and the overlay.
 * MEASURED (stage 2, test-host, Linux WebKit): no-css-fallback passes all six
 * tests, so the top layer alone escapes the row's scale. no-popover fails
 * only the `:popover-open` assertions and the parent-element probe (0/5
 * inside, rect 237.5/73.5/389x652); its row probes, held presses, close tap
 * and both exits pass on the CSS fallback and the render-order fix.
 */
const DIAG = process.env.PROTO_FS_DIAG ?? ""
/** Optional: also copy every screenshot here (outside test-results). */
const SHOT_DIR = process.env.PROTO_FS_SHOT_DIR ?? ""

const ROOT = '[data-role="prototype-canvas"]'
const ROOT_FS = '[data-role="prototype-canvas"][data-fullscreen="true"]'
const HOLD_MS = 700
/** `transition-all duration-200` on the row: wait past it before measuring. */
const SETTLE_MS = 450
const RECT_TOLERANCE_PX = 1

interface Hit {
  point: string
  x: number
  y: number
  inside: boolean
  target: string
}

interface Probe {
  label: string
  found: boolean
  hits: Hit[]
  rect: { top: number; left: number; width: number; height: number }
  viewport: { width: number; height: number }
  rectIsViewport: boolean
  /** Computed `transform`. Tailwind v4 `scale-*` does NOT write this. */
  rowTransform: string
  /** Computed individual `scale` / `translate` / `rotate` properties: what
   *  Tailwind v4's `active:scale-[0.99]` actually writes. Each of these, like
   *  `transform`, makes the row a containing block for fixed descendants. */
  rowScale: string
  rowTranslate: string
  rowRotate: string
  rowInlineTransform: string
  /** Every element matching `:active` at probe time, outermost first. */
  activeChain: string[]
  rowActive: boolean
  rowFound: boolean
  loads: number
  /** The root matches `:popover-open` (it is in the top layer). */
  popoverOpen: boolean
  popoverAttr: string | null
}

declare global {
  interface Window {
    __protoLoads: number
    __protoLoadTimes: number[]
    __protoEvents: { type: string; t: number; target: string; rowScale: string; rowActive: boolean }[]
    __nativeFullscreenBeforeStub: Record<string, string>
  }
}

async function installInitScript(page: Page) {
  if (DIAG === "no-popover") {
    await page.addInitScript(() => {
      try {
        Object.defineProperty(HTMLElement.prototype, "showPopover", {
          value: undefined,
          configurable: true,
        })
      } catch (_) {}
    })
  }
  await page.addInitScript(() => {
    // Runs in every frame; only the top document counts, and only iframes
    // inside a prototype canvas.
    window.__protoLoads = 0
    window.__protoLoadTimes = []
    document.addEventListener(
      "load",
      (e) => {
        const t = e.target as Element | null
        if (t && t.tagName === "IFRAME" && t.closest && t.closest('[data-role="prototype-canvas"]')) {
          window.__protoLoads += 1
          window.__protoLoadTimes.push(Math.round(performance.now()))
        }
      },
      true,
    )

    // Diagnostics, top document only. (1) Every iframe insertion/removal under
    // a prototype canvas: a morphdom MOVE of the iframe's ancestor detaches
    // and reattaches it, which reloads it, and is indistinguishable from a
    // reload in the load counter alone. (2) Input events with the row's
    // scale and :active state AT the event, so a refused tap can be traced
    // to the target the engine actually hit.
    window.__protoEvents = []
    if (window.top === window) {
      const tag = (el: Element | null) =>
        !el
          ? "(null)"
          : `${el.tagName.toLowerCase()}${el.id ? "#" + el.id.slice(0, 40) : ""}${
              el.getAttribute("data-role") ? "[" + el.getAttribute("data-role") + "]" : ""
            }`
      const rowState = () => {
        const root = document.querySelector('[data-role="prototype-canvas"]')
        const row = root && root.closest(".message-row-inner")
        return {
          rowScale: row ? getComputedStyle(row).getPropertyValue("scale") : "(no row)",
          rowActive: row ? row.matches(":active") : false,
        }
      }
      for (const type of ["touchstart", "touchend", "mousedown", "mouseup", "click"]) {
        document.addEventListener(
          type,
          (e) => {
            window.__protoEvents.push({
              type,
              t: Math.round(performance.now()),
              target: tag(e.target as Element),
              ...rowState(),
            })
          },
          true,
        )
      }
      new MutationObserver((records) => {
        for (const r of records) {
          for (const [kind, nodes] of [
            ["iframe-added", r.addedNodes],
            ["iframe-removed", r.removedNodes],
          ] as const) {
            nodes.forEach((n) => {
              if (!(n instanceof Element)) return
              const hasFrame = n.tagName === "IFRAME" || !!n.querySelector("iframe")
              if (hasFrame) {
                window.__protoEvents.push({
                  type: kind,
                  t: Math.round(performance.now()),
                  target: `${tag(n)} under ${tag(r.target as Element)}`,
                  ...rowState(),
                })
              }
            })
          }
        }
      }).observe(document, { childList: true, subtree: true })
    }

    const ep = Element.prototype as unknown as Record<string, unknown>
    window.__nativeFullscreenBeforeStub = {
      requestFullscreen: typeof ep.requestFullscreen,
      webkitRequestFullscreen: typeof ep.webkitRequestFullscreen,
      fullscreenEnabled: String((document as unknown as Record<string, unknown>).fullscreenEnabled),
      webkitFullscreenEnabled: String(
        (document as unknown as Record<string, unknown>).webkitFullscreenEnabled,
      ),
    }
    // iPhone: no element Fullscreen API. See the header.
    for (const name of ["requestFullscreen", "webkitRequestFullscreen"]) {
      try {
        Object.defineProperty(Element.prototype, name, { value: undefined, configurable: true })
      } catch (_) {}
    }
    for (const name of ["fullscreenEnabled", "webkitFullscreenEnabled"]) {
      try {
        Object.defineProperty(Document.prototype, name, { get: () => false, configurable: true })
      } catch (_) {}
    }
  })
}

async function openSpace(page: Page) {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await installInitScript(page)
  await page.goto(`/dev/login?as=${USER_SLUG}`)
  await page.waitForURL("**/chat**", { timeout: 20_000 })
  await page.goto(`/chat/${SPACE_SLUG}`)
  await page.waitForFunction(
    () => !!(window as unknown as { liveSocket?: { isConnected?: () => boolean } }).liveSocket?.isConnected?.(),
    null,
    { timeout: 20_000 },
  )
  await expect(page.locator(ROOT).first()).toBeAttached({ timeout: 20_000 })
  // The iframe has loaded at least once and the count has stopped moving.
  // The dead render and the connected LiveView render each mount an iframe,
  // and the second load can land seconds after the socket connects, so a
  // fixed short wait reads a baseline the page has not finished producing.
  await page.waitForFunction(() => window.__protoLoads >= 1, null, { timeout: 20_000 })
  let last = await loads(page)
  for (let quiet = 0, n = 0; quiet < 6 && n < 60; n++) {
    await page.waitForTimeout(500)
    const now = await loads(page)
    quiet = now === last ? quiet + 1 : 0
    last = now
  }
  if (DIAG === "no-css-fallback") {
    const removed = await page.evaluate(() => {
      let n = 0
      const walk = (rules: CSSRuleList, owner: { deleteRule(i: number): void }) => {
        for (let i = rules.length - 1; i >= 0; i--) {
          const r = rules[i] as CSSRule & { selectorText?: string; cssRules?: CSSRuleList }
          if (r.selectorText && r.selectorText.includes(".message-row-inner:has(")) {
            owner.deleteRule(i)
            n++
          } else if (r.cssRules) {
            walk(r.cssRules, r as unknown as { deleteRule(i: number): void })
          }
        }
      }
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          walk(sheet.cssRules, sheet)
        } catch (_) {}
      }
      return n
    })
    console.log(`[diag] no-css-fallback: removed ${removed} rule(s)`)
    expect(removed, "diagnostic could not find the app.css fallback rule").toBeGreaterThan(0)
  }
  if (DIAG) console.log(`[diag] PROTO_FS_DIAG=${DIAG}`)
  await logEvents(page, "settled after mount")
  console.log(
    `[native-fullscreen-before-stub] ${JSON.stringify(
      await page.evaluate(() => window.__nativeFullscreenBeforeStub),
    )}`,
  )
}

async function loads(page: Page): Promise<number> {
  return page.evaluate(() => window.__protoLoads)
}

/** Drain and log the diagnostic event log (see the init script). */
async function logEvents(page: Page, label: string) {
  const events = await page.evaluate(() => window.__protoEvents.splice(0))
  console.log(
    `[events] ${label}: loads=${await loads(page)} times=${JSON.stringify(
      await page.evaluate(() => window.__protoLoadTimes),
    )} ${JSON.stringify(events)}`,
  )
}

async function enterFullscreen(page: Page) {
  const button = page.locator('[data-role="prototype-fullscreen"]').first()
  await button.scrollIntoViewIfNeeded()
  await button.tap()
  await expect(page.locator(ROOT_FS)).toHaveCount(1, { timeout: 10_000 })
  await page.waitForTimeout(SETTLE_MS)
  await logEvents(page, "enter fullscreen")
  expect
    .soft(await isPopoverOpen(page), "the fullscreen root is not in the top layer (:popover-open)")
    .toBe(true)
}

async function isPopoverOpen(page: Page): Promise<boolean> {
  return page.evaluate((rootFs) => {
    const root = document.querySelector(rootFs)
    try {
      return !!root && root.matches(":popover-open")
    } catch (_) {
      return false
    }
  }, ROOT_FS)
}

/** After an exit: inline again, out of the top layer, attribute gone. */
async function expectInline(page: Page) {
  const state = await page.evaluate((rootSel) => {
    const root = document.querySelector(rootSel)!
    let open = false
    try {
      open = root.matches(":popover-open")
    } catch (_) {}
    return { fs: root.getAttribute("data-fullscreen"), popover: root.getAttribute("popover"), open }
  }, ROOT)
  console.log(`[inline] ${JSON.stringify(state)}`)
  expect.soft(state, "after exit the frame is not back inline").toEqual({
    fs: "false",
    popover: null,
    open: false,
  })
}

/** The five-point hit test, the root rect and the row's transform state. */
async function probe(page: Page, label: string): Promise<Probe> {
  const result = await page.evaluate(
    ({ label, rootFs, tol }) => {
      const describe = (el: Element | null): string => {
        if (!el) return "(null)"
        const id = el.id ? `#${el.id}` : ""
        const cls =
          typeof el.className === "string" && el.className
            ? "." + el.className.trim().split(/\s+/).slice(0, 3).join(".")
            : ""
        const role = el.getAttribute("data-role")
        const near = el.closest("[data-role]")?.getAttribute("data-role")
        const rowish = el.closest(".message-row-inner") ? " in:.message-row-inner" : ""
        return `${el.tagName.toLowerCase()}${id}${cls}${role ? `[${role}]` : ""}${
          near && near !== role ? ` near:${near}` : ""
        }${rowish}`
      }

      const root = document.querySelector(rootFs)
      const row = root ? root.closest(".message-row-inner") : null
      const w = window.innerWidth
      const h = window.innerHeight
      const i = 8
      const points: [string, number, number][] = [
        ["top-left", i, i],
        ["top-right", w - i, i],
        ["bottom-left", i, h - i],
        ["bottom-right", w - i, h - i],
        ["centre", w / 2, h / 2],
      ]
      const hits = points.map(([point, x, y]) => {
        const el = document.elementFromPoint(x, y)
        return { point, x, y, inside: !!root && !!el && root.contains(el), target: describe(el) }
      })
      const r = root ? root.getBoundingClientRect() : { top: NaN, left: NaN, width: NaN, height: NaN }
      return {
        label,
        found: !!root,
        hits,
        rect: { top: r.top, left: r.left, width: r.width, height: r.height },
        viewport: { width: w, height: h },
        rectIsViewport:
          Math.abs(r.top) <= tol &&
          Math.abs(r.left) <= tol &&
          Math.abs(r.width - w) <= tol &&
          Math.abs(r.height - h) <= tol,
        rowFound: !!row,
        rowTransform: row ? getComputedStyle(row).transform : "(no row)",
        rowScale: row ? getComputedStyle(row).getPropertyValue("scale") : "(no row)",
        rowTranslate: row ? getComputedStyle(row).getPropertyValue("translate") : "(no row)",
        rowRotate: row ? getComputedStyle(row).getPropertyValue("rotate") : "(no row)",
        activeChain: Array.from(document.querySelectorAll(":active")).map(describe),
        rowInlineTransform: row ? (row as HTMLElement).style.transform : "(no row)",
        rowActive: row ? row.matches(":active") : false,
        loads: window.__protoLoads,
        popoverOpen: (() => {
          try {
            return !!root && root.matches(":popover-open")
          } catch (_) {
            return false
          }
        })(),
        popoverAttr: root ? root.getAttribute("popover") : null,
      }
    },
    { label, rootFs: ROOT_FS, tol: RECT_TOLERANCE_PX },
  )
  console.log(`[measure] ${JSON.stringify(result)}`)
  return result
}

/** Soft-assert a probe so every probe in a test is measured and reported. */
function expectCovers(p: Probe) {
  expect.soft(p.found, `${p.label}: no fullscreen frame root in the DOM`).toBe(true)
  for (const hit of p.hits) {
    expect
      .soft(
        hit.inside,
        `${p.label}: elementFromPoint(${hit.point} ${hit.x},${hit.y}) hit ${hit.target}, ` +
          `outside the fullscreen frame root, so chat is on top of the prototype there`,
      )
      .toBe(true)
  }
  expect
    .soft(
      p.rectIsViewport,
      `${p.label}: frame root rect ${JSON.stringify(p.rect)} is not the viewport ` +
        `${JSON.stringify(p.viewport)} (row transform: ${p.rowTransform}, scale: ${p.rowScale})`,
    )
    .toBe(true)
}

async function shot(page: Page, testInfo: TestInfo, name: string) {
  const file = testInfo.outputPath(`${name}.png`)
  await page.screenshot({ path: file })
  await testInfo.attach(name, { path: file, contentType: "image/png" })
  if (SHOT_DIR) {
    fs.mkdirSync(SHOT_DIR, { recursive: true })
    fs.copyFileSync(file, path.join(SHOT_DIR, `${name}.png`))
  }
}

async function heldPress(
  page: Page,
  testInfo: TestInfo,
  name: string,
  x: number,
  y: number,
  releaseAt?: { x: number; y: number },
) {
  await page.mouse.move(x, y)
  await page.mouse.down()
  // Probed at once and after the 200ms transition as well as mid-hold: any
  // non-`none` scale (even the transition's first frame, `scale: 1`) already
  // makes the row a containing block, and `:active` can clear before 700ms,
  // so a mid-hold probe alone can miss a trap the finger did produce.
  const early = await probe(page, `${name} at press`)
  await page.waitForTimeout(250)
  const settled = await probe(page, `${name} +250ms`)
  await page.waitForTimeout(HOLD_MS - 250)
  const mid = await probe(page, `${name} mid-hold`)
  await shot(page, testInfo, `${name}-mid-hold`)
  // Moving off the target before release makes the click land on the common
  // ancestor (the bar), which has no handler, so the release does not toggle
  // the version list underneath the measurement.
  if (releaseAt) await page.mouse.move(releaseAt.x, releaseAt.y)
  await page.mouse.up()
  await page.waitForTimeout(SETTLE_MS)
  await logEvents(page, `${name} press+release`)
  const after = await probe(page, `${name} after release`)
  await shot(page, testInfo, `${name}-after-release`)
  return { early, settled, mid, after }
}

test.describe("prototype fullscreen overlay under a press (webkit-iphone)", () => {
  test.skip(!SPACE_SLUG, "FIXTURE_SPACE_SLUG not set — seed the fixture first")

  test("a held press INSIDE the prototype iframe leaves the overlay covering the viewport", async ({
    page,
  }, testInfo) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)
    expect.soft(await loads(page), "entering fullscreen reloaded the iframe").toBe(baseline)

    const before = await probe(page, "iframe-press before press")
    expectCovers(before)
    await shot(page, testInfo, "iframe-press-before")

    const box = await page.frameLocator(`${ROOT_FS} iframe`).locator("#hold").boundingBox()
    expect(box, "the prototype's #hold button has no box inside the fullscreen iframe").not.toBeNull()
    const cx = box!.x + box!.width / 2
    const cy = box!.y + box!.height / 2
    console.log(`[press] iframe #hold centre at ${cx},${cy} box=${JSON.stringify(box)}`)

    const { early, settled, mid, after } = await heldPress(page, testInfo, "iframe-press", cx, cy)
    console.log(
      `[active] press inside iframe: parent row :active at press/+250/mid-hold = ` +
        `${early.rowActive}/${settled.rowActive}/${mid.rowActive}`,
    )
    expectCovers(early)
    expectCovers(settled)
    expectCovers(mid)
    expectCovers(after)
    expect.soft(await loads(page), "a held press reloaded the iframe").toBe(baseline)
  })

  test("a held press on the bar's version stamp leaves the overlay covering the viewport", async ({
    page,
  }, testInfo) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)
    expect.soft(await loads(page), "entering fullscreen reloaded the iframe").toBe(baseline)

    const stamp = await page.locator(`${ROOT_FS} [data-role="prototype-version-stamp"]`).boundingBox()
    const title = await page.locator(`${ROOT_FS} [data-role="prototype-title"]`).boundingBox()
    expect(stamp, "no version stamp in the fullscreen bar").not.toBeNull()
    expect(title, "no title in the fullscreen bar").not.toBeNull()

    const { early, settled, mid, after } = await heldPress(
      page,
      testInfo,
      "stamp-press",
      stamp!.x + stamp!.width / 2,
      stamp!.y + stamp!.height / 2,
      { x: title!.x + Math.min(10, title!.width / 2), y: title!.y + title!.height / 2 },
    )
    console.log(
      `[active] press on stamp: parent row :active at press/+250/mid-hold = ` +
        `${early.rowActive}/${settled.rowActive}/${mid.rowActive}`,
    )
    expectCovers(early)
    expectCovers(settled)
    expectCovers(mid)
    expectCovers(after)
    expect.soft(await loads(page), "a held press reloaded the iframe").toBe(baseline)
  })

  test("structural probe: a scale(0.99) on the enclosing row cannot trap the overlay", async ({
    page,
  }, testInfo) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)

    // Positive control: with no transform the overlay covers the viewport. If
    // this fails, the forced-transform result below means nothing.
    const control = await probe(page, "forced-transform control (no transform)")
    expect(control.rowFound, "the frame root has no enclosing .message-row-inner").toBe(true)
    expectCovers(control)

    await page.evaluate((rootFs) => {
      const row = document.querySelector(rootFs)!.closest(".message-row-inner") as HTMLElement
      row.style.transform = "scale(0.99)"
    }, ROOT_FS)
    await page.waitForTimeout(SETTLE_MS)
    const forced = await probe(page, "forced-transform scale(0.99)")
    await shot(page, testInfo, "forced-transform")
    expectCovers(forced)

    await page.evaluate((rootFs) => {
      const row = document.querySelector(rootFs)!.closest(".message-row-inner") as HTMLElement
      row.style.transform = ""
    }, ROOT_FS)
    await page.waitForTimeout(SETTLE_MS)

    // The same probe through the INDIVIDUAL `scale` property, because that is
    // what the row's `active:scale-[0.99]` compiles to under Tailwind v4
    // (`&:active { scale: 0.99 }` in the built app.css), not `transform`. A
    // fix that resets only `transform` passes the probe above and leaves the
    // real press trapped; only this one sees it.
    await page.evaluate((rootFs) => {
      const row = document.querySelector(rootFs)!.closest(".message-row-inner") as HTMLElement
      row.style.setProperty("scale", "0.99")
    }, ROOT_FS)
    await page.waitForTimeout(SETTLE_MS)
    const forcedScale = await probe(page, "forced-scale-property 0.99")
    await shot(page, testInfo, "forced-scale-property")
    expectCovers(forcedScale)

    await page.evaluate((rootFs) => {
      const row = document.querySelector(rootFs)!.closest(".message-row-inner") as HTMLElement
      row.style.removeProperty("scale")
    }, ROOT_FS)
    await page.waitForTimeout(SETTLE_MS)

    // TOP-LAYER probe (see header, 6). The same transform on the root's
    // direct parent, which app.css's row fallback does not neutralise: only
    // the top layer escapes this one.
    await page.evaluate((rootFs) => {
      const parent = document.querySelector(rootFs)!.parentElement as HTMLElement
      parent.style.transform = "scale(0.99)"
    }, ROOT_FS)
    await page.waitForTimeout(SETTLE_MS)
    const forcedParent = await probe(page, "forced-transform scale(0.99) on the root's parent")
    await shot(page, testInfo, "forced-transform-parent")
    expectCovers(forcedParent)
    expect.soft(forcedParent.popoverOpen, "root left the top layer").toBe(true)
    await page.evaluate((rootFs) => {
      const parent = document.querySelector(rootFs)!.parentElement as HTMLElement
      parent.style.transform = ""
    }, ROOT_FS)
    expect.soft(await loads(page), "the forced transform reloaded the iframe").toBe(baseline)
  })

  test("the close button exits fullscreen without reloading the iframe", async ({ page }) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)
    expect.soft(await loads(page), "entering fullscreen reloaded the iframe").toBe(baseline)

    // MEASURED on the unfixed tree (stage 1): with no press held, the
    // button's centre hits the button (`[close-point]` below), yet the TAP is
    // refused because `#utility-bar` receives it. A tap's own touchstart puts
    // the row into `:active`, and the row's computed `scale` is already `1`
    // (not `none`) on that first frame, which is enough to make it the
    // containing block: the overlay is trapped by the very touch that tries
    // to close it. The tap stays a tap so the fix has to make it land.
    await probe(page, "close-button before tap")
    const closeSel = `${ROOT_FS} [data-role="prototype-fullscreen-close"]`
    const pointCheck = async (label: string) =>
      console.log(
        `[close-point] ${label} ${JSON.stringify(
          await page.evaluate((sel) => {
            const b = document.querySelector(sel)!
            const r = b.getBoundingClientRect()
            const x = r.left + r.width / 2
            const y = r.top + r.height / 2
            const hit = document.elementFromPoint(x, y)
            return {
              rect: { top: r.top, left: r.left, width: r.width, height: r.height },
              hit: hit ? `${hit.tagName.toLowerCase()}${hit.id ? "#" + hit.id : ""}` : "(null)",
              hitIsButton: !!hit && b.contains(hit),
              scrollY: window.scrollY,
              scroller: document.getElementById("chat-message-scroller")?.scrollTop,
              vv: window.visualViewport
                ? { top: window.visualViewport.offsetTop, h: window.visualViewport.height }
                : null,
            }
          }, closeSel),
        )}`,
      )
    await pointCheck("before scrollIntoViewIfNeeded")
    await page.locator(closeSel).scrollIntoViewIfNeeded()
    await pointCheck("after scrollIntoViewIfNeeded")
    try {
      await page.locator(`${ROOT_FS} [data-role="prototype-fullscreen-close"]`).tap({ timeout: 15_000 })
    } finally {
      await logEvents(page, "close-button tap")
    }
    await expect(page.locator(ROOT).first()).toHaveAttribute("data-fullscreen", "false", {
      timeout: 10_000,
    })
    await page.waitForTimeout(SETTLE_MS)
    await expectInline(page)
    expect(await loads(page), "exiting via the close button reloaded the iframe").toBe(baseline)
  })

  test("Escape exits fullscreen without reloading the iframe", async ({ page }) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)
    expect.soft(await loads(page), "entering fullscreen reloaded the iframe").toBe(baseline)

    await probe(page, "escape before keypress")
    await page.keyboard.press("Escape")
    await expect(page.locator(ROOT).first()).toHaveAttribute("data-fullscreen", "false", {
      timeout: 10_000,
    })
    await page.waitForTimeout(SETTLE_MS)
    await logEvents(page, "escape exit")
    await expectInline(page)
    expect(await loads(page), "exiting via Escape reloaded the iframe").toBe(baseline)

    // Re-enter after the exit: the sticky remove must not block promotion.
    await enterFullscreen(page)
    expect(await loads(page), "re-entering fullscreen reloaded the iframe").toBe(baseline)
  })

  test("a LiveView patch while fullscreen keeps the frame in the top layer, unreloaded", async ({
    page,
    browser,
  }, testInfo) => {
    await openSpace(page)
    const baseline = await loads(page)
    await enterFullscreen(page)
    expect.soft(await loads(page), "entering fullscreen reloaded the iframe").toBe(baseline)

    // (a) A message from the second member: a stream patch on this page.
    const body = `protofs patch ${Date.now()}`
    await postAsSecondMember(browser, body)
    await expect(page.locator("#message-list").getByText(body).first()).toBeAttached({
      timeout: 10_000,
    })
    await page.waitForTimeout(SETTLE_MS)
    await logEvents(page, "after remote message")
    const afterMessage = await probe(page, "after a remote message")
    expectCovers(afterMessage)
    expect.soft(afterMessage.popoverOpen, "a remote message closed the popover").toBe(true)
    expect.soft(afterMessage.popoverAttr, "a remote message stripped the popover attribute").toBe("manual")
    expect.soft(await loads(page), "a remote message reloaded the iframe").toBe(baseline)

    // (b) Open and close the versions panel: a re-render of the component
    // root itself, the patch most likely to strip a client-set attribute.
    // Opened from the bar's version stamp; closed from the panel's backdrop,
    // which covers the bar while the panel is open (the phone UX).
    const stampSel = `${ROOT_FS} [data-role="prototype-version-stamp"]`
    await page.locator(stampSel).tap()
    await expect(page.locator(`${ROOT_FS} [data-role="prototype-versions-panel"]`)).toBeVisible({
      timeout: 10_000,
    })
    const menuOpen = await probe(page, "versions panel open")
    await shot(page, testInfo, "versions-panel-open")
    expect.soft(menuOpen.popoverOpen, "opening the versions panel closed the popover").toBe(true)
    expect.soft(menuOpen.popoverAttr, "opening the versions panel stripped the attribute").toBe("manual")
    await page.locator(`${ROOT_FS} button[phx-click="close"][aria-label="Close"]`).tap()
    await expect(page.locator(`${ROOT_FS} [data-role="prototype-versions-panel"]`)).toHaveCount(0, {
      timeout: 10_000,
    })
    await page.waitForTimeout(SETTLE_MS)
    await logEvents(page, "versions panel toggled")
    const menuClosed = await probe(page, "versions panel closed")
    expectCovers(menuClosed)
    expect.soft(menuClosed.popoverOpen, "closing the versions panel closed the popover").toBe(true)
    expect.soft(menuClosed.popoverAttr, "closing the versions panel stripped the attribute").toBe("manual")
    expect.soft(await loads(page), "the versions panel toggle reloaded the iframe").toBe(baseline)
  })
})

async function postAsSecondMember(browser: Browser, body: string) {
  const context = await browser.newContext()
  const peer = await context.newPage()
  try {
    peer.on("pageerror", (err) => console.log(`[second pageerror] ${err.message}`))
    await peer.goto(`/dev/login?as=${SECOND_SLUG}`)
    await peer.waitForURL("**/chat**", { timeout: 20_000 })
    await peer.goto(`/chat/${SPACE_SLUG}`)
    // As in chat_reactions.spec.ts: pressSequentially so compose_changed
    // reaches the server before the submit, then the send button.
    const textarea = peer.locator('#compose-form textarea[name="compose[text]"]')
    await expect(textarea).toBeVisible({ timeout: 20_000 })
    await textarea.click()
    await textarea.pressSequentially(body, { delay: 5 })
    await expect(textarea).toHaveValue(body, { timeout: 5_000 })
    const send = peer.locator(".compose-pill-send")
    await expect(send).toBeEnabled({ timeout: 5_000 })
    await send.click()
    await expect(peer.locator("#message-list").getByText(body).first()).toBeAttached({
      timeout: 10_000,
    })
  } finally {
    await context.close()
  }
}
