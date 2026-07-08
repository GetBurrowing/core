import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import TasksStatusFilter from "../../js/hooks/tasks_status_filter.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the migrated `TasksStatusFilter` hook (task 019f3e9a stage 3).
 *
 * Coverage:
 *   - Persisted status is read from `ClientState.get("tasks_ui",
 *     "status_filter")` on mount and pushed to LV when it differs from the
 *     default.
 *   - Legacy un-namespaced key `"tasks-active-status-filter"` is read once,
 *     migrated into ClientState, and deleted from localStorage.
 *   - A click on a `filter_by_status` button writes the new value into
 *     ClientState (not the legacy key).
 *
 * Vitest default env is node; install a minimal in-memory `localStorage`
 * so the migration path (which uses raw `localStorage.*`) is exercisable.
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
  const hook = Object.create(TasksStatusFilter)
  hook.pushEvent = vi.fn()
  const listeners = []
  hook.el = {
    addEventListener(name, fn) {
      listeners.push({ name, fn })
    },
    removeEventListener(name, fn) {
      const idx = listeners.findIndex((l) => l.name === name && l.fn === fn)
      if (idx >= 0) listeners.splice(idx, 1)
    },
    dispatchClick(target) {
      for (const l of listeners) {
        if (l.name === "click") l.fn({ target })
      }
    },
    _listeners: listeners,
  }
  return hook
}

// Fake click target with a `.closest` that returns a button-like element when
// the selector matches `button[phx-click='filter_by_status']`.
function makeButtonTarget(status) {
  const btn = {
    getAttribute(name) {
      return name === "phx-value-status" ? status : null
    },
  }
  return {
    closest(sel) {
      return sel === "button[phx-click='filter_by_status']" ? btn : null
    },
  }
}

describe("TasksStatusFilter — ClientState migration", () => {
  beforeEach(() => {
    installStorage()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    __resetForTests()
  })

  it("reads the persisted status from ClientState on mount and pushes to LV", () => {
    ClientState.set("tasks_ui", "status_filter", "done")
    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEvent).toHaveBeenCalledWith("filter_by_status", { status: "done" })
  })

  it("does not push when the stored status equals the default", () => {
    ClientState.set("tasks_ui", "status_filter", "in_progress")
    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("migrates the legacy un-namespaced key on first read + deletes raw entry", () => {
    // Legacy state: raw string under the un-namespaced key.
    storage.setItem("tasks-active-status-filter", "blocked")

    const hook = buildHook()
    hook.mounted()

    // Push happened using the migrated value.
    expect(hook.pushEvent).toHaveBeenCalledWith("filter_by_status", { status: "blocked" })

    // The value now lives in ClientState under the new namespace…
    expect(ClientState.get("tasks_ui", "status_filter")).toBe("blocked")

    // …and the legacy raw entry has been deleted.
    expect(storage.getItem("tasks-active-status-filter")).toBeNull()
  })

  it("subsequent reads use ClientState only (no legacy fallback re-check)", () => {
    // Prime ClientState directly; leave the legacy key clean.
    ClientState.set("tasks_ui", "status_filter", "review")

    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEvent).toHaveBeenCalledWith("filter_by_status", { status: "review" })
    expect(storage.getItem("tasks-active-status-filter")).toBeNull()
  })

  it("writes clicked status into ClientState — legacy key stays untouched", () => {
    const hook = buildHook()
    hook.mounted()

    hook.el.dispatchClick(makeButtonTarget("blocked"))

    expect(ClientState.get("tasks_ui", "status_filter")).toBe("blocked")
    expect(storage.getItem("tasks-active-status-filter")).toBeNull()
  })

  it("returns null when neither ClientState nor legacy has a value", () => {
    const hook = buildHook()
    hook.mounted()

    // No push — nothing stored anywhere.
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })
})
