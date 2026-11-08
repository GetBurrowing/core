import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

/**
 * Calendar range gestures (task 01a1b8a5 stage 2). The state machine is
 * tested on plain inputs; the hook is tested against a minimal fake DOM
 * (vitest runs in plain node, no jsdom) that supports exactly what the hook
 * touches. The load-bearing claim: a gesture NEVER pushes anything but
 * `select_range`, and only after a real drag ends with pointerup.
 */

import CalendarSelection, {
  CalendarEditorFocus,
  createGesture,
  minuteAt,
  rangeOf,
} from "../../js/hooks/calendar_selection.js"

// 07:00 at y=0, 48px an hour: y = (minute - 420) / 60 * 48.
const y = (minute) => ((minute - 420) / 60) * 48

describe("minuteAt / rangeOf", () => {
  it("snaps down to 15 minutes inside the 07:00-21:00 window", () => {
    expect(minuteAt(y(600))).toBe(600)
    expect(minuteAt(y(611))).toBe(600)
    expect(minuteAt(y(614.9))).toBe(600)
    expect(minuteAt(-100)).toBe(420)
    expect(minuteAt(10_000)).toBe(1260)
  })

  it("normalizes a reverse drag and includes the slot under each end", () => {
    expect(rangeOf(600, 660)).toEqual({ start: 600, end: 675 })
    expect(rangeOf(660, 600)).toEqual({ start: 600, end: 675 })
    expect(rangeOf(600, 600)).toEqual({ start: 600, end: 615 })
  })

  it("never leaves the window, even at its edges", () => {
    expect(rangeOf(1260, 1260)).toEqual({ start: 1245, end: 1260 })
    expect(rangeOf(420, 1260)).toEqual({ start: 420, end: 1260 })
  })
})

describe("createGesture", () => {
  const down = (g, extra = {}) =>
    g.down({ pointerId: 1, pointerType: "mouse", button: 0, y: y(600), date: "2026-12-02", ...extra })

  it("below the threshold a press is a click, not a selection", () => {
    const g = createGesture()
    expect(down(g)).toBe(true)
    expect(g.move({ pointerId: 1, y: y(600) + 3 })).toEqual({ type: "none" })
    expect(g.up({ pointerId: 1, y: y(600) + 3 })).toEqual({ type: "click" })
    expect(g.state).toBe("idle")
  })

  it("a drag selects the normalized range on the day it started", () => {
    const g = createGesture()
    down(g)
    expect(g.move({ pointerId: 1, y: y(630) }).type).toBe("start")
    expect(g.move({ pointerId: 1, y: y(700) }).type).toBe("update")
    expect(g.up({ pointerId: 1, y: y(690) })).toEqual({
      type: "select",
      date: "2026-12-02",
      start: 600,
      end: 705,
    })
  })

  it("a reverse drag is normalized", () => {
    const g = createGesture()
    down(g, { y: y(720) })
    g.move({ pointerId: 1, y: y(650) })
    expect(g.up({ pointerId: 1, y: y(645) })).toMatchObject({ start: 645, end: 735 })
  })

  it("touch, a non-primary button and a second pointer never start one", () => {
    const g = createGesture()
    expect(down(g, { pointerType: "touch" })).toBe(false)
    expect(down(g, { button: 2 })).toBe(false)
    expect(down(g)).toBe(true)
    expect(down(g, { pointerId: 2 })).toBe(false)
    expect(g.move({ pointerId: 2, y: y(700) })).toEqual({ type: "none" })
    expect(g.up({ pointerId: 2, y: y(700) })).toEqual({ type: "none" })
  })

  it("abort ends a drag with nothing to select", () => {
    const g = createGesture()
    down(g)
    g.move({ pointerId: 1, y: y(700) })
    expect(g.abort()).toEqual({ type: "abort", wasActive: true })
    expect(g.up({ pointerId: 1, y: y(700) })).toEqual({ type: "none" })
    expect(g.abort()).toEqual({ type: "none" })
  })
})

