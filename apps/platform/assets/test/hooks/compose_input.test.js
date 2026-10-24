import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ComposeInput, {
  shouldResetViewportAfterBlur,
  shouldRestoreFocusAfterMove,
} from "../../js/hooks/compose_input.js"

/**
 * Tests for the `ComposeInput` hook's post-blur viewport reset (task
 * 01a1557a stage 2).
 *
 * The hook resets the page scroll 100ms after the textarea blurs, so the
 * viewport recovers when the iOS keyboard closes. Picking an @mention
 * suggestion also blurs the textarea, and `chat:insert-mention` refocuses it
 * synchronously; before this fix the queued reset still fired and jumped the
 * conversation to the top mid-compose. The reset must now run only when
 * focus has really left the composer.
 *
 * vitest runs in plain node here (no jsdom), so the second block stubs
 * `window`, `document` and `CSS` and drives the real listeners registered by
 * `mounted()` through a fake element.
 */
describe("shouldResetViewportAfterBlur", () => {
  const el = { id: "composer" }

  it("skips the reset when focus is back on the composer", () => {
    expect(shouldResetViewportAfterBlur(el, el)).toBe(false)
  })

  it("resets when focus moved to another element", () => {
    expect(shouldResetViewportAfterBlur({ id: "other" }, el)).toBe(true)
  })

  it("resets when nothing is focused (null or body)", () => {
    expect(shouldResetViewportAfterBlur(null, el)).toBe(true)
    expect(shouldResetViewportAfterBlur({ tagName: "BODY" }, el)).toBe(true)
  })
})

function fakeTextarea(doc) {
  const listeners = {}
  const el = {
    value: "hi @al",
    defaultValue: "",
    selectionStart: 6,
    dataset: {},
    style: {},
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    fire(type, event = {}) {
      for (const fn of listeners[type] || []) fn(event)
    },
    focus() {
      doc.activeElement = el
    },
    blur() {
      doc.activeElement = { tagName: "BODY" }
      el.fire("blur")
    },
    setSelectionRange(a) {
      el.selectionStart = a
    },
    closest() {
      return null
    },
  }
  return el
}

describe("ComposeInput blur listener", () => {
  let doc
  let scrollTo
  let hook

  beforeEach(() => {
    vi.useFakeTimers()
    doc = { activeElement: null }
    scrollTo = vi.fn()
    vi.stubGlobal("document", doc)
    vi.stubGlobal("window", {
      scrollTo,
      matchMedia: () => ({ matches: true }),
    })
    vi.stubGlobal("CSS", { supports: () => true })

    const el = fakeTextarea(doc)
    hook = Object.create(ComposeInput)
    hook.el = el
    hook.pushEvent = vi.fn()
    hook.mounted()
    el.focus()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it("does not scroll to the top when an @mention pick refocuses the composer", () => {
    hook.el.blur()
    hook.el.fire("chat:insert-mention", { detail: { name: "Alice" } })
    vi.advanceTimersByTime(200)

    expect(hook.el.value).toBe("hi @[Alice] ")
    expect(doc.activeElement).toBe(hook.el)
    expect(scrollTo).not.toHaveBeenCalled()
  })

  it("still resets the viewport when focus really leaves (keyboard dismissed)", () => {
    hook.el.blur()
    vi.advanceTimersByTime(200)

    expect(scrollTo).toHaveBeenCalledTimes(1)
    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "instant" })
  })
})

// ── The chat composer's chip field (redesign rung 10, task 01a1557a-997a
// stage 2). The hook branches on `isContentEditable`; the fake textareas
// above have none, so they keep driving the textarea path. The field below
// is built on test/lib/fake_dom.js.

const store = vi.hoisted(() => new Map())

vi.mock("../../js/client_state.js", () => ({
  default: {
    get: (ns, key, fallback) => (store.has(`${ns}:${key}`) ? store.get(`${ns}:${key}`) : fallback),
    set: (ns, key, value) => store.set(`${ns}:${key}`, value),
    remove: (ns, key) => store.delete(`${ns}:${key}`),
  },
}))

