import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ChatDock, { DOCK_VAR, DOCK_EVENT, MENTION_LIST_SELECTOR } from "../../js/hooks/chat_dock.js"
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js"

/**
 * The phone chat dock (task 01a15f2e stage 3).
 *
 * Below lg on a routed chat, #chat-dock (streaming replies, jump anchor,
 * typing indicator, composer) is a glass overlay and the timeline runs under
 * it. `ChatDock` writes the dock's height as `--chat-dock-h` on <html> for
 * the timeline's end padding, and reports each change as `chat:dock-resized`.
 * It never writes scrollTop: `ScrollToBottom` owns the pin, and its listener
 * runs the existing follow rule with the reader's position from BEFORE the
 * change.
 *
 * vitest runs in plain node here (no jsdom), so `window`, `document`,
 * `getComputedStyle`, `CustomEvent` and `ResizeObserver` are stubbed, as in
 * compose_input.test.js.
 */

const NEAR_BOTTOM_PX = 150
// Larger than NEAR_BOTTOM_PX on purpose: a smaller growth leaves a pinned
// reader inside the follow band, where no implementation can fail (the same
// trap scroll_to_bottom_viewport.test.js documents).
const DOCK_GROWTH_PX = 200

let saved, observers, rootStyle, windowListeners, display

function stubGlobals() {
  saved = {
    window: globalThis.window,
    document: globalThis.document,
    getComputedStyle: globalThis.getComputedStyle,
    CustomEvent: globalThis.CustomEvent,
    ResizeObserver: globalThis.ResizeObserver,
    MutationObserver: globalThis.MutationObserver,
    requestAnimationFrame: globalThis.requestAnimationFrame,
    cancelAnimationFrame: globalThis.cancelAnimationFrame,
  }
  rootStyle = {
    props: {},
    setProperty(k, v) {
      this.props[k] = v
    },
    removeProperty(k) {
      delete this.props[k]
    },
  }
  windowListeners = {}
  globalThis.window = {
    addEventListener(type, fn) {
      ;(windowListeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      windowListeners[type] = (windowListeners[type] || []).filter((f) => f !== fn)
    },
    dispatchEvent(event) {
      for (const fn of windowListeners[event.type] || []) fn(event)
      return true
    },
  }
  globalThis.document = { documentElement: { style: rootStyle } }
  display = "block"
  globalThis.getComputedStyle = () => ({ display })
  globalThis.CustomEvent = class {
    constructor(type, init = {}) {
      this.type = type
      this.detail = init.detail
    }
  }
  observers = []
  globalThis.ResizeObserver = class {
    constructor(cb) {
      this.cb = cb
      this.connected = false
      observers.push(this)
    }
    observe(target, opts) {
      this.connected = true
      this.target = target
      this.opts = opts
    }
    disconnect() {
      this.connected = false
    }
  }
  globalThis.MutationObserver = class {
    observe() {}
    disconnect() {}
  }
  globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)
}

function restoreGlobals() {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete globalThis[k]
    else globalThis[k] = v
  }
}

function dockEl(height) {
  return {
    _h: height,
    getBoundingClientRect() {
      return { height: this._h }
    },
  }
}

function mountDock(height = 137) {
  const el = dockEl(height)
  const hook = Object.create(ChatDock)
  hook.el = el
  hook.mounted()
  return { el, hook }
}

describe("ChatDock writes the dock height on <html>", () => {
  beforeEach(stubGlobals)
  afterEach(restoreGlobals)

  it("writes --chat-dock-h on documentElement and observes the border box", () => {
    const { hook } = mountDock(137)
    expect(rootStyle.props[DOCK_VAR]).toBe("137px")
    const ro = observers.find((o) => o === hook._observer)
    expect(ro.connected).toBe(true)
    expect(ro.opts).toEqual({ box: "border-box" })
  })

  it("updates the variable when the dock resizes", () => {
    const { el, hook } = mountDock(137)
    el._h = 169
    hook._observer.cb()
    expect(rootStyle.props[DOCK_VAR]).toBe("169px")
  })

  it("removes the variable and disconnects on destroyed", () => {
    const { hook } = mountDock(137)
    const ro = hook._observer
    hook.destroyed()
    expect(rootStyle.props[DOCK_VAR]).toBeUndefined()
    expect(ro.connected).toBe(false)
  })

  it("removes the variable when the dock has no box (display: contents)", () => {
    const { el, hook } = mountDock(137)
    expect(rootStyle.props[DOCK_VAR]).toBe("137px")
    display = "contents"
    el._h = 0
    hook._observer.cb()
    expect(rootStyle.props[DOCK_VAR]).toBeUndefined()
  })

  it("dispatches chat:dock-resized with the growth when the dock grows", () => {
    const seen = []
    window.addEventListener(DOCK_EVENT, (e) => seen.push(e.detail))
    const { el, hook } = mountDock(137)
    el._h = 137 + DOCK_GROWTH_PX
    hook._observer.cb()
    expect(seen.at(-1)).toEqual({ height: 137 + DOCK_GROWTH_PX, delta: DOCK_GROWTH_PX })
  })

  it("does not dispatch when the height did not change", () => {
    const seen = []
    const { hook } = mountDock(137)
    window.addEventListener(DOCK_EVENT, (e) => seen.push(e.detail))
    hook._observer.cb()
    expect(seen).toEqual([])
  })
})

