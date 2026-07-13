import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import StackGraphResize from "../../js/hooks/stack_graph_resize.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the StackGraphResize hook (task 019f487e, stages 2 + 3).
 *
 * Coverage:
 *   Mount defaults + stored-value validation (stage 2 surface, unchanged).
 *   ResizeObserver debounced persistence (stage 2).
 *   Border-box parity — persistence writes offsetWidth/offsetHeight, NOT
 *     contentRect (stage 3 bug fix: closes the mount-shrink loop under
 *     Tailwind's default box-sizing: border-box + p-2 padding).
 *   SVG re-fit — ResizeObserver fire writes inline width / height to the
 *     child [data-role=stack-detail-dag-svg], height minus an 8px handle
 *     reserve (stage 3 intrinsic-sizing workaround).
 *   Touch resize — touchstart on handle wires document-level touchmove /
 *     touchend, delta application, clamp to [260, innerWidth] ×
 *     [240, innerHeight], single-write-path through ResizeObserver
 *     debounce, destroyed() cleanup mid-drag.
 *
 * All state passes through Suite.ClientState (imported directly, not
 * mocked) — the module keeps an in-memory Map fallback when localStorage
 * is unavailable, which is what vitest's node env gives us.
 */

function makeFakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key(index) {
      return Array.from(store.keys())[index] ?? null
    },
    getItem(key) {
      return store.has(key) ? store.get(key) : null
    },
    setItem(key, value) {
      store.set(key, String(value))
    },
    removeItem(key) {
      store.delete(key)
    },
    clear() {
      store.clear()
    },
    __raw: store,
  }
}

let storage

function installStorage() {
  storage = makeFakeStorage()
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    get() {
      return storage
    },
  })
}

function uninstallStorage() {
  try {
    delete globalThis.localStorage
  } catch (_err) {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: undefined,
    })
  }
}

function installMatchMedia(coarse) {
  globalThis.matchMedia = (query) => ({
    matches: query === "(pointer: coarse)" ? coarse : false,
    media: query,
    addListener() {},
    removeListener() {},
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent() {
      return false
    },
    onchange: null,
  })
}

function uninstallMatchMedia() {
  try {
    delete globalThis.matchMedia
  } catch (_err) {
    globalThis.matchMedia = undefined
  }
}

// Capture the last ResizeObserver instance so tests can drive it manually.
let lastObserver

function installResizeObserver() {
  lastObserver = null
  globalThis.ResizeObserver = class {
    constructor(cb) {
      this.callback = cb
      this.observed = []
      this.disconnected = false
      lastObserver = this
    }
    observe(el) {
      this.observed.push(el)
    }
    disconnect() {
      this.disconnected = true
    }
    /**
     * Test helper — not part of the browser API.
     *
     * Fires the callback with a contentRect of (contentW, contentH). If
     * borderW/borderH are omitted they default to matching the contentRect
     * (existing test invariant); passing them separately simulates the
     * padded border-box a real Tailwind `p-2` container reports and lets
     * us prove the stage-3 border-box fix.
     */
    trigger(contentW, contentH, borderW, borderH) {
      const bW = borderW !== undefined ? borderW : contentW
      const bH = borderH !== undefined ? borderH : contentH
      for (const el of this.observed) {
        el.offsetWidth = bW
        el.offsetHeight = bH
      }
      this.callback([{ contentRect: { width: contentW, height: contentH } }], this)
    }
  }
}

function uninstallResizeObserver() {
  try {
    delete globalThis.ResizeObserver
  } catch (_err) {
    globalThis.ResizeObserver = undefined
  }
}

// document shim — tracks addEventListener / removeEventListener by type so
// we can assert cleanup and dispatch synthetic events.
let docListeners

function installDocument() {
  docListeners = {}
  const doc = {
    addEventListener(type, cb, opts) {
      if (!docListeners[type]) docListeners[type] = []
      docListeners[type].push({ cb, opts })
    },
    removeEventListener(type, cb) {
      if (!docListeners[type]) return
      docListeners[type] = docListeners[type].filter((entry) => entry.cb !== cb)
    },
  }
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    writable: true,
    value: doc,
  })
}

