import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import CanvasSidebarResize, {
  clampWidth,
} from "../../js/hooks/canvas_sidebar_resize.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the CanvasSidebarResize hook (task 019f5cf6 stage 2).
 *
 * Coverage:
 *   - Pure `clampWidth(startWidth, delta, innerWidth)` — min/max/inverted
 *     delta math without any DOM setup.
 *   - Default width applied when ClientState has no stored value.
 *   - Stored width restored on mount (ClientState round-trip).
 *   - Clamp to min on right-drag past the floor.
 *   - Clamp to max on left-drag past `Math.floor(innerWidth / 2)`.
 *   - Mouseup persists the final width to ClientState.
 *   - Mobile guard: `matchMedia("(min-width: 1024px)").matches = false`
 *     short-circuits `mounted()` — no listeners, no inline style, no state
 *     writes.
 *   - `destroyed()` removes document listeners and cleans the
 *     `.sidebar-resizing` body class.
 *
 * The hook stores through `Suite.ClientState`; the wrapper falls back to
 * an in-memory map when localStorage is missing, so most tests can rely on
 * the fallback and skip the fake-storage rigging. Fake storage IS installed
 * so we can assert the resulting `suite:canvas_sidebar:width` key persists
 * (and reads back) across the mount → drag → mouseup cycle.
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

function installMatchMedia(desktop) {
  globalThis.matchMedia = (query) => ({
    matches: query === "(min-width: 1024px)" ? desktop : false,
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
  // The hook reads `window.matchMedia`, not the bare global — mirror the
  // global on `window` too so the ternary in `isDesktop()` resolves.
  globalThis.window ??= globalThis
  globalThis.window.matchMedia = globalThis.matchMedia
}

function uninstallMatchMedia() {
  try {
    delete globalThis.matchMedia
  } catch (_err) {
    globalThis.matchMedia = undefined
  }
  if (globalThis.window && globalThis.window !== globalThis) {
    globalThis.window.matchMedia = undefined
  } else if (globalThis.window) {
    try {
      delete globalThis.window.matchMedia
    } catch (_err) {
      globalThis.window.matchMedia = undefined
    }
  }
}

function withInnerWidth(width) {
  globalThis.window ??= globalThis
  const previous = globalThis.window.innerWidth
  globalThis.window.innerWidth = width
  return () => {
    globalThis.window.innerWidth = previous
  }
}

// Minimal DOM stand-ins — jsdom is not on the vitest deps list; the hook
// only touches `el.style.width`, `el.offsetWidth`, `el.querySelector`,
// `handle.addEventListener/removeEventListener`, and the shared
// `document`/`window` singletons.
function makeHandle() {
  const listeners = new Map()
  const attrs = new Map()
  return {
    addEventListener(name, fn) {
      listeners.set(name, fn)
    },
    removeEventListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name)
    },
    setAttribute(name, value) {
      attrs.set(name, String(value))
    },
    getAttribute(name) {
      return attrs.has(name) ? attrs.get(name) : null
    },
    __fire(name, event) {
      const fn = listeners.get(name)
      if (fn) fn(event)
    },
    __has(name) {
      return listeners.has(name)
    },
    __attrs: attrs,
  }
}

function buildHook({ handle, initialWidth = 384 } = {}) {
  const hook = Object.create(CanvasSidebarResize)
  const _handle = handle === undefined ? makeHandle() : handle
  hook.el = {
    style: { width: "" },
    offsetWidth: initialWidth,
    querySelector(selector) {
      if (selector === "[data-drag-handle]") return _handle
      return null
    },
  }
  return { hook, handle: _handle }
}

function installDocumentBody() {
  const bodyClasses = new Set()
  const docListeners = new Map()
  globalThis.document = {
    body: {
      classList: {
        add(cls) {
          bodyClasses.add(cls)
        },
        remove(cls) {
          bodyClasses.delete(cls)
        },
        contains(cls) {
          return bodyClasses.has(cls)
        },
      },
    },
    addEventListener(name, fn) {
      docListeners.set(name, fn)
    },
    removeEventListener(name, fn) {
      if (docListeners.get(name) === fn) docListeners.delete(name)
    },
    __fire(name, event) {
      const fn = docListeners.get(name)
      if (fn) fn(event)
    },
    __has(name) {
      return docListeners.has(name)
    },
    __bodyClasses: bodyClasses,
  }
}

