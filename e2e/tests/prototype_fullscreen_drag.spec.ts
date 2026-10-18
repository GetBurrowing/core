/**
 * Prototype fullscreen under a DRAG: Burrow iOS and the installed PWA
 * (task 01a1389f, plan v2).
 *
 * THE REPORT (Rowan, 2026-10-14). On an iPad, in the installed Burrow iOS app
 * (Capacitor wrapping a WKWebView), a fast drag inside a fullscreen prototype
 * drops it out of fullscreen. He also sees a prominent X in the upper-left
 * corner. The web app renders no top-left X: the bar's close button is on the right.
 *
 * THE HYPOTHESIS UNDER TEST. The web app has no drag exit of its own. Capacitor
 * 8.5.2 turns on `isElementFullscreenEnabled` in the WKWebView, so inside
 * Burrow `document.fullscreenEnabled` is true and the PrototypeFullscreen
 * hook takes the NATIVE path (requestFullscreen). WebKit's own fullscreen UI
 * then owns the screen: the top-left system X and a drag-to-dismiss gesture.
 * A fast drag dismisses, `fullscreenchange` fires, and the hook's sync pushes
 * `fullscreen on=false`, which turns the web app's state off too.
 *
 * WHAT CAN AND CANNOT BE REPRODUCED OFF-DEVICE. Linux WebKit has no UIKit
 * fullscreen controller and no dismiss gesture. So this spec reproduces the
 * PRECONDITION (which path the hook selects in each context) and the CHAIN
 * (a system exit while native turns the web app's state off), with Burrow's page
 * marker INJECTED exactly as Capacitor injects it (`window.Capacitor`, main
 * frame only, before any page script), and with the installed PWA emulated
 * through `display-mode: standalone` + `navigator.standalone`. The injection
 * is how a reviewer exercises Burrow without the device; it is not Burrow.
 *
 * THE FULLSCREEN API IS PRESENT in every case but GREEN-OVERLAY. Where the
 * engine lacks it (Linux WebKit, measured and logged as
 * `[native-fullscreen-before-stub]`), a RECORDING FAKE is installed:
 * requestFullscreen sets a fake `document.fullscreenElement`, dispatches
 * `fullscreenchange` and resolves; exitFullscreen reverses it, and rejects
 * when nothing is fullscreen, as the real API does. Where the engine has it
 * (Chromium), the real methods are wrapped with a call counter and called
 * through. Every run logs which one it used (`[fullscreen-api]`).
 *
 * CASES and their expected result ON THE UNFIXED TREE:
 *   RED-1  webkit-ipad + API + Burrow marker: Full screen must NOT call
 *          requestFullscreen; fullscreenElement null; root :popover-open.
 *          Red: the unfixed hook goes native.
 *   RED-2  the same under webkit-iphone.
 *   RED-3  webkit-ipad + API + standalone, no marker. Red the same way.
 *   RED-4  webkit-ipad + marker; mid-drag, document.exitFullscreen() stands in
 *          for the system dismiss; data-fullscreen must stay "true". Red: the
 *          frame was native, so it exits.
 *   GREEN-BOTH-1  webkit-ipad + API, plain Safari tab: native, by design.
 *   GREEN-BOTH-2  chromium desktop: native, unchanged.
 *   GREEN-BOTH-3  chromium-android + API + marker getPlatform 'android'
 *          (Burrow Android): native, unchanged.
 *   GREEN-OVERLAY webkit-iphone with the API stubbed exactly as v1's spec
 *          does: the full drag set must not exit. This is the discriminator:
 *          if a drag exits here, the web app has a drag exit path of its own.
 *   MARKER CONTROL  RED-1's exact setup with the marker removed must take the
 *          native path (GREEN-BOTH-1's verdict). It and RED-1 differ by the
 *          marker alone, so a flip between them is what shows the verdict
 *          depends on the marker.
 *   POSITIVE CONTROL  Escape mid-drag must exit, in every project: without
 *          it, "no drag exits" could mean the instruments cannot see an exit.
 *          MEASURED: in WebKit a press inside the iframe moves keyboard focus
 *          into the frame, and a real Escape then lands in the prototype, not
 *          in the web app's window listener (`[escape-trace]`). The control moves
 *          focus back to a parent control mid-drag before the real key press.
 *
 * THE DRAG SET (every drag must move the iframe's counter above 0):
 *   fast drag inside #drag and inside #pan: 300px in ~80ms, 12 moves;
 *   a drag that starts in the iframe and ends on the bar;
 *   a drag that starts in the iframe and ends 40px past the viewport's top;
 *   a flick DOWN on the frame from 40px below the bar: 400px in ~60ms;
 *   a flick UP over the same span.
 * Chromium projects drive touches through CDP Input.dispatchTouchEvent
 * (desktop also drives the mouse). WebKit drives page.mouse, plus TouchEvents
 * synthesized inside the frame when they can be built (`[touch-ctor]`,
 * logged). MEASURED on Linux WebKit (Playwright 1.59.1): `new Touch()` throws
 * "Illegal constructor"; `document.createTouch` exists and builds one, but a
 * TouchEvent carrying it throws "Type error", so WebKit runs record the
 * failure and drive the mouse only. Moves are PIPELINED on a timer (one
 * round trip per move stretched an 80ms drag to ~300ms); the measured
 * duration and the moves the frame actually received are logged per drag
 * (`[drag]`), and the engine coalesces some of the 12 moves sent.
 *
 * INSTRUMENTS, per state snapshot: data-fullscreen, :popover-open, the
 * popover attribute, document.fullscreenElement, requestFullscreen /
 * exitFullscreen call counts, every `fullscreen` event the LiveSocket SENDS
 * (click, keydown and hook pushes alike), showPopover / hidePopover calls and
 * toggle events, hook mounts and destroys (the hook alone registers
 * `webkitfullscreenchange` on document here), iframe loads, the root element's
 * identity, `#chat-message-scroller.scrollTop`, scrollY and visualViewport.
 *
 * Seed the fixture first, in the dev container, from apps/platform:
 *   mix run priv/scripts/seed_prototype_drag_fixture.exs
 * and pass FIXTURE_SPACE_SLUG (default protodrag-fixture) and
 * FIXTURE_USER_SLUG (default protodrag-a). Runs under webkit-ipad,
 * webkit-iphone, chromium-android and chromium-desktop only.
 */

import { test, expect, Page, Frame, TestInfo, CDPSession } from "@playwright/test"
import * as fs from "fs"
import * as path from "path"

const SPACE_SLUG = process.env.FIXTURE_SPACE_SLUG ?? "protodrag-fixture"
const USER_SLUG = process.env.FIXTURE_USER_SLUG ?? "protodrag-a"
const SHOT_DIR = process.env.PROTO_FS_SHOT_DIR ?? ""

