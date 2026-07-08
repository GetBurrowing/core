import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import RouteResume, {
  moduleFromPath,
  sameModulePrefix,
  PATH_MODULE_MAP,
} from "../../js/hooks/route_resume.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the `RouteResume` hook (task 019f3e9a stage 2). Covers:
 *
 *   - pure `moduleFromPath` / `sameModulePrefix` derivation
 *   - end-to-end: mount hook, dispatch synthetic `phx:page-loading-stop`
 *     at `/chat/abc`, verify `ClientState.get("route_resume", "chat")`
 *     === `/chat/abc`
 *   - end-to-end: dispatch `phx:route_resume_stale` with `module: "chat"`,
 *     verify value cleared
 *   - click intercept: a `<a data-module-id="chat" href="/chat">` click
 *     with a saved value routes via `liveSocket.historyRedirect` and the
 *     default nav is prevented
 *   - click intercept: no saved value → default nav proceeds unmolested
 *   - click intercept: cross-module saved value (data-module-id="chat"
 *     but saved starts with `/tasks/…`) is not honored — sameModulePrefix
 *     guard fires
 *
 * Vitest default env is node; we install a minimal in-memory
 * `localStorage`, `window`, and `document` shim so the hook can run
 * against events + DOM traversal without pulling in jsdom.
 */

// ── Shims ─────────────────────────────────────────────────────────────

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

// Minimal `window` shim with an EventTarget-like listener registry so the
// hook's `addEventListener` / `dispatchEvent` round-trip works without
// jsdom. Also carries a `location` object we can mutate between tests.
function makeFakeWindow() {
  const listeners = new Map() // event name → Set<fn>
  return {
    location: { pathname: "/" },
    liveSocket: null,
    addEventListener(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set())
      listeners.get(name).add(fn)
    },
    removeEventListener(name, fn) {
      listeners.get(name)?.delete(fn)
    },
    dispatchEvent(evt) {
      const set = listeners.get(evt.type)
      if (!set) return
      for (const fn of set) fn(evt)
    },
    // Convenience for assertions.
    _listeners: listeners,
  }
}

// Minimal `document` shim mirroring the `addEventListener` triad and a
// `dispatchEvent` for click delegation. The hook attaches to `document`
// in capture phase (`true`) so we honor that on registration.
function makeFakeDocument() {
  const listeners = [] // {name, fn, capture}
  return {
    addEventListener(name, fn, capture) {
      listeners.push({ name, fn, capture: !!capture })
    },
    removeEventListener(name, fn, capture) {
      const idx = listeners.findIndex(
        (l) => l.name === name && l.fn === fn && l.capture === !!capture
      )
      if (idx >= 0) listeners.splice(idx, 1)
    },
    dispatchClick(evt) {
      for (const l of listeners) if (l.name === "click") l.fn(evt)
    },
    _listeners: listeners,
  }
}

// Fake anchor: the hook reads `dataset.moduleId`, `pathname`,
// `getAttribute("href")`, and uses `event.target.closest(...)` to hop from
// a click target up to the anchor. We just make the anchor its own closest
// match for the selector `a[data-module-id]`.
function makeAnchor({ moduleId, href }) {
  const anchor = {
    tagName: "A",
    dataset: { moduleId },
    pathname: href,
    getAttribute(name) {
      return name === "href" ? href : null
    },
    closest(sel) {
      // Only handle the exact selector the hook uses.
      return sel === "a[data-module-id]" ? anchor : null
    },
  }
  return anchor
}

function makeClickEvent(anchor) {
  const evt = {
    type: "click",
    target: anchor,
    button: 0,
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    defaultPrevented: false,
    propagationStopped: false,
    immediatePropagationStopped: false,
    preventDefault() {
      this.defaultPrevented = true
    },
    stopPropagation() {
      this.propagationStopped = true
    },
    stopImmediatePropagation() {
      this.immediatePropagationStopped = true
      this.propagationStopped = true
    },
  }
  return evt
}

function installShims() {
  const storage = makeFakeStorage()
  const win = makeFakeWindow()
  const doc = makeFakeDocument()

  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    get() {
      return storage
    },
  })
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    get() {
      return win
    },
  })
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    get() {
      return doc
    },
  })
  return { storage, win, doc }
}

function uninstallShims() {
  for (const name of ["localStorage", "window", "document"]) {
    try {
      delete globalThis[name]
    } catch (_err) {
      Object.defineProperty(globalThis, name, { configurable: true, value: undefined })
    }
  }
}

function buildHook() {
  const hook = Object.create(RouteResume)
  return hook
}

// ── Pure helpers ──────────────────────────────────────────────────────

