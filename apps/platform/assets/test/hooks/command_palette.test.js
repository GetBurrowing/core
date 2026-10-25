import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import CommandPalette, { DESKTOP_QUERY } from "../../js/hooks/command_palette.js"
import DetailsPanelState, { overlayOpen } from "../../js/hooks/details_panel_state.js"
import Sheet from "../../js/hooks/sheet.js"
import { __resetForTests } from "../../js/client_state.js"

/**
 * CommandPalette (Burrow redesign 23 stage 4): the ⌘K hook on
 * `#command-palette`. vitest runs in plain node, so this builds a small fake
 * DOM whose dispatch walks the real three phases (capture down from the
 * document, the target, bubble back up) and honours stopPropagation. That is
 * what lets the Escape interplay be tested for ORDER, not just for the
 * DetailsPanelState `overlayOpen` guard (which alone would hide a
 * bubble-phase palette listener; see the Sheet case).
 */

// ── Fake DOM ─────────────────────────────────────────────────────────

let doc

class FakeEl {
  constructor(tag, attrs = {}, { shown = true } = {}) {
    this.tagName = tag.toUpperCase()
    this.attrs = { ...attrs }
    this.children = []
    this.parentNode = null
    this.listeners = []
    this.shown = shown
    this.isContentEditable = attrs.contenteditable === "true"
    this.isConnected = true
    this.value = ""
    this.style = {}
    this.offsetTop = 0
    this.offsetHeight = 38
    this.clientHeight = 0
    this.scrollTop = 0
    this.focus = vi.fn(() => {
      doc.activeElement = this
    })
  }

  get id() {
    return this.attrs.id || ""
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

  get ownerDocument() {
    return doc
  }

  append(...kids) {
    for (const k of kids) {
      k.parentNode = this
      this.children.push(k)
    }
    return this
  }

  getAttribute(n) {
    return n in this.attrs ? this.attrs[n] : null
  }
  hasAttribute(n) {
    return n in this.attrs
  }
  setAttribute(n, v) {
    this.attrs[n] = String(v)
  }
  getClientRects() {
    return this.shown ? [{}] : []
  }
  contains(other) {
    for (let n = other; n; n = n.parentNode) if (n === this) return true
    return false
  }
  matches(sel) {
    return sel.split(",").some((part) => matchOne(this, part.trim()))
  }
  descendants() {
    return this.children.flatMap((c) => [c, ...c.descendants()])
  }
  querySelectorAll(sel) {
    return this.descendants().filter((n) => n.matches(sel))
  }
  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }
  addEventListener(type, fn, opts) {
    const capture = opts === true || !!(opts && opts.capture)
    this.listeners.push({ type, fn, capture })
  }
  removeEventListener(type, fn, opts) {
    const capture = opts === true || !!(opts && opts.capture)
    this.listeners = this.listeners.filter(
      (l) => !(l.type === type && l.fn === fn && l.capture === capture)
    )
  }
  setSelectionRange(a, b) {
    this.selectionStart = a
    this.selectionEnd = b
  }
}

// tag, #id, [attr] and [attr="v"]; anything else (":popover-open") throws,
// as an unsupported selector does in a browser.
function matchOne(el, sel) {
  if (sel.includes(":")) throw new Error(`unsupported selector ${sel}`)
  const m = sel.match(/^([a-z]*)(#[\w-]+)?((?:\[[^\]]+\])*)$/i)
  if (!m) return false
  const [, tag, id, attrs] = m
  if (tag && el.tagName !== tag.toUpperCase()) return false
  if (id && el.id !== id.slice(1)) return false
  for (const a of attrs.match(/\[[^\]]+\]/g) || []) {
    const [, name, value] = a.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/)
    if (!(name in el.attrs)) return false
    if (value !== undefined && el.attrs[name] !== value) return false
  }
  return true
}

function makeDoc() {
  const d = new FakeEl("#document")
  d.body = new FakeEl("body")
  d.append(d.body)
  d.activeElement = d.body
  return d
}

