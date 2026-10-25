import { describe, it, expect, vi, afterEach } from "vitest"
import GameViewDialog, { DESKTOP_QUERY, applyDialogSemantics } from "../js/hooks/game_view_dialog.js"
import hooks from "../js/extension.js"

// Task 01a1557a-efdd stage 3: role="dialog" and aria-modal are the phone
// layout's only. At lg and up the Game view sits beside the usable rail.
function el() {
  const attrs = new Map([
    ["role", "dialog"],
    ["aria-modal", "true"],
  ])
  return {
    attrs,
    setAttribute: (k, v) => attrs.set(k, String(v)),
    removeAttribute: k => attrs.delete(k),
  }
}

function media(matches) {
  const listeners = []
  return {
    matches,
    listeners,
    addEventListener: (type, fn) => listeners.push(fn),
    removeEventListener: (type, fn) => listeners.splice(listeners.indexOf(fn), 1),
    flip(next) {
      this.matches = next
      listeners.forEach(fn => fn())
    },
  }
}

function mount(m) {
  vi.stubGlobal("window", { matchMedia: q => (expect(q).toBe(DESKTOP_QUERY), m) })
  const hook = Object.create(GameViewDialog)
  hook.el = el()
  hook.mounted()
  return hook
}

afterEach(() => vi.unstubAllGlobals())

describe("GameViewDialog", () => {
  it("is registered in Play's hook map under the name the Game view renders", () => {
    expect(hooks.GameViewDialog).toBe(GameViewDialog)
  })

  it("the lg query is Tailwind's lg breakpoint", () => {
    expect(DESKTOP_QUERY).toBe("(min-width: 64rem)")
  })

  it("at lg and up drops role and aria-modal", () => {
    const hook = mount(media(true))
    expect(hook.el.attrs.has("role")).toBe(false)
    expect(hook.el.attrs.has("aria-modal")).toBe(false)
  })

  it("below lg keeps the phone's dialog semantics", () => {
    const hook = mount(media(false))
    expect(hook.el.attrs.get("role")).toBe("dialog")
    expect(hook.el.attrs.get("aria-modal")).toBe("true")
  })

  it("follows a viewport change both ways", () => {
    const m = media(false)
    const hook = mount(m)
    m.flip(true)
    expect(hook.el.attrs.has("role")).toBe(false)
    m.flip(false)
    expect(hook.el.attrs.get("role")).toBe("dialog")
    expect(hook.el.attrs.get("aria-modal")).toBe("true")
  })

  it("updated() strips the attributes LiveView's patch put back at lg", () => {
    const hook = mount(media(true))
    hook.el.setAttribute("role", "dialog")
    hook.el.setAttribute("aria-modal", "true")
    hook.updated()
    expect(hook.el.attrs.has("role")).toBe(false)
    expect(hook.el.attrs.has("aria-modal")).toBe(false)
  })

  it("destroyed() stops listening", () => {
    const m = media(false)
    const hook = mount(m)
    hook.destroyed()
    expect(m.listeners.length).toBe(0)
  })

  it("applyDialogSemantics sets exactly the two attributes", () => {
    const e = el()
    applyDialogSemantics(e, true)
    expect([...e.attrs.keys()]).toEqual([])
    applyDialogSemantics(e, false)
    expect(Object.fromEntries(e.attrs)).toEqual({ role: "dialog", "aria-modal": "true" })
  })
})
