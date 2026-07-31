import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import RouteResume, {
  moduleFromPath,
  sameModulePrefix,
  stripQueryAndFragment,
  stripTransientParams,
  PATH_MODULE_MAP,
  TRANSIENT_QUERY_PARAMS,
  RESUME_TTL_MS,
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
    // `search` mirrors browser `window.location.search` — either "" or a
    // leading-`?` string. Tests that care about query-string round-tripping
    // (task 019f487e Case 5) mutate this alongside `pathname`.
    location: { pathname: "/", search: "" },
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

// Fake anchor: the hook reads `dataset.moduleId`, `pathname`, `search`,
// `getAttribute("href")`, and uses `event.target.closest(...)` to hop from
// a click target up to the anchor. We just make the anchor its own closest
// match for the selector `a[data-module-id]`. `href` is split into path
// and query so the hook's path+search compare works the same way it does
// against a real HTMLAnchorElement.
function makeAnchor({ moduleId, href }) {
  const qIdx = href.indexOf("?")
  const path = qIdx >= 0 ? href.slice(0, qIdx) : href
  const search = qIdx >= 0 ? href.slice(qIdx) : ""
  const anchor = {
    tagName: "A",
    dataset: { moduleId },
    pathname: path,
    search,
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

  it("accepts a saved URL that carries a query string (Case 5 fix)", () => {
    // Regression guard: the sponsor pill saves `/tasks?sponsor=mine` into
    // the tasks slot. Prefix match MUST see the pathname component only —
    // otherwise the intercept refuses to restore the saved URL and the
    // query state is silently dropped on the top-nav round-trip.
    expect(sameModulePrefix("tasks", "/tasks?sponsor=mine")).toBe(true)
    expect(sameModulePrefix("tasks", "/tasks?a=b&c=d")).toBe(true)
    expect(sameModulePrefix("chat", "/chat/abc?scroll=42")).toBe(true)
  })

  it("still rejects cross-module saved value with a query string", () => {
    expect(sameModulePrefix("chat", "/tasks?sponsor=mine")).toBe(false)
  })
})

describe("stripQueryAndFragment", () => {
  it("returns input unchanged when no `?` or `#` present", () => {
    expect(stripQueryAndFragment("/tasks")).toBe("/tasks")
    expect(stripQueryAndFragment("/chat/abc")).toBe("/chat/abc")
    expect(stripQueryAndFragment("")).toBe("")
  })

  it("strips query string starting at `?`", () => {
    expect(stripQueryAndFragment("/tasks?sponsor=mine")).toBe("/tasks")
    expect(stripQueryAndFragment("/chat/abc?x=1&y=2")).toBe("/chat/abc")
  })

  it("strips fragment starting at `#`", () => {
    expect(stripQueryAndFragment("/tasks#top")).toBe("/tasks")
  })

  it("cuts at whichever of `?` or `#` comes first", () => {
    expect(stripQueryAndFragment("/tasks?x=1#top")).toBe("/tasks")
    expect(stripQueryAndFragment("/tasks#top?x=1")).toBe("/tasks")
  })

  it("returns empty string for non-string input", () => {
    expect(stripQueryAndFragment(null)).toBe("")
    expect(stripQueryAndFragment(undefined)).toBe("")
    expect(stripQueryAndFragment(42)).toBe("")
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

  it("persists pathname + search so `?sponsor=mine` round-trips (Case 5 fix)", () => {
    // Regression: previously the hook stored `pathname` only, so a
    // top-nav Tasks click after `/tasks?sponsor=mine` matched the anchor
    // href exactly and the intercept no-op'd — dropping the query.
    // Now the saved value includes the query so the intercept fires and
    // restores the deep-link URL.
    shims.win.location.pathname = "/tasks"
    shims.win.location.search = "?sponsor=mine"
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "tasks")).toBe("/tasks?sponsor=mine")

    // A subsequent nav within the tasks module drops the query — the
    // saved value follows.
    shims.win.location.pathname = "/tasks/abc-uuid"
    shims.win.location.search = ""
    shims.win.dispatchEvent({ type: "phx:page-loading-stop" })

    expect(ClientState.get("route_resume", "tasks")).toBe("/tasks/abc-uuid")
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

  it("routes to saved URL preserving `?sponsor=mine` on bare top-nav click (Case 5)", () => {
    // Load `/tasks?sponsor=mine`, navigate elsewhere, then click the bare
    // `/tasks` top-nav tile. Previously the pathname-only comparison
    // matched and the query was lost. Now the whole-URL comparison sees a
    // mismatch and redirects to the saved deep-link.
    ClientState.set("route_resume", "tasks", "/tasks?sponsor=mine")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "tasks", href: "/tasks" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    expect(evt.propagationStopped).toBe(true)
    expect(historyRedirect).toHaveBeenCalledTimes(1)
    expect(historyRedirect).toHaveBeenCalledWith(
      evt,
      "/tasks?sponsor=mine",
      "push",
      null,
      anchor,
    )
  })

  it("no-ops when the saved URL equals anchor path + search (query on both)", () => {
    // The anchor already carries the same query — nothing to restore.
    // Guards against a redundant historyRedirect fire that would push a
    // duplicate history entry for the same URL.
    ClientState.set("route_resume", "tasks", "/tasks?sponsor=mine")
    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "tasks", href: "/tasks?sponsor=mine" })
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

// ── Resume TTL (task 019f62c8) ────────────────────────────────────────
//
// The bug: the resume entry NEVER EXPIRED. `_persistCurrentPath` wrote via
// `ClientState.set(...)` with no opts, so a saved subpage (e.g.
// `/admin/users`) survived indefinitely — across hours and across a fresh
// deploy — and the Admin gear kept resuming a long-dead subpage instead of
// landing on the module root `/admin`.
//
// The fix: `_persistCurrentPath` now passes `{ ttlMs: RESUME_TTL_MS }`
// (3 hours). ClientState wraps the value in a `{v, e}` envelope whose `e` is
// the absolute expiry epoch; `ClientState.get` returns the value before `e`
// and the default (null) after, proactively cleaning the stale key. These
// tests exercise both edges through the hook + intercept.

describe("RouteResume resume TTL", () => {
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

  it("uses a 3-hour resume TTL", () => {
    // Named-constant documentation guard: keep the value Rowan approved.
    expect(RESUME_TTL_MS).toBe(3 * 60 * 60 * 1000)
  })

  it("persists the resume entry as a {v, e} TTL envelope, not a bare value", () => {
    shims.win.location.pathname = "/admin/users"
    const before = Date.now()
    const hook = buildHook()
    hook.mounted()
    const after = Date.now()

    // The raw stored value must be the TTL envelope so it can age out.
    const raw = shims.storage.__raw.get("suite:route_resume:admin")
    expect(raw).toBeTypeOf("string")
    const parsed = JSON.parse(raw)
    expect(parsed).toHaveProperty("v", "/admin/users")
    expect(parsed).toHaveProperty("e")
    // Expiry sits RESUME_TTL_MS in the future (bounded by the read window).
    expect(parsed.e).toBeGreaterThanOrEqual(before + RESUME_TTL_MS)
    expect(parsed.e).toBeLessThanOrEqual(after + RESUME_TTL_MS)
  })

  it("resumes the last subpage within the TTL window", () => {
    // Fresh return, well inside 3h: the Admin gear resumes /admin/users.
    shims.win.location.pathname = "/admin/users"
    const hook = buildHook()
    hook.mounted()

    // Read-back through the public API sees the live value.
    expect(ClientState.get("route_resume", "admin")).toBe("/admin/users")

    // Navigate away, then click the Admin gear (bare /admin href).
    const anchor = makeAnchor({ moduleId: "admin", href: "/admin" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    expect(evt.propagationStopped).toBe(true)
    expect(historyRedirect).toHaveBeenCalledTimes(1)
    expect(historyRedirect).toHaveBeenCalledWith(
      evt,
      "/admin/users",
      "push",
      null,
      anchor,
    )
  })

  it("ignores a stale (expired-envelope) resume so the gear falls back to module root", () => {
    // Simulate the "fresh deploy / hours later" condition: an already-expired
    // envelope for `admin` was left in localStorage from a prior session.
    // Seed it directly (past `e`) and mount on a non-allowlisted path so the
    // initial _persistCurrentPath() does not overwrite it.
    shims.win.location.pathname = "/unlisted"
    shims.storage.__raw.set(
      "suite:route_resume:admin",
      JSON.stringify({ v: "/admin/users", e: Date.now() - 1 }),
    )

    const hook = buildHook()
    hook.mounted()

    // Clicking the Admin gear must NOT resume — the intercept sees the
    // expired read as missing and lets normal LV navigation to /admin run.
    const anchor = makeAnchor({ moduleId: "admin", href: "/admin" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(false)
    expect(historyRedirect).not.toHaveBeenCalled()

    // ClientState.get expires-on-read and self-cleans, so the stale envelope
    // is gone after the intercept probed it.
    expect(shims.storage.__raw.has("suite:route_resume:admin")).toBe(false)
  })
})

// ── Transient params / sticky anchor (task 019fabe8 stage 5) ──────────
//
// Stage 2 put the inbox deep-link anchor in the URL as `?message=<id>`, on
// purpose: it is shareable and survives a refresh. But `_persistCurrentPath`
// saves `pathname + search`, so without this stage the anchor would ride
// into `route_resume:chat` and STICK — every later Chat-tile click would
// resume to `?message=<id>` and throw the reader back to an old message for
// the full 3h TTL.
//
// The fix strips transient params at PERSIST time (not at restore time), so
// the stored value is already clean and no other reader of
// `route_resume:<mod>` has to know that `message` is transient. Durable
// filter state (`/tasks?sponsor=mine`, task 019f487e Case 5) is untouched.

const ANCHOR_ID = "019fabe8-b05a-726e-9b3c-4ac701b73129"

describe("stripTransientParams", () => {
  it("drops chat's `message` anchor, leaving a bare path (no trailing `?`)", () => {
    expect(stripTransientParams("chat", `/chat/general?message=${ANCHOR_ID}`)).toBe(
      "/chat/general"
    )
  })

  it("keeps every other param on the same visit", () => {
    expect(
      stripTransientParams("chat", `/chat/general?thread=42&message=${ANCHOR_ID}`)
    ).toBe("/chat/general?thread=42")
    expect(
      stripTransientParams("chat", `/chat/general?message=${ANCHOR_ID}&thread=42`)
    ).toBe("/chat/general?thread=42")
  })

  it("leaves a non-chat module's `message` param alone", () => {
    // The strip is keyed by module. A `message` param that means something
    // durable elsewhere must not be silently swallowed by chat's rule.
    expect(stripTransientParams("tasks", "/tasks?message=hello")).toBe(
      "/tasks?message=hello"
    )
    expect(stripTransientParams("inbox", `/inbox?message=${ANCHOR_ID}`)).toBe(
      `/inbox?message=${ANCHOR_ID}`
    )
  })

  it("returns the input untouched when there is nothing to strip", () => {
    // Identity (not just equality) matters: the untouched path must never
    // round-trip through URLSearchParams re-encoding, which would rewrite
    // escapes and break the intercept's byte compare against an href.
    const durable = "/chat/general?filter=a%20b&sort=desc"
    expect(stripTransientParams("chat", durable)).toBe(durable)
    expect(stripTransientParams("chat", "/chat/general")).toBe("/chat/general")
    expect(stripTransientParams("tasks", "/tasks?sponsor=mine")).toBe(
      "/tasks?sponsor=mine"
    )
  })

  it("removes repeated occurrences of the transient param", () => {
    expect(
      stripTransientParams("chat", `/chat/general?message=a&message=${ANCHOR_ID}`)
    ).toBe("/chat/general")
  })

  it("returns empty string for non-string input", () => {
    expect(stripTransientParams("chat", null)).toBe("")
    expect(stripTransientParams("chat", undefined)).toBe("")
    expect(stripTransientParams("chat", 42)).toBe("")
  })
})

describe("TRANSIENT_QUERY_PARAMS", () => {
  it("scopes the transient list to chat's `message` anchor only", () => {
    // Documentation guard. A new transient param joins its module's array
    // here — one place, no second ad-hoc regex. Widening this to `tasks`
    // would silently start eating `?sponsor=mine`.
    expect(TRANSIENT_QUERY_PARAMS.chat).toEqual(["message"])
    expect(TRANSIENT_QUERY_PARAMS.tasks).toBeUndefined()
  })
})

describe("RouteResume transient anchor persistence", () => {
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

  it("persists a `?message=` deep-link visit without the anchor", () => {
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = `?message=${ANCHOR_ID}`
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "chat")).toBe("/chat/general")
  })

  it("keeps other query params on the anchored visit", () => {
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = `?thread=42&message=${ANCHOR_ID}`
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "chat")).toBe("/chat/general?thread=42")
  })

  it("leaves a non-chat module's `message` param in the persisted value", () => {
    shims.win.location.pathname = "/tasks"
    shims.win.location.search = "?sponsor=mine&message=hello"
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "tasks")).toBe(
      "/tasks?sponsor=mine&message=hello"
    )
  })

  it("stores the stripped value through the existing TTL envelope unchanged", () => {
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = `?message=${ANCHOR_ID}`
    const before = Date.now()
    const hook = buildHook()
    hook.mounted()
    const after = Date.now()

    const raw = shims.storage.__raw.get("suite:route_resume:chat")
    const parsed = JSON.parse(raw)
    expect(parsed).toHaveProperty("v", "/chat/general")
    expect(parsed.e).toBeGreaterThanOrEqual(before + RESUME_TTL_MS)
    expect(parsed.e).toBeLessThanOrEqual(after + RESUME_TTL_MS)
  })

  it("does not re-anchor a later Chat-tile click (the sticky-anchor regression)", () => {
    // Arrive from the inbox on a deep link…
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = `?message=${ANCHOR_ID}`
    const hook = buildHook()
    hook.mounted()

    // …then come back to Chat from another module. We resume the space, but
    // NOT the anchor: without the strip this redirect carries
    // `?message=<id>` and slams the reader back to the old message.
    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    expect(historyRedirect).toHaveBeenCalledWith(
      evt,
      "/chat/general",
      "push",
      null,
      anchor,
    )
  })

  it("still resumes normally when no anchor was involved (positive control)", () => {
    // The other direction: stripping must not break plain resume.
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = ""
    const hook = buildHook()
    hook.mounted()

    expect(ClientState.get("route_resume", "chat")).toBe("/chat/general")

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    expect(historyRedirect).toHaveBeenCalledWith(
      evt,
      "/chat/general",
      "push",
      null,
      anchor,
    )
  })

  it("keeps the persisted value clean across a same-module patch off the anchor", () => {
    // ChatLive drops `?message=` from the URL once the anchor is consumed;
    // that later `phx:page-loading-stop` must not resurrect anything.
    shims.win.location.pathname = "/chat/general"
    shims.win.location.search = `?message=${ANCHOR_ID}`
    const hook = buildHook()
    hook.mounted()

    shims.win.location.search = ""
    shims.win.dispatchEvent({ type: "phx:page-loading-stop" })

    expect(ClientState.get("route_resume", "chat")).toBe("/chat/general")
  })

  it("compares path+search together, so an anchored saved value IS a distinct target", () => {
    // Why persist-time stripping is required rather than relying on the
    // intercept to no-op: the saved-vs-href compare at `_maybeInterceptClick`
    // is path+search, not path alone (task 019f487e Case 5 needs that). So a
    // saved `/chat/general?message=<id>` does NOT match a bare
    // `/chat/general` anchor — it redirects and re-anchors. Seeded directly
    // here because after this stage nothing writes such a value any more;
    // legacy entries from before the fix age out with the 3h TTL.
    shims.win.location.pathname = "/unlisted"
    ClientState.set("route_resume", "chat", `/chat/general?message=${ANCHOR_ID}`)

    const hook = buildHook()
    hook.mounted()

    const anchor = makeAnchor({ moduleId: "chat", href: "/chat/general" })
    const evt = makeClickEvent(anchor)
    shims.doc.dispatchClick(evt)

    expect(evt.defaultPrevented).toBe(true)
    expect(historyRedirect).toHaveBeenCalledWith(
      evt,
      `/chat/general?message=${ANCHOR_ID}`,
      "push",
      null,
      anchor,
    )
  })
})