// ── the hook ──────────────────────────────────────────────────────────────

class FakeTarget {
  constructor() {
    this.listeners = {}
  }
  addEventListener(type, fn, opts) {
    const capture = opts === true || (opts && opts.capture)
    ;(this.listeners[type] ||= []).push({ fn, capture })
  }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((l) => l.fn !== fn)
  }
  fire(type, event) {
    for (const { fn } of [...(this.listeners[type] || [])]) {
      if (event._stopped) break
      fn(event)
    }
  }
}

class FakeEl extends FakeTarget {
  constructor({ role, date, cls } = {}) {
    super()
    this.dataset = date ? { date } : {}
    this.role = role
    this.cls = cls
    this.children = []
    this.parent = null
    this.style = {}
    this.attrs = {}
    this.captured = new Set()
  }
  appendChild(c) {
    c.parent = this
    this.children.push(c)
    return c
  }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this)
    this.parent = null
  }
  setAttribute(k, v) {
    this.attrs[k] = v
  }
  matches(sel) {
    if (sel === ".cal-ev") return this.cls === "cal-ev"
    if (sel === "[data-role=calendar-day-column]") return this.role === "calendar-day-column"
    if (sel === "#calendar-body") return this.role === "calendar-body"
    return false
  }
  closest(sel) {
    let n = this
    while (n) {
      if (n.matches && n.matches(sel)) return n
      n = n.parent
    }
    return null
  }
  contains(other) {
    let n = other
    while (n) {
      if (n === this) return true
      n = n.parent
    }
    return false
  }
  get parentElement() {
    return this.parent
  }
  getBoundingClientRect() {
    return { top: 100 }
  }
  setPointerCapture(id) {
    this.captured.add(id)
  }
  releasePointerCapture(id) {
    this.captured.delete(id)
  }
}

const ev = (target, extra = {}) => ({
  target,
  pointerId: 1,
  pointerType: "mouse",
  button: 0,
  clientY: 100,
  key: undefined,
  _stopped: false,
  _prevented: false,
  preventDefault() {
    this._prevented = true
  },
  stopImmediatePropagation() {
    this._stopped = true
  },
  ...extra,
})

