import { describe, it, expect, beforeEach, afterEach } from "vitest"
import RowContextMenu, { rowSpaceId, DESKTOP_QUERY } from "../../js/hooks/row_context_menu.js"

/**
 * RowContextMenu (Burrow redesign 22 stage 2): right-click a Chat list row
 * at lg pushes `open_row_actions` with the row's space id. vitest runs in
 * plain node, so the DOM here is a minimal fake.
 */

function row(spaceId) {
  const el = {
    getAttribute: (name) => (name === "data-long-press-space-id" ? spaceId : null),
  }
  el.closest = (sel) => (sel === "[data-long-press-space-id]" && spaceId ? el : null)
  return el
}

function child(parentRow) {
  return { closest: (sel) => parentRow.closest(sel) }
}

function mount() {
  const listeners = {}
  const pushed = []
  const hook = Object.create(RowContextMenu)
  hook.el = {
    getAttribute: (name) => (name === "data-context-event" ? "open_row_actions" : null),
    addEventListener: (name, fn) => (listeners[name] = fn),
    removeEventListener: (name) => delete listeners[name],
  }
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  hook.mounted()
  return { hook, listeners, pushed }
}

function contextmenu(target) {
  const event = { target, defaultPrevented: false }
  event.preventDefault = () => (event.defaultPrevented = true)
  return event
}

let desktop = true

beforeEach(() => {
  desktop = true
  globalThis.window = {
    matchMedia: (q) => ({ matches: q === DESKTOP_QUERY && desktop }),
  }
})

afterEach(() => {
  delete globalThis.window
})

describe("RowContextMenu", () => {
  it("pushes open_row_actions with the row's space id at lg and blocks the browser menu", () => {
    const { listeners, pushed } = mount()
    const event = contextmenu(child(row("space-1")))

    listeners.contextmenu(event)

    expect(pushed).toEqual([["open_row_actions", { space_id: "space-1" }]])
    expect(event.defaultPrevented).toBe(true)
  })

  it("leaves the event alone below lg (the phone long-press owns the row there)", () => {
    desktop = false
    const { listeners, pushed } = mount()
    const event = contextmenu(row("space-1"))

    listeners.contextmenu(event)

    expect(pushed).toEqual([])
    expect(event.defaultPrevented).toBe(false)
  })

  it("does nothing off a row, or on a row that offers no menu", () => {
    const { listeners, pushed } = mount()
    const off = contextmenu({ closest: () => null })
    const bare = contextmenu(row(null))

    listeners.contextmenu(off)
    listeners.contextmenu(bare)

    expect(pushed).toEqual([])
    expect(off.defaultPrevented).toBe(false)
    expect(bare.defaultPrevented).toBe(false)
  })

  it("removes its listener when destroyed", () => {
    const { hook, listeners } = mount()
    hook.destroyed()
    expect(listeners.contextmenu).toBeUndefined()
  })

  it("rowSpaceId reads the nearest row's space id", () => {
    expect(rowSpaceId(child(row("abc")))).toBe("abc")
    expect(rowSpaceId(null)).toBe(null)
  })
})
