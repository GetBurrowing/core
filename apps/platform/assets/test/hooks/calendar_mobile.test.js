import { describe, it, expect, beforeEach } from "vitest"
import {
  CalendarAgenda,
  CalendarSwipe,
  EDGE_PX,
  anchorRow,
  anchorShift,
  endReached,
  lineCount,
  lowSpace,
  monthAsSheet,
  nearEdge,
  stripHiddenAfter,
  weekStart,
  rowAt,
  rowForDate,
  rowVisible,
  scrollTarget,
  swipeDirection,
  tailPx,
} from "../../js/hooks/calendar_mobile.js"

/**
 * The phone calendar's hooks (canvas 01a2111c): the Day view and week strip
 * swipe with its 20px edge guard, the strip following the agenda, the
 * Today visibility report and the no-jump anchor for earlier days.
 * Plain node with fake elements.
 */

const W = 390

describe("swipeDirection", () => {
  it("reads a left swipe as next and a right swipe as previous", () => {
    expect(swipeDirection({ x: 300, y: 400 }, { x: 120, y: 410 }, W)).toBe("next")
    expect(swipeDirection({ x: 100, y: 400 }, { x: 280, y: 395 }, W)).toBe("previous")
  })

  it("ignores a swipe that starts within 20px of either edge (iOS Back)", () => {
    expect(EDGE_PX).toBe(20)
    expect(swipeDirection({ x: 19, y: 400 }, { x: 250, y: 400 }, W)).toBe(null)
    expect(swipeDirection({ x: W - 19, y: 400 }, { x: 100, y: 400 }, W)).toBe(null)
    // Just inside the guard is a swipe.
    expect(swipeDirection({ x: 20, y: 400 }, { x: 250, y: 400 }, W)).toBe("previous")
    expect(swipeDirection({ x: W - 20, y: 400 }, { x: 100, y: 400 }, W)).toBe("next")
  })

  it("ignores short and mostly vertical moves (a scroll is not a swipe)", () => {
    expect(swipeDirection({ x: 200, y: 400 }, { x: 170, y: 400 }, W)).toBe(null)
    expect(swipeDirection({ x: 200, y: 400 }, { x: 100, y: 250 }, W)).toBe(null)
    expect(swipeDirection(null, { x: 100, y: 400 }, W)).toBe(null)
    expect(swipeDirection({ x: 200, y: 400 }, null, W)).toBe(null)
  })
})

const rows = [
  { id: "a", type: "empty", from: "2026-11-09", to: "2026-11-22", top: -300, bottom: -100 },
  { id: "b", type: "day", from: "2026-11-23", to: "2026-11-23", top: -100, bottom: 40 },
  { id: "c", type: "day", from: "2026-11-24", to: "2026-11-24", top: 40, bottom: 400 },
  { id: "d", type: "empty", from: "2026-11-25", to: "2026-11-28", top: 400, bottom: 440 },
  { id: "e", type: "day", from: "2026-11-29", to: "2026-11-29", top: 440, bottom: 600 },
]

describe("row geometry", () => {
  it("rowAt finds the row under a line, else the last row", () => {
    expect(rowAt(rows, 0).id).toBe("b")
    expect(rowAt(rows, 41).id).toBe("c")
    expect(rowAt(rows, 10_000).id).toBe("e")
    expect(rowAt([], 0)).toBe(null)
  })

  it("rowForDate covers a date inside a collapsed empty run, or the next row", () => {
    expect(rowForDate(rows, "2026-11-26").id).toBe("d")
    expect(rowForDate(rows, "2026-11-24").id).toBe("c")
    expect(rowForDate(rows, "2026-11-01").id).toBe("a")
    expect(rowForDate(rows, "2027-01-01")).toBe(null)
  })

  it("anchorRow prefers a day row, whose id survives a merge above it", () => {
    expect(anchorRow(rows, -200).id).toBe("b")
    expect(anchorRow(rows, 420).id).toBe("e")
    expect(anchorRow([rows[0]], -200).id).toBe("a")
  })

  it("rowVisible needs more than the sticky header on screen", () => {
    const header = 36
    expect(rowVisible({ top: -500, bottom: 30 }, 0, 700, header)).toBe(false)
    expect(rowVisible({ top: -500, bottom: 37 }, 0, 700, header)).toBe(true)
    expect(rowVisible({ top: 700, bottom: 800 }, 0, 700, header)).toBe(false)
    expect(rowVisible(undefined, 0, 700, header)).toBe(false)
  })

  it("scrollTarget puts a target at the top, below a measured offset", () => {
    // Container at 151px, target 800px down the viewport, list scrolled 200.
    expect(scrollTarget({ targetTop: 800, containerTop: 151, scrollTop: 200 })).toBe(849)
    expect(
      scrollTarget({ targetTop: 800, containerTop: 151, scrollTop: 200, offset: 40, context: 100 }),
    ).toBe(709)
    expect(scrollTarget({ targetTop: 0, containerTop: 151, scrollTop: 0 })).toBe(0)
  })

  it("anchorShift is how far the anchor moved; tailPx leaves a header", () => {
    expect(anchorShift(117, 517)).toBe(400)
    expect(anchorShift(undefined, 517)).toBe(0)
    expect(tailPx(617, 37.5)).toBe(580)
    expect(tailPx(20, 37)).toBe(0)
  })
})

