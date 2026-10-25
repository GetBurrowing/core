import { describe, it, expect, beforeEach, afterEach } from "vitest"
import ThemePicker, { injectOrgTheme } from "../../js/hooks/theme_picker.js"

/**
 * An org theme published after the page loaded (task 01a1557a stage 5).
 * ShellLive answers `set_theme` for an org preset with `burrow:org-theme`
 * {preset, css}; the hook appends the css to #org-themes as text, registers
 * the id with window.burrowTheme and applies it. Minimal fake DOM, as in
 * theme_picker.test.js.
 */

const ID = "org-01a173d4-9a48-7004-9a0e-e12d2a39a5fe"
const CSS = `[data-preset="${ID}"][data-theme="dark"]:not([data-theme-preview]) {\ncolor-scheme: dark;\n--color-base-100: var(--x);\n}`

class FakeText {
  constructor(text) {
    this.textContent = text
  }
}

class FakeStyle {
  constructor() {
    this.attrs = {}
    this.childNodes = []
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }
  appendChild(node) {
    if (!(node instanceof FakeText)) throw new Error("only text may be appended")
    this.childNodes.push(node)
    return node
  }
  get textContent() {
    return this.childNodes.map((n) => n.textContent).join("")
  }
}

const fakeDoc = (style) => {
  const head = { children: [], appendChild: (el) => head.children.push(el) }
  return {
    head,
    getElementById: (id) => (id === "org-themes" ? style || head.children.find((el) => el.attrs.id === id) || null : null),
    createElement: (tag) => {
      if (tag !== "style") throw new Error(`unexpected ${tag}`)
      return new FakeStyle()
    },
    createTextNode: (text) => new FakeText(text),
  }
}

let calls
let presets
let state

const fakeApi = () => ({
  get: () => ({ ...state, resolved: state.mode }),
  has: (id) => presets.includes(id),
  register: (id) => {
    calls.push(["register", id])
    if (!presets.includes(id)) presets.push(id)
    return true
  },
  apply: (pref) => {
    calls.push(["apply", { ...pref }])
    if (presets.includes(pref.preset)) state = { ...state, preset: pref.preset }
    return { ...state, resolved: state.mode }
  },
})

beforeEach(() => {
  calls = []
  presets = ["burrow", "burrow-sand"]
  state = { preset: "burrow", mode: "light" }
  globalThis.window = { burrowTheme: fakeApi(), addEventListener() {}, removeEventListener() {} }
  globalThis.document = { documentElement: { getAttribute: () => null } }
})

afterEach(() => {
  delete globalThis.window
  delete globalThis.document
})

describe("injectOrgTheme", () => {
  it("appends the css to #org-themes as text, registers the id and applies it", () => {
    const style = new FakeStyle()
    const api = window.burrowTheme

    expect(injectOrgTheme({ preset: ID, css: CSS }, fakeDoc(style), api)).toBe(true)
    expect(style.textContent).toContain(CSS)
    expect(calls).toEqual([
      ["register", ID],
      ["apply", { preset: ID, mode: "light" }],
    ])
    expect(state.preset).toBe(ID)
  })

  it("creates #org-themes when the page loaded with no org theme at all", () => {
    const doc = fakeDoc(null)
    expect(injectOrgTheme({ preset: ID, css: CSS }, doc, window.burrowTheme)).toBe(true)
    const [style] = doc.head.children
    expect(style.attrs).toEqual({ id: "org-themes", "data-role": "org-themes" })
    expect(style.textContent).toContain(CSS)
  })

  it("does nothing for a preset already on the page", () => {
    presets.push(ID)
    const style = new FakeStyle()
    expect(injectOrgTheme({ preset: ID, css: CSS }, fakeDoc(style), window.burrowTheme)).toBe(false)
    expect(style.childNodes).toEqual([])
    expect(calls).toEqual([])
  })

  it("refuses a payload that is not an org id with its own blocks", () => {
    const style = new FakeStyle()
    const api = window.burrowTheme
    const bad = [
      null,
      { preset: "burrow-sand", css: CSS },
      { preset: "org-not-a-uuid", css: CSS },
      { preset: `${ID}"]{}`, css: CSS },
      { preset: ID, css: 42 },
      { preset: ID, css: "body { color: red }" },
    ]
    for (const payload of bad) expect(injectOrgTheme(payload, fakeDoc(style), api)).toBe(false)
    expect(style.childNodes).toEqual([])
    expect(calls).toEqual([])
  })
})

describe("ThemePicker: an unregistered org preset", () => {
  it("is not applied locally; set_theme carries the requested id, and the pushed css lands", () => {
    const handlers = {}
    const pushes = []
    const option = {
      dataset: { themeOption: "preset", value: ID },
      focus() {},
      closest() {
        return this
      },
    }
    const hook = Object.create(ThemePicker)
    hook.el = { querySelectorAll: () => [], addEventListener() {}, contains: () => true }
    hook.pushEvent = (event, payload) => pushes.push([event, { ...payload }])
    hook.handleEvent = (event, fn) => (handlers[event] = fn)
    hook.mounted()

    hook.select(option)
    expect(calls).toEqual([])
    expect(pushes).toEqual([["set_theme", { preset: ID, mode: "light" }]])

    const style = new FakeStyle()
    globalThis.document = { ...globalThis.document, ...fakeDoc(style) }
    handlers["burrow:org-theme"]({ preset: ID, css: CSS })
    expect(style.textContent).toContain(CSS)
    expect(state.preset).toBe(ID)
  })
})
