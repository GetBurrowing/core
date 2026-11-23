import { describe, it, expect } from "vitest"
import {
  fixedOriginInClient,
  keyboardState,
  roomAbove,
  visibleViewportRect,
  watchKeyboard,
  KEYBOARD_ATTR,
  KEYBOARD_INSET_VAR,
  KEYBOARD_MIN_PX,
  VISUAL_VIEWPORT_H_VAR,
} from "../../js/lib/keyboard_inset.js"

// iPhone 16 installed PWA: 852px layout viewport; the keyboard plus its
// accessory bar takes ~380px of it.
const LAYOUT = 852
const KEYBOARD = 380

function fakeViewport(height) {
  const listeners = {}
  return {
    height,
    offsetTop: 0,
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    fire(type) {
      for (const fn of listeners[type] || []) fn()
    },
    count(type) {
      return (listeners[type] || []).length
    },
  }
}

function fakeRoot() {
  return {
    attrs: {},
    props: {},
    setAttribute(k, v) {
      this.attrs[k] = v
    },
    removeAttribute(k) {
      delete this.attrs[k]
    },
    style: {
      props: {},
      setProperty(k, v) {
        this.props[k] = v
      },
      removeProperty(k) {
        delete this.props[k]
      },
    },
  }
}

function setup(height = LAYOUT) {
  const vv = fakeViewport(height)
  const win = { visualViewport: vv, innerHeight: LAYOUT, innerWidth: 390 }
  const root = fakeRoot()
  const detach = watchKeyboard(win, { documentElement: root })
  return { vv, win, root, detach }
}

describe("keyboardState", () => {
  it("is closed when the visual viewport is at its baseline", () => {
    expect(keyboardState({ innerHeight: LAYOUT, vvHeight: LAYOUT, vvOffsetTop: 0, baseline: LAYOUT })).toEqual({
      open: false,
      inset: 0,
    })
  })

  it("is closed for a browser-chrome-sized change", () => {
    const s = keyboardState({ innerHeight: LAYOUT, vvHeight: LAYOUT - 100, vvOffsetTop: 0, baseline: LAYOUT })
    expect(s.open).toBe(false)
  })

  it("is open at the threshold and reports the hidden layout band before any pan", () => {
    const s = keyboardState({
      innerHeight: LAYOUT,
      vvHeight: LAYOUT - KEYBOARD_MIN_PX,
      vvOffsetTop: 0,
      baseline: LAYOUT,
    })
    expect(s).toEqual({ open: true, inset: KEYBOARD_MIN_PX })
  })

  it("reports 0 inset once iOS has panned the visual viewport to the bottom", () => {
    const s = keyboardState({
      innerHeight: LAYOUT,
      vvHeight: LAYOUT - KEYBOARD,
      vvOffsetTop: KEYBOARD,
      baseline: LAYOUT,
    })
    expect(s).toEqual({ open: true, inset: 0 })
  })

  it("detects a resizes-content keyboard, where innerHeight shrinks too", () => {
    const h = LAYOUT - KEYBOARD
    const s = keyboardState({ innerHeight: h, vvHeight: h, vvOffsetTop: 0, baseline: LAYOUT })
    expect(s).toEqual({ open: true, inset: 0 })
  })
})

