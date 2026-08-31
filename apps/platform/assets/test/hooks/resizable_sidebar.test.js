import { describe, it, expect, beforeEach, afterEach } from "vitest"
import ResizableSidebar from "../../js/hooks/resizable_sidebar.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * Tests for the `ResizableSidebar` hook (task 019f3e9a stage 3 migration;
 * width-on-root-variable contract added by task 01a05873).
 *
 * The 01a05873 contract, pinned here:
 *   - The sidebar's width is carried by the `--suite-sidebar-width` custom
 *     property on `document.documentElement`, NOT by an inline style on
 *     the `<aside>`. Reason: morphdom strips inline styles mid-patch, and
 *     between that strip and `updated()`'s re-apply the aside rendered at
 *     its intrinsic width, squeezing the chat column during every LV
 *     patch and poisoning ScrollToBottom's beforeUpdate distance capture
 *     (the "desktop chat doesn't autoscroll" defect). A root-level
 *     variable cannot be stripped by a patch of the aside — there is no
 *     inline style left to strip.
 *   - `el.style.width` is NEVER written — the regression tests below
 *     assert it stays empty through mount, drag, and update. If a future
 *     edit reintroduces the inline style, they go red for the exact
 *     reason the transient returns.
 *
 * ClientState migration coverage (unchanged by 01a05873) is preserved:
 *   - Width persists to and reads from `ClientState.get("sidebar", "width")`.
 *   - Legacy raw key `"suite:sidebar_width:v2"` is read once (with numeric
 *     parse), migrated into ClientState, and deleted.
 *   - When no value exists in either store, the DEFAULT_WIDTH (224) applies.
 *   - The width value written by a drag-resize round-trip lands in
 *     ClientState (not the legacy key).
 */

const WIDTH_VAR = "--suite-sidebar-width"

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
let rootStyle

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

// The width now lives on <html>, so the test owns a fake document whose
// documentElement records setProperty calls. `calls` keeps the raw call
// log so a test can prove NO call happened, and `props` models the
// resolved custom-property map.
function installFakeDocument() {
  const props = new Map()
  const calls = []
  rootStyle = {
    props,
    calls,
    setProperty(name, value) {
      calls.push([name, value])
      props.set(name, value)
    },
    getPropertyValue(name) {
      return props.get(name) ?? ""
    },
    removeProperty(name) {
      calls.push([name, undefined])
      props.delete(name)
    },
  }
  const bodyClasses = new Set()
  globalThis.document = {
    documentElement: { style: rootStyle },
    body: {
      classList: {
        add(name) {
          bodyClasses.add(name)
        },
        remove(name) {
          bodyClasses.delete(name)
        },
        contains: (name) => bodyClasses.has(name),
      },
    },
    addEventListener() {},
    removeEventListener() {},
  }
}

function uninstallFakeDocument() {
  delete globalThis.document
}

function buildHook({ withHandle = false } = {}) {
  const styleWrites = []
  const hook = Object.create(ResizableSidebar)
  hook.el = {
    // The inline style record — the regression tests assert nothing is
    // ever written here. width records writes so a reintroduced inline
    // write is visible.
    style: {
      _writes: styleWrites,
      get width() {
        return this._w ?? ""
      },
      set width(v) {
        this._w = v
        styleWrites.push(["width", v])
      },
    },
    querySelector() {
      return withHandle
        ? { addEventListener() {}, removeEventListener() {} }
        : null
    },
  }
  return hook
}

describe("ResizableSidebar — width on the root CSS variable (01a05873)", () => {
  beforeEach(() => {
    installStorage()
    installFakeDocument()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    uninstallFakeDocument()
    __resetForTests()
  })

  it("writes --suite-sidebar-width on mount, never an inline style", () => {
    ClientState.set("sidebar", "width", 300)
    const hook = buildHook()
    hook.mounted()

    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("300px")
    expect(hook.el.style._writes).toEqual([])
  })

  it("falls back to the DEFAULT_WIDTH (224) when nothing is stored", () => {
    const hook = buildHook()
    hook.mounted()

    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("224px")
  })

  it("morphdom stripping inline styles is a no-op — the width cannot be stripped", () => {
    // THE 01a05873 regression. Under the inline-style contract, morphdom
    // resetting the aside's style mid-patch opened a window in which the
    // sidebar rendered at its intrinsic width and the chat column
    // rewrapped narrower. Under the variable contract there is no inline
    // width to strip, so simulating morphdom's style reset must leave the
    // width untouched.
    ClientState.set("sidebar", "width", 288)
    const hook = buildHook()
    hook.mounted()

    // Simulate exactly what morphdom does to inline styles: wipe them.
    hook.el.style.width = ""
    // The wipe itself is recorded by the fake; reset the record so the
    // assertion below proves the HOOK writes nothing back.
    hook.el.style._writes.length = 0
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("288px")

    // updated() re-applies from the stored preference — same value, and
    // still no inline style is written.
    hook.updated()
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("288px")
    expect(hook.el.style._writes).toEqual([])
  })

  it("drag updates the variable live and persists the final width", () => {
    const hook = buildHook({ withHandle: true })
    hook.mounted()

    // The listeners registered on document aren't owned by the fake, so
    // drive the hook's handlers directly — same code paths the real mouse
    // events reach.
    hook._onMouseDown({ preventDefault() {}, clientX: 500 })
    hook._onMouseMove({ clientX: 560 })
    // default 224 + 60px of drag
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("284px")
    expect(hook.el.style._writes).toEqual([])

    // Clamp floor: 160px.
    hook._onMouseMove({ clientX: -10000 })
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("160px")
    // Clamp ceiling: 480px.
    hook._onMouseMove({ clientX: 10000 })
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("480px")

    hook._onMouseUp()
    expect(ClientState.get("sidebar", "width")).toBe(480)
  })

  it("migrates the legacy raw key into ClientState + deletes it", () => {
    storage.setItem("suite:sidebar_width:v2", "260")

    const hook = buildHook()
    hook.mounted()

    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("260px")
    expect(ClientState.get("sidebar", "width")).toBe(260)
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })

  it("subsequent reads skip the legacy fallback path", () => {
    // Priming ClientState directly. Migration path should never be visited.
    ClientState.set("sidebar", "width", 320)

    const hook = buildHook()
    hook.mounted()

    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("320px")
    // Legacy key must not spontaneously appear from a ClientState-only read.
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })

  it("ignores an unparseable legacy value (falls back to default)", () => {
    storage.setItem("suite:sidebar_width:v2", "not-a-number")

    const hook = buildHook()
    hook.mounted()

    // Numeric parse failed → default width applies, and the legacy garbage
    // gets cleaned out so we never retry on next mount.
    expect(rootStyle.getPropertyValue(WIDTH_VAR)).toBe("224px")
    expect(storage.getItem("suite:sidebar_width:v2")).toBeNull()
  })
})
