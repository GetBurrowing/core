import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import Sheet, { SWIPE_CLOSE_PX } from "../../js/hooks/sheet.js"

/**
 * The Sheet hook's opt-in swipe-down-to-close (task 01a1557a-807f stage 4).
 *
 * Vitest's default env is node, so, like route_resume.test.js, this installs
 * a minimal `document` / `window` shim and drives the hook with synthetic
 * pointer events on a fake panel, no jsdom. Covered: the 60px threshold (59
 * stays, 61 closes), the scrolled-list guard (and its handle exception), an
 * upward drag, `pushEventTo` routing, reduced motion, cleanup in
 * `destroyed()`, and a sheet without `data-swipe-dismiss` ignoring pointers.
 */

// ── Shims ─────────────────────────────────────────────────────────────

class FakeNode {
  constructor({ classes = [], parent = null } = {}) {
    this.classes = new Set(classes)
    this.parent = parent
    this.listeners = new Map()
    this.style = {}
    this.dataset = {}
    this.scrollTop = 0
    this.children = []
  }

  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(fn)
  }

  removeEventListener(type, fn) {
    this.listeners.get(type)?.delete(fn)
  }

  listenerCount(type) {
    return this.listeners.get(type)?.size ?? 0
  }

  dispatch(type, event) {
    for (const fn of [...(this.listeners.get(type) ?? [])]) fn(event)
  }

  matches(selector) {
    return selector
      .split(",")
      .map((s) => s.trim())
      .some((s) => s.startsWith(".") && this.classes.has(s.slice(1)))
  }

  closest(selector) {
    let node = this
    while (node) {
      if (node.matches && node.matches(selector)) return node
      node = node.parent
    }
    return null
  }

  querySelector(selector) {
    for (const child of this.children) {
      if (child.matches(selector)) return child
      const deep = child.querySelector(selector)
      if (deep) return deep
    }
    return null
  }

  querySelectorAll() {
    return []
  }

  append(child) {
    child.parent = this
    this.children.push(child)
    return child
  }
}

function buildSheet({ swipe = true, open = true, target } = {}) {
  const el = new FakeNode({ classes: ["sheet"] })
  el.dataset.open = String(open)
  el.dataset.onClose = "close_more_sheet"
  if (swipe) el.dataset.swipeDismiss = "true"
  if (target) el.dataset.onCloseTarget = target

  const panel = el.append(new FakeNode({ classes: ["sheet-panel"] }))
  const handleButton = panel.append(new FakeNode({ classes: ["sheet-handle-button"] }))
  const handleBar = handleButton.append(new FakeNode({ classes: ["sheet-handle"] }))
  const body = panel.append(new FakeNode({ classes: ["sheet-body"] }))
  const row = body.append(new FakeNode({ classes: ["more-sheet-row"] }))

  const hook = Object.create(Sheet)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.pushEventTo = vi.fn()

  return { hook, el, panel, handleButton, handleBar, body, row }
}

function drag(panel, from, { dy, pointerId = 1, steps = 3 } = {}) {
  const startY = 100
  panel.dispatch("pointerdown", { target: from, clientY: startY, pointerId, pointerType: "touch" })
  for (let i = 1; i <= steps; i++) {
    panel.dispatch("pointermove", {
      target: from,
      clientY: startY + Math.round((dy * i) / steps),
      pointerId,
      pointerType: "touch",
    })
  }
  panel.dispatch("pointerup", { target: from, clientY: startY + dy, pointerId, pointerType: "touch" })
}

let reduced = false

beforeEach(() => {
  reduced = false
  globalThis.document = new FakeNode()
  globalThis.window = {
    matchMedia: (query) => ({
      matches: query === "(prefers-reduced-motion: reduce)" ? reduced : false,
    }),
  }
  globalThis.requestAnimationFrame = (fn) => fn()
})

afterEach(() => {
  delete globalThis.document
  delete globalThis.window
  delete globalThis.requestAnimationFrame
})

// ── Tests ─────────────────────────────────────────────────────────────