function uninstallDocument() {
  try {
    delete globalThis.document
  } catch (_err) {
    globalThis.document = undefined
  }
}

function dispatchDoc(type, event) {
  const listeners = (docListeners && docListeners[type]) || []
  for (const { cb } of listeners) cb(event)
}

function buildHook({
  dataset = {},
  parentWidth = 600,
  withHandle = true,
  withSvg = true,
  offsetWidth = 800,
  offsetHeight = 600,
} = {}) {
  const hook = Object.create(StackGraphResize)
  const svg = { style: {} }
  const handleListeners = {}
  const handle = {
    addEventListener(type, cb, opts) {
      handleListeners[type] = { cb, opts }
    },
    removeEventListener(type, cb) {
      if (handleListeners[type] && handleListeners[type].cb === cb) {
        delete handleListeners[type]
      }
    },
    __listeners: handleListeners,
  }
  hook.el = {
    style: {},
    dataset: {
      desktopDefaultW: "800",
      desktopDefaultH: "600",
      mobileDefaultH: "420",
      ...dataset,
    },
    parentElement: { clientWidth: parentWidth },
    offsetWidth,
    offsetHeight,
    querySelector(sel) {
      if (withSvg && sel.includes("stack-detail-dag-svg")) return svg
      if (withHandle && sel.includes("stack-detail-dag-resize-handle")) {
        return handle
      }
      return null
    },
  }
  hook.__testSvg = svg
  hook.__testHandle = handle
  hook.__handleListeners = handleListeners
  return hook
}

