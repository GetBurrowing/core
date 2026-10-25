import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import DetailsPanelState, {
  NAMESPACE,
  RESTORE_QUERY,
  keyFor,
  overlayOpen,
  nextPane,
} from "../../js/hooks/details_panel_state.js"
import ClientState, { __resetForTests } from "../../js/client_state.js"

/**
 * DetailsPanelState (Burrow redesign 22 stage 3): the desktop details
 * panel's client state. vitest runs in plain node, so the DOM is a fake.
 *
 *   - write: `details:changed {open}` lands in ClientState per viewer;
 *   - restore: a stored `true` pushes `details_restore` on mount, only at
 *     >= 1280px (the owner's rule: never restored or auto-opened at
 *     1024-1279px) and only while the server has it shut;
 *   - Escape closes only when nothing (sheet, modal, popover) is open above;
 *   - F6 / Shift+F6 cycle the shown panes.
 */

function makeFakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key: (i) => Array.from(store.keys())[i] ?? null,
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    clear: () => store.clear(),
  }
}

// A fake element: `shown` decides getClientRects, attrs are attributes.
function el({ id = null, shown = true, attrs = {}, focusable = null } = {}) {
  const node = {
    id,
    attrs: { ...attrs },
    getAttribute: (n) => (n in node.attrs ? node.attrs[n] : null),
    hasAttribute: (n) => n in node.attrs,
    setAttribute: (n, v) => (node.attrs[n] = v),
    getClientRects: () => (shown ? [{}] : []),
    matches: (sel) => sel === "[popover]" && "popover" in node.attrs,
    contains: (other) => other === node || other === focusable,
    querySelector: () => focusable,
    focus: vi.fn(),
  }
  return node
}

function fakeDoc({ panes = {}, overlays = [] } = {}) {
  const listeners = {}
  const doc = {
    activeElement: null,
    querySelector: (sel) => panes[sel] || null,
    querySelectorAll: () => overlays,
    addEventListener: (name, fn) => (listeners[name] = fn),
    removeEventListener: (name) => delete listeners[name],
  }
  return { doc, listeners }
}

let storage
let width

function mount({ doc, open = false, userId = "u-1" } = {}) {
  const hook = Object.create(DetailsPanelState)
  const handlers = new Map()
  hook.handleEvent = (name, fn) => handlers.set(name, fn)
  hook.pushEvent = vi.fn()
  hook.el = { dataset: { userId, open: open ? "true" : "false" }, ownerDocument: doc }
  hook.mounted()
  hook._fire = (name, payload) => handlers.get(name)(payload)
  return hook
}

function key(name, extra = {}) {
  const event = { key: name, shiftKey: false, defaultPrevented: false, target: null, ...extra }
  event.preventDefault = vi.fn(() => (event.defaultPrevented = true))
  return event
}

beforeEach(() => {
  storage = makeFakeStorage()
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    get: () => storage,
  })
  __resetForTests()
  width = 1280
  globalThis.window = {
    matchMedia: (q) => {
      const min = Number((q.match(/min-width:\s*(\d+)px/) || [])[1] || 0)
      return { matches: width >= min }
    },
  }
})

afterEach(() => {
  delete globalThis.window
  delete globalThis.localStorage
})

describe("DetailsPanelState: remember and restore", () => {
  it("writes the server's open/close per viewer", () => {
    const { doc } = fakeDoc()
    const hook = mount({ doc, userId: "u-7" })

    hook._fire("details:changed", { open: true })
    expect(ClientState.get(NAMESPACE, keyFor("u-7"))).toBe(true)

    hook._fire("details:changed", { open: false })
    expect(ClientState.get(NAMESPACE, keyFor("u-7"))).toBe(false)
    // Another viewer's key is untouched.
    expect(ClientState.get(NAMESPACE, keyFor("u-8"), null)).toBe(null)
  })

  it("restores a remembered open at 1280px", () => {
    ClientState.set(NAMESPACE, keyFor("u-1"), true)
    width = 1280
    const { doc } = fakeDoc()
    const hook = mount({ doc })

    expect(RESTORE_QUERY).toBe("(min-width: 1280px)")
    expect(hook.pushEvent).toHaveBeenCalledWith("details_restore", {})
  })

  it("never restores between 1024 and 1279px (the main pane would be ~304px)", () => {
    ClientState.set(NAMESPACE, keyFor("u-1"), true)

    for (const w of [1024, 1100, 1279]) {
      width = w
      const { doc } = fakeDoc()
      const hook = mount({ doc })
      expect(hook.pushEvent).not.toHaveBeenCalled()
    }
  })

  it("does not restore when nothing or false is stored, or when already open", () => {
    const { doc } = fakeDoc()
    expect(mount({ doc }).pushEvent).not.toHaveBeenCalled()

    ClientState.set(NAMESPACE, keyFor("u-1"), false)
    expect(mount({ doc }).pushEvent).not.toHaveBeenCalled()

    ClientState.set(NAMESPACE, keyFor("u-1"), true)
    expect(mount({ doc, open: true }).pushEvent).not.toHaveBeenCalled()
  })
})

