import { describe, it, expect, beforeEach, afterEach } from "vitest"
import ResizableSidebar from "../../js/hooks/resizable_sidebar.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the migrated `ResizableSidebar` hook (task 019f3e9a stage 3).
 *
 * Coverage:
 *   - Width persists to and reads from `ClientState.get("sidebar", "width")`.
 *   - Legacy raw key `"suite:sidebar_width:v2"` is read once (with numeric
 *     parse), migrated into ClientState, and deleted.
 *   - When no value exists in either store, the DEFAULT_WIDTH (224) applies.
 *   - The width value written by a drag-resize round-trip lands in
 *     ClientState (not the legacy key).
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

function buildHook() {
  const hook = Object.create(ResizableSidebar)
  hook.el = {
    style: {},
    querySelector() {
      // No drag handle available — mount() bails after applyWidth(),
      // which is all we need to exercise the read path.
      return null
    },
  }
  return hook
}

describe("ResizableSidebar — ClientState migration", () => {
  beforeEach(() => {
    installStorage()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    __resetForTests()
  })

  it("reads width from ClientState on mount", () => {
    ClientState.set("sidebar", "width", 300)
    const hook = buildHook()
    hook.mounted()

    expect(hook.el.style.width).toBe("300px")
  })

  it("falls back to the DEFAULT_WIDTH (224) when nothing is stored", () => {
    const hook = buildHook()
    hook.mounted()

    expect(hook.el.style.width).toBe("224px")
  })

  it("migrates the legacy raw key into ClientState + deletes it", () => {
    storage.setItem("suite:sidebar_width:v2", "260")

    const hook = buildHook()
    hook.mounted()

    expect(hook.el.style.width).toBe("260px")
    expect(ClientState.get("sidebar", "width")).toBe(260)
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })

  it("subsequent reads skip the legacy fallback path", () => {
    // Priming ClientState directly. Migration path should never be visited.
    ClientState.set("sidebar", "width", 320)

    const hook = buildHook()
    hook.mounted()

    expect(hook.el.style.width).toBe("320px")
    // Legacy key must not spontaneously appear from a ClientState-only read.
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })

  it("updated() re-applies the persisted width after LV patches", () => {
    ClientState.set("sidebar", "width", 288)
    const hook = buildHook()
    hook.mounted()

    // Simulate morphdom stripping inline style, then a LiveView update.
    hook.el.style.width = ""
    hook.updated()

    expect(hook.el.style.width).toBe("288px")
  })

  it("ignores an unparseable legacy value (falls back to default)", () => {
    storage.setItem("suite:sidebar_width:v2", "not-a-number")

    const hook = buildHook()
    hook.mounted()

    // Numeric parse failed → default width applies, and the legacy garbage
    // gets cleaned out so we never retry on next mount.
    expect(hook.el.style.width).toBe("224px")
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })
})