const ROOT = '[data-role="prototype-canvas"]'
const ROOT_FS = '[data-role="prototype-canvas"][data-fullscreen="true"]'
const SETTLE_MS = 450

type Api = "present" | "stubbed"
type Marker = null | "ios" | "android"

interface Setup {
  api: Api
  marker: Marker
  standalone: boolean
}

interface Snapshot {
  label: string
  fs: string | null
  popoverOpen: boolean
  popoverAttr: string | null
  fullscreenElement: string
  fullscreenElementIsRoot: boolean
  requestCalls: number
  exitCalls: number
  pushes: { t: number; type: string; on: string }[]
  showPopover: number
  hidePopover: number
  toggles: string[]
  hookMounts: number
  hookDestroys: number
  loads: number
  rootSame: boolean
  scrollerTop: number | null
  scrollY: number
  vv: { offsetTop: number; pageTop: number; height: number; scale: number } | null
}

interface Moves {
  total: number
  /** Moves with a finger or button down (touchmove, or buttons > 0). */
  pressed: number
  pointermove: number
  touchmove: number
  mousemove: number
  drag: number
  pan: number
  down: number
  up: number
  cancel: number
  touchcancel: number
  /** Keydowns delivered INSIDE the prototype frame. */
  keydown: number
}

declare global {
  interface Window {
    __protoLoads: number
    __fsProbe: {
      api: string
      before: Record<string, string>
      requestCalls: number
      exitCalls: number
      pushes: { t: number; type: string; on: string }[]
      showPopover: number
      hidePopover: number
      toggles: string[]
      hookMounts: number
      hookDestroys: number
      /** Keydowns the PARENT window received, with the active element. */
      keydowns: string[]
      root: Element | null
    }
    __moves: Moves
  }
}

function project(testInfo: TestInfo): string {
  return testInfo.project.name
}

async function installInitScripts(page: Page, testInfo: TestInfo, setup: Setup) {
  const ipad = project(testInfo) === "webkit-ipad"
  await page.addInitScript(
    ({ setup, ipad }) => {
      // Burrow's marker, as Capacitor injects it: a document-start,
      // main-frame-only WKUserScript (JSExport.swift), plus native-bridge's
      // isNativePlatform/getPlatform. The prototype iframe never sees it.
      if (window.top !== window) return

      if (ipad) {
        // iPadOS Safari's desktop-class UA claims a Mac; maxTouchPoints is
        // what tells an iPad apart.
        try {
          Object.defineProperty(Navigator.prototype, "maxTouchPoints", {
            get: () => 5,
            configurable: true,
          })
        } catch (_) {}
      }
      if (setup.marker) {
        const platform = setup.marker
        ;(window as unknown as Record<string, unknown>).Capacitor = {
          DEBUG: false,
          isLoggingEnabled: false,
          Plugins: {},
          isNativePlatform: () => true,
          getPlatform: () => platform,
        }
      }
      if (setup.standalone) {
        const real = window.matchMedia.bind(window)
        window.matchMedia = (q: string) => {
          const mql = real(q)
          if (/display-mode:\s*standalone/.test(q)) {
            return new Proxy(mql, {
              get(target, prop) {
                if (prop === "matches") return true
                const v = Reflect.get(target, prop)
                return typeof v === "function" ? v.bind(target) : v
              },
            })
          }
          return mql
        }
        try {
          Object.defineProperty(Navigator.prototype, "standalone", {
            get: () => true,
            configurable: true,
          })
        } catch (_) {}
      }

      const ep = Element.prototype as unknown as Record<string, unknown>
      const dp = Document.prototype as unknown as Record<string, unknown>
      const d = document as unknown as Record<string, unknown>
      const probe = (window.__fsProbe = {
        api: "",
        before: {
          requestFullscreen: typeof ep.requestFullscreen,
          webkitRequestFullscreen: typeof ep.webkitRequestFullscreen,
          fullscreenEnabled: String(d.fullscreenEnabled),
          webkitFullscreenEnabled: String(d.webkitFullscreenEnabled),
        },
        requestCalls: 0,
        exitCalls: 0,
        pushes: [],
        showPopover: 0,
        hidePopover: 0,
        toggles: [],
        hookMounts: 0,
        hookDestroys: 0,
        keydowns: [],
        root: null,
      } as Window["__fsProbe"])
      window.addEventListener(
        "keydown",
        (e) => probe.keydowns.push(`${e.key}@${(document.activeElement && document.activeElement.tagName) || "?"}`),
        true,
      )

      if (setup.api === "stubbed") {
        // Exactly as prototype_fullscreen_touch.spec.ts: an iPhone Safari tab
        // has no element Fullscreen API.
        probe.api = "stubbed"
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
      } else if (typeof ep.requestFullscreen === "function" && d.fullscreenEnabled === true) {
        // Native: count and call through.
        probe.api = "native"
        const realRequest = ep.requestFullscreen as (this: Element, o?: unknown) => Promise<void>
        const realExit = dp.exitFullscreen as (this: Document) => Promise<void>
        Object.defineProperty(Element.prototype, "requestFullscreen", {
          configurable: true,
          writable: true,
          value: function (this: Element, o?: unknown) {
            probe.requestCalls += 1
            return realRequest.call(this, o)
          },
        })
        Object.defineProperty(Document.prototype, "exitFullscreen", {
          configurable: true,
          writable: true,
          value: function (this: Document) {
            probe.exitCalls += 1
            return realExit.call(this)
          },
        })
      } else {
        // Recording fake. Linux WebKit exposes no element Fullscreen API; an
        // iPad Safari tab and Burrow's WKWebView (isElementFullscreenEnabled)
        // do.
        probe.api = "fake"
        let current: Element | null = null
        const fire = () =>
          queueMicrotask(() => document.dispatchEvent(new Event("fullscreenchange")))
        Object.defineProperty(Document.prototype, "fullscreenEnabled", {
          get: () => true,
          configurable: true,
        })
        Object.defineProperty(Document.prototype, "fullscreenElement", {
          get: () => current,
          configurable: true,
        })
        Object.defineProperty(Element.prototype, "requestFullscreen", {
          configurable: true,
          writable: true,
          value: function (this: Element) {
            probe.requestCalls += 1
            current = this
            fire()
            return Promise.resolve()
          },
        })
        Object.defineProperty(Document.prototype, "exitFullscreen", {
          configurable: true,
          writable: true,
          value: function () {
            probe.exitCalls += 1
            if (!current) return Promise.reject(new TypeError("Not in fullscreen"))
            current = null
            fire()
            return Promise.resolve()
          },
        })
      }

      // Every `fullscreen` event the LiveSocket sends: the bar button's
      // phx-click, the Escape phx-window-keydown and the hook's pushEventTo.
      const realSend = WebSocket.prototype.send
      WebSocket.prototype.send = function (this: WebSocket, data: string | ArrayBufferLike | Blob | ArrayBufferView) {
        if (typeof data === "string" && data.includes('"event":"fullscreen"')) {
          const on = /"on":"(true|false)"/.exec(data)?.[1] ?? "?"
          const type = /"type":"([a-z]+)"/.exec(data)?.[1] ?? "?"
          probe.pushes.push({ t: Math.round(performance.now()), type, on })
        }
        return realSend.call(this, data)
      }

      // Popover calls and toggle events (toggle does not bubble; a capture
      // listener on document still sees it).
      const hp = HTMLElement.prototype as unknown as Record<string, (this: HTMLElement) => void>
      for (const [name, key] of [
        ["showPopover", "showPopover"],
        ["hidePopover", "hidePopover"],
      ] as const) {
        const real = hp[name]
        if (typeof real !== "function") continue
        Object.defineProperty(HTMLElement.prototype, name, {
          configurable: true,
          writable: true,
          value: function (this: HTMLElement) {
            if (this.matches('[data-role="prototype-canvas"]')) probe[key] += 1
            return real.call(this)
          },
        })
      }
      document.addEventListener(
        "toggle",
        (e) => {
          const t = e.target as Element
          if (t && t.matches && t.matches('[data-role="prototype-canvas"]')) {
            probe.toggles.push(`${(e as ToggleEvent).oldState}->${(e as ToggleEvent).newState}`)
          }
        },
        true,
      )

      // Hook lifecycle: on this page only PrototypeFullscreen registers
      // `webkitfullscreenchange` on document (mounted) and removes it
      // (destroyed). screen_share_viewer.js also does, but no meeting runs here.
      const realAdd = Document.prototype.addEventListener
      const realRemove = Document.prototype.removeEventListener
      Document.prototype.addEventListener = function (this: Document, type: string, ...rest: unknown[]) {
        if (type === "webkitfullscreenchange") probe.hookMounts += 1
        return (realAdd as (...a: unknown[]) => void).call(this, type, ...rest)
      } as typeof Document.prototype.addEventListener
      Document.prototype.removeEventListener = function (this: Document, type: string, ...rest: unknown[]) {
        if (type === "webkitfullscreenchange") probe.hookDestroys += 1
        return (realRemove as (...a: unknown[]) => void).call(this, type, ...rest)
      } as typeof Document.prototype.removeEventListener

      window.__protoLoads = 0
      document.addEventListener(
        "load",
        (e) => {
          const t = e.target as Element | null
          if (t && t.tagName === "IFRAME" && t.closest && t.closest('[data-role="prototype-canvas"]')) {
            window.__protoLoads += 1
          }
        },
        true,
      )
    },
    { setup, ipad },
  )
}

