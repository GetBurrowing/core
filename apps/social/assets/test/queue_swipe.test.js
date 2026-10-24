import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import QueueSwipe, {
  SETTLE_MS,
  clampIndex,
  indexAt,
  keyIndex,
  nearestIndex,
  typingTarget,
} from "../js/hooks/queue_swipe.js"

/**
 * The Queue's version strip (Social authoring 5/11, task 01a16c50): a swipe
 * on a 375px phone lands on the next version and the hook tells the card,
 * so the sticky bar acts on the version on screen.
 */

// A strip at 375px wide holding `count` full-width columns, scrolled to
// `scrollLeft`. Columns report boxes as the browser would lay them out.
function strip(count, { width = 375, current = 0 } = {}) {
  const listeners = {}
  const el = {
    dataset: { current: String(current), count: String(count) },
    scrollLeft: 0,
    clientWidth: width,
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type) => delete listeners[type],
    closest: () => null,
    getBoundingClientRect: () => ({ left: 0, width }),
    scrolledTo: null,
    children: [],
  }
  el.children = Array.from({ length: count }, (_, i) => ({
    getBoundingClientRect: () => ({ left: i * width - el.scrollLeft, width }),
    scrollIntoView: () => (el.scrolledTo = i),
  }))
  return { el, listeners }
}

function mount(el) {
  const pushed = []
  const hook = Object.create(QueueSwipe)
  hook.el = el
  hook.pushEventTo = (target, event, payload) => pushed.push({ target, event, payload })
  hook.mounted()
  return { hook, pushed }
}

describe("pure parts", () => {
  it("clamps an index into the strip", () => {
    expect(clampIndex(-1, 3)).toBe(0)
    expect(clampIndex(5, 3)).toBe(2)
    expect(clampIndex("1", "3")).toBe(1)
    expect(clampIndex(0, 0)).toBe(0)
    expect(clampIndex("x", 3)).toBe(0)
  })

  it("reads the full-width column under a scroll offset", () => {
    expect(indexAt(0, 375, 3)).toBe(0)
    expect(indexAt(375, 375, 3)).toBe(1)
    expect(indexAt(700, 375, 3)).toBe(2)
    expect(indexAt(5000, 375, 3)).toBe(2)
    expect(indexAt(100, 0, 3)).toBe(0)
  })

  it("finds the column centred in the strip", () => {
    expect(nearestIndex([187, 562, 937], 187)).toBe(0)
    expect(nearestIndex([-188, 187, 562], 187)).toBe(1)
    expect(nearestIndex([], 187)).toBe(-1)
  })

  it("moves one version with the arrow keys, never past an end", () => {
    expect(keyIndex("ArrowRight", 0, 3, null)).toBe(1)
    expect(keyIndex("ArrowLeft", 1, 3, null)).toBe(0)
    expect(keyIndex("ArrowLeft", 0, 3, null)).toBeNull()
    expect(keyIndex("ArrowRight", 2, 3, null)).toBeNull()
  })

  it("ignores other keys, typing and modifiers", () => {
    expect(keyIndex("Enter", 0, 3, null)).toBeNull()
    expect(keyIndex("ArrowRight", 0, 3, { tagName: "TEXTAREA" })).toBeNull()
    expect(keyIndex("ArrowRight", 0, 3, { tagName: "DIV", isContentEditable: true })).toBeNull()
    expect(keyIndex("ArrowRight", 0, 3, null, { metaKey: true })).toBeNull()
    expect(typingTarget({ tagName: "INPUT" })).toBe(true)
    expect(typingTarget({ tagName: "BUTTON" })).toBe(false)
  })
})

describe("the hook on a 375px phone", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    globalThis.window = { matchMedia: () => ({ matches: true }) }
  })

  afterEach(() => {
    vi.useRealTimers()
    delete globalThis.window
  })

  it("a swipe to the second version pushes q_version 1 to the card once it settles", () => {
    const { el, listeners } = strip(3)
    const { pushed } = mount(el)

    el.scrollLeft = 375
    listeners.scroll()
    expect(pushed).toEqual([])
    vi.advanceTimersByTime(SETTLE_MS)
    expect(pushed).toEqual([{ target: el, event: "q_version", payload: { index: 1 } }])

    // Settling again on the same column pushes nothing new.
    listeners.scroll()
    vi.advanceTimersByTime(SETTLE_MS)
    expect(pushed.length).toBe(1)

    el.scrollLeft = 750
    listeners.scroll()
    vi.advanceTimersByTime(SETTLE_MS)
    expect(pushed.at(-1).payload).toEqual({ index: 2 })
  })

  it("a half swipe that snaps back pushes nothing", () => {
    const { el, listeners } = strip(3)
    const { pushed } = mount(el)
    el.scrollLeft = 120
    listeners.scroll()
    vi.advanceTimersByTime(SETTLE_MS)
    expect(pushed).toEqual([])
  })

  it("ArrowRight scrolls to and selects the next version", () => {
    const { el, listeners } = strip(3)
    const { pushed } = mount(el)
    const e = { key: "ArrowRight", target: el, preventDefault: vi.fn() }
    listeners.keydown(e)
    expect(e.preventDefault).toHaveBeenCalled()
    expect(el.scrolledTo).toBe(1)
    expect(pushed.at(-1).payload).toEqual({ index: 1 })
  })

  it("follows the server when it moves data-current", () => {
    const { el } = strip(3)
    const { hook, pushed } = mount(el)
    el.dataset.current = "2"
    hook.updated()
    expect(el.scrolledTo).toBe(2)
    expect(pushed).toEqual([])
  })
})

describe("the hook on a desktop", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    globalThis.window = { matchMedia: () => ({ matches: false }) }
  })

  afterEach(() => {
    vi.useRealTimers()
    delete globalThis.window
  })

  it("a horizontal scroll through the columns selects nothing", () => {
    const { el, listeners } = strip(3, { width: 1200 })
    const { pushed } = mount(el)
    el.scrollLeft = 400
    listeners.scroll()
    vi.advanceTimersByTime(SETTLE_MS)
    expect(pushed).toEqual([])
  })
})