function uninstallDocumentBody() {
  try {
    delete globalThis.document
  } catch (_err) {
    globalThis.document = undefined
  }
}

describe("clampWidth(startWidth, delta, innerWidth) — pure helper", () => {
  it("respects the 360px minimum floor", () => {
    // 400 - 100 = 300, floors to MIN (360). Right-drag past the min.
    expect(clampWidth(400, -100, 1600)).toBe(360)
  })

  it("respects the innerWidth / 2 ceiling", () => {
    // 400 + 10000 = 10400, ceiled to floor(1600 / 2) = 800. Left-drag past.
    expect(clampWidth(400, 10000, 1600)).toBe(800)
  })

  it("passes through in-range values unchanged", () => {
    expect(clampWidth(400, 100, 1600)).toBe(500)
  })

  it("uses Math.floor for the max so odd viewports don't overshoot", () => {
    // floor(1601 / 2) = 800, not 800.5.
    expect(clampWidth(1000, 100, 1601)).toBe(800)
  })
})

describe("CanvasSidebarResize.mounted() — desktop", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("applies the default 384px when ClientState has no stored value", () => {
    const { hook } = buildHook()
    hook.mounted()

    expect(hook.el.style.width).toBe("384px")
  })

  it("restores the stored width from ClientState on mount", () => {
    ClientState.set("canvas_sidebar", "width", 520)
    const { hook } = buildHook({ initialWidth: 384 })
    hook.mounted()

    expect(hook.el.style.width).toBe("520px")
  })

  it("clamps to the 360px min when the pointer drags past the floor", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      // startWidth=400, drag pointer RIGHT by 100 (clientX moves +100).
      // Inverted delta: startX - clientX = -100. 400 + -100 = 300 → 360.
      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      globalThis.document.__fire("mousemove", { clientX: 600 })

      expect(hook.el.style.width).toBe("360px")
    } finally {
      restore()
    }
  })

  it("clamps to the innerWidth/2 max when the pointer drags left off-screen", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      // Drag LEFT by 10000 → clientX = 500 - 10000. Delta = 10000.
      // 400 + 10000 = 10400 → floor(1600/2) = 800.
      globalThis.document.__fire("mousemove", { clientX: -9500 })

      expect(hook.el.style.width).toBe("800px")
    } finally {
      restore()
    }
  })

  it("persists the final width to ClientState on mouseup", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      globalThis.document.__fire("mousemove", { clientX: 400 }) // +100 wider
      globalThis.document.__fire("mouseup", {})

      expect(hook.el.style.width).toBe("500px")
      expect(ClientState.get("canvas_sidebar", "width")).toBe(500)
      // Alex's ClientState scheme collapses namespace+key into
      // `suite:<ns>:<key>` — verify the raw persisted key is what the wire
      // format promises.
      expect(storage.getItem("suite:canvas_sidebar:width")).toBe("500")
    } finally {
      restore()
    }
  })

  it("clears the .sidebar-resizing body class after mouseup", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(true)

      globalThis.document.__fire("mouseup", {})
      expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(false)
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize.mounted() — mobile guard", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(false)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("writes no inline style and installs no listeners below the lg breakpoint", () => {
    const { hook, handle } = buildHook({ initialWidth: 384 })
    hook.mounted()

    expect(hook.el.style.width).toBe("")
    expect(handle.__has("mousedown")).toBe(false)
    expect(globalThis.document.__has("mousemove")).toBe(false)
    expect(globalThis.document.__has("mouseup")).toBe(false)
    expect(ClientState.get("canvas_sidebar", "width")).toBeNull()
  })

  it("destroyed() is a no-op when mount short-circuited on mobile", () => {
    const { hook } = buildHook()
    hook.mounted()

    // No throws, no body-class pollution — destroyed() bails before
    // touching document listeners.
    expect(() => hook.destroyed()).not.toThrow()
    expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(false)
  })
})