async function loads(page: Page): Promise<number> {
  return page.evaluate(() => window.__protoLoads)
}

async function openSpace(page: Page, testInfo: TestInfo, setup: Setup) {
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await installInitScripts(page, testInfo, setup)
  await page.goto(`/dev/login?as=${USER_SLUG}`)
  await page.waitForURL("**/chat**", { timeout: 20_000 })
  await page.goto(`/chat/${SPACE_SLUG}`)
  await page.waitForFunction(
    () => !!(window as unknown as { liveSocket?: { isConnected?: () => boolean } }).liveSocket?.isConnected?.(),
    null,
    { timeout: 20_000 },
  )
  await expect(page.locator(ROOT).first()).toBeAttached({ timeout: 20_000 })
  await page.waitForFunction(() => window.__protoLoads >= 1, null, { timeout: 20_000 })
  let last = await loads(page)
  for (let quiet = 0, n = 0; quiet < 6 && n < 60; n++) {
    await page.waitForTimeout(500)
    const now = await loads(page)
    quiet = now === last ? quiet + 1 : 0
    last = now
  }
  const env = await page.evaluate(() => {
    const w = window as unknown as {
      Capacitor?: { isNativePlatform?: () => boolean; getPlatform?: () => string }
    }
    return {
      api: window.__fsProbe.api,
      before: window.__fsProbe.before,
      fullscreenEnabled: String(document.fullscreenEnabled),
      ua: navigator.userAgent,
      maxTouchPoints: navigator.maxTouchPoints,
      capacitor: w.Capacitor
        ? { native: w.Capacitor.isNativePlatform?.(), platform: w.Capacitor.getPlatform?.() }
        : null,
      standaloneMQ: window.matchMedia("(display-mode: standalone)").matches,
      navStandalone: (navigator as unknown as { standalone?: boolean }).standalone ?? null,
      viewport: { w: window.innerWidth, h: window.innerHeight },
    }
  })
  console.log(`[native-fullscreen-before-stub] ${JSON.stringify(env.before)}`)
  console.log(`[fullscreen-api] ${project(testInfo)} ${env.api} ${JSON.stringify(env)}`)
  if (setup.api === "present") {
    expect(env.fullscreenEnabled, "the Fullscreen API must be PRESENT in this case").toBe("true")
  }
  if (setup.marker) expect(env.capacitor, "the Burrow marker was not injected").not.toBeNull()
  else expect(env.capacitor, "a Capacitor marker is present in a no-marker case").toBeNull()
  expect(env.standaloneMQ || env.navStandalone === true, "standalone emulation mismatch").toBe(setup.standalone)
}

async function snapshot(page: Page, label: string): Promise<Snapshot> {
  const s = await page.evaluate(
    ({ label, rootSel }) => {
      const root = document.querySelector(rootSel)
      const p = window.__fsProbe
      if (!p.root && root) p.root = root
      const fe = document.fullscreenElement || (document as unknown as { webkitFullscreenElement?: Element }).webkitFullscreenElement || null
      let open = false
      try {
        open = !!root && root.matches(":popover-open")
      } catch (_) {}
      const vv = window.visualViewport
      const scroller = document.getElementById("chat-message-scroller")
      return {
        label,
        fs: root ? root.getAttribute("data-fullscreen") : null,
        popoverOpen: open,
        popoverAttr: root ? root.getAttribute("popover") : null,
        fullscreenElement: fe ? `${fe.tagName.toLowerCase()}${fe.getAttribute("data-role") ? "[" + fe.getAttribute("data-role") + "]" : ""}` : "(null)",
        fullscreenElementIsRoot: !!fe && fe === root,
        requestCalls: p.requestCalls,
        exitCalls: p.exitCalls,
        pushes: p.pushes.slice(),
        showPopover: p.showPopover,
        hidePopover: p.hidePopover,
        toggles: p.toggles.slice(),
        hookMounts: p.hookMounts,
        hookDestroys: p.hookDestroys,
        loads: window.__protoLoads,
        rootSame: !!root && root === p.root,
        scrollerTop: scroller ? scroller.scrollTop : null,
        scrollY: window.scrollY,
        vv: vv ? { offsetTop: vv.offsetTop, pageTop: vv.pageTop, height: vv.height, scale: vv.scale } : null,
      }
    },
    { label, rootSel: ROOT },
  )
  console.log(`[state] ${JSON.stringify(s)}`)
  return s
}