function dispatchKey(target, key, mods = {}) {
  const event = {
    type: "keydown",
    key,
    target,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    isComposing: false,
    defaultPrevented: false,
    stopped: false,
    ...mods,
  }
  event.preventDefault = () => (event.defaultPrevented = true)
  event.stopPropagation = () => (event.stopped = true)

  const path = []
  for (let n = target; n; n = n.parentNode) path.unshift(n)
  const run = (node, capture) => {
    for (const l of [...node.listeners]) {
      if (l.type === "keydown" && (capture === null || l.capture === capture)) l.fn(event)
    }
  }
  for (const node of path.slice(0, -1)) {
    run(node, true)
    if (event.stopped) return event
  }
  run(target, true)
  if (!event.stopped) run(target, false)
  for (const node of path.slice(0, -1).reverse()) {
    if (event.stopped) return event
    run(node, false)
  }
  return event
}

function keydownListenerCount(node) {
  return node.listeners.filter((l) => l.type === "keydown").length
}

// ── The palette, as CommandPaletteLive renders it ───────────────────

function paletteRoot({ rows = 3, open = false, query = "" } = {}) {
  const root = new FakeEl("div", {
    id: "command-palette",
    role: "dialog",
    "aria-modal": "true",
    "data-open": String(open),
  })
  setRows(root, { rows, open, query })
  return root
}

function setRows(root, { rows, open, query }) {
  root.children = []
  if (!open) return
  const input = new FakeEl("input", { id: "command-palette-input", type: "text" })
  input.value = query
  const index = new FakeEl("input", { type: "hidden", name: "index" })
  index.value = "0"
  const list = new FakeEl("div", {
    id: "command-palette-results",
    role: "listbox",
    "data-query": query,
  })
  list.clientHeight = 76
  for (let n = 0; n < rows; n++) {
    const row = new FakeEl("a", {
      id: `command-palette-row-${n}`,
      role: "option",
      "aria-selected": String(n === 0),
    })
    row.offsetTop = n * 38
    list.append(row)
  }
  const box = new FakeEl("div", { id: "command-palette-box" })
  box.append(new FakeEl("form").append(input, index), list)
  root.append(box)
}

// What a LiveView patch does: re-render the server's state, then updated().
function render(hook, { open, rows = 3, query = "" }) {
  hook.el.setAttribute("data-open", String(open))
  setRows(hook.el, { rows, open, query })
  hook.updated()
}

const mounted = []

function mountHook(Hook, el, extra = {}) {
  const hook = Object.create(Hook)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.pushEventTo = vi.fn()
  hook.handleEvent = vi.fn()
  Object.assign(hook, extra)
  hook.mounted()
  mounted.push(hook)
  return hook
}

function destroy(hook) {
  const at = mounted.indexOf(hook)
  if (at !== -1) mounted.splice(at, 1)
  hook.destroyed()
}

function selected(root) {
  return root.querySelectorAll('[role="option"]').map((r) => r.getAttribute("aria-selected"))
}

let width

beforeEach(() => {
  __resetForTests()
  doc = makeDoc()
  globalThis.document = doc
  globalThis.requestAnimationFrame = (fn) => fn()
  width = 1280
  globalThis.window = {
    matchMedia: (q) => {
      const min = Number((q.match(/min-width:\s*(\d+)px/) || [])[1] || 0)
      return { matches: width >= min }
    },
  }
})

afterEach(() => {
  while (mounted.length) destroy(mounted[mounted.length - 1])
  delete globalThis.window
  delete globalThis.document
  delete globalThis.requestAnimationFrame
})

function setup(opts = {}) {
  const root = paletteRoot(opts)
  doc.body.append(root)
  const hook = mountHook(CommandPalette, root)
  return { root, hook }
}

// ── Listener lifecycle ──────────────────────────────────────────────

describe("CommandPalette: one shared document listener", () => {
  it("mounting twice leaves one capture-phase listener; destroyed removes it", () => {
    const a = setup()
    const b = setup()

    expect(keydownListenerCount(doc)).toBe(1)
    expect(doc.listeners[0].capture).toBe(true)

    destroy(a.hook)
    expect(keydownListenerCount(doc)).toBe(1)
    destroy(b.hook)
    expect(keydownListenerCount(doc)).toBe(0)
  })

  it("adds no window listener", () => {
    const added = []
    globalThis.window.addEventListener = (t) => added.push(t)
    setup()
    expect(added).toEqual([])
  })
})