describe("moduleFromPath", () => {
  it("maps the first path segment to its module id (allowlist)", () => {
    expect(moduleFromPath("/chat/abc")).toBe("chat")
    expect(moduleFromPath("/tasks/xyz")).toBe("tasks")
    expect(moduleFromPath("/meetings/room-1")).toBe("meetings")
    expect(moduleFromPath("/inbox")).toBe("inbox")
    expect(moduleFromPath("/activity")).toBe("activity")
    expect(moduleFromPath("/skills/deep-dive")).toBe("skills")
    expect(moduleFromPath("/files")).toBe("files")
  })

  it("resolves /admin/prompts to `prompts` before /admin captures it", () => {
    // Longest-prefix-first guard: without it, `/admin/prompts/foo` would
    // silently save under `admin` and clobber the actual admin state.
    expect(moduleFromPath("/admin/prompts")).toBe("prompts")
    expect(moduleFromPath("/admin/prompts/foo")).toBe("prompts")
    expect(moduleFromPath("/admin")).toBe("admin")
    expect(moduleFromPath("/admin/federation")).toBe("admin")
  })

  it("resolves /org_memory to the context module (icon_rail dest.key)", () => {
    // The org-memory tile carries `data-module-id="context"` (dest.key)
    // while the URL segment is `org_memory`. moduleFromPath bridges the
    // mismatch so both sides agree on a single moduleId.
    expect(moduleFromPath("/org_memory")).toBe("context")
    expect(moduleFromPath("/org_memory/some-file")).toBe("context")
  })

  it("returns null for paths outside the allowlist", () => {
    expect(moduleFromPath("/")).toBeNull()
    expect(moduleFromPath("/unknown")).toBeNull()
    expect(moduleFromPath("/tasksy")).toBeNull() // segment boundary — no prefix leak
  })

  it("returns null on non-string / non-slash-prefixed input", () => {
    expect(moduleFromPath(null)).toBeNull()
    expect(moduleFromPath(undefined)).toBeNull()
    expect(moduleFromPath("chat/abc")).toBeNull()
  })
})

describe("sameModulePrefix", () => {
  it("matches when saved URL lives under the module's canonical prefix", () => {
    expect(sameModulePrefix("chat", "/chat/abc")).toBe(true)
    expect(sameModulePrefix("chat", "/chat")).toBe(true)
    expect(sameModulePrefix("tasks", "/tasks/1234-uuid")).toBe(true)
  })

  it("rejects a cross-module saved value (namespace pollution guard)", () => {
    expect(sameModulePrefix("chat", "/tasks/whatever")).toBe(false)
    expect(sameModulePrefix("meetings", "/chat/room")).toBe(false)
  })

  it("rejects unknown module ids", () => {
    expect(sameModulePrefix("nope", "/nope")).toBe(false)
  })
})

describe("PATH_MODULE_MAP ordering invariant", () => {
  it("places /admin/prompts before /admin", () => {
    const idxPrompts = PATH_MODULE_MAP.findIndex(([p]) => p === "/admin/prompts")
    const idxAdmin = PATH_MODULE_MAP.findIndex(([p]) => p === "/admin")
    expect(idxPrompts).toBeGreaterThanOrEqual(0)
    expect(idxAdmin).toBeGreaterThan(idxPrompts)
  })
})

// ── Hook lifecycle ────────────────────────────────────────────────────

describe("RouteResume hook", () => {
  let shims

  beforeEach(() => {
    shims = installShims()
    __resetForTests()
  })

  afterEach(() => {
    uninstallShims()
    __resetForTests()
  })

  it("persists the current pathname to route_resume on phx:page-loading-stop", () => {
    shims.win.location.pathname = "/chat/abc"
    const hook = buildHook()
    hook.mounted()

    // mounted() also fires _persistCurrentPath() with the current URL.
    expect(ClientState.get("route_resume", "chat")).toBe("/chat/abc")

    // Simulate a client-side patch to a new URL within the module.
    shims.win.location.pathname = "/chat/def"
    shims.win.dispatchEvent({ type: "phx:page-loading-stop" })

    expect(ClientState.get("route_resume", "chat")).toBe("/chat/def")
  })

  it("skips persistence for paths outside the module allowlist", () => {
    shims.win.location.pathname = "/unknown-route"
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "unknown-route")).toBeNull()
    // Nothing at all should be written for these routes.
    expect(shims.storage.__raw.size).toBe(0)
  })

  it("clears route_resume:<module> on phx:route_resume_stale", () => {
    shims.win.location.pathname = "/chat/abc"
    const hook = buildHook()
    hook.mounted()
    expect(ClientState.get("route_resume", "chat")).toBe("/chat/abc")

    shims.win.dispatchEvent({
      type: "phx:route_resume_stale",
      detail: { module: "chat" },
    })

    expect(ClientState.get("route_resume", "chat")).toBeNull()
  })

  it("ignores phx:route_resume_stale with a missing / non-string module", () => {
    ClientState.set("route_resume", "chat", "/chat/abc")
    const hook = buildHook()
    hook.mounted()

    // Malformed detail must not crash the listener.
    shims.win.dispatchEvent({ type: "phx:route_resume_stale", detail: null })
    shims.win.dispatchEvent({ type: "phx:route_resume_stale", detail: {} })
    shims.win.dispatchEvent({
      type: "phx:route_resume_stale",
      detail: { module: 42 },
    })

    // Existing entry should still be there.
    expect(ClientState.get("route_resume", "chat")).toBe("/chat/abc")
  })

  it("cleans up listeners on destroyed()", () => {
    shims.win.location.pathname = "/chat/abc"
    const hook = buildHook()
    hook.mounted()

    expect(shims.win._listeners.get("phx:page-loading-stop")?.size ?? 0).toBe(1)
    expect(shims.doc._listeners.filter((l) => l.name === "click")).toHaveLength(1)

    hook.destroyed()

    expect(shims.win._listeners.get("phx:page-loading-stop")?.size ?? 0).toBe(0)
    expect(shims.doc._listeners.filter((l) => l.name === "click")).toHaveLength(0)
  })
})

