import { describe, it, expect, beforeEach, afterEach } from "vitest"
import ThemePicker from "../../js/hooks/theme_picker.js"

/**
 * The ThemePicker hook (task 01a1557a stage 4). vitest runs in plain node,
 * so this file carries a minimal fake DOM: just the calls the hook makes.
 * The markup mirrors `PlatformWeb.Components.ThemePicker.picker_body/1`.
 */

const PRESETS = ["burrow", "burrow-midnight", "burrow-sand", "burrow-forest", "high-contrast"]
const MODES = ["light", "dark", "system"]

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

class FakeEl {
  constructor(attrs = {}, children = [], classes = []) {
    this.attrs = { ...attrs }
    this.children = children
    this.parent = null
    this.classList = new FakeClassList(classes)
    this.listeners = {}
    for (const child of children) child.parent = this
  }

  get dataset() {
    const out = {}
    for (const [k, v] of Object.entries(this.attrs)) {
      if (k.startsWith("data-")) {
        out[k.slice(5).replace(/-([a-z])/g, (_m, c) => c.toUpperCase())] = v
      }
    }
    return out
  }

  getAttribute(name) {
    return name in this.attrs ? this.attrs[name] : null
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }

  matches(selector) {
    // Supports [attr] and [attr="value"], one or more in sequence.
    const parts = selector.match(/\[[^\]]+\]/g) || []
    if (parts.join("") !== selector) throw new Error(`unsupported selector ${selector}`)
    return parts.every((part) => {
      const m = part.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/)
      if (!m) throw new Error(`unsupported selector ${part}`)
      const [, name, value] = m
      return value === undefined ? name in this.attrs : this.attrs[name] === value
    })
  }

  descendants() {
    return this.children.flatMap((child) => [child, ...child.descendants()])
  }
  querySelectorAll(selector) {
    return this.descendants().filter((el) => el.matches(selector))
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null
  }
  closest(selector) {
    for (let el = this; el; el = el.parent) if (el.matches(selector)) return el
    return null
  }
  contains(other) {
    for (let el = other; el; el = el.parent) if (el === this) return true
    return false
  }

  addEventListener(type, fn) {
    ;(this.listeners[type] ||= []).push(fn)
  }
  dispatch(type, event = {}) {
    const ev = { type, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, ...event }
    for (let el = this; el; el = el.parent) {
      for (const fn of el.listeners[type] || []) fn(ev)
    }
    return ev
  }
  focus() {
    globalThis.document.activeElement = this
  }
}

const build = ({ preset, mode, resolved }) => {
  const modeButtons = MODES.map(
    (m) => new FakeEl({ "data-theme-option": "mode", "data-value": m, role: "radio" })
  )
  const rows = PRESETS.map(
    (p) =>
      new FakeEl({ "data-theme-option": "preset", "data-value": p, role: "radio" }, [
        new FakeEl({ "data-theme-chip": "", "data-preset": p, "data-theme": resolved }),
        new FakeEl({ "data-theme-check": "" }, [], ["hero-check", "invisible"]),
      ])
  )
  const root = new FakeEl({ "phx-hook": "ThemePicker" }, [
    new FakeEl({ "data-theme-group": "mode", role: "radiogroup" }, modeButtons),
    new FakeEl({ "data-theme-group": "preset", role: "radiogroup" }, rows),
  ])
  return { root, modeButtons, rows, initial: { preset, mode, resolved } }
}

let calls
let state
let osDark
let windowListeners

const resolve = (mode) => (mode === "system" ? (osDark ? "dark" : "light") : mode)

const snapshot = () => ({ ...state, resolved: resolve(state.mode) })

const fireTheme = () => {
  for (const fn of windowListeners["burrow:theme"] || []) fn({ detail: snapshot() })
}