async function shot(page: Page, testInfo: TestInfo, name: string) {
  const file = testInfo.outputPath(`${name}.png`)
  await page.screenshot({ path: file })
  await testInfo.attach(name, { path: file, contentType: "image/png" })
  if (SHOT_DIR) {
    fs.mkdirSync(SHOT_DIR, { recursive: true })
    fs.copyFileSync(file, path.join(SHOT_DIR, `${project(testInfo)}-${name}.png`))
  }
}

async function tapFullscreen(page: Page, testInfo: TestInfo) {
  const button = page.locator('[data-role="prototype-fullscreen"]').first()
  await button.scrollIntoViewIfNeeded()
  if (project(testInfo) === "chromium-desktop") await button.click()
  else await button.tap()
  await expect(page.locator(ROOT_FS)).toHaveCount(1, { timeout: 10_000 })
  await page.waitForTimeout(SETTLE_MS)
}

async function protoFrame(page: Page): Promise<Frame> {
  const handle = await page.locator(`${ROOT} iframe`).first().elementHandle()
  const frame = handle && (await handle.contentFrame())
  expect(frame, "no prototype iframe content frame").not.toBeNull()
  return frame!
}

async function moves(frame: Frame): Promise<Moves> {
  return frame.evaluate(() => ({ ...window.__moves }))
}

function delta(after: Moves, before: Moves): Moves {
  const out = {} as Moves
  for (const k of Object.keys(after) as (keyof Moves)[]) out[k] = after[k] - before[k]
  return out
}

interface Pt {
  x: number
  y: number
}

/** The drag set's geometry, read from the live fullscreen layout. */
async function geometry(page: Page, frame: Frame) {
  const bar = await page.evaluate((rootFs) => {
    const root = document.querySelector(rootFs)!
    const frameEl = root.querySelector("iframe")!.getBoundingClientRect()
    const title = root.querySelector('[data-role="prototype-title"]')
    const t = title ? title.getBoundingClientRect() : null
    return {
      iframe: { x: frameEl.left, y: frameEl.top, w: frameEl.width, h: frameEl.height },
      title: t ? { x: t.left + Math.min(10, t.width / 2), y: t.top + t.height / 2 } : null,
    }
  }, ROOT_FS)
  const off = bar.iframe
  const box = async (sel: string) => {
    const b = await frame.evaluate((s) => {
      const r = document.querySelector(s)!.getBoundingClientRect()
      return { x: r.left, y: r.top, w: r.width, h: r.height }
    }, sel)
    return { x: b.x + off.x, y: b.y + off.y, w: b.w, h: b.h }
  }
  return { iframe: off, title: bar.title, drag: await box("#drag"), pan: await box("#pan") }
}

interface Drag {
  name: string
  from: Pt
  to: Pt
  ms: number
  steps: number
}

async function dragSet(page: Page, frame: Frame): Promise<Drag[]> {
  const g = await geometry(page, frame)
  console.log(`[geometry] ${JSON.stringify(g)}`)
  const span = Math.min(300, g.iframe.w - 40)
  const dy = g.drag.y + g.drag.h / 2
  const py = g.pan.y + g.pan.h / 2
  const x0 = g.iframe.x + (g.iframe.w - span) / 2
  const flickTop = g.iframe.y + 40
  const flickSpan = Math.min(400, g.iframe.h - 60)
  const cx = g.iframe.x + g.iframe.w / 2
  const drags: Drag[] = [
    { name: "fast-inside-drag", from: { x: x0, y: dy }, to: { x: x0 + span, y: dy }, ms: 80, steps: 12 },
    { name: "fast-inside-pan", from: { x: x0, y: py }, to: { x: x0 + span, y: py }, ms: 80, steps: 12 },
    {
      name: "out-onto-bar",
      from: { x: cx, y: dy },
      to: g.title ?? { x: cx, y: Math.max(1, g.iframe.y - 20) },
      ms: 80,
      steps: 12,
    },
    { name: "out-past-top", from: { x: cx, y: dy }, to: { x: cx, y: -40 }, ms: 80, steps: 12 },
    { name: "flick-down", from: { x: cx, y: flickTop }, to: { x: cx, y: flickTop + flickSpan }, ms: 60, steps: 10 },
    { name: "flick-up", from: { x: cx, y: flickTop + flickSpan }, to: { x: cx, y: flickTop }, ms: 60, steps: 10 },
  ]
  return drags
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function lerp(a: Pt, b: Pt, f: number): Pt {
  return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f }
}

/** CDP touch drag (Chromium). Coordinates past the top are clamped to 0:
 *  a finger cannot leave the screen. `mid` runs once halfway. */
async function cdpTouchDrag(cdp: CDPSession, d: Drag, mid?: () => Promise<void>) {
  const clamp = (p: Pt) => ({ x: Math.round(p.x), y: Math.max(0, Math.round(p.y)) })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [clamp(d.from)] })
  // Moves are PIPELINED on a timer, not awaited one by one: an awaited
  // round trip per move stretches an ~80ms drag to ~250ms.
  const half = Math.floor(d.steps / 2)
  const send = (i: number) =>
    cdp.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [clamp(lerp(d.from, d.to, i / d.steps))],
    })
  const first: Promise<unknown>[] = []
  for (let i = 1; i <= half; i++) {
    first.push(send(i))
    await sleep(d.ms / d.steps)
  }
  await Promise.all(first)
  if (mid) await mid()
  const rest: Promise<unknown>[] = []
  for (let i = half + 1; i <= d.steps; i++) {
    rest.push(send(i))
    await sleep(d.ms / d.steps)
  }
  await Promise.all(rest)
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
}

