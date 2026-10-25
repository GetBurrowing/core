import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import ModeToggle, { labelFor, nextMode } from "../../js/hooks/mode_toggle.js"

/**
 * The ModeToggle hook (Burrow redesign 22 stage 1): the desktop sidebar's
 * `#mode-toggle` row. vitest runs in plain node, so this file carries a
 * minimal fake DOM: the label span and the two icons the component renders.
 */

class FakeClassList {
  constructor(names = []) {
    this.set = new Set(names)
  }
  toggle(name, force) {
    const on = force === undefined ? !this.set.has(name) : force
    if (on) this.set.add(name)
    else this.set.delete(name)
    return on
  }
  contains(name) {
    return this.set.has(name)
  }
}

class FakeNode {
  constructor(attrs = {}, classes = []) {
    this.attrs = { ...attrs }
    this.classList = new FakeClassList(classes)
    this.textContent = ""
  }
  getAttribute(name) {
    return name in this.attrs ? this.attrs[name] : null
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }
}

function mount({ resolved = "dark", apply = true } = {}) {
  const label = new FakeNode({ "data-mode-label": "" })
  label.textContent = "Light mode"
  const darkIcon = new FakeNode({ "data-mode-icon": "dark" })
  const lightIcon = new FakeNode({ "data-mode-icon": "light" }, ["hidden"])

  const listeners = {}
  const el = new FakeNode({ id: "mode-toggle" })
  el.querySelector = (sel) => (sel === "[data-mode-label]" ? label : null)
  el.querySelectorAll = (sel) => (sel === "[data-mode-icon]" ? [darkIcon, lightIcon] : [])
  el.addEventListener = (name, fn) => {
    listeners[name] = fn
  }

  let state = { preset: "burrow-sand", mode: resolved, resolved }
  const applied = []
  globalThis.window.burrowTheme = {
    get: () => ({ ...state }),
    apply: apply
      ? (next) => {
          applied.push(next)
          state = { ...next, resolved: next.mode }
          return { ...state }
        }
      : undefined,
  }

  const hook = Object.create(ModeToggle)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  return { hook, el, label, darkIcon, lightIcon, listeners, applied }
}

describe("ModeToggle", () => {
  let windowListeners

  beforeEach(() => {
    windowListeners = {}
    globalThis.window = {
      addEventListener: (name, fn) => {
        windowListeners[name] = fn
      },
      removeEventListener: (name) => {
        delete windowListeners[name]
      },
    }
  })

  afterEach(() => {
    delete globalThis.window
  })

  it("names the mode a click turns on", () => {
    expect(labelFor("dark")).toBe("Light mode")
    expect(labelFor("light")).toBe("Dark mode")
    expect(nextMode("dark")).toBe("light")
    expect(nextMode("light")).toBe("dark")
  })

  it("paints from the page's resolved theme on mount (a system mode resolved light)", () => {
    const { el, label, darkIcon, lightIcon } = mount({ resolved: "light" })
    expect(label.textContent).toBe("Dark mode")
    expect(el.getAttribute("data-resolved")).toBe("light")
    expect(darkIcon.classList.contains("hidden")).toBe(true)
    expect(lightIcon.classList.contains("hidden")).toBe(false)
  })

  it("a click applies the other mode at once, keeps the preset, then stores it", () => {
    const { hook, listeners, label, applied } = mount({ resolved: "dark" })
    const event = { preventDefault: vi.fn() }

    listeners.click(event)

    expect(event.preventDefault).toHaveBeenCalled()
    expect(applied).toEqual([{ preset: "burrow-sand", mode: "light" }])
    expect(label.textContent).toBe("Dark mode")
    expect(hook.pushEvent).toHaveBeenCalledWith("set_theme", { preset: "burrow-sand", mode: "light" })

    listeners.click(event)
    expect(applied[1]).toEqual({ preset: "burrow-sand", mode: "dark" })
    expect(label.textContent).toBe("Light mode")
    expect(hook.pushEvent).toHaveBeenLastCalledWith("set_theme", { preset: "burrow-sand", mode: "dark" })
  })

  it("repaints on burrow:theme and after a patch", () => {
    const { hook, label } = mount({ resolved: "dark" })
    windowListeners["burrow:theme"]({ detail: { preset: "burrow", mode: "light", resolved: "light" } })
    expect(label.textContent).toBe("Dark mode")

    // A server patch reset the label to its first-frame text; updated() repaints.
    label.textContent = "Light mode"
    globalThis.window.burrowTheme.get = () => ({ preset: "burrow", mode: "system", resolved: "light" })
    hook.updated()
    expect(label.textContent).toBe("Dark mode")
  })

  it("removes its window listener on destroy", () => {
    const { hook } = mount()
    expect(windowListeners["burrow:theme"]).toBeTypeOf("function")
    hook.destroyed()
    expect(windowListeners["burrow:theme"]).toBeUndefined()
  })
})