vi.mock("../../js/attach_stage.js", async (importOriginal) => {
  const actual = await importOriginal()
  return { ...actual, installRetry: vi.fn(), stageFiles: vi.fn(), toast: vi.fn() }
})

import { fakeDocument, caret } from "../lib/fake_dom.js"
import { hydrate, serialize } from "../../js/lib/mention_field.js"

// The space composer by default; `thread: "<message id>"` builds the inline
// thread reply box instead (stage 4): its own form id, value input, draft
// key and listbox, and `data-clear-on-submit`.
function richComposer({ coarse = false, serverValue = "", staged = false, thread = null } = {}) {
  const ids = thread
    ? {
        form: `inline-thread-compose-form-${thread}`,
        value: `inline-thread-compose-value-${thread}`,
        field: `inline-thread-compose-${thread}`,
        draft: `thread-draft:${thread}`,
        list: `inline-thread-mention-list-${thread}`,
      }
    : {
        form: "compose-form",
        value: "compose_text_value",
        field: "compose_text",
        draft: "chat-draft:space-1",
        list: "compose-mention-list",
      }
  const doc = fakeDocument()
  const form = doc.createElement("form")
  form.setAttribute("id", ids.form)
  form.requestSubmit = vi.fn()

  const hidden = doc.createElement("input")
  hidden.setAttribute("id", ids.value)
  hidden.value = serverValue
  const hiddenInputs = vi.fn()
  hidden.addEventListener("input", hiddenInputs)

  const el = doc.createElement("div")
  el.setAttribute("id", ids.field)
  el.setAttribute("contenteditable", "true")
  el.setAttribute("data-draft-key", ids.draft)
  el.setAttribute("data-value-input", ids.value)
  el.setAttribute("aria-controls", ids.list)
  el.setAttribute("aria-expanded", "false")
  if (thread) el.setAttribute("data-clear-on-submit", "")

  const at = doc.createElement("button")
  at.setAttribute("type", "button")
  at.setAttribute("data-role", "compose-mention-button")

  const send = doc.createElement("button")
  send.setAttribute("type", "submit")
  send.setAttribute("data-staged", String(staged))
  send.setAttribute("data-send-blocked", "false")
  send.disabled = true

  for (const n of [hidden, el, at, send]) form.appendChild(n)

  doc.getElementById = (id) => (id === ids.value ? hidden : null)
  doc.execCommand = vi.fn()

  const ctx = { selection: null }
  const windowListeners = {}
  vi.stubGlobal("document", doc)
  vi.stubGlobal("window", {
    scrollTo: vi.fn(),
    matchMedia: () => ({ matches: coarse }),
    getSelection: () => ctx.selection,
    addEventListener: (type, fn) => (windowListeners[type] ||= []).push(fn),
    removeEventListener: (type, fn) => {
      windowListeners[type] = (windowListeners[type] || []).filter((f) => f !== fn)
    },
  })
  vi.stubGlobal("CSS", { supports: () => true })

  const handlers = {}
  const hook = Object.create(ComposeInput)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.handleEvent = (name, fn) => (handlers[name] = fn)
  hook.mounted()

  return { doc, form, hidden, hiddenInputs, el, at, send, hook, handlers, ctx, windowListeners, ids }
}

function type(c, text) {
  hydrate(c.el, text)
  c.el.fire("input")
}

function key(c, k, mods = {}) {
  const e = { key: k, preventDefault: vi.fn(), ...mods }
  c.el.fire("keydown", e)
  return e
}