/** page.mouse drag with explicit steps. `mid` runs once halfway. */
async function mouseDrag(page: Page, d: Drag, mid?: () => Promise<void>) {
  await page.mouse.move(d.from.x, d.from.y)
  await page.mouse.down()
  const half = Math.floor(d.steps / 2)
  // Pipelined like cdpTouchDrag: issued on a timer, awaited per half.
  const move = (i: number) => {
    const p = lerp(d.from, d.to, i / d.steps)
    return page.mouse.move(p.x, p.y).catch(async (e) => {
      console.log(`[mouse] ${d.name} move to ${p.x},${p.y} refused: ${(e as Error).message}`)
      await page.mouse.move(p.x, Math.max(0, p.y))
    })
  }
  const first: Promise<unknown>[] = []
  for (let i = 1; i <= half; i++) {
    first.push(move(i))
    await sleep(d.ms / d.steps)
  }
  await Promise.all(first)
  if (mid) await mid()
  const rest: Promise<unknown>[] = []
  for (let i = half + 1; i <= d.steps; i++) {
    rest.push(move(i))
    await sleep(d.ms / d.steps)
  }
  await Promise.all(rest)
  await page.mouse.up()
}

/** TouchEvents synthesized INSIDE the prototype frame (WebKit). Only the
 *  in-frame part of a drag can be synthesized this way; points outside the
 *  frame are clamped to its edge. Returns whether `new Touch()` worked. */
async function frameTouchDrag(frame: Frame, d: Drag, off: { x: number; y: number; w: number; h: number }) {
  const local = (p: Pt) => ({
    x: Math.min(Math.max(p.x - off.x, 1), off.w - 1),
    y: Math.min(Math.max(p.y - off.y, 1), off.h - 1),
  })
  return frame.evaluate(
    async ({ from, to, ms, steps }) => {
      let ctor = false
      let err = ""
      let via = "new Touch()"
      const legacy = (document as unknown as { createTouch?: (...a: unknown[]) => Touch }).createTouch
      const mk = (target: Element, x: number, y: number): Touch => {
        if (via === "new Touch()") {
          return new Touch({ identifier: 1, target, clientX: x, clientY: y, pageX: x, pageY: y, screenX: x, screenY: y })
        }
        return legacy!.call(document, window, target, 1, x, y, x, y)
      }
      try {
        mk(document.body, 1, 1)
        ctor = true
      } catch (e) {
        err = String(e)
        if (typeof legacy === "function") {
          via = "document.createTouch"
          try {
            mk(document.body, 1, 1)
          } catch (e2) {
            err += `; createTouch: ${e2}`
            via = ""
          }
        } else {
          via = ""
        }
      }
      if (!via || typeof TouchEvent !== "function")
        return { ctor, via, createTouch: typeof legacy, touchEvent: typeof TouchEvent, err }
      // A Touch can be built; can a TouchEvent carrying it? Linux WebKit
      // answers this one separately, so it is measured, not assumed.
      try {
        const t = mk(document.body, 1, 1)
        new TouchEvent("touchmove", { touches: [t], targetTouches: [t], changedTouches: [t] })
      } catch (e) {
        return { ctor, via: "", builtVia: via, createTouch: typeof legacy, touchEvent: typeof TouchEvent, err: `${err}; TouchEvent: ${e}` }
      }
      const target = document.elementFromPoint(from.x, from.y) || document.body
      const fire = (type: string, x: number, y: number, ended = false) => {
        const t = mk(target, x, y)
        target.dispatchEvent(
          new TouchEvent(type, {
            bubbles: true,
            cancelable: true,
            touches: ended ? [] : [t],
            targetTouches: ended ? [] : [t],
            changedTouches: [t],
          }),
        )
      }
      fire("touchstart", from.x, from.y)
      for (let i = 1; i <= steps; i++) {
        await new Promise((r) => setTimeout(r, ms / steps))
        fire("touchmove", from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps)
      }
      fire("touchend", to.x, to.y, true)
      return { ctor, via, createTouch: typeof legacy, touchEvent: typeof TouchEvent, err }
    },
    { from: local(d.from), to: local(d.to), ms: d.ms, steps: d.steps },
  )
}

interface DragResult {
  drag: string
  driver: string
  moves: Moves
  ms: number
  after: Snapshot
}

/** Run one drag with every driver the project has; snapshot after each. */
async function runDrag(
  page: Page,
  testInfo: TestInfo,
  frame: Frame,
  d: Drag,
  cdp: CDPSession | null,
): Promise<DragResult[]> {
  const out: DragResult[] = []
  const p = project(testInfo)
  const drivers: string[] = p.startsWith("chromium")
    ? p === "chromium-desktop"
      ? ["mouse", "cdp-touch"]
      : ["cdp-touch"]
    : ["mouse", "frame-touch"]
  for (const driver of drivers) {
    // Position first, so the hover move to the start is not in the delta.
    if (driver === "mouse") await page.mouse.move(d.from.x, d.from.y)
    const before = await moves(frame)
    const t0 = Date.now()
    if (driver === "mouse") await mouseDrag(page, d)
    else if (driver === "cdp-touch") await cdpTouchDrag(cdp!, d)
    else {
      const g = await geometry(page, frame)
      const r = await frameTouchDrag(frame, d, g.iframe)
      console.log(`[touch-ctor] ${p} ${JSON.stringify(r)}`)
      if (!r.via) continue
    }
    const ms = Date.now() - t0
    await page.waitForTimeout(SETTLE_MS)
    const m = delta(await moves(frame), before)
    const after = await snapshot(page, `${d.name} via ${driver}`)
    console.log(`[drag] ${p} ${d.name} via ${driver} ${ms}ms moves=${JSON.stringify(m)}`)
    out.push({ drag: d.name, driver, moves: m, ms, after })
  }
  return out
}

/** The stay-fullscreen verdict for one drag, soft so every drag reports. */
function expectStayed(r: DragResult, base: Snapshot, path: "native" | "overlay") {
  const tag = `${r.drag} via ${r.driver}`
  expect.soft(r.moves.pressed, `${tag}: the prototype received no pressed moves`).toBeGreaterThan(0)
  expect.soft(r.after.fs, `${tag}: the frame left fullscreen (data-fullscreen)`).toBe("true")
  expect
    .soft(r.after.pushes.slice(base.pushes.length), `${tag}: a fullscreen event was sent`)
    .toEqual([])
  expect.soft(r.after.hidePopover, `${tag}: hidePopover was called`).toBe(base.hidePopover)
  expect.soft(r.after.hookMounts, `${tag}: the hook remounted`).toBe(base.hookMounts)
  expect.soft(r.after.loads, `${tag}: the iframe reloaded`).toBe(base.loads)
  expect.soft(r.after.rootSame, `${tag}: the root element was replaced`).toBe(true)
  if (path === "overlay") {
    expect.soft(r.after.popoverOpen, `${tag}: the root left the top layer`).toBe(true)
  } else {
    expect.soft(r.after.fullscreenElementIsRoot, `${tag}: native fullscreen ended`).toBe(true)
  }
}

