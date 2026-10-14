import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import LazyInlineCanvas, {
  NAMESPACE,
  KEY,
  ROOT_MARGIN,
  MAX_ENTRIES,
  readHeights,
  recordHeight,
  storedHeight,
  __resetForTests,
} from "../../js/hooks/lazy_inline_canvas.js"
import ClientState, { __resetForTests as resetClientState } from "../../js/client_state.js"

/**
 * LazyInlineCanvas (task 01a13884 stage 4).
 *
 *   - one IntersectionObserver per scroll container, rootMargin 600px 0px,
 *     shared by every placeholder;
 *   - an intersecting placeholder pushes `inline_canvas_mount` exactly once,
 *     batched per task with the others that intersected together;
 *   - a mounted canvas's height is written through Suite.ClientState and read
 *     back by the next placeholder for that canvas at the same width;
 *   - a canvas above the viewport that changes height moves scrollTop by the
 *     same delta, so the reader's lines do not move.
 */

function makeFakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key: (i) => Array.from(store.keys())[i] ?? null,
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    clear: () => store.clear(),
  }
}

let ioInstances
class FakeIntersectionObserver {
  constructor(cb, opts) {
    this.cb = cb
    this.opts = opts
    this.targets = new Set()
    this.disconnected = false
    ioInstances.push(this)
  }
  observe(el) {
    this.targets.add(el)
  }
  unobserve(el) {
    this.targets.delete(el)
  }
  disconnect() {
    this.disconnected = true
    this.targets.clear()
  }
  fire(entries) {
    this.cb(entries)
  }
}

let roInstances
class FakeResizeObserver {
  constructor(cb) {
    this.cb = cb
    this.targets = new Set()
    roInstances.push(this)
  }
  observe(el) {
    this.targets.add(el)
  }
  unobserve(el) {
    this.targets.delete(el)
  }
  disconnect() {
    this.targets.clear()
  }
  resize(el, height) {
    this.cb([{ target: el, borderBoxSize: [{ blockSize: height }] }])
  }
}

function fakeScroller({ width = 900, top = 0 } = {}) {
  return {
    clientWidth: width,
    scrollTop: 1000,
    getBoundingClientRect: () => ({ top }),
  }
}

function fakeWrapper(scroller, { messageId, canvasId, mounted = false, top = 500 }) {
  const placeholder = { style: {} }
  return {
    dataset: { messageId, canvasId, mounted: mounted ? "true" : "false" },
    placeholder,
    rectTop: top,
    closest: (sel) => (sel === "[data-scroll-container]" ? scroller : null),
    querySelector: (sel) =>
      sel === '[data-role="inline-canvas-placeholder"]' && mounted === false ? placeholder : null,
    getBoundingClientRect() {
      return { top: this.rectTop }
    },
  }
}

function mountHook(el) {
  const hook = Object.create(LazyInlineCanvas)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  return hook
}

const flushMicrotasks = () => new Promise((r) => setTimeout(r, 0))