// ── ⌘K / Ctrl+K ─────────────────────────────────────────────────────

describe("CommandPalette: ⌘K / Ctrl+K", () => {
  function fields() {
    const input = new FakeEl("input", { type: "text" })
    const textarea = new FakeEl("textarea")
    const rich = new FakeEl("div", { contenteditable: "true" })
    doc.body.append(input, textarea, rich)
    return { body: doc.body, input, textarea, rich }
  }

  it("Meta+K and Ctrl+K push palette_toggle from the body, an input, a textarea and a contenteditable", () => {
    const { hook } = setup()
    const targets = fields()

    for (const [name, target] of Object.entries(targets)) {
      for (const mod of [{ metaKey: true }, { ctrlKey: true }]) {
        hook.pushEventTo.mockClear()
        const e = dispatchKey(target, "k", mod)
        expect(e.defaultPrevented, `${name} ${JSON.stringify(mod)}`).toBe(true)
        expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "palette_toggle", {})
      }
    }
    expect(DESKTOP_QUERY).toBe("(min-width: 1024px)")
  })

  it("a plain k in a textarea, Alt+K, Shift+K and a composing ⌘K do nothing", () => {
    const { hook } = setup()
    const { textarea } = fields()

    for (const mods of [
      {},
      { metaKey: true, altKey: true },
      { metaKey: true, shiftKey: true },
      { ctrlKey: true, shiftKey: true },
      { metaKey: true, isComposing: true },
    ]) {
      const e = dispatchKey(textarea, mods.shiftKey ? "K" : "k", mods)
      expect(e.defaultPrevented, JSON.stringify(mods)).toBe(false)
    }
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })

  it("at 1023px wide ⌘K neither pushes nor preventDefaults", () => {
    width = 1023
    const { hook } = setup()

    const e = dispatchKey(doc.body, "k", { metaKey: true })
    expect(e.defaultPrevented).toBe(false)
    expect(hook.pushEventTo).not.toHaveBeenCalled()

    width = 1024
    expect(dispatchKey(doc.body, "k", { metaKey: true }).defaultPrevented).toBe(true)
    expect(hook.pushEventTo).toHaveBeenCalledTimes(1)
  })

  it("while closed, Escape, the arrows and Enter are untouched", () => {
    const { hook } = setup()
    const textarea = new FakeEl("textarea")
    doc.body.append(textarea)

    for (const k of ["Escape", "ArrowDown", "ArrowUp", "Enter"]) {
      for (const target of [doc.body, textarea]) {
        const e = dispatchKey(target, k)
        expect(e.defaultPrevented, k).toBe(false)
        expect(e.stopped, k).toBe(false)
      }
    }
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })
})

// ── Open: selection, Enter, Escape, scrim ───────────────────────────