function logResult(testInfo: TestInfo, caseName: string, data: unknown) {
  console.log(`[result] ${project(testInfo)} ${caseName} ${JSON.stringify(data)}`)
}

async function cdpFor(page: Page, testInfo: TestInfo): Promise<CDPSession | null> {
  if (!project(testInfo).startsWith("chromium")) return null
  const cdp = await page.context().newCDPSession(page)
  return cdp
}

/** Shared path-selection body for RED-1/2/3 and the marker control. */
async function overlayPathSelection(page: Page, testInfo: TestInfo, caseName: string) {
  const base = await snapshot(page, `${caseName} before tap`)
  await tapFullscreen(page, testInfo)
  const s = await snapshot(page, `${caseName} after tap`)
  await shot(page, testInfo, `${caseName}-entered`)
  logResult(testInfo, caseName, {
    requestCalls: s.requestCalls - base.requestCalls,
    fullscreenElement: s.fullscreenElement,
    popoverOpen: s.popoverOpen,
    popoverAttr: s.popoverAttr,
  })
  return { base, s }
}

test.describe("prototype fullscreen under a drag (Burrow iOS, installed PWA)", () => {
  test("RED-1 webkit-ipad + Burrow marker: the overlay path, never native", async ({ page }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-ipad", "webkit-ipad only")
    await openSpace(page, testInfo, { api: "present", marker: "ios", standalone: false })
    const { base, s } = await overlayPathSelection(page, testInfo, "RED-1")
    expect.soft(s.requestCalls - base.requestCalls, "Burrow iOS: requestFullscreen was called").toBe(0)
    expect.soft(s.fullscreenElement, "Burrow iOS: a native fullscreen element is set").toBe("(null)")
    expect.soft(s.popoverOpen, "Burrow iOS: the root is not in the top layer").toBe(true)
  })

  test("RED-2 webkit-iphone + Burrow marker: the overlay path, never native", async ({ page }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-iphone", "webkit-iphone only")
    await openSpace(page, testInfo, { api: "present", marker: "ios", standalone: false })
    const { base, s } = await overlayPathSelection(page, testInfo, "RED-2")
    expect.soft(s.requestCalls - base.requestCalls, "Burrow iPhone: requestFullscreen was called").toBe(0)
    expect.soft(s.fullscreenElement, "Burrow iPhone: a native fullscreen element is set").toBe("(null)")
    expect.soft(s.popoverOpen, "Burrow iPhone: the root is not in the top layer").toBe(true)
  })

  test("RED-3 webkit-ipad + standalone PWA: the overlay path, never native", async ({ page }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-ipad", "webkit-ipad only")
    await openSpace(page, testInfo, { api: "present", marker: null, standalone: true })
    const { base, s } = await overlayPathSelection(page, testInfo, "RED-3")
    expect.soft(s.requestCalls - base.requestCalls, "installed PWA: requestFullscreen was called").toBe(0)
    expect.soft(s.fullscreenElement, "installed PWA: a native fullscreen element is set").toBe("(null)")
    expect.soft(s.popoverOpen, "installed PWA: the root is not in the top layer").toBe(true)
  })

  test("RED-4 webkit-ipad + Burrow marker: a system exit mid-drag leaves the web app fullscreen", async ({
    page,
  }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-ipad", "webkit-ipad only")
    await openSpace(page, testInfo, { api: "present", marker: "ios", standalone: false })
    await tapFullscreen(page, testInfo)
    const frame = await protoFrame(page)
    const base = await snapshot(page, "RED-4 entered")
    const [d] = await dragSet(page, frame)
    await page.mouse.move(d.from.x, d.from.y)
    const before = await moves(frame)
    let exitResult = ""
    await mouseDrag(page, d, async () => {
      // The stand-in for WebKit's drag-to-dismiss: the system leaving native
      // fullscreen while the finger is still down.
      exitResult = await page.evaluate(() =>
        document.exitFullscreen().then(
          () => "resolved",
          (e) => `rejected: ${e}`,
        ),
      )
      await shot(page, testInfo, "RED-4-mid-drag")
    })
    await page.waitForTimeout(SETTLE_MS)
    const m = delta(await moves(frame), before)
    const s = await snapshot(page, "RED-4 after drag")
    logResult(testInfo, "RED-4", {
      exitFullscreen: exitResult,
      moves: m.pressed,
      fs: s.fs,
      pushes: s.pushes.slice(base.pushes.length),
      fullscreenElement: s.fullscreenElement,
    })
    expect.soft(m.pressed, "RED-4: the drag never reached the prototype").toBeGreaterThan(0)
    expect.soft(s.fs, "RED-4: a system fullscreen exit mid-drag took the web app out of fullscreen").toBe("true")
  })

  test("MARKER CONTROL webkit-ipad: RED-1's setup without the marker goes native", async ({
    page,
  }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-ipad", "webkit-ipad only")
    await openSpace(page, testInfo, { api: "present", marker: null, standalone: false })
    const { base, s } = await overlayPathSelection(page, testInfo, "MARKER-CONTROL")
    expect.soft(s.requestCalls - base.requestCalls, "no marker: requestFullscreen was not called").toBe(1)
    expect.soft(s.fullscreenElementIsRoot, "no marker: the root is not the native fullscreen element").toBe(true)
  })

  test("GREEN-BOTH-1 webkit-ipad Safari tab: native, and drags keep it", async ({ page }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-ipad", "webkit-ipad only")
    await openSpace(page, testInfo, { api: "present", marker: null, standalone: false })
    await nativeCase(page, testInfo, "GREEN-BOTH-1")
  })

  test("GREEN-BOTH-2 chromium desktop: native, unchanged, and drags keep it", async ({ page }, testInfo) => {
    test.skip(project(testInfo) !== "chromium-desktop", "chromium-desktop only")
    await openSpace(page, testInfo, { api: "present", marker: null, standalone: false })
    await nativeCase(page, testInfo, "GREEN-BOTH-2")
  })

  test("GREEN-BOTH-3 chromium-android + Burrow Android marker: native, unchanged", async ({
    page,
  }, testInfo) => {
    test.skip(project(testInfo) !== "chromium-android", "chromium-android only")
    await openSpace(page, testInfo, { api: "present", marker: "android", standalone: false })
    await nativeCase(page, testInfo, "GREEN-BOTH-3")
  })

  test("GREEN-OVERLAY webkit-iphone, no Fullscreen API: no drag exits the overlay", async ({
    page,
  }, testInfo) => {
    test.skip(project(testInfo) !== "webkit-iphone", "webkit-iphone only")
    await openSpace(page, testInfo, { api: "stubbed", marker: null, standalone: false })
    await tapFullscreen(page, testInfo)
    const entered = await snapshot(page, "GREEN-OVERLAY entered")
    expect(entered.popoverOpen, "GREEN-OVERLAY: not on the overlay path at entry").toBe(true)
    expect(entered.requestCalls, "GREEN-OVERLAY: requestFullscreen was called").toBe(0)
    const frame = await protoFrame(page)
    const results: DragResult[] = []
    for (const d of await dragSet(page, frame)) {
      const base = await snapshot(page, `GREEN-OVERLAY before ${d.name}`)
      for (const r of await runDrag(page, testInfo, frame, d, null)) {
        expectStayed(r, base, "overlay")
        results.push(r)
      }
    }
    await shot(page, testInfo, "GREEN-OVERLAY-after-drags")
    logResult(testInfo, "GREEN-OVERLAY", summarise(results))
  })

  test("POSITIVE CONTROL: Escape mid-drag exits", async ({ page }, testInfo) => {
    const p = project(testInfo)
    const setup: Setup =
      p === "webkit-iphone"
        ? { api: "stubbed", marker: null, standalone: false }
        : p === "webkit-ipad"
          ? { api: "present", marker: "ios", standalone: false }
          : p === "chromium-android"
            ? { api: "present", marker: "android", standalone: false }
            : { api: "present", marker: null, standalone: false }
    await openSpace(page, testInfo, setup)
    await tapFullscreen(page, testInfo)
    const frame = await protoFrame(page)
    const base = await snapshot(page, "control entered")
    const [d] = await dragSet(page, frame)
    await page.mouse.move(d.from.x, d.from.y)
    const before = await moves(frame)
    const cdp = await cdpFor(page, testInfo)
    let keyTrace: unknown = null
    const mid = async () => {
      const kd0 = (await moves(frame)).keydown
      const active = await page.evaluate(() => document.activeElement?.tagName ?? "(none)")
      // MEASURED (unfixed tree, Linux WebKit): a press inside the iframe moves
      // focus INTO the frame, so a real Escape lands in the prototype
      // (frameKeydowns 1, parentKeydowns 0) and never reaches the web app's
      // phx-window-keydown. That is a property of focus, not of the drag; the
      // control is about whether the instruments can see an exit, so the
      // parent takes focus back (the finger/button stays down) and the key is
      // still a real key press. MEASURED: iframe.blur() alone leaves WebKit's
      // keyboard focus in the frame; focusing a parent control moves it.
      const blurred = await page.evaluate((rootFs) => {
        const a = document.activeElement as HTMLElement | null
        if (a && a.tagName === "IFRAME") {
          window.focus()
          ;(document.querySelector(`${rootFs} [data-role="prototype-fullscreen-close"]`) as HTMLElement | null)?.focus()
          return document.activeElement?.tagName ?? "(none)"
        }
        return false
      }, ROOT_FS)
      await page.keyboard.press("Escape")
      await page.waitForTimeout(100)
      keyTrace = {
        activeBefore: active,
        blurredFrame: blurred,
        parentKeydowns: await page.evaluate(() => window.__fsProbe.keydowns.slice()),
        frameKeydowns: (await moves(frame)).keydown - kd0,
      }
      console.log(`[escape-trace] ${project(testInfo)} ${JSON.stringify(keyTrace)}`)
    }
    if (cdp) await cdpTouchDrag(cdp, d, mid)
    else await mouseDrag(page, d, mid)
    await expect(page.locator(ROOT).first()).toHaveAttribute("data-fullscreen", "false", { timeout: 10_000 })
    await page.waitForTimeout(SETTLE_MS)
    const m = delta(await moves(frame), before)
    const s = await snapshot(page, "control after Escape")
    logResult(testInfo, "POSITIVE-CONTROL", {
      setup,
      keyTrace,
      moves: m.pressed,
      fs: s.fs,
      pushes: s.pushes.slice(base.pushes.length),
      hidePopover: s.hidePopover - base.hidePopover,
      exitCalls: s.exitCalls - base.exitCalls,
      fullscreenElement: s.fullscreenElement,
    })
    expect.soft(m.pressed, "control: the drag never reached the prototype").toBeGreaterThan(0)
    expect.soft(s.pushes.slice(base.pushes.length).map((x) => x.on), "control: no exit was sent").toContain("false")
  })

  // Stage 2 (01a1389f v2): the close controls a user can actually reach in
  // fullscreen. A control counts when it is visible, hit-testable (the
  // element at its centre is it or inside it) and named /close|exit/i. The
  // system top-left X of WebKit's native fullscreen UI is not DOM and cannot
  // be counted here, so on the overlay variants its measurable form is
  // `document.fullscreenElement === null`: no native fullscreen, no system UI.
  // One test per variant: init scripts accumulate on a page, so a variant
  // never shares a page with another.
  const CLOSE_VARIANTS: { project: string; name: string; setup: Setup; overlay: boolean }[] = [
    { project: "webkit-ipad", name: "burrow-ios", setup: { api: "present", marker: "ios", standalone: false }, overlay: true },
    { project: "webkit-ipad", name: "standalone", setup: { api: "present", marker: null, standalone: true }, overlay: true },
    { project: "webkit-ipad", name: "safari-tab", setup: { api: "present", marker: null, standalone: false }, overlay: false },
    { project: "webkit-iphone", name: "burrow-ios", setup: { api: "present", marker: "ios", standalone: false }, overlay: true },
    {
      project: "chromium-android",
      name: "burrow-android",
      setup: { api: "present", marker: "android", standalone: false },
      overlay: false,
    },
    { project: "chromium-desktop", name: "desktop", setup: { api: "present", marker: null, standalone: false }, overlay: false },
  ]
  for (const v of CLOSE_VARIANTS) {
    test(`CLOSE CONTROLS ${v.project} ${v.name}: exactly one reachable close control, exits on first tap and first Escape`, async ({
      page,
    }, testInfo) => {
      test.skip(project(testInfo) !== v.project, `${v.project} only`)
      const p = project(testInfo)
      const closeControls = () =>
        page.evaluate(() => {
          const sel = 'button, a[href], [role="button"], input[type="button"], input[type="submit"]'
          const all = Array.from(document.querySelectorAll(sel)) as HTMLElement[]
          const named = all
            .map((el) => ({
              el,
              name: (el.getAttribute("aria-label") || el.getAttribute("title") || el.textContent || "").trim(),
            }))
            .filter((c) => /close|exit/i.test(c.name))
          const reachable = named.filter(({ el }) => {
            const r = el.getBoundingClientRect()
            if (r.width <= 0 || r.height <= 0) return false
            const cs = getComputedStyle(el)
            if (cs.visibility === "hidden" || cs.display === "none" || cs.opacity === "0") return false
            const cx = r.left + r.width / 2
            const cy = r.top + r.height / 2
            if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return false
            const hit = document.elementFromPoint(cx, cy)
            return !!hit && (hit === el || el.contains(hit))
          })
          return {
            named: named.map((c) => c.name),
            reachable: reachable.map((c) => ({ name: c.name, role: c.el.getAttribute("data-role") })),
          }
        })
      await openSpace(page, testInfo, v.setup)
      await tapFullscreen(page, testInfo)
      const entered = await snapshot(page, `CLOSE ${v.name} entered`)
      const cc = await closeControls()
      if (v.name === "burrow-ios" && p === "webkit-ipad") {
        // Mid-drag evidence shot for the overlay path under the Burrow marker.
        const frame = await protoFrame(page)
        const [d] = await dragSet(page, frame)
        await page.mouse.move(d.from.x, d.from.y)
        const before = await moves(frame)
        await mouseDrag(page, d, async () => {
          await shot(page, testInfo, "CLOSE-burrow-ios-mid-drag")
          const mid = await snapshot(page, "CLOSE burrow-ios mid-drag")
          logResult(testInfo, "CLOSE-burrow-ios-mid-drag", {
            fs: mid.fs,
            fullscreenElement: mid.fullscreenElement,
            popoverOpen: mid.popoverOpen,
            pressedSoFar: delta(await moves(frame), before).pressed,
          })
        })
        await page.waitForTimeout(SETTLE_MS)
        const after = await snapshot(page, "CLOSE burrow-ios after drag")
        const m = delta(await moves(frame), before)
        logResult(testInfo, "CLOSE-burrow-ios-after-drag", { moves: m.pressed, fs: after.fs, fe: after.fullscreenElement })
        expect.soft(m.pressed, "burrow-ios: the drag never reached the prototype").toBeGreaterThan(0)
        expect.soft(after.fs, "burrow-ios: the drag left fullscreen").toBe("true")
      }
      logResult(testInfo, `CLOSE-${v.name}`, {
        named: cc.named,
        reachable: cc.reachable,
        fullscreenElement: entered.fullscreenElement,
        popoverOpen: entered.popoverOpen,
      })
      expect.soft(cc.reachable.length, `${v.name}: reachable close controls`).toBe(1)
      expect.soft(cc.reachable[0]?.role, `${v.name}: the one close control is not the bar X`).toBe(
        "prototype-fullscreen-close",
      )
      if (v.overlay) {
        expect.soft(entered.fullscreenElement, `${v.name}: native fullscreen (system UI) is engaged`).toBe("(null)")
        expect.soft(entered.popoverOpen, `${v.name}: the root is not in the top layer`).toBe(true)
      }
      // The bar X exits on the first tap.
      const close = page.locator('[data-role="prototype-fullscreen-close"]').first()
      if (p === "chromium-desktop") await close.click()
      else await close.tap()
      await expect(page.locator(ROOT).first()).toHaveAttribute("data-fullscreen", "false", { timeout: 3_000 })
      await page.waitForTimeout(SETTLE_MS)
      const closed = await snapshot(page, `CLOSE ${v.name} after one tap`)
      expect.soft(closed.fullscreenElement, `${v.name}: native fullscreen survived the X`).toBe("(null)")
      expect.soft(closed.popoverOpen, `${v.name}: the top layer survived the X`).toBe(false)
      // Re-enter; Escape exits on the first press. Focus stays on the bar
      // button after the tap (no press inside the frame), so the key reaches
      // the web app's phx-window-keydown; logged to show it.
      await tapFullscreen(page, testInfo)
      const active = await page.evaluate(() => {
        const a = document.activeElement as HTMLElement | null
        return a ? `${a.tagName.toLowerCase()}[${a.getAttribute("data-role") ?? ""}]` : "(none)"
      })
      await page.keyboard.press("Escape")
      await expect(page.locator(ROOT).first()).toHaveAttribute("data-fullscreen", "false", { timeout: 3_000 })
      await page.waitForTimeout(SETTLE_MS)
      const esc = await snapshot(page, `CLOSE ${v.name} after one Escape`)
      logResult(testInfo, `CLOSE-${v.name}-exits`, {
        afterTap: { fs: closed.fs, fe: closed.fullscreenElement, open: closed.popoverOpen },
        escapeActiveElement: active,
        afterEscape: { fs: esc.fs, fe: esc.fullscreenElement, open: esc.popoverOpen },
      })
      expect.soft(esc.fullscreenElement, `${v.name}: native fullscreen survived Escape`).toBe("(null)")
      expect.soft(esc.popoverOpen, `${v.name}: the top layer survived Escape`).toBe(false)
    })
  }
})