// The @mention list (redesign rung 10, stage 3) opens in flow INSIDE the
// dock and grows it upward over the conversation. It is not clearance: the
// field's height is. So inserting, resizing and removing the list must leave
// --chat-dock-h alone and dispatch nothing (ScrollToBottom would otherwise
// re-pin the reader, and #message-list's end padding would grow).
describe("ChatDock ignores the @mention list's height", () => {
  beforeEach(stubGlobals)
  afterEach(restoreGlobals)

  function dockWithList(height) {
    const el = dockEl(height)
    el._list = null
    el.querySelector = (sel) => (sel === MENTION_LIST_SELECTOR ? el._list : null)
    const hook = Object.create(ChatDock)
    hook.el = el
    hook.mounted()
    return { el, hook }
  }

  function openList(el, h) {
    el._list = { getBoundingClientRect: () => ({ height: h }) }
    el._h += h
  }

  it("inserting a 200px list changes neither --chat-dock-h nor dispatches chat:dock-resized", () => {
    const seen = []
    window.addEventListener(DOCK_EVENT, (e) => seen.push(e.detail))
    const { el, hook } = dockWithList(137)
    expect(rootStyle.props[DOCK_VAR]).toBe("137px")
    seen.length = 0

    openList(el, 200)
    expect(el.getBoundingClientRect().height).toBe(337)
    hook._observer.cb()
    hook.updated()
    expect(rootStyle.props[DOCK_VAR]).toBe("137px")
    expect(seen).toEqual([])

    // Filtering resizes the list; closing removes it.
    el._h = 137 + 120
    el._list = { getBoundingClientRect: () => ({ height: 120 }) }
    hook._observer.cb()
    el._h = 137
    el._list = null
    hook._observer.cb()
    expect(rootStyle.props[DOCK_VAR]).toBe("137px")
    expect(seen).toEqual([])
  })

  it("the field growing while the list is open still reports, by the field's growth only", () => {
    const seen = []
    window.addEventListener(DOCK_EVENT, (e) => seen.push(e.detail))
    const { el, hook } = dockWithList(137)
    openList(el, 200)
    hook._observer.cb()
    el._h += 24
    hook._observer.cb()
    expect(rootStyle.props[DOCK_VAR]).toBe("161px")
    expect(seen.at(-1)).toEqual({ height: 161, delta: 24 })
  })
})

// The scroller as ScrollToBottom reads it, with the browser's scrollTop clamp.
function fakeScroller({ clientHeight = 700, scrollHeight = 6000 } = {}) {
  return {
    clientHeight,
    clientWidth: 393,
    scrollHeight,
    _scrollTop: 0,
    writes: [],
    get scrollTop() {
      return this._scrollTop
    },
    set scrollTop(v) {
      const max = Math.max(0, this.scrollHeight - this.clientHeight)
      this._scrollTop = Math.min(Math.max(0, v), max)
      this.writes.push(this._scrollTop)
    },
    parkAt(distance) {
      this._scrollTop = this.scrollHeight - this.clientHeight - distance
      this.writes = []
    },
    addEventListener() {},
    removeEventListener() {},
  }
}

function settledScrollHook(scrollEl) {
  const el = {
    dataset: { spaceId: "space-dock-1" },
    closest: (sel) => (sel === "[data-scroll-container]" ? scrollEl : null),
    querySelectorAll: () => [],
    querySelector: () => null,
  }
  const hook = Object.create(ScrollToBottom)
  hook.el = el
  hook.handleEvent = vi.fn()
  hook.pushEvent = vi.fn()
  hook.mounted()
  hook._endInitialPhase("test setup")
  clearTimeout(hook._iosFallbackTimer)
  hook._iosFallbackTimer = null
  return hook
}

describe("ScrollToBottom follows a dock resize through its existing pin", () => {
  beforeEach(stubGlobals)
  afterEach(restoreGlobals)

  it("FIXTURE GUARD: the growth exceeds the follow threshold", () => {
    expect(DOCK_GROWTH_PX).toBeGreaterThan(NEAR_BOTTOM_PX)
  })

  it("a pinned reader ends at the bottom after the dock grows", () => {
    const scrollEl = fakeScroller()
    const hook = settledScrollHook(scrollEl)
    scrollEl.parkAt(0)
    hook._lastAway = false
    // The dock grows: #message-list's end padding grows with it, so
    // scrollHeight grows while scrollTop stays where it was.
    scrollEl.scrollHeight += DOCK_GROWTH_PX
    window.dispatchEvent(
      new CustomEvent(DOCK_EVENT, { detail: { height: 337, delta: DOCK_GROWTH_PX } }),
    )
    expect(scrollEl.scrollTop).toBe(scrollEl.scrollHeight - scrollEl.clientHeight)
  })

  it("a reader who scrolled up keeps their scrollTop", () => {
    const scrollEl = fakeScroller()
    const hook = settledScrollHook(scrollEl)
    scrollEl.parkAt(2000)
    hook._lastAway = true
    const before = scrollEl.scrollTop
    scrollEl.scrollHeight += DOCK_GROWTH_PX
    window.dispatchEvent(
      new CustomEvent(DOCK_EVENT, { detail: { height: 337, delta: DOCK_GROWTH_PX } }),
    )
    expect(scrollEl.scrollTop).toBe(before)
    expect(scrollEl.writes).toEqual([])
  })

  it("with no report yet, the pre-change distance is the live one less the growth", () => {
    const scrollEl = fakeScroller()
    const hook = settledScrollHook(scrollEl)
    scrollEl.parkAt(0)
    hook._lastAway = null
    scrollEl.scrollHeight += DOCK_GROWTH_PX
    window.dispatchEvent(
      new CustomEvent(DOCK_EVENT, { detail: { height: 337, delta: DOCK_GROWTH_PX } }),
    )
    expect(scrollEl.scrollTop).toBe(scrollEl.scrollHeight - scrollEl.clientHeight)
  })

  it("stops listening on destroyed", () => {
    const scrollEl = fakeScroller()
    const hook = settledScrollHook(scrollEl)
    hook.destroyed()
    expect(windowListeners[DOCK_EVENT] || []).toEqual([])
  })
})