describe("ComposeInput chip field: Enter", () => {
  beforeEach(() => store.clear())
  afterEach(() => vi.unstubAllGlobals())

  for (const coarse of [false, true]) {
    const pointer = coarse ? "coarse (phone)" : "fine (desktop)"

    it(`Enter sends with the list closed on a ${pointer} pointer`, () => {
      const c = richComposer({ coarse })
      type(c, "hello @[Builder]")
      const e = key(c, "Enter")
      expect(e.preventDefault).toHaveBeenCalled()
      expect(c.form.requestSubmit).toHaveBeenCalledTimes(1)
      expect(c.hidden.value).toBe("hello @[Builder]")
    })

    it(`Shift+Enter does not send on a ${pointer} pointer (the browser breaks the line)`, () => {
      const c = richComposer({ coarse })
      type(c, "hello")
      const e = key(c, "Enter", { shiftKey: true })
      expect(e.preventDefault).not.toHaveBeenCalled()
      expect(c.form.requestSubmit).not.toHaveBeenCalled()
    })
  }

  it("Cmd+Enter and Ctrl+Enter send", () => {
    const c = richComposer()
    type(c, "hello")
    key(c, "Enter", { metaKey: true })
    key(c, "Enter", { ctrlKey: true })
    expect(c.form.requestSubmit).toHaveBeenCalledTimes(2)
  })

  it("Enter on whitespace sends nothing; with a file staged it sends", () => {
    const c = richComposer()
    type(c, "   ")
    key(c, "Enter")
    expect(c.form.requestSubmit).not.toHaveBeenCalled()
    expect(c.send.disabled).toBe(true)

    const s = richComposer({ staged: true })
    type(s, "")
    expect(s.send.disabled).toBe(false)
    key(s, "Enter")
    expect(s.form.requestSubmit).toHaveBeenCalledTimes(1)
  })

  it("Enter picks the open list's row instead of sending", () => {
    const c = richComposer()
    queryAt(c, "ask @Da")
    expect(c.hook.pushEvent).toHaveBeenCalledWith("mention_query", { query: "Da", source: "compose-form" })
    const rows = openList(c, ["Planner"])

    key(c, "Enter")
    expect(rows[0].click).toHaveBeenCalledTimes(1)
    expect(c.form.requestSubmit).not.toHaveBeenCalled()
  })
})

describe("ComposeInput chip field: value, draft, Send", () => {
  beforeEach(() => store.clear())
  afterEach(() => vi.unstubAllGlobals())

  it("serializes every edit into the hidden input and fires its input event", () => {
    const c = richComposer()
    type(c, "hi @[Design Lead]")
    expect(c.hidden.value).toBe("hi @[Design Lead]")
    expect(c.hiddenInputs).toHaveBeenCalled()
    expect(c.hiddenInputs.mock.calls.at(-1)[0].bubbles).toBe(true)
    expect(c.send.disabled).toBe(false)
  })

  it("writes the draft SERIALIZED and restores it as chips", () => {
    const c = richComposer()
    type(c, "hi @[Builder] there")
    expect(store.get("compose:chat-draft:space-1")).toBe("hi @[Builder] there")
    vi.unstubAllGlobals()

    // A reload: the server has no draft, ClientState does.
    const r = richComposer({ serverValue: "" })
    const chip = r.el.childNodes.find((n) => n.nodeType === 1)
    expect(chip.getAttribute("data-mention")).toBe("Builder")
    expect(chip.getAttribute("contenteditable")).toBe("false")
    expect(serialize(r.el)).toBe("hi @[Builder] there")
    expect(r.hidden.value).toBe("hi @[Builder] there")
    expect(r.hiddenInputs).toHaveBeenCalled()
  })

  it("prefers the server's draft when it has one", () => {
    store.set("compose:chat-draft:space-1", "stale local")
    const c = richComposer({ serverValue: "from @[Reviewer]" })
    expect(serialize(c.el)).toBe("from @[Reviewer]")
  })

  it("one Backspace after a chip removes the whole chip", () => {
    const c = richComposer()
    type(c, "hi @[Builder] there")
    c.ctx.selection = caret(c.el.childNodes[2], 1)
    const e = key(c, "Backspace")
    expect(e.preventDefault).toHaveBeenCalled()
    expect(c.hidden.value).toBe("hi there")
    expect(store.get("compose:chat-draft:space-1")).toBe("hi there")
  })

  it("a picked suggestion replaces the typed @query with a chip and keeps focus", () => {
    const c = richComposer()
    hydrate(c.el, "ask @Da")
    c.ctx.selection = caret(c.el.firstChild, 7)
    c.el.fire("input")
    c.el.fire("chat:insert-mention", { detail: { name: "Builder" } })
    expect(c.hidden.value).toBe("ask @[Builder] ")
    expect(c.doc.activeElement).toBe(c.el)
    expect(c.hook.pushEvent).toHaveBeenLastCalledWith("mention_clear", {})
  })

  it("compose_reset clears the field, the hidden input and the draft", () => {
    const c = richComposer()
    type(c, "sent")
    c.handlers.compose_reset()
    expect(c.el.childNodes).toHaveLength(0)
    expect(c.hidden.value).toBe("")
    expect(store.has("compose:chat-draft:space-1")).toBe(false)
    expect(c.send.disabled).toBe(true)
  })

  it("a text paste goes in as plain text; an image still stages (rung 11)", () => {
    const c = richComposer()
    const e = { clipboardData: { items: [], getData: () => "<b>plain</b>" }, preventDefault: vi.fn() }
    c.el.fire("paste", e)
    expect(e.preventDefault).toHaveBeenCalled()
    expect(c.doc.execCommand).toHaveBeenCalledWith("insertText", false, "<b>plain</b>")
  })
})

