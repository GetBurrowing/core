import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { fakeDocument } from "./fake_dom.js"
import {
  openLayer,
  openLayerCount,
  __resetForTests,
  CLOSE_CONTROL_CLASS,
  SWIPE_CLOSE_PX,
} from "../../js/lib/dismissable_overlay.js"

// A window with real listener bookkeeping and a history whose back() only
// records the call: the test fires the echoing popstate itself, the way a
// browser does asynchronously after back().
function fakeWindow() {
  const listeners = {}
  const w = {
    location: { href: "https://app.test/chat/general?x=1" },
    history: {
      state: { type: "patch", id: "phx-1", position: 3 },
      pushState: vi.fn((state) => {
        w.history.state = state
      }),
      back: vi.fn(),
    },
    addEventListener: (type, fn, capture) => (listeners[type] ||= []).push({ fn, capture: !!capture }),
    removeEventListener: (type, fn) => {
      listeners[type] = (listeners[type] || []).filter((l) => l.fn !== fn)
    },
    listeners,
    fire(type, event = {}) {
      for (const l of [...(listeners[type] || [])]) l.fn({ type, ...event })
    },
  }
  return w
}

function layerEl(doc, name) {
  const el = doc.createElement("div")
  el.setAttribute("id", name)
  const x = doc.createElement("button")
  x.setAttribute("class", `${CLOSE_CONTROL_CLASS} btn`)
  x.setAttribute("id", `${name}-x`)
  el.appendChild(x)
  return { el, x }
}

function keyEvent(key) {
  return {
    key,
    preventDefault: vi.fn(),
    stopImmediatePropagation: vi.fn(),
  }
}

