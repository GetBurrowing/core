import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ChatListSettle, {
  SETTLE_MS,
  FLIP_MS,
  HIGHLIGHT_MS,
  FADE_MS,
  REHOLD_MS,
  ROW_SELECTOR,
} from "../../js/hooks/chat_list_settle.js"

/**
 * `ChatListSettle` (task 01a166bf stage 4): the hold-the-order gesture on the
 * phone Chat list's scroller, and the FLIP on release. vitest runs in plain
 * node (no DOM), so the scroller, the document and the rows are minimal
 * fakes; fake timers drive the 600ms settle window.
 */

function target() {
  const listeners = {}
  return {
    listeners,
    addEventListener: vi.fn((type, fn) => {
      ;(listeners[type] ||= []).push(fn)
    }),
    removeEventListener: vi.fn((type, fn) => {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    }),
    fire(type, event = {}) {
      for (const fn of listeners[type] || []) fn(event)
    },
  }
}

function fakeClassList() {
  const set = new Set()
  return {
    set,
    add: (...cs) => cs.forEach((c) => set.add(c)),
    remove: (...cs) => cs.forEach((c) => set.delete(c)),
    contains: (c) => set.has(c),
  }
}

function fakeRow(spaceId, top, floated = false) {
  return {
    dataset: floated ? { spaceId, floated: "true" } : { spaceId },
    top,
    style: {},
    classList: fakeClassList(),
    getBoundingClientRect() {
      return { top: this.top }
    },
  }
}

let doc

function mount(rows = []) {
  const el = Object.assign(target(), {
    rows,
    querySelectorAll: vi.fn((sel) => (sel === ROW_SELECTOR ? el.rows : [])),
  })
  const pushes = []
  const hook = Object.assign(Object.create(ChatListSettle), {
    el,
    pushEvent: (name, payload) => pushes.push([name, payload]),
  })
  hook.mounted()
  return { hook, el, pushes }
}

const names = (pushes) => pushes.map(([name]) => name)

function stubMotion(reduce, desktop = false) {
  vi.stubGlobal("window", {
    matchMedia: vi.fn((q) => ({
      matches:
        (reduce && q === "(prefers-reduced-motion: reduce)") ||
        (desktop && q === "(min-width: 1024px)"),
    })),
  })
}

// C (quiet) floats above A and B: the arrival that puts it in the active run.
function floatC({ reduce = false, desktop = true } = {}) {
  stubMotion(reduce, desktop)
  const a = fakeRow("a", 0)
  const b = fakeRow("b", 60)
  const c = fakeRow("c", 120)
  const { hook, el } = mount([a, b, c])
  hook.beforeUpdate()
  c.dataset.floated = "true"
  c.top = 0
  a.top = 60
  b.top = 120
  el.rows = [c, a, b]
  hook.updated()
  return { hook, a, b, c }
}