describe("Sheet hook swipe-down", () => {
  it("uses the masters' 60px threshold", () => {
    expect(SWIPE_CLOSE_PX).toBe(60)
  })

  it("a 59px drag from the handle snaps back; 61px closes", () => {
    const s = buildSheet()
    s.hook.mounted()

    drag(s.panel, s.handleBar, { dy: 59 })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
    expect(s.panel.style.transform).toBe("")

    drag(s.panel, s.handleBar, { dy: 61 })
    expect(s.hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(s.hook.pushEvent).toHaveBeenCalledWith("close_more_sheet")
  })

  it("the panel follows the finger while dragging down", () => {
    const s = buildSheet()
    s.hook.mounted()
    s.panel.dispatch("pointerdown", { target: s.handleButton, clientY: 100, pointerId: 7, pointerType: "touch" })
    s.panel.dispatch("pointermove", { target: s.handleButton, clientY: 140, pointerId: 7, pointerType: "touch" })
    expect(s.panel.style.transform).toBe("translateY(40px)")
    expect(s.panel.style.transition).toBe("none")
  })

  it("a drag from a row closes when the list is at its top", () => {
    const s = buildSheet()
    s.hook.mounted()
    s.body.scrollTop = 0
    drag(s.panel, s.row, { dy: 80 })
    expect(s.hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("a drag that begins while the list is scrolled does nothing (the list scrolls)", () => {
    const s = buildSheet()
    s.hook.mounted()
    s.body.scrollTop = 120
    drag(s.panel, s.row, { dy: 200 })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
    expect(s.panel.style.transform ?? "").toBe("")
  })

  it("the handle still closes when the list is scrolled", () => {
    const s = buildSheet()
    s.hook.mounted()
    s.body.scrollTop = 120
    drag(s.panel, s.handleBar, { dy: 80 })
    expect(s.hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("an upward drag never moves the panel and never closes", () => {
    const s = buildSheet()
    s.hook.mounted()
    drag(s.panel, s.handleBar, { dy: -200 })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
    expect(s.panel.style.transform).toBe("")
  })

  it("routes to on_close_target with pushEventTo, as Escape does", () => {
    const s = buildSheet({ target: "#my-component" })
    s.hook.mounted()
    drag(s.panel, s.handleBar, { dy: 90 })
    expect(s.hook.pushEventTo).toHaveBeenCalledWith("#my-component", "close_more_sheet")
    expect(s.hook.pushEvent).not.toHaveBeenCalled()

    document.dispatch("keydown", { key: "Escape" })
    expect(s.hook.pushEventTo).toHaveBeenCalledTimes(2)
  })

  it("under reduced motion the panel does not follow, and a long drag still closes", () => {
    reduced = true
    const s = buildSheet()
    s.hook.mounted()
    s.panel.dispatch("pointerdown", { target: s.handleBar, clientY: 100, pointerId: 2, pointerType: "touch" })
    s.panel.dispatch("pointermove", { target: s.handleBar, clientY: 180, pointerId: 2, pointerType: "touch" })
    expect(s.panel.style.transform ?? "").toBe("")
    s.panel.dispatch("pointerup", { target: s.handleBar, clientY: 180, pointerId: 2, pointerType: "touch" })
    expect(s.hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("pointercancel snaps back without closing", () => {
    const s = buildSheet()
    s.hook.mounted()
    s.panel.dispatch("pointerdown", { target: s.handleBar, clientY: 100, pointerId: 3, pointerType: "touch" })
    s.panel.dispatch("pointermove", { target: s.handleBar, clientY: 200, pointerId: 3, pointerType: "touch" })
    s.panel.dispatch("pointercancel", { pointerId: 3 })
    expect(s.panel.style.transform).toBe("")
    s.panel.dispatch("pointerup", { target: s.handleBar, clientY: 200, pointerId: 3, pointerType: "touch" })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
  })

  it("a closed sheet ignores drags", () => {
    const s = buildSheet({ open: false })
    s.hook.mounted()
    drag(s.panel, s.handleBar, { dy: 120 })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
  })

  it("a sheet without data-swipe-dismiss attaches no pointer listeners and never closes on a drag", () => {
    const s = buildSheet({ swipe: false })
    s.hook.mounted()
    for (const t of ["pointerdown", "pointermove", "pointerup", "pointercancel"]) {
      expect(s.panel.listenerCount(t)).toBe(0)
    }
    drag(s.panel, s.handleBar, { dy: 200 })
    expect(s.hook.pushEvent).not.toHaveBeenCalled()
  })

  it("destroyed() removes every listener it added", () => {
    const s = buildSheet()
    s.hook.mounted()
    expect(s.panel.listenerCount("pointerdown")).toBe(1)
    expect(document.listenerCount("keydown")).toBe(1)

    s.hook.destroyed()
    for (const t of ["pointerdown", "pointermove", "pointerup", "pointercancel"]) {
      expect(s.panel.listenerCount(t)).toBe(0)
    }
    expect(document.listenerCount("keydown")).toBe(0)
    expect(s.el.listenerCount("keydown")).toBe(0)
  })
})

describe("Sheet hook focus return", () => {
  it("restores focus to the element focused before the sheet opened", () => {
    const more = { focus: vi.fn() }
    const firstRow = { focus: vi.fn() }
    const s = buildSheet({ swipe: true, open: false })
    s.el.querySelector = (sel) => (sel.includes("[href]") ? firstRow : FakeNode.prototype.querySelector.call(s.el, sel))
    document.activeElement = more
    s.hook.mounted()

    s.el.dataset.open = "true"
    s.hook.updated()
    expect(firstRow.focus).toHaveBeenCalled()

    s.el.dataset.open = "false"
    s.hook.updated()
    expect(more.focus).toHaveBeenCalledTimes(1)
  })

  it("a trigger that unmounted does not throw", () => {
    const gone = {
      focus: () => {
        throw new Error("detached")
      },
    }
    const s = buildSheet({ open: false })
    s.el.querySelector = (sel) => (sel.includes("[href]") ? null : FakeNode.prototype.querySelector.call(s.el, sel))
    document.activeElement = gone
    s.hook.mounted()
    s.el.dataset.open = "true"
    s.hook.updated()
    s.el.dataset.open = "false"
    expect(() => s.hook.updated()).not.toThrow()
  })
})