// ── Click intercept ───────────────────────────────────────────────────

describe("RouteResume click intercept", () => {
  let shims
  let historyRedirect

  beforeEach(() => {
    shims = installShims()
    __resetForTests()
    historyRedirect = vi.fn()
    shims.win.liveSocket = { historyRedirect }
  })

  afterEach(() => {
    uninstallShims()
    __resetForTests()
  })

  it("routes a tile click to the saved URL when it differs from href", () => {
    ClientState.set("route_resume", "chat", "/chat/abc")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    // Bubble-phase propagation to `window` MUST be stopped — LiveView's
    // own window-level click handler runs `historyRedirect(event,
    // anchor.href, …)` without checking `defaultPrevented`, which would
    // clobber our navigation to the saved URL and send the user to the
    // anchor's raw href instead.
    expect(evt.propagationStopped).toBe(true)
    expect(historyRedirect).toHaveBeenCalledTimes(1)
    // Signature is `historyRedirect(e, href, linkState, flash, targetEl)`
    // — event first, `null` for flash, anchor as targetEl.
    expect(historyRedirect).toHaveBeenCalledWith(evt, "/chat/abc", "push", null, anchor)
  })

  it("stops event propagation BEFORE calling historyRedirect", () => {
    // Ordering matters: if historyRedirect were called first, an error
    // thrown by LV internals would leave the event un-stopped and the
    // bubble-phase LV handler would still clobber us. Assert the exact
    // ordering via a call log.
    ClientState.set("route_resume", "chat", "/chat/abc")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)

    const callLog = []
    const originalStop = evt.stopPropagation
    evt.stopPropagation = function () {
      callLog.push("stopPropagation")
      originalStop.call(this)
    }
    historyRedirect.mockImplementation(() => {
      callLog.push("historyRedirect")
    })

    shims.doc.dispatchClick(evt)

    expect(callLog).toEqual(["stopPropagation", "historyRedirect"])
  })

  it("no-ops when saved URL equals the anchor's href (nothing to change)", () => {
    ClientState.set("route_resume", "chat", "/chat")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()
  })

  it("no-ops when nothing is saved for the tile's module", () => {
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "tasks", href: "/tasks" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()
  })

  it("refuses to route to a saved URL from a different module prefix", () => {
    // Namespace pollution guard: `route_resume:chat` accidentally holds a
    // Tasks URL. A Chat-tile click MUST NOT navigate to /tasks/….
    ClientState.set("route_resume", "chat", "/tasks/some-task-id")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()
  })

  it("ignores modifier / non-primary clicks (Cmd-click, middle-click)", () => {
    ClientState.set("route_resume", "chat", "/chat/abc")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    evt.metaKey = true
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()
  })

  it("no-ops when the click target has no data-module-id ancestor", () => {
    ClientState.set("route_resume", "chat", "/chat/abc")
    const hook = buildHook()
    hook.mounted()

    const bareTarget = {
      closest() {
        return null
      },
    }
    const evt = {
      type: "click",
      target: bareTarget,
      button: 0,
      metaKey: false,
      ctrlKey: false,
      shiftKey: false,
      altKey: false,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true
      },
    }
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()
  })

  it("falls back to window.location.assign when liveSocket is missing", () => {
    shims.win.liveSocket = null
    // Location is a non-allowlisted route so mount()'s _persistCurrentPath
    // is a no-op — otherwise it would clobber the saved value we plant
    // below with the current pathname.
    const assigns = []
    shims.win.location = {
      pathname: "/unlisted",
      assign(url) {
        assigns.push(url)
      },
    }

    const hook = buildHook()
    hook.mounted()

    // Plant the saved value AFTER mount so it survives the initial
    // _persistCurrentPath() call.
    ClientState.set("route_resume", "chat", "/chat/abc")

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    // Even in the fallback branch, bubble-phase propagation must be
    // stopped so LV (if present) can't fire a competing navigation.
    expect(evt.propagationStopped).toBe(true)
    expect(assigns).toEqual(["/chat/abc"])
  })
})