beforeEach(() => {
  calls = []
  osDark = true
  windowListeners = {}
  state = { preset: "burrow", mode: "dark" }

  globalThis.document = {
    activeElement: null,
    documentElement: new FakeEl({ "data-theme": "dark" }),
  }

  globalThis.window = {
    addEventListener(type, fn) {
      ;(windowListeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      windowListeners[type] = (windowListeners[type] || []).filter((f) => f !== fn)
    },
    burrowTheme: {
      get: () => snapshot(),
      apply(pref) {
        calls.push(["apply", { ...pref }])
        state = {
          preset: PRESETS.includes(pref.preset) ? pref.preset : state.preset,
          mode: MODES.includes(pref.mode) ? pref.mode : state.mode,
        }
        fireTheme()
        return snapshot()
      },
    },
  }
})

afterEach(() => {
  delete globalThis.window
  delete globalThis.document
})

const mount = () => {
  const dom = build({ ...snapshot() })
  const hook = Object.create(ThemePicker)
  hook.el = dom.root
  hook.pushEvent = (event, payload) => calls.push(["push", event, { ...payload }])
  hook.mounted()
  return { ...dom, hook }
}

const checked = (els) => els.filter((el) => el.getAttribute("aria-checked") === "true")
const value = (el) => el.getAttribute("data-value")
const visibleChecks = (rows) =>
  rows.filter((row) => !row.querySelector("[data-theme-check]").classList.contains("invisible"))
const chipThemes = (rows) => rows.map((row) => row.querySelector("[data-theme-chip]").getAttribute("data-theme"))

describe("ThemePicker: click", () => {
  it("applies through window.burrowTheme first, then pushes set_theme", () => {
    const { rows } = mount()
    rows[2].dispatch("click")

    expect(calls).toEqual([
      ["apply", { preset: "burrow-sand", mode: "dark" }],
      ["push", "set_theme", { preset: "burrow-sand", mode: "dark" }],
    ])
  })

  it("a mode click keeps the preset and pushes the pair", () => {
    state = { preset: "high-contrast", mode: "dark" }
    const { modeButtons } = mount()
    modeButtons[0].dispatch("click")

    expect(calls).toEqual([
      ["apply", { preset: "high-contrast", mode: "light" }],
      ["push", "set_theme", { preset: "high-contrast", mode: "light" }],
    ])
  })

  it("a click on the chip inside a row selects that row", () => {
    const { rows } = mount()
    rows[4].querySelector("[data-theme-chip]").dispatch("click")
    expect(calls.at(-1)).toEqual(["push", "set_theme", { preset: "high-contrast", mode: "dark" }])
  })
})

describe("ThemePicker: keyboard", () => {
  it("ArrowDown moves focus to the next row and wraps; nothing is applied", () => {
    const { rows } = mount()
    rows[0].focus()

    rows[0].dispatch("keydown", { key: "ArrowDown" })
    expect(document.activeElement).toBe(rows[1])

    rows[4].focus()
    rows[4].dispatch("keydown", { key: "ArrowDown" })
    expect(document.activeElement).toBe(rows[0])

    expect(calls).toEqual([])
  })

  it("ArrowUp moves focus to the previous row and wraps", () => {
    const { rows } = mount()
    rows[2].dispatch("keydown", { key: "ArrowUp" })
    expect(document.activeElement).toBe(rows[1])

    rows[0].dispatch("keydown", { key: "ArrowUp" })
    expect(document.activeElement).toBe(rows[4])
    expect(calls).toEqual([])
  })

  it("arrows stay inside their own group", () => {
    const { modeButtons } = mount()
    modeButtons[2].dispatch("keydown", { key: "ArrowRight" })
    expect(document.activeElement).toBe(modeButtons[0])
  })

  it("Enter applies the focused row and prevents the native click", () => {
    const { rows } = mount()
    const ev = rows[3].dispatch("keydown", { key: "Enter" })

    expect(ev.defaultPrevented).toBe(true)
    expect(calls).toEqual([
      ["apply", { preset: "burrow-forest", mode: "dark" }],
      ["push", "set_theme", { preset: "burrow-forest", mode: "dark" }],
    ])
  })

  it("Space applies the focused mode", () => {
    const { modeButtons } = mount()
    modeButtons[2].dispatch("keydown", { key: " " })
    expect(calls.at(-1)).toEqual(["push", "set_theme", { preset: "burrow", mode: "system" }])
  })
})

describe("ThemePicker: checked state", () => {
  it("mounts with the boot script's state checked, one tab stop per group", () => {
    state = { preset: "burrow-sand", mode: "light" }
    const { rows, modeButtons } = mount()

    expect(checked(rows).map(value)).toEqual(["burrow-sand"])
    expect(checked(modeButtons).map(value)).toEqual(["light"])
    expect(visibleChecks(rows).map(value)).toEqual(["burrow-sand"])
    expect(rows.map((r) => r.getAttribute("tabindex"))).toEqual(["-1", "-1", "0", "-1", "-1"])
  })

  it("the check follows the active row", () => {
    const { rows } = mount()
    expect(visibleChecks(rows).map(value)).toEqual(["burrow"])

    rows[4].dispatch("click")
    expect(checked(rows).map(value)).toEqual(["high-contrast"])
    expect(visibleChecks(rows).map(value)).toEqual(["high-contrast"])

    rows[1].dispatch("keydown", { key: "Enter" })
    expect(visibleChecks(rows).map(value)).toEqual(["burrow-midnight"])
  })

  it("a burrow:theme from another tab moves the check without a push", () => {
    const { rows } = mount()
    state = { preset: "burrow-forest", mode: "dark" }
    fireTheme()

    expect(visibleChecks(rows).map(value)).toEqual(["burrow-forest"])
    expect(calls).toEqual([])
  })
})

describe("ThemePicker: chips follow the mode", () => {
  it("chips repaint in the chosen mode", () => {
    const { rows, modeButtons } = mount()
    expect(new Set(chipThemes(rows))).toEqual(new Set(["dark"]))

    modeButtons[0].dispatch("click")
    expect(new Set(chipThemes(rows))).toEqual(new Set(["light"]))
  })

  it("system resolves through the OS scheme, and follows it live", () => {
    osDark = false
    const { rows, modeButtons } = mount()

    modeButtons[2].dispatch("click")
    expect(new Set(chipThemes(rows))).toEqual(new Set(["light"]))

    osDark = true
    fireTheme() // the boot script repaints on the matchMedia change
    expect(new Set(chipThemes(rows))).toEqual(new Set(["dark"]))

    osDark = false
    fireTheme()
    expect(new Set(chipThemes(rows))).toEqual(new Set(["light"]))
  })

  it("each chip keeps its own preset", () => {
    const { rows } = mount()
    rows[2].dispatch("click")
    expect(rows.map((r) => r.querySelector("[data-theme-chip]").getAttribute("data-preset"))).toEqual(PRESETS)
  })
})

describe("ThemePicker: teardown", () => {
  it("destroyed() stops following burrow:theme", () => {
    const { rows, hook } = mount()
    hook.destroyed()
    state = { preset: "burrow-sand", mode: "dark" }
    fireTheme()
    expect(visibleChecks(rows).map(value)).toEqual(["burrow"])
  })
})