describe("StackGraphResize", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(false)
    installResizeObserver()
    installDocument()
    // Give the ceiling check a stable reference so oversized-stored
    // fixtures reliably fail validation.
    globalThis.innerWidth = 1440
    globalThis.innerHeight = 900
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallResizeObserver()
    uninstallDocument()
    __resetForTests()
    vi.useRealTimers()
  })

  describe("mount defaults", () => {
    it("applies desktop default 800x600 when nothing stored + fine-pointer", () => {
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("applies mobile default parentWidth + 420 height when coarse-pointer", () => {
      installMatchMedia(true)
      const hook = buildHook({ parentWidth: 375 })
      hook.mounted()

      expect(hook.el.style.width).toBe("375px")
      expect(hook.el.style.height).toBe("420px")
    })

    it("respects dataset override values", () => {
      const hook = buildHook({
        dataset: { desktopDefaultW: "1024", desktopDefaultH: "768" },
      })
      hook.mounted()

      expect(hook.el.style.width).toBe("1024px")
      expect(hook.el.style.height).toBe("768px")
    })

    it("falls back to hardcoded defaults when dataset values are unparseable", () => {
      const hook = buildHook({
        dataset: {
          desktopDefaultW: "not-a-number",
          desktopDefaultH: "also-bad",
        },
      })
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })
  })

  describe("mount with stored value", () => {
    it("restores a valid stored size", () => {
      ClientState.set("tasks_ui", "stack_graph_size", { width: 1200, height: 900 })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("1200px")
      expect(hook.el.style.height).toBe("900px")
    })

    it("falls back to default when a stored field is missing", () => {
      ClientState.set("tasks_ui", "stack_graph_size", { width: 1000 })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when a stored field is non-finite", () => {
      ClientState.set("tasks_ui", "stack_graph_size", {
        width: Number.POSITIVE_INFINITY,
        height: 800,
      })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when a stored field is negative", () => {
      ClientState.set("tasks_ui", "stack_graph_size", { width: -500, height: 800 })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when a stored field is below the min floor", () => {
      ClientState.set("tasks_ui", "stack_graph_size", { width: 100, height: 800 })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when a stored field is above the ceiling", () => {
      ClientState.set("tasks_ui", "stack_graph_size", {
        width: 99999,
        height: 99999,
      })
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when the stored value is not an object", () => {
      ClientState.set("tasks_ui", "stack_graph_size", "1200x900")
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })

    it("falls back to default when the stored value is an array", () => {
      ClientState.set("tasks_ui", "stack_graph_size", [1200, 900])
      const hook = buildHook()
      hook.mounted()

      expect(hook.el.style.width).toBe("800px")
      expect(hook.el.style.height).toBe("600px")
    })
  })

  describe("ResizeObserver -> debounced persistence", () => {
    it("collapses many rapid fires into a single ClientState.set", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      // Feed five rapid resize events within 200ms.
      lastObserver.trigger(900, 700)
      vi.advanceTimersByTime(50)
      lastObserver.trigger(950, 720)
      vi.advanceTimersByTime(50)
      lastObserver.trigger(1000, 740)
      vi.advanceTimersByTime(50)
      lastObserver.trigger(1100, 800)
      vi.advanceTimersByTime(50)
      lastObserver.trigger(1200, 850)

      // Before the 300ms trailing window elapses, nothing should be stored
      // beyond the initial null seed.
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()

      vi.advanceTimersByTime(299)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()

      vi.advanceTimersByTime(1)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toEqual({
        width: 1200,
        height: 850,
      })
    })

    it("writes the final size after debounce elapses on a single fire", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      lastObserver.trigger(950, 720)

      // Case 7 boundary lock (stage 4): no ClientState.set may fire before
      // the 300ms trailing window elapses; exactly one write lands at 300ms.
      // Advance up to (but not past) the debounce delay and confirm silence.
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()
      vi.advanceTimersByTime(299)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()

      // Cross the 300ms threshold — the single trailing write now lands.
      vi.advanceTimersByTime(1)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toEqual({
        width: 950,
        height: 720,
      })
    })
  })

  describe("border-box parity (stage 3 bug fix)", () => {
    it("persists offsetWidth/offsetHeight, NOT contentRect", () => {
      // Simulate the real DOM: Tailwind `p-2` gives 16px padding per axis.
      // ResizeObserver.contentRect reports content-box (padding excluded);
      // offsetWidth reports border-box (padding + border included). The
      // stage-2 bug wrote contentRect, which then restored via style.width
      // as border-box on next mount — shrinking the value by 2×padding each
      // round trip. Fix: write offsetWidth so it matches what the restore
      // path sets.
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      // contentRect (784, 584) but offset (border-box) is (800, 600) —
      // matches how a real p-2 container reports its two boxes.
      lastObserver.trigger(784, 584, 800, 600)
      vi.advanceTimersByTime(300)

      const stored = ClientState.get("tasks_ui", "stack_graph_size")
      expect(stored).toEqual({ width: 800, height: 600 })
      // Explicit anti-assertion: it must NOT be the contentRect values.
      expect(stored).not.toEqual({ width: 784, height: 584 })
    })

    it("round-tripping a stored value does not shrink across mounts", () => {
      vi.useFakeTimers()
      // First mount: user drags the container to 1000×800 border-box; that
      // yields a contentRect of (984, 784) inside p-2. Persistence writes
      // border-box (1000, 800).
      const hook1 = buildHook()
      hook1.mounted()
      lastObserver.trigger(984, 784, 1000, 800)
      vi.advanceTimersByTime(300)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toEqual({
        width: 1000,
        height: 800,
      })

      // Second mount reads back the stored value; style.width/height are
      // border-box, so the container's border-box size is exactly 1000×800.
      const hook2 = buildHook()
      hook2.mounted()
      expect(hook2.el.style.width).toBe("1000px")
      expect(hook2.el.style.height).toBe("800px")
    })
  })

  describe("SVG re-fit on ResizeObserver", () => {
    it("sets svg.style.width / height from contentRect minus 8px handle reserve", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      lastObserver.trigger(984, 584, 1000, 600)

      expect(hook.__testSvg.style.width).toBe("984px")
      expect(hook.__testSvg.style.height).toBe(`${584 - 8}px`)
    })

    it("re-fit fires immediately (NOT debounced) so the SVG tracks the drag", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      lastObserver.trigger(1000, 700, 1016, 716)
      // No timer advance — the SVG must have been updated inline.
      expect(hook.__testSvg.style.width).toBe("1000px")
      expect(hook.__testSvg.style.height).toBe(`${700 - 8}px`)

      lastObserver.trigger(1200, 900, 1216, 916)
      expect(hook.__testSvg.style.width).toBe("1200px")
      expect(hook.__testSvg.style.height).toBe(`${900 - 8}px`)
    })

    it("clamps svg height at 0 when contentRect is smaller than reserve", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      // Content rect height 4 < reserve 8 → Math.max(0, ...) kicks in.
      lastObserver.trigger(400, 4, 416, 20)
      expect(hook.__testSvg.style.height).toBe("0px")
    })
  })

  describe("touch resize", () => {
    it("touchstart on handle attaches document touchmove/touchend and snapshots start size", () => {
      const hook = buildHook({ offsetWidth: 800, offsetHeight: 600 })
      hook.mounted()

      const handleListener = hook.__handleListeners.touchstart
      expect(handleListener).toBeTruthy()
      expect(handleListener.opts).toEqual({ passive: false })

      let prevented = false
      handleListener.cb({
        touches: [{ clientX: 400, clientY: 300 }],
        preventDefault() {
          prevented = true
        },
      })

      expect(prevented).toBe(true)
      expect((docListeners.touchmove || []).length).toBe(1)
      expect((docListeners.touchend || []).length).toBe(1)
      expect(docListeners.touchmove[0].opts).toEqual({ passive: false })
      expect(docListeners.touchend[0].opts).toEqual({ passive: false })
    })

    it("touchmove applies delta to style.width/height while dragging", () => {
      const hook = buildHook({ offsetWidth: 800, offsetHeight: 600 })
      hook.mounted()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 400, clientY: 300 }],
        preventDefault() {},
      })

      let moved = false
      dispatchDoc("touchmove", {
        touches: [{ clientX: 400 + 120, clientY: 300 + 80 }],
        preventDefault() {
          moved = true
        },
      })

      expect(moved).toBe(true)
      expect(hook.el.style.width).toBe("920px")
      expect(hook.el.style.height).toBe("680px")

      dispatchDoc("touchmove", {
        touches: [{ clientX: 400 + 250, clientY: 300 + 150 }],
        preventDefault() {},
      })
      expect(hook.el.style.width).toBe("1050px")
      expect(hook.el.style.height).toBe("750px")
    })

    it("touchmove clamps to the floor (260 × 240)", () => {
      const hook = buildHook({ offsetWidth: 400, offsetHeight: 350 })
      hook.mounted()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 500, clientY: 500 }],
        preventDefault() {},
      })

      // Drag inward by more than the room to floor.
      dispatchDoc("touchmove", {
        touches: [{ clientX: 500 - 400, clientY: 500 - 400 }],
        preventDefault() {},
      })

      expect(hook.el.style.width).toBe("260px")
      expect(hook.el.style.height).toBe("240px")
    })

    it("touchmove clamps to window inner dimensions (ceiling)", () => {
      globalThis.innerWidth = 1024
      globalThis.innerHeight = 768
      const hook = buildHook({ offsetWidth: 900, offsetHeight: 700 })
      hook.mounted()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 500, clientY: 500 }],
        preventDefault() {},
      })

      // Drag outward well past the window edges.
      dispatchDoc("touchmove", {
        touches: [{ clientX: 500 + 5000, clientY: 500 + 5000 }],
        preventDefault() {},
      })

      expect(hook.el.style.width).toBe("1024px")
      expect(hook.el.style.height).toBe("768px")
    })

    it("touchend removes the document-level listeners", () => {
      const hook = buildHook({ offsetWidth: 800, offsetHeight: 600 })
      hook.mounted()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 400, clientY: 300 }],
        preventDefault() {},
      })

      expect((docListeners.touchmove || []).length).toBe(1)
      expect((docListeners.touchend || []).length).toBe(1)

      dispatchDoc("touchend", { touches: [], preventDefault() {} })

      expect((docListeners.touchmove || []).length).toBe(0)
      expect((docListeners.touchend || []).length).toBe(0)
    })

    it("a full touchstart -> touchmove -> touchend produces exactly ONE debounced write", () => {
      vi.useFakeTimers()
      const hook = buildHook({ offsetWidth: 800, offsetHeight: 600 })
      hook.mounted()

      // Snapshot pre-drag state.
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 400, clientY: 300 }],
        preventDefault() {},
      })

      // Three touchmoves. Each mutates style but does NOT itself call
      // ClientState.set — the invariant is that persistence only happens
      // through the ResizeObserver path (fired externally in real browsers,
      // driven manually here). Emit a single ResizeObserver fire matching
      // the final touchmove size to simulate the browser's async
      // notification after the style write.
      dispatchDoc("touchmove", {
        touches: [{ clientX: 500, clientY: 400 }],
        preventDefault() {},
      })
      dispatchDoc("touchmove", {
        touches: [{ clientX: 600, clientY: 500 }],
        preventDefault() {},
      })
      dispatchDoc("touchmove", {
        touches: [{ clientX: 700, clientY: 600 }],
        preventDefault() {},
      })
      dispatchDoc("touchend", { touches: [], preventDefault() {} })

      // No ClientState.set fired directly from the touch handlers.
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()

      // Simulate the ResizeObserver fire the browser would deliver once the
      // style writes settled — final size is 1100×900 (border-box).
      lastObserver.trigger(1084, 884, 1100, 900)
      vi.advanceTimersByTime(300)

      expect(ClientState.get("tasks_ui", "stack_graph_size")).toEqual({
        width: 1100,
        height: 900,
      })
    })

    it("destroyed() mid-drag removes both handle and document listeners", () => {
      const hook = buildHook({ offsetWidth: 800, offsetHeight: 600 })
      hook.mounted()

      hook.__handleListeners.touchstart.cb({
        touches: [{ clientX: 400, clientY: 300 }],
        preventDefault() {},
      })

      expect((docListeners.touchmove || []).length).toBe(1)
      expect((docListeners.touchend || []).length).toBe(1)
      expect(hook.__handleListeners.touchstart).toBeTruthy()

      hook.destroyed()

      expect((docListeners.touchmove || []).length).toBe(0)
      expect((docListeners.touchend || []).length).toBe(0)
      expect(hook.__handleListeners.touchstart).toBeUndefined()
    })

    it("logs and continues when the handle child is missing (fine-pointer viewports hide it)", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const hook = buildHook({ withHandle: false })
      hook.mounted()

      expect(warn).toHaveBeenCalledTimes(1)
      expect(warn.mock.calls[0][0]).toMatch(/stack-detail-dag-resize-handle/)
      // ResizeObserver path still wired.
      expect(lastObserver.observed[0]).toBe(hook.el)
      warn.mockRestore()
    })
  })

  describe("lifecycle", () => {
    it("destroyed() disconnects the observer and clears pending debounce", () => {
      vi.useFakeTimers()
      const hook = buildHook()
      hook.mounted()

      lastObserver.trigger(950, 720)
      // Pending debounce should now be scheduled.
      expect(() => hook.destroyed()).not.toThrow()

      // Advancing past 300ms must NOT flush a write — the timer was cleared.
      vi.advanceTimersByTime(600)
      expect(ClientState.get("tasks_ui", "stack_graph_size")).toBeNull()
      expect(lastObserver.disconnected).toBe(true)
    })

    it("destroyed() is a no-op safe to call before mounted()", () => {
      const hook = buildHook()
      expect(() => hook.destroyed()).not.toThrow()
    })

    it("updated() does not touch inline styles (phx-update=ignore invariant)", () => {
      const hook = buildHook()
      hook.mounted()
      hook.el.style.width = "999px"
      hook.el.style.height = "999px"

      hook.updated()

      // updated() must be a no-op so LV re-renders can't clobber the size
      // and the hook itself can't re-race with a native drag in flight.
      expect(hook.el.style.width).toBe("999px")
      expect(hook.el.style.height).toBe("999px")
    })
  })
})