async function nativeCase(page: Page, testInfo: TestInfo, caseName: string) {
  const pre = await snapshot(page, `${caseName} before tap`)
  await tapFullscreen(page, testInfo)
  const entered = await snapshot(page, `${caseName} entered`)
  expect.soft(entered.requestCalls - pre.requestCalls, `${caseName}: requestFullscreen not called`).toBe(1)
  expect.soft(entered.fullscreenElementIsRoot, `${caseName}: the root is not the fullscreen element`).toBe(true)
  expect.soft(entered.popoverAttr, `${caseName}: the native path got a popover attribute`).toBeNull()
  const frame = await protoFrame(page)
  const cdp = await cdpFor(page, testInfo)
  const results: DragResult[] = []
  for (const d of await dragSet(page, frame)) {
    const base = await snapshot(page, `${caseName} before ${d.name}`)
    for (const r of await runDrag(page, testInfo, frame, d, cdp)) {
      expectStayed(r, base, "native")
      results.push(r)
    }
  }
  await shot(page, testInfo, `${caseName}-after-drags`)
  logResult(testInfo, caseName, {
    requestCalls: entered.requestCalls - pre.requestCalls,
    fullscreenElement: entered.fullscreenElement,
    popoverAttr: entered.popoverAttr,
    drags: summarise(results),
  })
}

function summarise(results: DragResult[]) {
  return results.map((r) => ({
    drag: r.drag,
    driver: r.driver,
    ms: r.ms,
    moves: r.moves.pressed,
    fs: r.after.fs,
    popoverOpen: r.after.popoverOpen,
    fsElement: r.after.fullscreenElement,
    pushes: r.after.pushes.length,
    hide: r.after.hidePopover,
    mounts: r.after.hookMounts,
    loads: r.after.loads,
    scrollerTop: r.after.scrollerTop,
    scrollY: r.after.scrollY,
    vvTop: r.after.vv?.offsetTop,
    vvPageTop: r.after.vv?.pageTop,
  }))
}