describe("CommandPalette: while open", () => {
  function opened(rows = 3, query = "") {
    const s = setup()
    render(s.hook, { open: true, rows, query })
    return s
  }

  it("focuses the input on open, without scrolling", () => {
    const { root } = opened()
    const input = root.querySelector("#command-palette-input")
    expect(input.focus).toHaveBeenCalledWith({ preventScroll: true })
    expect(doc.activeElement).toBe(input)
  })

  it("ArrowDown on the last row wraps to the first; ArrowUp on the first wraps to the last", () => {
    const { root } = opened(3)
    const input = root.querySelector("#command-palette-input")

    expect(selected(root)).toEqual(["true", "false", "false"])
    const down = dispatchKey(input, "ArrowDown")
    expect(down.defaultPrevented).toBe(true)
    expect(selected(root)).toEqual(["false", "true", "false"])
    dispatchKey(input, "ArrowDown")
    expect(selected(root)).toEqual(["false", "false", "true"])
    dispatchKey(input, "ArrowDown")
    expect(selected(root)).toEqual(["true", "false", "false"])

    dispatchKey(input, "ArrowUp")
    expect(selected(root)).toEqual(["false", "false", "true"])
    expect(input.getAttribute("aria-activedescendant")).toBe("command-palette-row-2")
    expect(root.querySelector('input[name="index"]').value).toBe("2")
  })

  it("scrolls the listbox, not the page, to keep the selected row in view", () => {
    const { root } = opened(5)
    const input = root.querySelector("#command-palette-input")
    const list = root.querySelector('[role="listbox"]')

    dispatchKey(input, "ArrowDown")
    dispatchKey(input, "ArrowDown")
    // row 2: top 76, bottom 114; the box is 76 tall.
    expect(list.scrollTop).toBe(38)
    dispatchKey(input, "ArrowUp")
    dispatchKey(input, "ArrowUp")
    expect(list.scrollTop).toBe(0)
  })

  it("Enter pushes palette_go with the input value and the selected index", () => {
    const { root, hook } = opened(3, "be")
    const input = root.querySelector("#command-palette-input")
    input.value = "bet"

    dispatchKey(input, "ArrowDown")
    const e = dispatchKey(input, "Enter")

    expect(e.defaultPrevented).toBe(true)
    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "palette_go", { q: "bet", index: 1 })
  })

  it("updated() keeps the selection across a same-query patch and resets it to 0 when the query changes", () => {
    const { root, hook } = opened(3, "b")
    dispatchKey(root.querySelector("#command-palette-input"), "ArrowDown")

    render(hook, { open: true, rows: 3, query: "b" })
    expect(selected(root)).toEqual(["false", "true", "false"])

    render(hook, { open: true, rows: 3, query: "be" })
    expect(selected(root)).toEqual(["true", "false", "false"])
  })

  it("Escape closes, is stopped, and a click on the scrim (the root) closes", () => {
    const { root, hook } = opened()
    const e = dispatchKey(root.querySelector("#command-palette-input"), "Escape")
    expect(e.defaultPrevented).toBe(true)
    expect(e.stopped).toBe(true)
    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "palette_close", {})

    hook.pushEventTo.mockClear()
    const click = root.listeners.find((l) => l.type === "click").fn
    click({ target: root.querySelector("#command-palette-box") })
    expect(hook.pushEventTo).not.toHaveBeenCalled()
    click({ target: root })
    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "palette_close", {})
  })

  it("⌘K while open toggles (closes)", () => {
    const { hook } = opened()
    dispatchKey(doc.activeElement, "k", { metaKey: true })
    expect(hook.pushEventTo).toHaveBeenCalledWith(hook.el, "palette_toggle", {})
  })
})

// ── Focus return ────────────────────────────────────────────────────

describe("CommandPalette: focus returns on close", () => {
  it("to the textarea that held focus before ⌘K, value and caret unchanged", () => {
    const { hook } = setup()
    const composer = new FakeEl("textarea", { id: "compose-input" })
    composer.value = "half-typed draft"
    composer.setSelectionRange(4, 4)
    doc.body.append(composer)
    composer.focus()

    dispatchKey(composer, "k", { metaKey: true })
    render(hook, { open: true })
    expect(doc.activeElement).toBe(hook.el.querySelector("#command-palette-input"))
    composer.selectionStart = composer.selectionEnd = 16

    dispatchKey(doc.activeElement, "Escape")
    render(hook, { open: false })

    expect(doc.activeElement).toBe(composer)
    expect(composer.focus).toHaveBeenLastCalledWith({ preventScroll: true })
    expect(composer.value).toBe("half-typed draft")
    expect([composer.selectionStart, composer.selectionEnd]).toEqual([4, 4])
  })

  it("to the contenteditable composer, with its caret range put back", () => {
    const { hook } = setup()
    const composer = new FakeEl("div", { id: "compose-input", contenteditable: "true" })
    const textNode = new FakeEl("#text")
    composer.append(textNode)
    doc.body.append(composer)
    composer.focus()

    const caret = { startContainer: textNode, offset: 4 }
    caret.cloneRange = () => ({ ...caret, cloned: true })
    const sel = { ranges: [caret] }
    sel.getRangeAt = (i) => sel.ranges[i]
    Object.defineProperty(sel, "rangeCount", { get: () => sel.ranges.length })
    sel.removeAllRanges = () => (sel.ranges = [])
    sel.addRange = (r) => sel.ranges.push(r)
    doc.defaultView = { getSelection: () => sel }

    dispatchKey(composer, "k", { metaKey: true })
    render(hook, { open: true })
    // The palette input takes the document selection.
    sel.ranges = [{ startContainer: hook.el.querySelector("#command-palette-input"), offset: 0 }]

    dispatchKey(doc.activeElement, "Escape")
    render(hook, { open: false })

    expect(doc.activeElement).toBe(composer)
    expect(sel.ranges).toHaveLength(1)
    expect(sel.ranges[0]).toMatchObject({ startContainer: textNode, offset: 4, cloned: true })
  })

  it("an open from the button (no ⌘K) still returns focus to it", () => {
    const { hook } = setup()
    const button = new FakeEl("button", { id: "cmdk-btn" })
    doc.body.append(button)
    button.focus()

    render(hook, { open: true })
    render(hook, { open: false })
    expect(doc.activeElement).toBe(button)
  })
})