describe("watchKeyboard", () => {
  it("sets the attribute and inset while the keyboard is up and clears them after", () => {
    const { vv, root } = setup()
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()

    vv.height = LAYOUT - KEYBOARD
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")
    expect(root.style.props[KEYBOARD_INSET_VAR]).toBe(`${KEYBOARD}px`)

    vv.offsetTop = KEYBOARD
    vv.fire("scroll")
    expect(root.style.props[KEYBOARD_INSET_VAR]).toBe("0px")

    vv.height = LAYOUT
    vv.offsetTop = 0
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
    expect(root.style.props[KEYBOARD_INSET_VAR]).toBeUndefined()
  })

  it("re-baselines on a width change, so a rotation does not read as a keyboard", () => {
    const { vv, win, root } = setup()
    win.innerWidth = 844
    win.innerHeight = 390
    vv.height = 390
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
  })

  it("rotating back to a width seen without the keyboard restores its baseline, so a keyboard kept up through the rotation still reads open", () => {
    // Measured shape, task 01a1c863 stage 3: portrait, landscape with the
    // keyboard up, back to portrait with it still up (vv 409 of 714).
    const { vv, win, root } = setup()
    win.innerWidth = 844
    win.innerHeight = 390
    vv.height = 390
    vv.fire("resize")
    vv.height = 120
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")

    win.innerWidth = 390
    win.innerHeight = LAYOUT
    vv.height = LAYOUT - KEYBOARD
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")
    expect(root.style.props[KEYBOARD_INSET_VAR]).toBe(`${KEYBOARD}px`)

    vv.height = LAYOUT
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
  })

  // Task 01a20618: the open iPhone Duo, with the web view sizes measured on
  // the device by the DEBUG geometry probe. Folded the web view is 382x678
  // (side strip), unfolded landscape 867x669 (strip), portrait 669x951. In
  // the app's WKWebView the keyboard shrinks innerHeight with the visual
  // viewport (measured 867x323 with the keyboard up in landscape).
  function duo(width, height) {
    const vv = fakeViewport(height)
    const win = { visualViewport: vv, innerHeight: height, innerWidth: width }
    const root = fakeRoot()
    const detach = watchKeyboard(win, { documentElement: root })
    const resize = (w, h, vvH = h) => {
      win.innerWidth = w
      win.innerHeight = h
      vv.height = vvH
      vv.fire("resize")
    }
    return { vv, win, root, detach, resize }
  }

  function expectClosed(root) {
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
    expect(root.style.props[KEYBOARD_INSET_VAR]).toBeUndefined()
    expect(root.style.props[VISUAL_VIEWPORT_H_VAR]).toBeUndefined()
  }

  it("folded -> unfolded in landscape -> portrait with no keyboard never reads as a keyboard (the device repro)", () => {
    const { root, resize, detach } = duo(382, 678)
    resize(466, 678)
    resize(951, 669)
    resize(867, 669)
    expectClosed(root)
    resize(585, 951)
    resize(669, 951)
    expectClosed(root)
    resize(867, 669)
    expectClosed(root)
    detach()
  })

  it("open Duo: keyboard up at 669, turned to landscape with it up, dismissed, turned back: no keyboard state remains", () => {
    const { root, resize, detach } = duo(669, 951)
    resize(669, 951, 951 - KEYBOARD)
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")
    resize(867, 669, 669 - KEYBOARD)
    resize(867, 669)
    resize(669, 951)
    expectClosed(root)
    detach()
  })

  it("fold widths 466 -> 669 -> 466 with the keyboard raised and dismissed at each leave no keyboard state", () => {
    const { root, resize, detach } = duo(466, 678)
    resize(466, 678, 678 - KEYBOARD)
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")
    resize(466, 678)
    resize(669, 951)
    resize(669, 951, 951 - KEYBOARD)
    expect(root.attrs[KEYBOARD_ATTR]).toBe("")
    resize(669, 951)
    resize(466, 678)
    expectClosed(root)
    detach()
  })

  it("a width never seen still takes the current height as its baseline", () => {
    const { vv, win, root } = setup()
    win.innerWidth = 844
    win.innerHeight = 390
    vv.height = 300
    vv.fire("resize")
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
  })

  it("detaches its listeners and clears the state", () => {
    const { vv, root, detach } = setup()
    vv.height = LAYOUT - KEYBOARD
    vv.fire("resize")
    detach()
    expect(vv.count("resize")).toBe(0)
    expect(vv.count("scroll")).toBe(0)
    expect(root.attrs[KEYBOARD_ATTR]).toBeUndefined()
  })

  it("is a no-op without visualViewport", () => {
    const root = fakeRoot()
    const detach = watchKeyboard({ innerHeight: LAYOUT, innerWidth: 390 }, { documentElement: root })
    detach()
    expect(root.attrs).toEqual({})
  })
})