// A fake agenda: rows are elements with datasets and rects.
function fakeAgenda(rowRects, { top = 151, bottom = 768, header = 37 } = {}) {
  const els = rowRects.map((r) => ({
    id: `m_agenda-${r.id}`,
    dataset: { type: r.type, from: r.from, to: r.to, today: r.today ? "true" : undefined },
    getBoundingClientRect: () => ({ top: r.top, bottom: r.bottom }),
  }))
  const headerEl = { getBoundingClientRect: () => ({ height: header }) }
  return {
    offsetParent: {},
    scrollTop: 0,
    getBoundingClientRect: () => ({ top, bottom }),
    querySelectorAll: () => els,
    querySelector: (sel) => (sel.includes("m-agenda-day-header") ? headerEl : null),
  }
}

function agendaHook(el) {
  const h = Object.create(CalendarAgenda)
  h.el = el
  h.pushed = []
  h.pushEvent = (event, payload) => h.pushed.push([event, payload])
  h.lastReport = null
  return h
}

describe("CalendarAgenda.report (the strip follows the agenda)", () => {
  const at = (shift) => [
    { id: "d1", type: "day", from: "2026-11-24", to: "2026-11-24", today: true, top: 151 - shift, bottom: 500 - shift },
    { id: "e1", type: "empty", from: "2026-11-25", to: "2026-12-06", top: 500 - shift, bottom: 540 - shift },
    { id: "d2", type: "day", from: "2026-12-07", to: "2026-12-07", top: 540 - shift, bottom: 900 - shift },
  ]

  it("reports the day at the top and that today is on screen", () => {
    const h = agendaHook(fakeAgenda(at(0)))
    h.report()
    expect(h.pushed).toEqual([["m_agenda_focus", { date: "2026-11-24", today_visible: true }]])
  })

  it("follows into a new week and says today went off screen", () => {
    const h = agendaHook(fakeAgenda(at(400)))
    h.report()
    expect(h.pushed).toEqual([["m_agenda_focus", { date: "2026-12-07", today_visible: false }]])
  })

  it("does not push again while nothing changed, unless forced", () => {
    const h = agendaHook(fakeAgenda(at(0)))
    h.report()
    h.report()
    expect(h.pushed.length).toBe(1)
    h.report(true)
    expect(h.pushed.length).toBe(2)
  })

  it("only today's header left on screen counts as off screen", () => {
    // Today's row ends 30px below the list top: under the 37px sticky header.
    const rects = [
      { id: "d1", type: "day", from: "2026-11-24", to: "2026-11-24", today: true, top: -200, bottom: 181 },
      { id: "e1", type: "empty", from: "2026-11-25", to: "2026-12-06", top: 181, bottom: 221 },
    ]
    const h2 = agendaHook(fakeAgenda(rects))
    h2.report()
    expect(h2.pushed[0][1].today_visible).toBe(false)
  })

  it("stays quiet while hidden under Day view", () => {
    const el = fakeAgenda(at(0))
    el.offsetParent = null
    const h = agendaHook(el)
    h.report()
    expect(h.pushed).toEqual([])
  })
})

describe("CalendarAgenda.scrollToDate", () => {
  it("puts the date's row at the top of the list (a date inside an empty run too)", () => {
    const el = fakeAgenda([
      { id: "d1", type: "day", from: "2026-11-24", to: "2026-11-24", top: 151, bottom: 500 },
      { id: "e1", type: "empty", from: "2026-11-25", to: "2026-12-06", top: 500, bottom: 540 },
    ])
    const h = agendaHook(el)
    h.scrollToDate("2026-11-30")
    expect(el.scrollTop).toBe(349)
  })
})

describe("CalendarSwipe", () => {
  let handlers, el, pushed

  beforeEach(() => {
    globalThis.window = { innerWidth: W }
    handlers = {}
    pushed = []
    el = {
      dataset: { swipeEvent: "m_strip_step" },
      addEventListener: (name, fn) => (handlers[name] = fn),
      removeEventListener: (name) => delete handlers[name],
    }
    const h = Object.create(CalendarSwipe)
    h.el = el
    h.pushEvent = (event, payload) => pushed.push([event, payload])
    h.mounted()
  })

  const swipe = (x0, x1) => {
    handlers.touchstart({ touches: [{ clientX: x0, clientY: 100 }] })
    handlers.touchend({ changedTouches: [{ clientX: x1, clientY: 104 }] })
  }

  it("pushes the element's event with the direction", () => {
    swipe(300, 100)
    swipe(100, 300)
    expect(pushed).toEqual([
      ["m_strip_step", { direction: "next" }],
      ["m_strip_step", { direction: "previous" }],
    ])
  })

  it("pushes nothing for an edge swipe", () => {
    swipe(8, 250)
    swipe(W - 5, 100)
    expect(pushed).toEqual([])
  })
})