describe("DetailsPanelState: Escape", () => {
  it("closes an open panel when nothing is open above it", () => {
    const panel = el({ id: "details-panel" })
    // A closed sheet still renders aria-modal="true"; data-open="false" rules it out.
    const closedSheet = el({ attrs: { "aria-modal": "true", "data-open": "false" } })
    const { doc, listeners } = fakeDoc({ panes: { "#details-panel": panel }, overlays: [closedSheet] })
    const hook = mount({ doc })

    listeners.keydown(key("Escape"))
    expect(hook.pushEvent).toHaveBeenCalledWith("details_close", {})
  })

  it("leaves the panel alone while a modal (the settings dialog) is open", () => {
    const panel = el({ id: "details-panel" })
    const modal = el({ attrs: { role: "dialog", "aria-modal": "true" }, shown: true })
    const { doc, listeners } = fakeDoc({ panes: { "#details-panel": panel }, overlays: [modal] })
    const hook = mount({ doc })

    listeners.keydown(key("Escape"))
    expect(hook.pushEvent).not.toHaveBeenCalledWith("details_close", {})
  })

  it("leaves it alone while a sheet or a popover is open", () => {
    const panel = el({ id: "details-panel" })
    const sheet = el({ attrs: { "aria-modal": "true", "data-open": "true" } })
    const popover = el({ attrs: { role: "dialog" }, shown: true })

    for (const overlay of [sheet, popover]) {
      const { doc, listeners } = fakeDoc({ panes: { "#details-panel": panel }, overlays: [overlay] })
      const hook = mount({ doc })
      listeners.keydown(key("Escape"))
      expect(hook.pushEvent).not.toHaveBeenCalled()
    }
  })

  it("does nothing when the panel is closed, or the key was typed into a field", () => {
    const { doc, listeners } = fakeDoc()
    const hook = mount({ doc })
    listeners.keydown(key("Escape"))
    expect(hook.pushEvent).not.toHaveBeenCalled()

    const panel = el({ id: "details-panel" })
    const open = fakeDoc({ panes: { "#details-panel": panel } })
    const hook2 = mount({ doc: open.doc })
    open.listeners.keydown(key("Escape", { target: { tagName: "TEXTAREA" } }))
    expect(hook2.pushEvent).not.toHaveBeenCalled()
  })

  it("overlayOpen ignores painted-nothing dialogs", () => {
    const hidden = el({ attrs: { role: "dialog" }, shown: false })
    expect(overlayOpen({ querySelectorAll: () => [hidden] })).toBe(false)
  })
})

describe("DetailsPanelState: F6", () => {
  it("cycles sidebar -> list -> composer -> panel, skipping hidden panes", () => {
    const sidebar = el({ id: "sidebar" })
    const list = el({ id: "chat-list", shown: false })
    const composer = el({ id: "compose-form" })
    const panel = el({ id: "details-panel" })
    const panes = {
      "#sidebar": sidebar,
      "#chat-list": list,
      "#compose-form": composer,
      "#details-panel": panel,
    }
    const { doc, listeners } = fakeDoc({ panes })
    mount({ doc })

    doc.activeElement = sidebar
    const e1 = key("F6")
    listeners.keydown(e1)
    expect(e1.preventDefault).toHaveBeenCalled()
    expect(composer.focus).toHaveBeenCalled()

    doc.activeElement = composer
    listeners.keydown(key("F6"))
    expect(panel.focus).toHaveBeenCalled()

    doc.activeElement = panel
    listeners.keydown(key("F6", { shiftKey: true }))
    expect(composer.focus).toHaveBeenCalledTimes(2)
    expect(list.focus).not.toHaveBeenCalled()
  })

  it("nextPane wraps and starts at the first pane from outside", () => {
    const a = el()
    const b = el()
    expect(nextPane([a, b], null, false)).toBe(a)
    expect(nextPane([a, b], b, false)).toBe(a)
    expect(nextPane([a, b], a, true)).toBe(b)
    expect(nextPane([], a, false)).toBe(null)
  })
})