describe("CanvasSidebarResize.destroyed()", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("removes the handle mousedown listener and cleans the body class", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      // Simulate a mid-drag teardown — body class is set, doc listeners live.
      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(true)
      expect(globalThis.document.__has("mousemove")).toBe(true)

      hook.destroyed()

      expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(false)
      expect(handle.__has("mousedown")).toBe(false)
      expect(globalThis.document.__has("mousemove")).toBe(false)
      expect(globalThis.document.__has("mouseup")).toBe(false)
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize aria-value population — stage 4", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("writes aria-valuemin, aria-valuemax, aria-valuenow on mount", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 384 })
      hook.mounted()

      expect(handle.getAttribute("aria-valuemin")).toBe("360")
      expect(handle.getAttribute("aria-valuemax")).toBe("800")
      expect(handle.getAttribute("aria-valuenow")).toBe("384")
    } finally {
      restore()
    }
  })

  it("updates aria-valuenow while dragging so SRs announce live width", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      handle.__fire("mousedown", { preventDefault() {}, clientX: 500 })
      globalThis.document.__fire("mousemove", { clientX: 400 }) // +100 wider

      expect(hook.el.style.width).toBe("500px")
      expect(handle.getAttribute("aria-valuenow")).toBe("500")
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize keyboard nudges — stage 4", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  function keydown(handle, { key, shiftKey = false } = {}) {
    let prevented = false
    handle.__fire("keydown", {
      key,
      shiftKey,
      preventDefault() {
        prevented = true
      },
    })
    return { prevented }
  }

  it("ArrowLeft grows the panel by 2px and updates aria-valuenow", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted() // starts at DEFAULT_WIDTH (384) via storedWidth()

      keydown(handle, { key: "ArrowLeft" })

      expect(hook.el.style.width).toBe("386px")
      expect(handle.getAttribute("aria-valuenow")).toBe("386")
      // Discrete interactions persist immediately (no debounce).
      expect(ClientState.get("canvas_sidebar", "width")).toBe(386)
    } finally {
      restore()
    }
  })

  it("Shift+ArrowLeft grows the panel by 20px", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      keydown(handle, { key: "ArrowLeft", shiftKey: true })

      expect(hook.el.style.width).toBe("404px") // 384 + 20
      expect(handle.getAttribute("aria-valuenow")).toBe("404")
    } finally {
      restore()
    }
  })

  it("100× ArrowRight clamps at the 360px minimum, never below", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted() // starts at 384

      for (let i = 0; i < 100; i++) {
        keydown(handle, { key: "ArrowRight" })
      }

      expect(hook.el.style.width).toBe("360px")
      expect(handle.getAttribute("aria-valuenow")).toBe("360")
    } finally {
      restore()
    }
  })

  it("100× Shift+ArrowLeft clamps at innerWidth/2 max", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      for (let i = 0; i < 100; i++) {
        keydown(handle, { key: "ArrowLeft", shiftKey: true })
      }

      expect(hook.el.style.width).toBe("800px") // floor(1600/2)
      expect(handle.getAttribute("aria-valuenow")).toBe("800")
    } finally {
      restore()
    }
  })

  it("Home jumps to the current max width", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      keydown(handle, { key: "Home" })

      expect(hook.el.style.width).toBe("800px")
      expect(handle.getAttribute("aria-valuenow")).toBe("800")
    } finally {
      restore()
    }
  })

  it("End jumps to the 360px minimum", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      keydown(handle, { key: "End" })

      expect(hook.el.style.width).toBe("360px")
      expect(handle.getAttribute("aria-valuenow")).toBe("360")
    } finally {
      restore()
    }
  })

  it("ArrowLeft calls event.preventDefault so the page does not scroll", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      const { prevented } = keydown(handle, { key: "ArrowLeft" })

      expect(prevented).toBe(true)
    } finally {
      restore()
    }
  })

  it("ignores keys that are not Arrow/Home/End", () => {
    const restore = withInnerWidth(1600)
    try {
      const { hook, handle } = buildHook({ initialWidth: 400 })
      hook.mounted()

      // A random key must not preventDefault (or resize).
      const { prevented } = keydown(handle, { key: "a" })

      expect(prevented).toBe(false)
      expect(hook.el.style.width).toBe("384px")
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize double-click reset — stage 4", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("dblclick on the handle resets to DEFAULT (384) and persists", () => {
    const restore = withInnerWidth(1600)
    try {
      ClientState.set("canvas_sidebar", "width", 620)
      const { hook, handle } = buildHook({ initialWidth: 620 })
      hook.mounted()
      expect(hook.el.style.width).toBe("620px")

      handle.__fire("dblclick", { preventDefault() {} })

      expect(hook.el.style.width).toBe("384px")
      expect(handle.getAttribute("aria-valuenow")).toBe("384")
      expect(ClientState.get("canvas_sidebar", "width")).toBe(384)
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize matchMedia change listener — stage 4", () => {
  let mediaListeners

  function installReactiveMatchMedia(initialDesktop) {
    mediaListeners = new Set()
    const state = { desktop: initialDesktop }
    const mql = {
      get matches() {
        return state.desktop
      },
      media: "(min-width: 1024px)",
      addEventListener(_name, fn) {
        mediaListeners.add(fn)
      },
      removeEventListener(_name, fn) {
        mediaListeners.delete(fn)
      },
      addListener() {},
      removeListener() {},
      dispatchEvent() {
        return false
      },
      onchange: null,
    }
    globalThis.matchMedia = () => mql
    globalThis.window ??= globalThis
    globalThis.window.matchMedia = globalThis.matchMedia
    return {
      cross(nextDesktop) {
        state.desktop = nextDesktop
        for (const fn of mediaListeners) fn({ matches: nextDesktop })
      },
    }
  }

  beforeEach(() => {
    installStorage()
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
    mediaListeners = null
  })

  it("activates the drag machinery when the viewport crosses into desktop", () => {
    const restore = withInnerWidth(1600)
    try {
      const controller = installReactiveMatchMedia(false)
      const { hook, handle } = buildHook({ initialWidth: 384 })
      hook.mounted()

      // Below lg → no listeners wired, no inline width.
      expect(hook.el.style.width).toBe("")
      expect(handle.__has("mousedown")).toBe(false)

      // Cross into desktop.
      controller.cross(true)

      expect(hook.el.style.width).toBe("384px")
      expect(handle.__has("mousedown")).toBe(true)
      expect(handle.__has("keydown")).toBe(true)
      expect(handle.__has("dblclick")).toBe(true)
    } finally {
      restore()
    }
  })

  it("tears down when the viewport crosses out of desktop", () => {
    const restore = withInnerWidth(1600)
    try {
      const controller = installReactiveMatchMedia(true)
      const { hook, handle } = buildHook({ initialWidth: 384 })
      hook.mounted()
      expect(handle.__has("mousedown")).toBe(true)

      controller.cross(false)

      expect(handle.__has("mousedown")).toBe(false)
      expect(handle.__has("keydown")).toBe(false)
      expect(handle.__has("dblclick")).toBe(false)
      expect(globalThis.document.__bodyClasses.has("sidebar-resizing")).toBe(false)
    } finally {
      restore()
    }
  })
})

describe("CanvasSidebarResize.updated() — LiveView diff patch guard", () => {
  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("re-applies the persisted width after a simulated morphdom clobber", () => {
    const restore = withInnerWidth(1600)
    try {
      ClientState.set("canvas_sidebar", "width", 800)
      const { hook } = buildHook({ initialWidth: 384 })
      hook.mounted()
      expect(hook.el.style.width).toBe("800px")

      // Simulate morphdom attribute reconciliation clearing the inline style
      // (compose_changed on every keystroke → parent re-render → aside diff).
      hook.el.style.width = ""

      hook.updated()

      expect(hook.el.style.width).toBe("800px")
    } finally {
      restore()
    }
  })

  it("no-ops on mobile viewport (hook attached but drag machinery inactive)", () => {
    // Rebuild environment as mobile — mounted() will short-circuit and
    // updated() must not touch inline style or write to ClientState.
    uninstallMatchMedia()
    installMatchMedia(false)

    const { hook } = buildHook({ initialWidth: 384 })
    hook.mounted()
    expect(hook.el.style.width).toBe("")

    // A later parent re-render fires updated() — still nothing to do.
    hook.updated()

    expect(hook.el.style.width).toBe("")
    expect(ClientState.get("canvas_sidebar", "width")).toBeNull()
  })

  it("no-ops mid-drag so an in-flight mousemove is not clobbered", () => {
    const restore = withInnerWidth(1600)
    try {
      ClientState.set("canvas_sidebar", "width", 500)
      const { hook } = buildHook({ initialWidth: 500 })
      hook.mounted()
      expect(hook.el.style.width).toBe("500px")

      // Simulate an in-progress drag: mousedown set the body class, mousemove
      // wrote the live width (say user is dragging out to 820). Then
      // LiveView emits a diff patch → updated() fires. Must NOT snap back
      // to the last persisted 500.
      globalThis.document.body.classList.add("sidebar-resizing")
      hook.el.style.width = "820px"

      hook.updated()

      expect(hook.el.style.width).toBe("820px")
    } finally {
      restore()
    }
  })

  it("refreshes aria-valuemax when the viewport width changed since mount", () => {
    // Mount at 1600 → max=800; then viewport shrinks to 1200 → max=600;
    // an updated() re-run should refresh aria-valuemax accordingly.
    const restoreMount = withInnerWidth(1600)
    const { hook, handle } = buildHook({ initialWidth: 384 })
    hook.mounted()
    expect(handle.getAttribute("aria-valuemax")).toBe("800")
    restoreMount()

    const restorePatch = withInnerWidth(1200)
    try {
      hook.updated()
      expect(handle.getAttribute("aria-valuemax")).toBe("600")
    } finally {
      restorePatch()
    }
  })

  it("refreshes aria-valuemax upward when the viewport grows since mount", () => {
    // Symmetric to the shrink case above: mount at 1200 (max=600), then the
    // browser window is dragged wider to 1920 (max=960). The next patch's
    // updated() should raise aria-valuemax to 960 so SR users hear the new
    // ceiling — the divider's static `aria-valuemax="960"` in partials.ex
    // matches this default 1920-wide viewport assumption; the hook overwrites
    // once mounted and after every viewport-crossing patch.
    const restoreMount = withInnerWidth(1200)
    const { hook, handle } = buildHook({ initialWidth: 384 })
    hook.mounted()
    expect(handle.getAttribute("aria-valuemax")).toBe("600")
    restoreMount()

    const restorePatch = withInnerWidth(1920)
    try {
      hook.updated()
      expect(handle.getAttribute("aria-valuemax")).toBe("960")
    } finally {
      restorePatch()
    }
  })

  it("no-ops before mounted() runs (guards against updated() first-flight)", () => {
    // LiveView can, in odd reconnect sequences, fire updated() before or
    // without mounted(). The `!this._active` guard protects against a
    // NullReferenceError-shaped bug in that case.
    const { hook } = buildHook({ initialWidth: 384 })
    expect(() => hook.updated()).not.toThrow()
    expect(hook.el.style.width).toBe("")
  })
})

describe("CanvasSidebarResize — Alex's regression scenario: compose_changed sequence", () => {
  // Stage 3 dedicated regression guard for the exact scenario Alex reported
  // in task 019f5cf6 v2: user drags the canvas sidebar wider, then types
  // into the chat composer — every keystroke fires `compose_changed`, which
  // triggers a parent re-render, which hands the aside to morphdom, which
  // reconciles attributes and CLEARS the inline `style="width: 800px"` we
  // set at mount / mousemove. Panel snaps back to the Tailwind `w-96`
  // fallback (384px) on every keystroke.
  //
  // Stage 2 (commit e252e50) wired `updated()` to re-apply the persisted
  // width after every diff patch. The three cases below reproduce Alex's
  // exact workflow and lock in the fix against future regressions.

  beforeEach(() => {
    installStorage()
    installMatchMedia(true)
    installDocumentBody()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallMatchMedia()
    uninstallDocumentBody()
    __resetForTests()
  })

  it("Case A — width sticks across 20 sequential compose_changed patches", () => {
    // Headline regression. A realistic short-burst typing scenario is
    // ~20 keystrokes (~4 seconds at 5cps). Each keystroke is one
    // compose_changed → one morphdom pass → one updated() invocation.
    // Every single one must preserve the 800px width.
    const restore = withInnerWidth(1600)
    try {
      ClientState.set("canvas_sidebar", "width", 800)
      const { hook } = buildHook({ initialWidth: 384 })
      hook.mounted()
      expect(hook.el.style.width).toBe("800px")

      for (let i = 0; i < 20; i++) {
        // Simulate morphdom attribute reconciliation clearing the inline
        // style during the diff patch that LiveView applies before
        // invoking updated().
        hook.el.style.width = ""
        hook.updated()
        expect(hook.el.style.width).toBe("800px")
      }

      // Persisted value untouched — updated() is a pure re-application,
      // never a write back to ClientState.
      expect(ClientState.get("canvas_sidebar", "width")).toBe(800)
    } finally {
      restore()
    }
  })

  it("Case B — width survives a compose reset after the keystroke burst", () => {
    // Sending a message clears the composer (`compose_reset`-shaped diff).
    // From the hook's perspective this is indistinguishable from another
    // keystroke patch: parent re-renders with an empty compose form and
    // morphdom passes over the aside again. This case guards against a
    // regression where the reset patch has a different diff shape (e.g.
    // whole-tree replace vs attribute-only) that bypasses the fix.
    const restore = withInnerWidth(1600)
    try {
      ClientState.set("canvas_sidebar", "width", 800)
      const { hook } = buildHook({ initialWidth: 384 })
      hook.mounted()

      // A short burst of keystroke patches first.
      for (let i = 0; i < 5; i++) {
        hook.el.style.width = ""
        hook.updated()
      }
      expect(hook.el.style.width).toBe("800px")

      // Now the send/reset patch. Same code path from the hook's POV.
      hook.el.style.width = ""
      hook.updated()

      expect(hook.el.style.width).toBe("800px")
      expect(ClientState.get("canvas_sidebar", "width")).toBe(800)
    } finally {
      restore()
    }
  })

  it("Case C — width restored after viewport crosses mobile → desktop mid-sequence", () => {
    // Viewport-crossing regression. If the user resizes the browser window
    // across the lg breakpoint (1024px) between compose_changed patches,
    // the mobile branch's updated() must not clobber the persisted width,
    // and the desktop re-entry must restore the panel to 800px via
    // _activate() → _applyWidth(). Persistence isn't lost by the crossing.
    const mediaListeners = new Set()
    const state = { desktop: true }
    const mql = {
      get matches() {
        return state.desktop
      },
      media: "(min-width: 1024px)",
      addEventListener(_name, fn) {
        mediaListeners.add(fn)
      },
      removeEventListener(_name, fn) {
        mediaListeners.delete(fn)
      },
      addListener() {},
      removeListener() {},
      dispatchEvent() {
        return false
      },
      onchange: null,
    }
    globalThis.matchMedia = () => mql
    globalThis.window ??= globalThis
    globalThis.window.matchMedia = globalThis.matchMedia

    ClientState.set("canvas_sidebar", "width", 800)
    const restore = withInnerWidth(1440)
    try {
      const { hook } = buildHook({ initialWidth: 384 })
      hook.mounted()
      expect(hook.el.style.width).toBe("800px")

      // 1. compose_changed at desktop — width preserved.
      hook.el.style.width = ""
      hook.updated()
      expect(hook.el.style.width).toBe("800px")

      // 2. Viewport shrinks past the lg breakpoint. matchMedia change
      //    fires → _deactivate(). Any subsequent updated() must no-op
      //    (the mobile overlay branch owns the presentation).
      state.desktop = false
      globalThis.window.innerWidth = 600
      for (const fn of mediaListeners) fn({ matches: false })

      hook.el.style.width = ""
      hook.updated()
      expect(hook.el.style.width).toBe("")
      // ClientState never mutated by the mobile-branch updated().
      expect(ClientState.get("canvas_sidebar", "width")).toBe(800)

      // 3. Viewport grows back past lg. matchMedia change → _activate() →
      //    _applyWidth() restores the persisted 800px on the same DOM node.
      state.desktop = true
      globalThis.window.innerWidth = 1440
      for (const fn of mediaListeners) fn({ matches: true })
      expect(hook.el.style.width).toBe("800px")

      // 4. A follow-up compose_changed at desktop still preserves 800.
      hook.el.style.width = ""
      hook.updated()
      expect(hook.el.style.width).toBe("800px")
    } finally {
      restore()
    }
  })
})
