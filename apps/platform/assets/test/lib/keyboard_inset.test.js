import { describe, it, expect } from "vitest"
import {
  keyboardState,
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
