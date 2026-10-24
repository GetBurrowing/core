import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import LastProject, { ALL_PROJECTS_SENTINEL } from "../../js/hooks/last_project.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * LastProject (task 01a161fd stage 2): the per-device restore of the /tasks
 * project must not override the server's choice.
 *
 *   - `?project=` in the URL: no restore push;
 *   - `data-project-source="pref"` (the server applied the per-user
 *     preference): no restore push;
 *   - neither: the stored device value is still replayed, exactly as before.
 */

const NAMESPACE = "tasks_ui"
const KEY = "last_project_id"
const STORED = "01a16208-0000-7000-8000-000000000001"

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

function buildHook(dataset = {}) {
  const hook = Object.create(LastProject)
  hook.pushEventTo = vi.fn()
  hook.pushEvent = vi.fn()
  hook.handleEvent = vi.fn()
  hook.el = { dataset: { selectedProjectId: ALL_PROJECTS_SENTINEL, ...dataset } }
  return hook
}

function setSearch(search) {
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: { location: { pathname: "/tasks", search } },
  })
}

describe("LastProject restore", () => {
  let storage

  beforeEach(() => {
    storage = makeFakeStorage()
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get() {
        return storage
      },
    })
    __resetForTests()
    ClientState.set(NAMESPACE, KEY, STORED)
    setSearch("")
  })

  afterEach(() => {
    delete globalThis.localStorage
    delete globalThis.window
    __resetForTests()
  })

  it("still replays a stored project with no URL project and no server preference", () => {
    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEventTo).toHaveBeenCalledTimes(1)
    expect(hook.pushEventTo).toHaveBeenCalledWith("#tasks-sidebar", "sidebar_select_project", {
      id: STORED,
    })
  })

  it("skips the restore when the URL carries ?project=", () => {
    setSearch("?sort=oldest&project=all")
    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEventTo).not.toHaveBeenCalled()
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("skips the restore when the server applied a stored preference", () => {
    const hook = buildHook({ projectSource: "pref" })
    hook.mounted()

    expect(hook.pushEventTo).not.toHaveBeenCalled()
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("keeps the device copy in step with the server's choice when it skips", () => {
    const current = "01a16208-0000-7000-8000-000000000002"
    const hook = buildHook({ projectSource: "pref", selectedProjectId: current })
    hook.mounted()

    expect(ClientState.get(NAMESPACE, KEY)).toBe(current)
  })

  // Stage 5: the server pins a bare /tasks to `?project=all` when it remembers
  // nothing, and says so with `data-project-source="default"`.
  it("replays the device copy over the server's default, for the server to pin", () => {
    setSearch("?sort=oldest&project=all")
    const hook = buildHook({ projectSource: "default" })
    hook.mounted()

    expect(hook.pushEventTo).not.toHaveBeenCalled()
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).toHaveBeenCalledWith("tasks_restore_device_project", { id: STORED })
  })

  it("does not patch over the server's default when the device copy is All", () => {
    ClientState.set(NAMESPACE, KEY, ALL_PROJECTS_SENTINEL)
    setSearch("?project=all")
    const hook = buildHook({ projectSource: "default" })
    hook.mounted()

    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })

  it("an explicit ?project= with no source mark is never replayed over", () => {
    setSearch("?project=all")
    const hook = buildHook()
    hook.mounted()

    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })
})