// Type `text` with the caret at its end, as one edit (fires `input`).
function queryAt(c, text) {
  hydrate(c.el, text)
  c.ctx.selection = caret(c.el.firstChild, c.el.firstChild.data.length)
  c.el.fire("input")
}

// What Partials.MentionList renders after `mention_query` comes back: the
// listbox the field's aria-controls names, inside the form above the pill,
// with the server's own first-row highlight. Then the patch's `updated()`.
function openList(c, names, { empty = false } = {}) {
  closeList(c)
  const wrap = c.doc.createElement("div")
  wrap.setAttribute("data-role", "mention-list")
  const list = c.doc.createElement("div")
  list.setAttribute("id", "compose-mention-list")
  list.setAttribute("role", "listbox")
  wrap.appendChild(list)
  const rows = names.map((name, i) => {
    const row = c.doc.createElement("div")
    row.setAttribute("id", `compose-mention-list-opt-${i}`)
    row.setAttribute("role", "option")
    row.setAttribute("aria-selected", String(i === 0))
    row.setAttribute("data-mention-name", name)
    row.click = vi.fn()
    list.appendChild(row)
    return row
  })
  if (empty) {
    const row = c.doc.createElement("div")
    row.setAttribute("role", "option")
    row.setAttribute("aria-disabled", "true")
    row.click = vi.fn()
    list.appendChild(row)
  }
  c.form.insertBefore(wrap, c.form.firstChild)
  c.hook.updated()
  return rows
}

function closeList(c) {
  const wrap = c.form.querySelector('[data-role="mention-list"]')
  if (wrap) c.form.removeChild(wrap)
}

function selected(rows) {
  return rows.findIndex((r) => r.getAttribute("aria-selected") === "true")
}