describe("weekStart (review E)", () => {
  class WithMethod {
    constructor(tag) {
      this.tag = tag
    }
    getWeekInfo() {
      return { firstDay: this.tag === "en-US" ? 7 : 1 }
    }
  }
  class WithProperty {
    constructor(tag) {
      this.weekInfo = { firstDay: tag === "ar-EG" ? 6 : 1 }
    }
  }

  it("reads getWeekInfo().firstDay", () => {
    expect(weekStart("en-US", WithMethod)).toBe(7)
    expect(weekStart("en-GB", WithMethod)).toBe(1)
  })

  it("reads the older weekInfo property", () => {
    expect(weekStart("ar-EG", WithProperty)).toBe(6)
    expect(weekStart("de-DE", WithProperty)).toBe(1)
  })

  it("falls back to Monday without either, on a bad value, or when the locale throws", () => {
    expect(weekStart("en-US", class {})).toBe(1)
    expect(weekStart("en-US", class { getWeekInfo() { return { firstDay: 0 } } })).toBe(1)
    expect(weekStart("en-US", class { constructor() { throw new RangeError("bad tag") } })).toBe(1)
    expect(weekStart("en-US", null)).toBe(1)
    expect(weekStart("", WithMethod)).toBe(1)
  })
})

describe("phone layout rules (review A, B, C)", () => {
  it("lineCount groups wrapped flex items by top", () => {
    expect(lineCount([48, 47, 50, 48])).toBe(1)
    expect(lineCount([92, 172, 177, 172])).toBe(2)
    expect(lineCount([92, 172, 254, 258])).toBe(3)
    expect(lineCount([])).toBe(0)
  })

  it("monthAsSheet: landscape or 150%+ text; portrait at default text is inline", () => {
    expect(monthAsSheet({ width: 390, height: 844, rootPx: 16 })).toBe(false)
    expect(monthAsSheet({ width: 844, height: 390, rootPx: 16 })).toBe(true)
    expect(monthAsSheet({ width: 390, height: 844, rootPx: 23 })).toBe(false)
    expect(monthAsSheet({ width: 390, height: 844, rootPx: 24 })).toBe(true)
  })

  it("lowSpace: the list with the strip, less the day header, under 40% of the viewport", () => {
    // 844x390 landscape: 163px list, 33px header → 130 < 156.
    expect(lowSpace({ listPx: 163, stripPx: 62, stripHidden: false, headerPx: 33, viewportPx: 390 })).toBe(true)
    // Measured with the strip already tucked away: the same answer.
    expect(lowSpace({ listPx: 225, stripPx: 62, stripHidden: true, headerPx: 33, viewportPx: 390 })).toBe(true)
    // 390x844 portrait: 617px list.
    expect(lowSpace({ listPx: 617, stripPx: 62, stripHidden: false, headerPx: 37, viewportPx: 844 })).toBe(false)
  })

  it("stripHiddenAfter: down hides, up shows, jitter keeps; never hidden with room", () => {
    expect(stripHiddenAfter(false, 30, true)).toBe(true)
    expect(stripHiddenAfter(true, -30, true)).toBe(false)
    expect(stripHiddenAfter(true, 2, true)).toBe(true)
    expect(stripHiddenAfter(false, -2, true)).toBe(false)
    expect(stripHiddenAfter(true, 30, false)).toBe(false)
  })

  it("nearEdge: the sentinel within the margin of its end of the list", () => {
    const view = { top: 151, bottom: 768 }
    expect(nearEdge("later", { top: 900, bottom: 1500 }, view)).toBe(true)
    expect(nearEdge("later", { top: 1100, bottom: 1500 }, view)).toBe(false)
    expect(nearEdge("earlier", { top: -200, bottom: -50 }, view)).toBe(true)
    expect(nearEdge("earlier", { top: -500, bottom: -100 }, view)).toBe(false)
    expect(nearEdge("later", null, view)).toBe(false)
  })
})

describe("the agenda's ends (review 3)", () => {
  it("endReached reads the server's data-end-* marks", () => {
    expect(endReached({ endLater: "true", endEarlier: "false" }, "later")).toBe(true)
    expect(endReached({ endLater: "true", endEarlier: "false" }, "earlier")).toBe(false)
    expect(endReached({}, "later")).toBe(false)
  })

  it("loadMore pushes nothing past a reached end", () => {
    const pushed = []
    const h = Object.create(CalendarAgenda)
    h.el = { offsetParent: {}, dataset: { endLater: "true", endEarlier: "false" } }
    h.ready = true
    h.loading = false
    h.pushEvent = (e, p) => pushed.push([e, p])
    h.loadMore("later")
    expect(pushed).toEqual([])
    expect(h.loading).toBe(false)
  })
})
