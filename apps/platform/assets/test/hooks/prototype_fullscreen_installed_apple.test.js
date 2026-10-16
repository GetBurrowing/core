import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import PrototypeFullscreen, { prefersOverlay } from "../../js/hooks/prototype_fullscreen.js"

// Task 01a1389f v2: Burrow iOS and the installed Apple PWA stay on the
// top-layer overlay instead of WebKit's native fullscreen UI, whose
// drag-to-dismiss gesture exits the prototype mid-drag.

const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
// iPadOS Safari presents a desktop-class Macintosh UA; only touch points tell
// it apart from a Mac.
const IPADOS_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
const ANDROID_UA =
  "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"

function burrowMarker(platform = "ios") {
  return {
    DEBUG: false,
    isLoggingEnabled: false,
    Plugins: {},
    isNativePlatform: () => true,
    getPlatform: () => platform,
  }
}

function makeWin({ ua = IPADOS_UA, maxTouchPoints = 5, standalone = false, navStandalone, capacitor } = {}) {
  const win = {
    navigator: { userAgent: ua, maxTouchPoints },
    matchMedia: (q) => ({ matches: q === "(display-mode: standalone)" && standalone }),
  }
  if (navStandalone !== undefined) win.navigator.standalone = navStandalone
  if (capacitor !== undefined) win.Capacitor = capacitor
  return win
}

describe("prefersOverlay", () => {
  it("is true under the Burrow iOS marker, whatever the UA says", () => {
    for (const ua of [IPADOS_UA, IPHONE_UA, ANDROID_UA, "", "SomethingElse/1.0"]) {
      expect(prefersOverlay(makeWin({ ua, maxTouchPoints: 0, capacitor: burrowMarker("ios") }))).toBe(true)
    }
  })

  it("is false for Burrow Android (getPlatform 'android')", () => {
    expect(prefersOverlay(makeWin({ ua: ANDROID_UA, capacitor: burrowMarker("android") }))).toBe(false)
    // Even on an Apple UA, the android marker alone does not select the overlay.
    expect(prefersOverlay(makeWin({ ua: IPADOS_UA, capacitor: burrowMarker("android") }))).toBe(false)
  })

  it("MARKER-ABSENT CONTROL: deleting window.Capacitor in the same context flips it to false", () => {
    const win = makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, standalone: false, capacitor: burrowMarker("ios") })
    expect(prefersOverlay(win)).toBe(true)
    delete win.Capacitor
    expect(prefersOverlay(win)).toBe(false)
  })

  it("is false when isNativePlatform is missing or false", () => {
    const missing = { Plugins: {}, getPlatform: () => "ios" }
    const falsy = { Plugins: {}, isNativePlatform: () => false, getPlatform: () => "ios" }
    expect(prefersOverlay(makeWin({ capacitor: missing }))).toBe(false)
    expect(prefersOverlay(makeWin({ capacitor: falsy }))).toBe(false)
  })

  it("iPadOS Macintosh UA + maxTouchPoints 5: true when standalone, false when not", () => {
    expect(prefersOverlay(makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, standalone: true }))).toBe(true)
    expect(prefersOverlay(makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, standalone: false }))).toBe(false)
  })

  it("navigator.standalone true on an iPhone UA is true", () => {
    expect(prefersOverlay(makeWin({ ua: IPHONE_UA, maxTouchPoints: 5, navStandalone: true }))).toBe(true)
  })

  it("desktop Mac Safari (maxTouchPoints 0) + standalone is false", () => {
    expect(prefersOverlay(makeWin({ ua: IPADOS_UA, maxTouchPoints: 0, standalone: true }))).toBe(false)
    expect(prefersOverlay(makeWin({ ua: IPADOS_UA, maxTouchPoints: 0, navStandalone: true }))).toBe(false)
  })

  it("an installed Android PWA is false (native path unchanged)", () => {
    expect(prefersOverlay(makeWin({ ua: ANDROID_UA, standalone: true }))).toBe(false)
  })

  it("is false with no window at all (node, jsdom-less)", () => {
    expect(prefersOverlay(undefined)).toBe(false)
  })
})

function setupHook() {
  const doc = {
    fullscreenEnabled: true,
    fullscreenElement: null,
    addEventListener: () => {},
    removeEventListener: () => {},
    exitFullscreen: vi.fn(() => Promise.resolve()),
  }
  globalThis.document = doc
  const btn = { closest: () => btn }
  const attrs = new Map()
  const el = {
    dataset: { fullscreen: "false" },
    _open: false,
    requestFullscreen: vi.fn(() => Promise.resolve()),
    contains: () => true,
    addEventListener: (t, f) => (el._click = f),
    removeEventListener: () => {},
    getAttribute: (n) => (attrs.has(n) ? attrs.get(n) : null),
    hasAttribute: (n) => attrs.has(n),
    setAttribute: (n, v) => attrs.set(n, String(v)),
    removeAttribute: (n) => {
      attrs.delete(n)
      if (n === "popover") el._open = false
    },
    matches: () => el._open,
    showPopover: vi.fn(() => {
      if (!attrs.has("popover")) throw new Error("NotSupportedError")
      el._open = true
    }),
    hidePopover: vi.fn(() => (el._open = false)),
  }
  const js = {
    setAttribute: vi.fn((target, n, v) => target.setAttribute(n, v)),
    removeAttribute: vi.fn((target, n) => target.removeAttribute(n)),
  }
  const hook = Object.create(PrototypeFullscreen)
  hook.el = el
  hook.pushEventTo = vi.fn()
  hook.js = () => js
  hook.mounted()
  return { doc, el, hook, btn }
}

describe("PrototypeFullscreen onClick under prefersOverlay", () => {
  let savedDoc, savedWin
  beforeEach(() => {
    savedDoc = globalThis.document
    savedWin = globalThis.window
  })
  afterEach(() => {
    globalThis.document = savedDoc
    if (savedWin === undefined) delete globalThis.window
    else globalThis.window = savedWin
  })

  it("under the Burrow marker never calls requestFullscreen and promotes on updated()", () => {
    globalThis.window = makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, capacitor: burrowMarker("ios") })
    const { el, hook, btn, doc } = setupHook()
    el._click({ target: btn })
    expect(el.requestFullscreen).not.toHaveBeenCalled()
    el.dataset.fullscreen = "true"
    hook.updated()
    expect(el.showPopover).toHaveBeenCalledTimes(1)
    expect(el.getAttribute("popover")).toBe("manual")
    expect(el._open).toBe(true)
    expect(doc.fullscreenElement).toBe(null)
  })

  it("CONTROL: the same click in a plain iPad Safari tab still requests native", () => {
    globalThis.window = makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, standalone: false })
    const { el, btn } = setupHook()
    el._click({ target: btn })
    expect(el.requestFullscreen).toHaveBeenCalledTimes(1)
  })

  it("an installed iPad PWA (standalone) stays on the overlay", () => {
    globalThis.window = makeWin({ ua: IPADOS_UA, maxTouchPoints: 5, standalone: true })
    const { el, hook, btn } = setupHook()
    el._click({ target: btn })
    expect(el.requestFullscreen).not.toHaveBeenCalled()
    el.dataset.fullscreen = "true"
    hook.updated()
    expect(el._open).toBe(true)
  })
})