describe("ComposeInput chip field: the in-flow @mention list (stage 3)", () => {
  beforeEach(() => store.clear())
  afterEach(() => vi.unstubAllGlobals())

  it("ArrowDown and ArrowUp move the highlight and wrap", () => {
    const c = richComposer()
    queryAt(c, "ask @")
    const rows = openList(c, ["Builder", "Reviewer", "Scout"])
    expect(selected(rows)).toBe(0)

    const up = key(c, "ArrowUp")
    expect(up.preventDefault).toHaveBeenCalled()
    expect(selected(rows)).toBe(2)

    key(c, "ArrowDown")
    expect(selected(rows)).toBe(0)
    key(c, "ArrowDown")
    key(c, "ArrowDown")
    expect(selected(rows)).toBe(2)
    key(c, "ArrowDown")
    expect(selected(rows)).toBe(0)
    expect(rows.filter((r) => r.getAttribute("aria-selected") === "true")).toHaveLength(1)
  })

  it("Enter and Tab pick the highlighted row", () => {
    const c = richComposer()
    queryAt(c, "ask @")
    const rows = openList(c, ["Builder", "Reviewer", "Scout"])
    key(c, "ArrowDown")
    const enter = key(c, "Enter")
    expect(enter.preventDefault).toHaveBeenCalled()
    expect(rows[1].click).toHaveBeenCalledTimes(1)

    key(c, "ArrowDown")
    const tab = key(c, "Tab")
    expect(tab.preventDefault).toHaveBeenCalled()
    expect(rows[2].click).toHaveBeenCalledTimes(1)
    expect(rows[0].click).not.toHaveBeenCalled()
  })

  it("Enter does not submit while the list is open, Cmd/Ctrl+Enter included", () => {
    const c = richComposer()
    queryAt(c, "hello @Bu")
    openList(c, ["Builder"])
    key(c, "Enter")
    key(c, "Enter", { metaKey: true })
    key(c, "Enter", { ctrlKey: true })
    expect(c.form.requestSubmit).not.toHaveBeenCalled()

    // An empty filter is still an open list: Enter picks nothing and sends nothing.
    const e = richComposer()
    queryAt(e, "hello @zz")
    openList(e, [], { empty: true })
    key(e, "Enter")
    expect(e.form.requestSubmit).not.toHaveBeenCalled()
  })

  it("Esc closes the list, keeps the typed @text, and does not reopen on that token", () => {
    const c = richComposer()
    queryAt(c, "ask @Da")
    openList(c, ["Planner"])
    expect(c.el.getAttribute("aria-expanded")).toBe("true")

    const esc = key(c, "Escape")
    expect(esc.preventDefault).toHaveBeenCalled()
    expect(c.hook.pushEvent).toHaveBeenLastCalledWith("mention_clear", {})
    expect(c.hidden.value).toBe("ask @Da")
    expect(c.el.getAttribute("aria-expanded")).toBe("false")
    expect(c.el.getAttribute("aria-activedescendant")).toBeNull()
    closeList(c)

    // Typing on in the same token stays plain text: no new query.
    const node = c.el.firstChild
    node.data = "ask @Dal"
    c.ctx.selection = caret(node, 8)
    c.el.fire("input")
    expect(c.hook.pushEvent).toHaveBeenLastCalledWith("mention_clear", {})
    expect(c.hidden.value).toBe("ask @Dal")

    // Enter now sends (the list is closed).
    key(c, "Enter")
    expect(c.form.requestSubmit).toHaveBeenCalledTimes(1)

    // A new @token opens the list again.
    node.data = "ask @Dal and @Bu"
    c.ctx.selection = caret(node, 16)
    c.el.fire("input")
    expect(c.hook.pushEvent).toHaveBeenLastCalledWith("mention_query", { query: "Bu", source: "compose-form" })
  })

  it("a pointerdown on a row keeps document.activeElement on the field, and the click inserts the chip", () => {
    const c = richComposer()
    c.el.focus()
    queryAt(c, "ask @Da")
    const rows = openList(c, ["Planner"])

    // The browser's default for a press on a non-focusable row is to move
    // focus off the field (to the body); only preventDefault stops it.
    for (const type of ["pointerdown", "mousedown"]) {
      const e = { target: rows[0], defaultPrevented: false }
      e.preventDefault = () => (e.defaultPrevented = true)
      c.form.fire(type, e)
      if (!e.defaultPrevented) c.doc.activeElement = null
    }
    expect(c.doc.activeElement).toBe(c.el)

    // The row's click dispatches the insertion API on the field.
    c.el.fire("chat:insert-mention", { detail: { name: "Planner" } })
    expect(c.doc.activeElement).toBe(c.el)
    expect(c.hidden.value).toBe("ask @[Planner] ")
    expect(c.el.getAttribute("aria-expanded")).toBe("false")
  })

  it("aria-activedescendant tracks the highlight, and survives a server patch, clamped", () => {
    const c = richComposer()
    queryAt(c, "ask @")
    let rows = openList(c, ["Builder", "Reviewer", "Scout"])
    expect(c.el.getAttribute("aria-expanded")).toBe("true")
    expect(c.el.getAttribute("aria-activedescendant")).toBe("compose-mention-list-opt-0")

    key(c, "ArrowDown")
    key(c, "ArrowDown")
    expect(c.el.getAttribute("aria-activedescendant")).toBe("compose-mention-list-opt-2")

    // A patch that re-renders the same rows with the server's first-row
    // highlight: the hook's index wins.
    rows[0].setAttribute("aria-selected", "true")
    rows[2].setAttribute("aria-selected", "false")
    c.hook.updated()
    expect(selected(rows)).toBe(2)
    expect(c.el.getAttribute("aria-activedescendant")).toBe("compose-mention-list-opt-2")

    // Filtering down to two rows clamps the index to the last row.
    rows = openList(c, ["Builder", "Reviewer"])
    expect(selected(rows)).toBe(1)
    expect(c.el.getAttribute("aria-activedescendant")).toBe("compose-mention-list-opt-1")

    // The empty row is never active.
    openList(c, [], { empty: true })
    expect(c.el.getAttribute("aria-expanded")).toBe("true")
    expect(c.el.getAttribute("aria-activedescendant")).toBeNull()
  })

  it("a typed space closes the list only when nothing matches", () => {
    const c = richComposer()
    queryAt(c, "ask @Design")
    openList(c, ["Design Lead"])
    const node = c.el.firstChild
    node.data = "ask @Design "
    c.ctx.selection = caret(node, 12)
    c.el.fire("input")
    expect(c.hook.pushEvent).toHaveBeenLastCalledWith("mention_query", {
      query: "Design ",
      source: "compose-form",
    })

    const d = richComposer()
    queryAt(d, "ask @zz")
    openList(d, [], { empty: true })
    const n = d.el.firstChild
    n.data = "ask @zz "
    d.ctx.selection = caret(n, 8)
    d.el.fire("input")
    expect(d.hook.pushEvent).toHaveBeenLastCalledWith("mention_clear", {})
    expect(d.el.getAttribute("aria-expanded")).toBe("false")
    expect(d.hidden.value).toBe("ask @zz ")
  })
})

