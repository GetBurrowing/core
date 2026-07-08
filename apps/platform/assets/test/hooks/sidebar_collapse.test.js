import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import SidebarCollapse from "../../js/hooks/sidebar_collapse.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the migrated `SidebarCollapse` hook (task 019f3e9a stage 3).
 *
 * Coverage:
 *   - Stored `collapsed` flag is read from ClientState on mount; when it
 *     differs from the LV's current `data-collapsed` attribute, the
 *     hydrate event is pushed.
 *   - Legacy raw un-namespaced key (string "true"/"false") is migrated
 *     into ClientState as a bool and the raw entry is deleted.
 *   - Server-emitted change event mirrors the incoming bool into
 *     ClientState (not the legacy key).
 *   - The parametrized `data-storage-key` acts as the ClientState sub-key,
 *     so multiple mounts don't collide.
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

function buildHook({ collapsed = false, dataset = {} } = {}) {
  const hook = Object.create(SidebarCollapse)
  hook.pushEventTo = vi.fn()
  const eventHandlers = new Map()
  hook.handleEvent = (name, fn) => {
    eventHandlers.set(name, fn)
  }
  hook.el = {
    dataset,
    getAttribute(name) {
      if (name === "data-collapsed") return collapsed ? "true" : "false"
      return null
    },
  }
  hook._fire = (name, payload) => {
    const fn = eventHandlers.get(name)
    if (fn) fn(payload)
  }
  return hook
}

describe("SidebarCollapse — ClientState migration", () => {
  beforeEach(() => {
    installStorage()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    __resetForTests()
  })

  it("reads from ClientState + pushes hydrate when stored value differs", () => {
    ClientState.set("sidebar", "suite.sidebar.collapsed", true)
    const hook = buildHook({ collapsed: false })
    hook.mounted()

    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "sidebar_hydrate", { collapsed: true })
  })

  it("does not push when stored value matches the current DOM state", () => {
    ClientState.set("sidebar", "suite.sidebar.collapsed", false)
    const hook = buildHook({ collapsed: false })
    hook.mounted()

    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })

  it("migrates the legacy raw string 'true' into a bool + deletes raw entry", () => {
    // Legacy raw entry (byte-identical to what the pre-migration hook wrote).
    storage.setItem("suite.sidebar.collapsed", "true")

    const hook = buildHook({ collapsed: false })
    hook.mounted()

    // Hydrate fires because the migrated bool `true` differs from DOM `false`.
    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "sidebar_hydrate", { collapsed: true })

    // Value now lives in ClientState…
    expect(ClientState.get("sidebar", "suite.sidebar.collapsed")).toBe(true)
    // …and the legacy raw entry is gone.
    expect(storage.getItem("suite.sidebar.collapsed")).toBeNull()
  })

  it("migrates the legacy raw string 'false' correctly (no hydrate needed)", () => {
    storage.setItem("suite.sidebar.collapsed", "false")

    const hook = buildHook({ collapsed: false })
    hook.mounted()

    // No push: migrated `false` matches DOM `false`.
    expect(hook.pushEventTo).not.toHaveBeenCalled()
    expect(ClientState.get("sidebar", "suite.sidebar.collapsed")).toBe(false)
    expect(storage.getItem("suite.sidebar.collapsed")).toBeNull()
  })

  it("mirrors change_event payload into ClientState (not the legacy key)", () => {
    const hook = buildHook({ collapsed: false })
    hook.mounted()

    hook._fire("sidebar_collapsed_changed", { collapsed: true })

    expect(ClientState.get("sidebar", "suite.sidebar.collapsed")).toBe(true)
    expect(storage.getItem("suite.sidebar.collapsed")).toBeNull()
  })

  it("respects `data-storage-key` parametrization for independent panes", () => {
    // Two mounts with different storage-keys don't collide.
    const hookA = buildHook({
      collapsed: false,
      dataset: { storageKey: "meeting.participants.collapsed" },
    })
    const hookB = buildHook({
      collapsed: false,
      dataset: { storageKey: "meeting.chat.collapsed" },
    })
    hookA.mounted()
    hookB.mounted()

    hookA._fire("sidebar_collapsed_changed", { collapsed: true })
    hookB._fire("sidebar_collapsed_changed", { collapsed: false })

    expect(ClientState.get("sidebar", "meeting.participants.collapsed")).toBe(true)
    expect(ClientState.get("sidebar", "meeting.chat.collapsed")).toBe(false)
    // Default shell key is not touched.
    expect(ClientState.get("sidebar", "suite.sidebar.collapsed")).toBeNull()
  })
})