// ── Escape interplay with the details panel and a sheet ─────────────

describe("CommandPalette: Escape interplay", () => {
  function shell({ paletteOpen }) {
    const state = new FakeEl("div", { id: "details-panel-state", "data-open": "true" })
    const panel = new FakeEl("aside", { id: "details-panel" })
    const root = paletteRoot()
    doc.body.append(state, panel, root)

    const details = mountHook(DetailsPanelState, state)
    const palette = mountHook(CommandPalette, root)
    if (paletteOpen) render(palette, { open: true })
    return { details, palette, root }
  }

  it("with the palette open, Escape closes the palette and DetailsPanelState pushes nothing", () => {
    const { details, palette, root } = shell({ paletteOpen: true })

    dispatchKey(root.querySelector("#command-palette-input"), "Escape")
    expect(palette.pushEventTo).toHaveBeenCalledWith(palette.el, "palette_close", {})
    expect(details.pushEvent).not.toHaveBeenCalled()

    // Focus outside any field too (the body).
    palette.pushEventTo.mockClear()
    dispatchKey(doc.body, "Escape")
    expect(palette.pushEventTo).toHaveBeenCalledWith(palette.el, "palette_close", {})
    expect(details.pushEvent).not.toHaveBeenCalled()
  })

  it("with the palette closed and focus on the body, Escape makes DetailsPanelState push details_close", () => {
    const { details, palette } = shell({ paletteOpen: false })

    const e = dispatchKey(doc.body, "Escape")
    expect(e.defaultPrevented).toBe(false)
    expect(details.pushEvent).toHaveBeenCalledWith("details_close", {})
    expect(palette.pushEventTo).not.toHaveBeenCalled()
  })

  it("overlayOpen(document) is true while the palette root has data-open=true", () => {
    const { palette } = shell({ paletteOpen: false })
    expect(overlayOpen(doc)).toBe(false)
    render(palette, { open: true })
    expect(overlayOpen(doc)).toBe(true)
    render(palette, { open: false })
    expect(overlayOpen(doc)).toBe(false)
  })

  it("the palette closes FIRST over an open sheet: the sheet never sees the Escape", () => {
    const { details, palette, root } = shell({ paletteOpen: true })
    const sheetEl = new FakeEl("div", {
      id: "some-sheet",
      "aria-modal": "true",
      "data-open": "true",
      "data-on-close": "sheet_close",
    })
    doc.body.append(sheetEl)
    const sheet = mountHook(Sheet, sheetEl, { _captureFocusInto: vi.fn() })

    dispatchKey(root.querySelector("#command-palette-input"), "Escape")
    expect(palette.pushEventTo).toHaveBeenCalledWith(palette.el, "palette_close", {})
    expect(sheet.pushEvent).not.toHaveBeenCalled()
    expect(details.pushEvent).not.toHaveBeenCalled()

    // Positive control: with the palette closed, the same Escape is the sheet's.
    render(palette, { open: false })
    dispatchKey(doc.body, "Escape")
    expect(sheet.pushEvent).toHaveBeenCalledWith("sheet_close")
  })
})