describe("CalendarSelection hook", () => {
  let win, body, grid, column, slot, chip, hook

  beforeEach(() => {
    win = new FakeTarget()
    vi.stubGlobal("window", win)
    vi.stubGlobal("document", { createElement: () => new FakeEl() })
    body = new FakeEl({ role: "calendar-body" })
    grid = body.appendChild(new FakeEl())
    column = grid.appendChild(new FakeEl({ role: "calendar-day-column", date: "2026-12-02" }))
    slot = column.appendChild(new FakeEl())
    chip = column.appendChild(new FakeEl({ cls: "cal-ev" }))
    hook = Object.create(CalendarSelection)
    hook.el = grid
    hook.pushEvent = vi.fn()
    hook.mounted()
  })

  afterEach(() => {
    hook.destroyed()
    vi.unstubAllGlobals()
  })

  const at = (minute) => 100 + y(minute)

  const drag = (from, to) => {
    grid.fire("pointerdown", ev(slot, { clientY: at(from) }))
    grid.fire("pointermove", ev(slot, { clientY: at(to) }))
  }

  it("a drag pushes ONE select_range with the local range, then nothing else", () => {
    drag(600, 660)
    expect(column.captured.has(1)).toBe(true)
    expect(column.children.some((c) => c.className === "cal-drag-selection")).toBe(true)
    grid.fire("pointerup", ev(slot, { clientY: at(660) }))

    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).toHaveBeenCalledWith("select_range", {
      date: "2026-12-02",
      start: 600,
      end: 675,
    })
    expect(column.children.some((c) => c.className === "cal-drag-selection")).toBe(false)
  })

  it("suppresses the click that trails a drag, and only that one", () => {
    drag(600, 660)
    grid.fire("pointerup", ev(slot, { clientY: at(660) }))
    const trailing = ev(slot)
    grid.fire("click", trailing)
    expect(trailing._prevented).toBe(true)
    expect(trailing._stopped).toBe(true)

    const next = ev(slot)
    grid.fire("click", next)
    expect(next._prevented).toBe(false)
  })

  it("a drag whose release made no click does not swallow the next real click", () => {
    drag(600, 660)
    grid.fire("pointerup", ev(slot, { clientY: at(660) }))
    grid.fire("pointerdown", ev(slot, { clientY: at(600) }))
    grid.fire("pointerup", ev(slot, { clientY: at(600) }))
    const click = ev(slot)
    grid.fire("click", click)
    expect(click._prevented).toBe(false)
  })

  it("a plain click pushes nothing and leaves the slot's own click alone", () => {
    grid.fire("pointerdown", ev(slot, { clientY: at(600) }))
    grid.fire("pointerup", ev(slot, { clientY: at(600) }))
    const click = ev(slot)
    grid.fire("click", click)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(click._prevented).toBe(false)
    expect(column.captured.size).toBe(0)
  })

  it("touch never starts a gesture, so scrolling and tap stay native", () => {
    grid.fire("pointerdown", ev(slot, { pointerType: "touch", clientY: at(600) }))
    const move = ev(slot, { pointerType: "touch", clientY: at(700) })
    grid.fire("pointermove", move)
    grid.fire("pointerup", ev(slot, { pointerType: "touch", clientY: at(700) }))
    expect(move._prevented).toBe(false)
    expect(column.captured.size).toBe(0)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("pressing on an event chip starts nothing", () => {
    grid.fire("pointerdown", ev(chip, { clientY: at(600) }))
    grid.fire("pointermove", ev(chip, { clientY: at(700) }))
    grid.fire("pointerup", ev(chip, { clientY: at(700) }))
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  for (const [name, abort] of [
    ["pointercancel", () => grid.fire("pointercancel", ev(slot))],
    ["lost capture", () => grid.fire("lostpointercapture", ev(slot))],
    ["a scroll of the grid", () => body.fire("scroll", {})],
    ["LiveView navigation", () => win.fire("phx:page-loading-start", {})],
    ["the hook going away", () => hook.destroyed()],
  ]) {
    it(`${name} aborts: no select_range, no overlay`, () => {
      drag(600, 700)
      abort()
      grid.fire("pointerup", ev(slot, { clientY: at(700) }))
      expect(hook.pushEvent).not.toHaveBeenCalled()
      expect(column.children.some((c) => c.className === "cal-drag-selection")).toBe(false)
    })
  }

  it("Escape aborts the drag and is consumed, so the page does not also close details", () => {
    drag(600, 700)
    const page = vi.fn()
    win.addEventListener("keydown", page)
    const key = ev(null, { key: "Escape" })
    win.fire("keydown", key)

    expect(key._stopped).toBe(true)
    expect(page).not.toHaveBeenCalled()
    grid.fire("pointerup", ev(slot, { clientY: at(700) }))
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("Escape with no gesture passes through to the page-level handler", () => {
    const page = vi.fn()
    win.addEventListener("keydown", page)
    const key = ev(null, { key: "Escape" })
    win.fire("keydown", key)
    expect(key._stopped).toBe(false)
    expect(page).toHaveBeenCalledTimes(1)
  })
})

describe("CalendarEditorFocus", () => {
  it("returns focus to what opened the editor, if it is still there", () => {
    const opener = { isConnected: true, focus: vi.fn() }
    const hook = Object.create(CalendarEditorFocus)
    hook.returnTo = opener
    hook.destroyed()
    expect(opener.focus).toHaveBeenCalledTimes(1)

    const gone = { isConnected: false, focus: vi.fn() }
    hook.returnTo = gone
    hook.destroyed()
    expect(gone.focus).not.toHaveBeenCalled()
  })
})