describe("ComposeInput chip field: the @ button", () => {
  beforeEach(() => store.clear())
  afterEach(() => vi.unstubAllGlobals())

  it("keeps document.activeElement on the field and inserts @ at the caret", () => {
    const c = richComposer()
    c.el.focus()
    const down = { preventDefault: vi.fn() }
    c.at.fire("pointerdown", down)
    c.at.fire("mousedown", down)
    expect(down.preventDefault).toHaveBeenCalledTimes(2)
    expect(c.doc.activeElement).toBe(c.el)

    c.at.fire("click", { preventDefault: vi.fn() })
    expect(c.doc.activeElement).toBe(c.el)
    expect(c.doc.execCommand).toHaveBeenCalledWith("insertText", false, "@")
  })

  it("puts a space before the @ after a word", () => {
    const c = richComposer()
    hydrate(c.el, "hey")
    c.el.focus()
    c.ctx.selection = caret(c.el.firstChild, 3)
    c.at.fire("click", { preventDefault: vi.fn() })
    expect(c.doc.execCommand).toHaveBeenCalledWith("insertText", false, " @")
  })
})

describe("ComposeInput textarea path (steering composer) is unchanged", () => {
  afterEach(() => vi.unstubAllGlobals())

  function steering(coarse) {
    const doc = { activeElement: null }
    vi.stubGlobal("document", doc)
    vi.stubGlobal("window", { scrollTo: vi.fn(), matchMedia: () => ({ matches: coarse }) })
    vi.stubGlobal("CSS", { supports: () => true })
    const form = { id: "steering-form", requestSubmit: vi.fn(), addEventListener() {} }
    const el = fakeTextarea(doc)
    el.value = "steer this"
    el.closest = (sel) => (sel === "form" ? form : null)
    const hook = Object.create(ComposeInput)
    hook.el = el
    hook.pushEvent = vi.fn()
    hook.mounted()
    return { el, form }
  }

  it("keeps Enter as a newline on a coarse pointer (send via the button)", () => {
    const { el, form } = steering(true)
    const e = { key: "Enter", preventDefault: vi.fn() }
    el.fire("keydown", e)
    expect(e.preventDefault).not.toHaveBeenCalled()
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("sends on Enter on a fine pointer", () => {
    const { el, form } = steering(false)
    el.fire("keydown", { key: "Enter", preventDefault: vi.fn() })
    expect(form.requestSubmit).toHaveBeenCalledTimes(1)
  })
})

describe("shouldRestoreFocusAfterMove (a patch that moves the chip field)", () => {
  // LiveView restores focus only for textual inputs; a patch that inserts the
  // mention list or the staged tray before the field re-appends it, and the
  // contenteditable would lose focus (and the phone keyboard) mid-sentence.
  const doc = fakeDocument()
  const body = doc.createElement("body")
  const pill = doc.createElement("div")
  const el = doc.createElement("div")
  pill.appendChild(el)

  it("restores when the field's ancestor was moved and focus fell to the body", () => {
    expect(shouldRestoreFocusAfterMove([{ removedNodes: [pill] }], el, body, body)).toBe(true)
    expect(shouldRestoreFocusAfterMove([{ removedNodes: [el] }], el, null, body)).toBe(true)
  })

  it("leaves focus alone when it went to another control, or nothing moved the field", () => {
    const other = doc.createElement("button")
    expect(shouldRestoreFocusAfterMove([{ removedNodes: [pill] }], el, other, body)).toBe(false)
    expect(shouldRestoreFocusAfterMove([{ removedNodes: [other] }], el, body, body)).toBe(false)
    expect(shouldRestoreFocusAfterMove([{ removedNodes: [] }], el, body, body)).toBe(false)
  })
})

// ── The thread reply box (redesign rung 10, stage 4) ───────────────────
//
// A form submit as the browser and LiveView run it: the form's own submit
// listeners first, then LiveView's window-level listener (registered when
// the socket connected, so before the hook's), which serializes the form
// and blurs the active element (`submitForm` -> `blurActiveElement`), then
// the hook's own window-level listener. Returns what LiveView serialized.
function submit(c) {
  const e = { target: c.form }
  c.form.fire("submit", e)
  const sent = c.hidden.value
  if (c.doc.activeElement) {
    const was = c.doc.activeElement
    c.doc.activeElement = null
    if (was.fire) was.fire("blur")
  }
  for (const fn of c.windowListeners.submit || []) fn({ type: "submit", ...e })
  return sent
}

describe("ComposeInput thread reply box: draft, clear after send, Send", () => {
  beforeEach(() => {
    store.clear()
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it("keeps its draft under thread-draft:<id>, apart from the space's, and both restore", () => {
    const space = richComposer()
    type(space, "space words")
    vi.unstubAllGlobals()
    const thread = richComposer({ thread: "msg-1" })
    type(thread, "thread @[Builder] words")
    vi.unstubAllGlobals()

    expect(thread.ids.draft).not.toBe(space.ids.draft)
    expect(store.get("compose:chat-draft:space-1")).toBe("space words")
    expect(store.get("compose:thread-draft:msg-1")).toBe("thread @[Builder] words")

    // A reload: each field restores its own draft and only its own.
    const s2 = richComposer()
    expect(serialize(s2.el)).toBe("space words")
    vi.unstubAllGlobals()
    const t2 = richComposer({ thread: "msg-1" })
    expect(serialize(t2.el)).toBe("thread @[Builder] words")
    expect(t2.hidden.value).toBe("thread @[Builder] words")
    vi.unstubAllGlobals()
    const other = richComposer({ thread: "msg-2" })
    expect(serialize(other.el)).toBe("")
  })

  it("clears the field, its value input and its draft after a send, with the value sent first", () => {
    const c = richComposer({ thread: "msg-1" })
    c.el.focus()
    type(c, "reply to @[Builder]")
    expect(c.send.disabled).toBe(false)

    const sent = submit(c)
    expect(sent).toBe("reply to @[Builder]")

    vi.runAllTimers()
    expect(c.el.childNodes).toHaveLength(0)
    expect(c.hidden.value).toBe("")
    expect(store.has("compose:thread-draft:msg-1")).toBe(false)
    expect(c.send.disabled).toBe(true)
  })

  it("Enter sends a thread reply and the clear still follows LiveView's read", () => {
    const c = richComposer({ thread: "msg-1" })
    c.el.focus()
    type(c, "quick reply")
    c.form.requestSubmit = vi.fn(() => {
      c.sent = submit(c)
    })
    key(c, "Enter")
    expect(c.sent).toBe("quick reply")
    vi.runAllTimers()
    expect(serialize(c.el)).toBe("")
  })

  it("ignores the space composer's compose_reset; the space composer still takes it", () => {
    const t = richComposer({ thread: "msg-1" })
    type(t, "half a reply")
    t.handlers.compose_reset()
    expect(serialize(t.el)).toBe("half a reply")
    expect(store.get("compose:thread-draft:msg-1")).toBe("half a reply")
    vi.unstubAllGlobals()

    const s = richComposer()
    type(s, "sent")
    s.handlers.compose_reset()
    expect(serialize(s.el)).toBe("")
  })

  it("Send is disabled while the field is empty or only spaces", () => {
    const c = richComposer({ thread: "msg-1" })
    expect(c.send.disabled).toBe(true)
    type(c, "   ")
    expect(c.send.disabled).toBe(true)
    type(c, "ok")
    expect(c.send.disabled).toBe(false)
  })

  it("a submit in flight (data-phx-disabled) is left to LiveView", () => {
    const c = richComposer({ thread: "msg-1" })
    type(c, "ok")
    c.send.setAttribute("data-phx-disabled", "false")
    c.send.disabled = true
    type(c, "ok more")
    expect(c.send.disabled).toBe(true)
  })
})

describe("ComposeInput: focus stays in the field after a send", () => {
  beforeEach(() => {
    store.clear()
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  for (const thread of [null, "msg-1"]) {
    const which = thread ? "thread reply box" : "space composer"

    it(`the ${which} keeps document.activeElement through LiveView's blur, caret at the end`, () => {
      const c = richComposer({ thread })
      const placed = []
      c.doc.createRange = () => ({
        setStart(node, offset) {
          this.node = node
          this.offset = offset
        },
        collapse() {},
      })
      c.ctx.selection = {
        rangeCount: 0,
        anchorNode: null,
        removeAllRanges() {},
        addRange: (r) => placed.push(r),
      }
      c.el.focus()
      type(c, "hello there")

      submit(c)
      expect(c.doc.activeElement).toBe(c.el)
      const last = placed.at(-1)
      expect(last.node).toBe(c.el)
      expect(last.offset).toBe(c.el.childNodes.length)

      vi.runAllTimers()
      expect(c.doc.activeElement).toBe(c.el)
    })
  }

  it("does not take focus when the field did not have it (Send tapped, keyboard down)", () => {
    const c = richComposer({ thread: "msg-1" })
    type(c, "hello")
    const other = c.doc.createElement("button")
    other.focus()
    submit(c)
    vi.runAllTimers()
    expect(c.doc.activeElement).not.toBe(c.el)
  })
})