beforeEach(() => {
  vi.useFakeTimers()
  doc = target()
  vi.stubGlobal("document", doc)
  vi.stubGlobal("requestAnimationFrame", (fn) => setTimeout(fn, 0))
  stubMotion(false)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("ChatListSettle", () => {
  it("uses the rule's constants", () => {
    expect(SETTLE_MS).toBe(600)
    expect(FLIP_MS).toBe(150)
    expect(HIGHLIGHT_MS).toBe(600)
  })

  it("pushes hold on pointerdown and release 600ms after pointerup", () => {
    const { el, pushes } = mount()

    el.fire("pointerdown")
    expect(names(pushes)).toEqual(["chat_list_hold"])

    // touchstart on the same press is the same hold: one push.
    el.fire("touchstart")
    expect(names(pushes)).toEqual(["chat_list_hold"])

    el.fire("pointerup")
    vi.advanceTimersByTime(SETTLE_MS - 1)
    expect(names(pushes)).toEqual(["chat_list_hold"])

    vi.advanceTimersByTime(1)
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_release"])

    // The next touch is a new hold.
    el.fire("touchstart")
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_release", "chat_list_hold"])
  })

  it("a scroll inside the window restarts the 600ms", () => {
    const { el, pushes } = mount()

    el.fire("scroll")
    expect(names(pushes)).toEqual(["chat_list_hold"])

    vi.advanceTimersByTime(400)
    el.fire("scroll")
    vi.advanceTimersByTime(400)
    // 800ms after the first scroll, 400ms after the latest: still held.
    expect(names(pushes)).toEqual(["chat_list_hold"])

    vi.advanceTimersByTime(SETTLE_MS - 400)
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_release"])
  })

  it("never releases while a pointer is down", () => {
    const { el, pushes } = mount()

    el.fire("pointerdown")
    // Momentum or a drag scrolls while the finger stays down.
    el.fire("scroll")
    vi.advanceTimersByTime(SETTLE_MS * 10)
    expect(names(pushes)).toEqual(["chat_list_hold"])

    // The release can arrive on the document (a mouse let go off the list).
    doc.fire("pointerup")
    vi.advanceTimersByTime(SETTLE_MS)
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_release"])
  })

  it("a touch pointercancel (the browser taking the pan) is not a release", () => {
    const { el, pushes } = mount()

    el.fire("touchstart", { touches: [{}] })
    el.fire("pointerdown", { pointerType: "touch" })
    el.fire("pointercancel", { pointerType: "touch" })
    el.fire("scroll")
    vi.advanceTimersByTime(SETTLE_MS * 5)
    expect(names(pushes)).toEqual(["chat_list_hold"])

    // One finger lifts, another stays: still held.
    el.fire("touchend", { touches: [{}] })
    vi.advanceTimersByTime(SETTLE_MS * 2)
    expect(names(pushes)).toEqual(["chat_list_hold"])

    el.fire("touchend", { touches: [] })
    vi.advanceTimersByTime(SETTLE_MS)
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_release"])
  })

  it("a continuous scroll longer than 10s keeps the hold alive", () => {
    const { el, pushes } = mount()
    const holdTimes = []
    const t0 = Date.now()
    const watch = () => {
      while (holdTimes.length < pushes.length) {
        if (pushes[holdTimes.length][0] !== "chat_list_hold") throw new Error("released mid-scroll")
        holdTimes.push(Date.now() - t0)
      }
    }

    // Scroll every 100ms for 12s.
    for (let t = 0; t <= 12_000; t += 100) {
      el.fire("scroll")
      watch()
      vi.advanceTimersByTime(100)
    }

    expect(REHOLD_MS).toBeLessThan(10_000)
    expect(pushes.every(([name]) => name === "chat_list_hold")).toBe(true)
    // A second hold well before the server's 10s, and the hold kept fresh
    // throughout: no gap between holds reaches the 10s timeout.
    expect(holdTimes.length).toBeGreaterThan(1)
    expect(holdTimes[1]).toBeLessThan(10_000)
    const gaps = holdTimes.slice(1).map((t, i) => t - holdTimes[i])
    expect(Math.max(...gaps)).toBeLessThanOrEqual(REHOLD_MS + 100)

    // Scrolling stopped at 12_000 (the clock is now 12_100): release lands
    // 600ms after the last scroll, not before.
    const holds = pushes.length
    vi.advanceTimersByTime(SETTLE_MS - 100 - 1)
    expect(pushes.length).toBe(holds)
    vi.advanceTimersByTime(1)
    expect(names(pushes).slice(holds)).toEqual(["chat_list_release"])
  })

  it("a touch drag refreshes the hold on touchmove; movement alone never starts one", () => {
    const { el, pushes } = mount()

    el.fire("touchmove", { type: "touchmove" })
    el.fire("pointermove", { type: "pointermove", pointerType: "mouse" })
    expect(pushes).toEqual([])

    el.fire("touchstart", { touches: [{}] })
    for (let t = 0; t < 12_000; t += 200) {
      vi.advanceTimersByTime(200)
      el.fire("touchmove", { type: "touchmove" })
    }
    const holds = names(pushes)
    expect(holds.length).toBeGreaterThan(1)
    expect(holds.every((n) => n === "chat_list_hold")).toBe(true)
  })

  it("a re-push is throttled to one per REHOLD_MS", () => {
    const { el, pushes } = mount()
    const t0 = Date.now()
    el.fire("scroll")
    // Keep scrolling (inside the 600ms window) up to 1ms short of REHOLD_MS.
    while (Date.now() - t0 < REHOLD_MS - 100) {
      vi.advanceTimersByTime(100)
      el.fire("scroll")
    }
    vi.advanceTimersByTime(REHOLD_MS - 1 - (Date.now() - t0))
    el.fire("scroll")
    expect(names(pushes)).toEqual(["chat_list_hold"])
    vi.advanceTimersByTime(1)
    el.fire("scroll")
    expect(names(pushes)).toEqual(["chat_list_hold", "chat_list_hold"])
  })

  it("slides a moved row from its old place over 150ms on a re-sort", () => {
    const a = fakeRow("a", 0)
    const b = fakeRow("b", 60)
    const { hook, el } = mount([a, b])

    hook.beforeUpdate()
    // The re-sort: b now first.
    b.top = 0
    a.top = 60
    el.rows = [b, a]
    hook.updated()

    expect(b.style.transform).toBe("translateY(60px)")
    expect(a.style.transform).toBe("translateY(-60px)")

    vi.advanceTimersByTime(0)
    expect(b.style.transition).toBe("transform 150ms ease-out")
    expect(b.style.transform).toBe("")
    vi.advanceTimersByTime(150)
    expect(b.style.transition).toBe("")
  })

  describe("float highlight (task 01a1b6fd stage 2)", () => {
    it("at lg, a row that floated up gets bg-base-200 for 600ms, then fades and clears", () => {
      const { a, b, c } = floatC()

      expect(c.classList.contains("bg-base-200")).toBe(true)
      expect(a.classList.set.size).toBe(0)
      expect(b.classList.set.size).toBe(0)

      vi.advanceTimersByTime(HIGHLIGHT_MS - 1)
      expect(c.classList.contains("bg-base-200")).toBe(true)

      vi.advanceTimersByTime(1)
      expect(c.classList.contains("bg-base-200")).toBe(false)
      expect(c.classList.contains("transition-colors")).toBe(true)

      vi.advanceTimersByTime(FADE_MS)
      expect(c.classList.set.size).toBe(0)
    })

    it("the slide still runs alongside the highlight", () => {
      const { c } = floatC()
      expect(c.style.transform).toBe("translateY(120px)")
    })

    it("on the phone: the slide, no highlight", () => {
      const { c } = floatC({ desktop: false })
      expect(c.style.transform).toBe("translateY(120px)")
      vi.advanceTimersByTime(0)
      expect(c.style.transition).toBe("transform 150ms ease-out")
      expect(c.classList.set.size).toBe(0)
    })

    it("under reduced motion: no slide and no highlight, at lg too", () => {
      const { c } = floatC({ reduce: true })
      vi.advanceTimersByTime(HIGHLIGHT_MS + FADE_MS)
      expect(c.style.transform).toBeUndefined()
      expect(c.style.transition).toBeUndefined()
      expect(c.classList.set.size).toBe(0)
    })

    it("an unmarked row that moves up is not highlighted", () => {
      stubMotion(false, true)
      const a = fakeRow("a", 0)
      const b = fakeRow("b", 60)
      const { hook, el } = mount([a, b])
      hook.beforeUpdate()
      b.top = 0
      a.top = 60
      el.rows = [b, a]
      hook.updated()
      expect(b.classList.set.size).toBe(0)
    })

    it("a marked row that passes another marked row floats; one that rises only because its neighbour left does not", () => {
      stubMotion(false, true)
      // Active run [a, b]; a message in b puts it above a: a float.
      const a = fakeRow("a", 0, true)
      const b = fakeRow("b", 60, true)
      const q = fakeRow("q", 120)
      const { hook, el } = mount([a, b, q])
      hook.beforeUpdate()
      b.top = 0
      a.top = 60
      el.rows = [b, a, q]
      hook.updated()
      expect(b.classList.contains("bg-base-200")).toBe(true)
      expect(a.classList.set.size).toBe(0)

      // b leaves the run and settles below a: a rises, but floated nothing.
      vi.advanceTimersByTime(HIGHLIGHT_MS + FADE_MS)
      hook.beforeUpdate()
      delete b.dataset.floated
      a.top = 0
      b.top = 60
      el.rows = [a, b, q]
      hook.updated()
      expect(a.classList.set.size).toBe(0)
      expect(b.classList.set.size).toBe(0)
    })
  })

  it("a shift with no re-sort (a fold) animates nothing", () => {
    const a = fakeRow("a", 100)
    const b = fakeRow("b", 160)
    const { hook, el } = mount([a, b])

    hook.beforeUpdate()
    a.top = 40
    b.top = 100
    el.rows = [a, b]
    hook.updated()

    expect(a.style.transform).toBeUndefined()
    expect(b.style.transform).toBeUndefined()
  })

  it("reduced motion applies no transform", () => {
    stubMotion(true)
    const a = fakeRow("a", 0)
    const b = fakeRow("b", 60)
    const { hook, el } = mount([a, b])

    hook.beforeUpdate()
    b.top = 0
    a.top = 60
    el.rows = [b, a]
    hook.updated()
    vi.advanceTimersByTime(FLIP_MS * 2)

    expect(a.style.transform).toBeUndefined()
    expect(b.style.transform).toBeUndefined()
    expect(a.style.transition).toBeUndefined()
  })

  it("listens passively and cleans up on destroy", () => {
    const { hook, el, pushes } = mount()

    for (const call of el.addEventListener.mock.calls) {
      expect(call[2]).toEqual({ passive: true })
    }

    el.fire("scroll")
    hook.destroyed()
    vi.advanceTimersByTime(SETTLE_MS * 2)
    el.fire("pointerdown")
    expect(names(pushes)).toEqual(["chat_list_hold"])
  })
})
