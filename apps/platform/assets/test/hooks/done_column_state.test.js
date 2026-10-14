import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import DoneColumnState, { NAMESPACE, KEY } from "../../js/hooks/done_column_state.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * DoneColumnState (task 01a13884 stage 3): the per-viewer memory of the
 * /tasks Done column's expansion, kept through Suite.ClientState.
 *
 *   - read + replay: a stored `true` is pushed to `#tasks-board` as
 *     `board_toggle_done {expanded: true}` on mount, once;
 *   - no replay when nothing is stored (cleared storage = server default),
 *     when `false` is stored, or when the render is already expanded;
 *   - write: every server `done_column_changed` lands in ClientState, so a
 *     Show and a Hide are both remembered across a remount.
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
  }
}

let storage

function buildHook({ expanded = false } = {}) {
  const hook = Object.create(DoneColumnState)
  hook.pushEventTo = vi.fn()
  hook.pushEvent = vi.fn()
  const handlers = new Map()
  hook.handleEvent = (name, fn) => handlers.set(name, fn)
  hook.el = { dataset: { expanded: expanded ? "true" : "false" } }
  hook._fire = (name, payload) => handlers.get(name)(payload)
  return hook
}

describe("DoneColumnState", () => {
  beforeEach(() => {
    storage = makeFakeStorage()
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get() {
        return storage
      },
    })
    __resetForTests()
  })

  afterEach(() => {
    delete globalThis.localStorage
    __resetForTests()
  })

  it("replays a stored expansion to the board component exactly once", () => {
    ClientState.set(NAMESPACE, KEY, true)
    const hook = buildHook({ expanded: false })
    hook.mounted()

    expect(hook.pushEventTo).toHaveBeenCalledTimes(1)
    expect(hook.pushEventTo).toHaveBeenCalledWith("#tasks-board", "board_toggle_done", {
      expanded: true,
    })
    // A hook's pushEvent ignores phx-target and would land on the LiveView.
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("pushes nothing when storage is empty (the collapsed default stands)", () => {
    const hook = buildHook({ expanded: false })
    hook.mounted()
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })

  it("pushes nothing when a collapse is stored or the render is already expanded", () => {
    ClientState.set(NAMESPACE, KEY, false)
    buildHook({ expanded: false }).mounted()

    ClientState.set(NAMESPACE, KEY, true)
    const already = buildHook({ expanded: true })
    already.mounted()

    expect(already.pushEventTo).not.toHaveBeenCalled()
  })

  it("writes every server change through ClientState, never a raw key", () => {
    const hook = buildHook()
    hook.mounted()

    hook._fire("done_column_changed", { expanded: true })
    expect(ClientState.get(NAMESPACE, KEY)).toBe(true)
    // The namespaced ClientState key is the only entry written.
    expect(storage.length).toBe(1)
    expect(storage.key(0)).not.toBe(KEY)

    hook._fire("done_column_changed", { expanded: false })
    expect(ClientState.get(NAMESPACE, KEY)).toBe(false)
  })

  it("a stored Show survives a remount and replays; clearing storage drops it", () => {
    const first = buildHook()
    first.mounted()
    first._fire("done_column_changed", { expanded: true })

    const second = buildHook({ expanded: false })
    second.mounted()
    expect(second.pushEventTo).toHaveBeenCalledWith("#tasks-board", "board_toggle_done", {
      expanded: true,
    })

    storage.clear()
    const third = buildHook({ expanded: false })
    third.mounted()
    expect(third.pushEventTo).not.toHaveBeenCalled()
  })
})