describe("dismissable_overlay", () => {
  let win, doc, prevWindow

  beforeEach(() => {
    __resetForTests()
    prevWindow = globalThis.window
    win = fakeWindow()
    globalThis.window = win
    doc = fakeDocument()
  })

  afterEach(() => {
    __resetForTests()
    if (prevWindow === undefined) delete globalThis.window
    else globalThis.window = prevWindow
  })

  it("open pushes exactly one entry, at the same url, keeping LiveView's state", () => {
    const { el } = layerEl(doc, "a")
    openLayer({ el, onClose: () => {} })
    expect(win.history.pushState).toHaveBeenCalledTimes(1)
    const [state, , url] = win.history.pushState.mock.calls[0]
    expect(url).toBe("https://app.test/chat/general?x=1")
    expect(state).toEqual({ type: "patch", id: "phx-1", position: 3, overlayDepth: 1 })

    const { el: el2 } = layerEl(doc, "b")
    openLayer({ el: el2, onClose: () => {} })
    expect(win.history.pushState).toHaveBeenCalledTimes(2)
    expect(win.history.pushState.mock.calls[1][0].overlayDepth).toBe(2)
  })

  it("installs one popstate and one capture-phase keydown listener however many layers open", () => {
    for (const n of ["a", "b", "c"]) openLayer({ el: layerEl(doc, n).el, onClose: () => {} })
    expect(win.listeners.popstate).toHaveLength(1)
    expect(win.listeners.keydown).toHaveLength(1)
    expect(win.listeners.keydown[0].capture).toBe(true)
  })

  it("popstate closes only the top of two layers", () => {
    const closedA = vi.fn()
    const closedB = vi.fn()
    openLayer({ el: layerEl(doc, "a").el, onClose: closedA })
    const b = openLayer({ el: layerEl(doc, "b").el, onClose: closedB })

    win.fire("popstate")
    expect(closedB).toHaveBeenCalledTimes(1)
    expect(closedA).not.toHaveBeenCalled()
    expect(b.isOpen()).toBe(false)
    expect(openLayerCount()).toBe(1)
    // The entry is already gone: a popstate close never goes back again.
    expect(win.history.back).not.toHaveBeenCalled()

    win.fire("popstate")
    expect(closedA).toHaveBeenCalledTimes(1)
    expect(openLayerCount()).toBe(0)
  })

  it("Escape closes only the top layer and is swallowed", () => {
    const closedA = vi.fn()
    const closedB = vi.fn()
    openLayer({ el: layerEl(doc, "a").el, onClose: closedA })
    openLayer({ el: layerEl(doc, "b").el, onClose: closedB })

    const esc = keyEvent("Escape")
    win.fire("keydown", esc)
    expect(closedB).toHaveBeenCalledTimes(1)
    expect(closedA).not.toHaveBeenCalled()
    expect(esc.preventDefault).toHaveBeenCalled()
    expect(esc.stopImmediatePropagation).toHaveBeenCalled()
    expect(win.history.back).toHaveBeenCalledTimes(1)

    const other = keyEvent("a")
    win.fire("keydown", other)
    expect(other.preventDefault).not.toHaveBeenCalled()
    expect(closedA).not.toHaveBeenCalled()
  })

  it("X close calls history.back once, and the echoing popstate does not close the layer below", () => {
    const closedA = vi.fn()
    const closedB = vi.fn()
    const a = openLayer({ el: layerEl(doc, "a").el, onClose: closedA })
    const b = openLayer({ el: layerEl(doc, "b").el, onClose: closedB })

    b.close()
    expect(closedB).toHaveBeenCalledTimes(1)
    expect(win.history.back).toHaveBeenCalledTimes(1)

    // The browser's echo of that back().
    win.fire("popstate")
    expect(closedA).not.toHaveBeenCalled()
    expect(a.isOpen()).toBe(true)

    // A close is idempotent: no second onClose, no second back().
    b.close()
    expect(closedB).toHaveBeenCalledTimes(1)
    expect(win.history.back).toHaveBeenCalledTimes(1)

    // The next real back closes A.
    win.fire("popstate")
    expect(closedA).toHaveBeenCalledTimes(1)
  })

  it("focus moves to the close control on open and returns on close", () => {
    const opener = doc.createElement("button")
    opener.focus()
    const { el, x } = layerEl(doc, "a")
    const h = openLayer({ el, onClose: () => {}, returnFocusTo: opener })
    expect(doc.activeElement).toBe(x)
    h.close()
    expect(doc.activeElement).toBe(opener)
  })

  it("a 150px swipe-down closes; focus returns; a short one springs back", () => {
    const opener = doc.createElement("button")
    const { el } = layerEl(doc, "a")
    const closed = vi.fn()
    openLayer({ el, onClose: closed, swipeTarget: el, returnFocusTo: opener })

    el.fire("pointerdown", { pointerId: 1, button: 0, clientY: 100 })
    el.fire("pointermove", { pointerId: 1, clientY: 160 })
    expect(el.style.transform).toBe("translateY(60px)")
    el.fire("pointerup", { pointerId: 1, clientY: 160 })
    expect(closed).not.toHaveBeenCalled()
    expect(el.style.transform).toBe("")

    expect(150).toBeGreaterThan(SWIPE_CLOSE_PX)
    el.fire("pointerdown", { pointerId: 2, button: 0, clientY: 100 })
    el.fire("pointermove", { pointerId: 2, clientY: 250 })
    el.fire("pointerup", { pointerId: 2, clientY: 250 })
    expect(closed).toHaveBeenCalledTimes(1)
    expect(win.history.back).toHaveBeenCalledTimes(1)
    expect(doc.activeElement).toBe(opener)
  })

  it("the caller's canSwipe gate and a second finger stop a swipe", () => {
    const { el } = layerEl(doc, "a")
    const closed = vi.fn()
    let allow = false
    openLayer({ el, onClose: closed, swipeTarget: el, canSwipe: () => allow })

    el.fire("pointerdown", { pointerId: 1, button: 0, clientY: 100 })
    el.fire("pointerup", { pointerId: 1, clientY: 300 })
    expect(closed).not.toHaveBeenCalled()

    allow = true
    el.fire("pointerdown", { pointerId: 2, button: 0, clientY: 100 })
    el.fire("pointerdown", { pointerId: 3, button: 0, clientY: 100 })
    el.fire("pointerup", { pointerId: 2, clientY: 300 })
    el.fire("pointerup", { pointerId: 3, clientY: 300 })
    expect(closed).not.toHaveBeenCalled()
  })

  it("release forgets a layer without onClose and without going back", () => {
    const closed = vi.fn()
    const h = openLayer({ el: layerEl(doc, "a").el, onClose: closed })
    h.release()
    expect(closed).not.toHaveBeenCalled()
    expect(win.history.back).not.toHaveBeenCalled()
    expect(openLayerCount()).toBe(0)
    win.fire("popstate")
    expect(closed).not.toHaveBeenCalled()
  })
})