describe("LazyInlineCanvas", () => {
  let storage

  beforeEach(() => {
    storage = makeFakeStorage()
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get: () => storage,
    })
    resetClientState()
    __resetForTests()
    ioInstances = []
    roInstances = []
    globalThis.IntersectionObserver = FakeIntersectionObserver
    globalThis.ResizeObserver = FakeResizeObserver
  })

  afterEach(() => {
    __resetForTests()
    delete globalThis.IntersectionObserver
    delete globalThis.ResizeObserver
    vi.useRealTimers()
  })

  it("shares ONE observer per scroll container, rooted there with a 600px margin", () => {
    const scroller = fakeScroller()
    mountHook(fakeWrapper(scroller, { messageId: "m1", canvasId: "c1" }))
    mountHook(fakeWrapper(scroller, { messageId: "m2", canvasId: "c2" }))

    expect(ioInstances).toHaveLength(1)
    expect(ioInstances[0].opts.root).toBe(scroller)
    expect(ioInstances[0].opts.rootMargin).toBe(ROOT_MARGIN)
    expect(ROOT_MARGIN).toBe("600px 0px")
    expect(ioInstances[0].targets.size).toBe(2)
  })

  it("pushes inline_canvas_mount exactly once per element, batching those that intersect together", async () => {
    const scroller = fakeScroller()
    const a = mountHook(fakeWrapper(scroller, { messageId: "m1", canvasId: "c1" }))
    const b = mountHook(fakeWrapper(scroller, { messageId: "m2", canvasId: "c2" }))
    const io = ioInstances[0]

    io.fire([
      { target: a.el, isIntersecting: true },
      { target: b.el, isIntersecting: true },
    ])
    // A second intersection of the same elements (scroll jitter) is ignored.
    io.fire([{ target: a.el, isIntersecting: true }])
    a._requestMount()
    await flushMicrotasks()

    const pushes = [...a.pushEvent.mock.calls, ...b.pushEvent.mock.calls]
    expect(pushes).toEqual([["inline_canvas_mount", { message_ids: ["m1", "m2"] }]])
    // Requested elements leave the observer; the last one disconnects it.
    expect(io.disconnected).toBe(true)
  })

  it("does not push for a non-intersecting entry or an already-mounted canvas", async () => {
    const scroller = fakeScroller()
    const lazy = mountHook(fakeWrapper(scroller, { messageId: "m1", canvasId: "c1" }))
    const done = mountHook(fakeWrapper(scroller, { messageId: "m2", canvasId: "c2", mounted: true }))

    expect(ioInstances[0].targets.has(done.el)).toBe(false)
    ioInstances[0].fire([{ target: lazy.el, isIntersecting: false }])
    done._requestMount()
    await flushMicrotasks()

    expect(lazy.pushEvent).not.toHaveBeenCalled()
    expect(done.pushEvent).not.toHaveBeenCalled()
  })

  it("records a mounted canvas's height through ClientState and the next placeholder reserves it", () => {
    vi.useFakeTimers()
    const scroller = fakeScroller({ width: 900 })
    const mounted = mountHook(
      fakeWrapper(scroller, { messageId: "m1", canvasId: "c1", mounted: true, top: 500 }),
    )
    const ro = roInstances[0]
    ro.resize(mounted.el, 300)
    ro.resize(mounted.el, 612)
    vi.advanceTimersByTime(400)

    expect(ClientState.get(NAMESPACE, KEY, null)).toEqual({ c1: [612, 900] })
    expect(storedHeight("c1", 900)).toBe(612)

    // Same canvas, same width: the placeholder takes the measured height.
    const again = mountHook(fakeWrapper(scroller, { messageId: "m1", canvasId: "c1" }))
    expect(again.el.placeholder.style.height).toBe("612px")

    // A different width is not trusted: the server's reserved height stays.
    const narrow = mountHook(
      fakeWrapper(fakeScroller({ width: 375 }), { messageId: "m1", canvasId: "c1" }),
    )
    expect(narrow.el.placeholder.style.height).toBeUndefined()
  })

  it("keeps the height memory bounded, newest last", () => {
    for (let i = 0; i < MAX_ENTRIES + 5; i++) recordHeight(`c${i}`, 100 + i, 900)
    const keys = Object.keys(readHeights())
    expect(keys).toHaveLength(MAX_ENTRIES)
    expect(keys[0]).toBe("c5")
    expect(keys.at(-1)).toBe(`c${MAX_ENTRIES + 4}`)
  })

  it("moves scrollTop by the delta when a canvas ABOVE the viewport changes height, and only then", () => {
    const scroller = fakeScroller({ top: 100 })
    const above = mountHook(fakeWrapper(scroller, { messageId: "m1", canvasId: "c1", top: -400 }))
    const below = mountHook(fakeWrapper(scroller, { messageId: "m2", canvasId: "c2", top: 600 }))
    const ro = roInstances[0]
    expect(roInstances).toHaveLength(1)

    // First observation is the placeholder's size: nothing moves.
    ro.resize(above.el, 520)
    ro.resize(below.el, 240)
    expect(scroller.scrollTop).toBe(1000)

    // The placeholder above becomes a 610px document: +90.
    above.el.dataset.mounted = "true"
    ro.resize(above.el, 610)
    expect(scroller.scrollTop).toBe(1090)

    // A canvas below the viewport top grows: the reader's lines do not move.
    ro.resize(below.el, 700)
    expect(scroller.scrollTop).toBe(1090)
  })
})