describe("watchKeyboard is shared by reference count", () => {
  const OPEN_H = LAYOUT - KEYBOARD

  function shared() {
    const vv = fakeViewport(LAYOUT)
    const win = { visualViewport: vv, innerHeight: LAYOUT, innerWidth: 390 }
    const root = fakeRoot()
    const doc = { documentElement: root }
    return { vv, win, root, doc }
  }

  const state = (root) => ({
    open: root.attrs[KEYBOARD_ATTR],
    inset: root.style.props[KEYBOARD_INSET_VAR],
    height: root.style.props[VISUAL_VIEWPORT_H_VAR],
  })

  it("publishes the visible height while open and nothing while closed", () => {
    const { vv, win, root, doc } = shared()
    const detach = watchKeyboard(win, doc)
    expect(state(root).height).toBeUndefined()

    vv.height = OPEN_H
    vv.fire("resize")
    expect(state(root)).toEqual({ open: "", inset: `${KEYBOARD}px`, height: `${OPEN_H}px` })

    vv.height = LAYOUT
    vv.fire("resize")
    expect(state(root)).toEqual({ open: undefined, inset: undefined, height: undefined })
    detach()
  })

  it("two callers share one listener; only the last detach clears <html> and removes it", () => {
    const { vv, win, root, doc } = shared()
    const detachA = watchKeyboard(win, doc)
    const detachB = watchKeyboard(win, doc)
    expect(vv.count("resize")).toBe(1)
    expect(vv.count("scroll")).toBe(1)

    vv.height = OPEN_H
    vv.fire("resize")
    expect(state(root)).toEqual({ open: "", inset: `${KEYBOARD}px`, height: `${OPEN_H}px` })

    detachA()
    // A second call from the same caller counts once, so it cannot release B's hold.
    detachA()
    expect(state(root)).toEqual({ open: "", inset: `${KEYBOARD}px`, height: `${OPEN_H}px` })
    expect(vv.count("resize")).toBe(1)

    // B is still attached and still tracking.
    vv.height = OPEN_H - 20
    vv.fire("resize")
    expect(state(root).height).toBe(`${OPEN_H - 20}px`)

    detachB()
    expect(state(root)).toEqual({ open: undefined, inset: undefined, height: undefined })
    expect(vv.count("resize")).toBe(0)
    expect(vv.count("scroll")).toBe(0)
  })

  it("a caller attaching after everyone detached starts a fresh watcher", () => {
    const { vv, win, root, doc } = shared()
    watchKeyboard(win, doc)()
    expect(vv.count("resize")).toBe(0)
    const detach = watchKeyboard(win, doc)
    expect(vv.count("resize")).toBe(1)
    vv.height = OPEN_H
    vv.fire("resize")
    expect(state(root).open).toBe("")
    detach()
    expect(state(root).open).toBeUndefined()
  })
})

// Task 01a1c863: the visible top must be in client coordinates in both
// engines. Numbers are the measured iOS 26.3 WebKit pan and its Chromium
// equivalent (layout fixed, visual viewport panned).
describe("visibleViewportRect / roomAbove", () => {
  const webkitPanned = {
    innerWidth: 402, innerHeight: 377, scrollY: 337, scrollX: 0,
    visualViewport: { width: 402, height: 377, offsetTop: 337, offsetLeft: 0, pageTop: 337, pageLeft: 0 },
  }
  const chromiumPanned = {
    innerWidth: 402, innerHeight: 714, scrollY: 0, scrollX: 0,
    visualViewport: { width: 402, height: 377, offsetTop: 337, offsetLeft: 0, pageTop: 337, pageLeft: 0 },
  }

  it("WebKit scrolled the document: the visible top is client 0, not offsetTop", () => {
    expect(visibleViewportRect(webkitPanned)).toEqual({ top: 0, left: 0, width: 402, height: 377 })
  })

  it("Chromium panned the visual viewport: the visible top is offsetTop", () => {
    expect(visibleViewportRect(chromiumPanned).top).toBe(337)
  })

  it("a document scroll plus a pinch pan adds up to pageTop - scrollY", () => {
    const win = {
      innerWidth: 402, innerHeight: 714, scrollY: 500, scrollX: 0,
      visualViewport: { width: 201, height: 357, offsetTop: 40, offsetLeft: 30, pageTop: 540, pageLeft: 30 },
    }
    expect(visibleViewportRect(win)).toEqual({ top: 40, left: 30, width: 201, height: 357 })
  })

  it("falls back to offsetTop without pageTop, and to the window without visualViewport", () => {
    expect(visibleViewportRect({ scrollY: 337, visualViewport: { width: 1, height: 2, offsetTop: 5, offsetLeft: 6 } }))
      .toEqual({ top: 5, left: 6, width: 1, height: 2 })
    expect(visibleViewportRect({ innerWidth: 800, innerHeight: 600 })).toEqual({ top: 0, left: 0, width: 800, height: 600 })
  })

  it("fixedOriginInClient: -offsetTop in panned WebKit, 0 in Chromium, 0 without pageTop or visualViewport", () => {
    expect(fixedOriginInClient(webkitPanned)).toEqual({ top: -337, left: 0 })
    expect(fixedOriginInClient(chromiumPanned)).toEqual({ top: 0, left: 0 })
    expect(fixedOriginInClient({ visualViewport: { offsetTop: 40, offsetLeft: 0 } })).toEqual({ top: 0, left: 0 })
    expect(fixedOriginInClient({ innerWidth: 800, innerHeight: 600 })).toEqual({ top: 0, left: 0 })
  })

  it("roomAbove: bounded by the visible top or the ceiling, whichever is lower on screen, never negative", () => {
    expect(roomAbove(325, { win: webkitPanned, ceilingTop: -293, gap: 2 })).toBe(323)
    expect(roomAbove(662, { win: chromiumPanned, ceilingTop: 44, gap: 2 })).toBe(323)
    expect(roomAbove(662, { win: { visualViewport: null }, ceilingTop: 44, gap: 2 })).toBe(616)
    expect(roomAbove(-12, { win: webkitPanned, gap: 2 })).toBe(0)
  })
})
