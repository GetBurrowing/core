import { describe, it, expect, beforeEach } from "vitest"
import {
  installNavPending,
  rollbackMessage,
  renderToast,
  NAV_PENDING_TIMEOUT_MS,
} from "../../js/lib/nav_pending.js"

/**
 * Optimistic navigation (task 01a166be-b5b9 stage 2, ./js/lib/nav_pending.js).
 * vitest runs in plain node here (no jsdom in this repo), so the shell is a
 * small fake DOM: elements with attributes, classes, parent/children,
 * `matches`/`closest`/`querySelector(All)` over compound selectors and
 * selector lists (all the module uses). A fake clock drives the timeout.
 */

function parseCompound(sel) {
  const s = sel.trim()
  const out = { tag: null, classes: [], attrs: [] }
  const re = /^[a-z]+|\.[\w-]+|\[([\w-]+)(?:="([^"]*)")?\]/g
  let m
  let consumed = 0
  while ((m = re.exec(s))) {
    if (m.index !== consumed) throw new Error(`fake DOM cannot parse ${sel}`)
    consumed = re.lastIndex
    if (m[0][0] === ".") out.classes.push(m[0].slice(1))
    else if (m[0][0] === "[") out.attrs.push([m[1], m[2]])
    else out.tag = m[0]
  }
  if (consumed !== s.length) throw new Error(`fake DOM cannot parse ${sel}`)
  return out
}

class FakeEl {
  constructor(doc, tag, { cls = [], attrs = {}, text = "" } = {}) {
    this.doc = doc
    this.tagName = tag
    this.attrs = new Map(Object.entries(attrs))
    this.classes = new Set(cls)
    this.children = []
    this.parent = null
    this.textContent = text
    this.listeners = {}
    const self = this
    this.classList = {
      add: (c) => self.classes.add(c),
      remove: (c) => self.classes.delete(c),
      contains: (c) => self.classes.has(c),
    }
  }
  set className(v) {
    this.classes = new Set(v.split(/\s+/).filter(Boolean))
  }
  get className() {
    return [...this.classes].join(" ")
  }
  set id(v) {
    this.attrs.set("id", v)
  }
  get id() {
    return this.attrs.get("id")
  }
  getAttribute(n) {
    return this.attrs.has(n) ? this.attrs.get(n) : null
  }
  setAttribute(n, v) {
    this.attrs.set(n, String(v))
  }
  removeAttribute(n) {
    this.attrs.delete(n)
  }
  hasAttribute(n) {
    return this.attrs.has(n)
  }
  appendChild(c) {
    c.parent = this
    this.children.push(c)
    return c
  }
  remove() {
    if (!this.parent) return
    this.parent.children = this.parent.children.filter((c) => c !== this)
    this.parent = null
  }
  get isConnected() {
    let n = this
    while (n.parent) n = n.parent
    return n === this.doc.body
  }
  addEventListener(t, fn) {
    this.listeners[t] = fn
  }
  matchesOne(sel) {
    const c = parseCompound(sel)
    if (c.tag && c.tag !== this.tagName) return false
    if (!c.classes.every((k) => this.classes.has(k))) return false
    return c.attrs.every(([n, v]) => this.attrs.has(n) && (v === undefined || this.attrs.get(n) === v))
  }
  matches(list) {
    return list.split(",").some((s) => this.matchesOne(s))
  }
  closest(list) {
    let n = this
    while (n && n !== this.doc.body) {
      if (n.matches(list)) return n
      n = n.parent
    }
    return null
  }
  querySelectorAll(list) {
    const out = []
    const walk = (n) => {
      for (const c of n.children) {
        if (c.matches(list)) out.push(c)
        walk(c)
      }
    }
    walk(this)
    return out
  }
  querySelector(list) {
    return this.querySelectorAll(list)[0] || null
  }
}

function fakeDoc() {
  const doc = {}
  doc.body = new FakeEl(doc, "body")
  doc.createElement = (tag) => new FakeEl(doc, tag)
  doc.querySelector = (s) => doc.body.querySelector(s)
  doc.querySelectorAll = (s) => doc.body.querySelectorAll(s)
  doc.getElementById = (id) => doc.body.querySelectorAll(`[id="${id}"]`)[0] || null
  return doc
}

function el(doc, parent, tag, opts) {
  return parent.appendChild(new FakeEl(doc, tag, opts))
}

function fakeClock() {
  let t = 0
  const timers = []
  return {
    setTimer: (fn, ms) => {
      const timer = { fn, at: t + ms, cleared: false }
      timers.push(timer)
      return timer
    },
    clearTimer: (timer) => {
      if (timer) timer.cleared = true
    },
    advance(ms) {
      t += ms
      for (const x of timers) {
        if (!x.cleared && x.at <= t) {
          x.cleared = true
          x.fn()
        }
      }
    },
  }
}

function fakeWin(path) {
  const listeners = {}
  const win = {
    location: { href: `https://app.test${path}`, pathname: path },
    addEventListener: (t, fn) => {
      listeners[t] = fn
    },
    removeEventListener: (t) => {
      delete listeners[t]
    },
    go(p) {
      win.location.href = `https://app.test${p}`
      win.location.pathname = p
    },
    fire(t, e) {
      if (listeners[t]) listeners[t](e)
    },
  }
  return win
}

// The phone shell on /chat: bottom bar (Chat current), More sheet, chat list.
function shell(doc) {
  const nav = el(doc, doc.body, "nav", { cls: ["bottom-nav"] })
  const tab = (key, label, active) =>
    el(doc, nav, "a", {
      cls: ["bottom-nav-tab", ...(active ? ["bottom-nav-tab--active"] : [])],
      attrs: {
        href: `/${key}`,
        "data-destination": key,
        "data-nav-label": label,
        ...(active ? { "aria-current": "page" } : {}),
      },
    })
  const chat = tab("chat", "Chat", true)
  const tasks = tab("tasks", "Tasks", false)
  const meetings = tab("meetings", "Meetings", false)
  const more = el(doc, nav, "button", { cls: ["bottom-nav-tab"], attrs: { "data-destination": "more" } })
  const moreIcon = el(doc, more, "span", { cls: ["bottom-nav-icon"] })

  const sheet = el(doc, doc.body, "div", { cls: ["sheet", "more-sheet", "sheet-open"] })
  const files = el(doc, sheet, "a", {
    cls: ["more-sheet-row"],
    attrs: { href: "/files", "data-destination": "files", "data-nav-label": "Files" },
  })

  const list = el(doc, doc.body, "div", {})
  const row = (id, name) => {
    const a = el(doc, list, "a", {
      cls: ["chat-list-row"],
      attrs: { href: `/chat/${id}`, "data-role": "chat-list-row" },
    })
    el(doc, a, "span", { cls: ["truncate"], text: name })
    return a
  }
  return { nav, chat, tasks, meetings, more, moreIcon, files, rowA: row("a", "general"), rowB: row("b", "design") }
}

const click = (target, extra = {}) => ({ target, button: 0, ...extra })
const pendingEls = (doc) => doc.querySelectorAll("[data-nav-pending]")

describe("nav_pending", () => {
  let doc, win, clock, toasts, rollbacks, dismissed, s, api

  beforeEach(() => {
    doc = fakeDoc()
    win = fakeWin("/chat")
    clock = fakeClock()
    toasts = []
    rollbacks = []
    dismissed = []
    s = shell(doc)
    api = installNavPending({
      win,
      doc,
      setTimer: clock.setTimer,
      clearTimer: clock.clearTimer,
      showToast: (m) => toasts.push(m),
      dismissToast: () => dismissed.push(true),
      onRollback: (info) => rollbacks.push(info),
    })
  })

  it("the timeout is 8 seconds", () => {
    expect(NAV_PENDING_TIMEOUT_MS).toBe(8000)
  })

  it("a tapped tab takes the current look and the previous current tab yields it, at once", () => {
    // LiveView's own class arrives in the same click; the module keys on the tap.
    s.tasks.classList.add("phx-click-loading")
    win.fire("click", click(s.tasks))
    expect(s.tasks.hasAttribute("data-nav-pending")).toBe(true)
    expect(s.chat.hasAttribute("data-nav-yielded")).toBe(true)
    expect(pendingEls(doc)).toEqual([s.tasks])
  })

  it("a matching page-loading-stop clears pending without a toast", () => {
    win.fire("click", click(s.tasks))
    win.go("/tasks")
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/tasks", kind: "redirect" } })
    expect(pendingEls(doc)).toEqual([])
    expect(s.chat.hasAttribute("data-nav-yielded")).toBe(false)
    expect(toasts).toEqual([])
    clock.advance(NAV_PENDING_TIMEOUT_MS + 1000)
    expect(toasts).toEqual([])
  })

  it("a stop for the target whose location does not match rolls back and toasts", () => {
    s.tasks.classList.add("phx-click-loading")
    win.fire("click", click(s.tasks))
    // location stays /chat
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/tasks", kind: "redirect" } })
    expect(s.tasks.hasAttribute("data-nav-pending")).toBe(false)
    expect(s.tasks.classList.contains("phx-click-loading")).toBe(false)
    expect(s.chat.hasAttribute("data-nav-yielded")).toBe(false)
    expect(toasts).toEqual(["Couldn't open Tasks. Try again."])
    expect(rollbacks).toEqual([{ reason: "mismatch", path: "/tasks" }])
  })

  it("a stop for some other navigation is not this tap's verdict", () => {
    win.fire("click", click(s.tasks))
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/chat", kind: "initial" } })
    expect(pendingEls(doc)).toEqual([s.tasks])
    expect(toasts).toEqual([])
  })

  it("no stop within the timeout rolls back and toasts", () => {
    s.tasks.classList.add("phx-click-loading")
    win.fire("click", click(s.tasks))
    clock.advance(NAV_PENDING_TIMEOUT_MS - 1)
    expect(pendingEls(doc)).toEqual([s.tasks])
    expect(toasts).toEqual([])
    clock.advance(1)
    expect(pendingEls(doc)).toEqual([])
    expect(s.tasks.classList.contains("phx-click-loading")).toBe(false)
    expect(s.chat.hasAttribute("data-nav-yielded")).toBe(false)
    expect(toasts).toEqual(["Couldn't open Tasks. Try again."])
    expect(rollbacks).toEqual([{ reason: "timeout", path: "/tasks" }])
  })

  it("a navigation that lands after the timeout withdraws the failure toast", () => {
    win.fire("click", click(s.tasks))
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    expect(toasts).toEqual(["Couldn't open Tasks. Try again."])
    expect(dismissed).toEqual([])
    win.go("/tasks")
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/tasks", kind: "redirect" } })
    expect(dismissed).toEqual([true])
  })

  it("a late stop that still does not land keeps the failure toast", () => {
    win.fire("click", click(s.tasks))
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/tasks", kind: "redirect" } })
    win.go("/meetings")
    win.fire("phx:page-loading-stop", { detail: { to: "https://app.test/meetings", kind: "redirect" } })
    expect(dismissed).toEqual([])
  })

  it("a second tap leaves exactly one pending element", () => {
    win.fire("click", click(s.tasks))
    s.tasks.classList.add("phx-click-loading")
    win.fire("click", click(s.meetings))
    expect(pendingEls(doc)).toEqual([s.meetings])
    expect(s.tasks.classList.contains("phx-click-loading")).toBe(false)
    // the first tap's timer is gone: only one verdict, for Meetings
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    expect(toasts).toEqual(["Couldn't open Meetings. Try again."])
  })

  it("only one chat row carries the pending bar", () => {
    win.fire("click", click(s.rowA))
    win.fire("click", click(s.rowB))
    expect(pendingEls(doc)).toEqual([s.rowB])
    win.go("/chat/b")
    win.fire("phx:page-loading-stop", { detail: { to: "/chat/b", kind: "patch" } })
    expect(pendingEls(doc)).toEqual([])
  })

  it("a chat row's rollback names the conversation", () => {
    win.fire("click", click(s.rowA))
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    expect(toasts).toEqual(["Couldn't open general. Try again."])
  })

  it("a More row marks the row and moves the pending cue to the More tab", () => {
    win.fire("click", click(s.files))
    expect(pendingEls(doc).sort((a, b) => (a === s.files ? -1 : 1))).toEqual([s.files, s.more])
    // Chat was current in the bar, More takes the cue, so Chat yields
    expect(s.chat.hasAttribute("data-nav-yielded")).toBe(true)
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    expect(pendingEls(doc)).toEqual([])
    expect(toasts).toEqual(["Couldn't open Files. Try again."])
  })

  it("a tap inside a tab (on its icon) still resolves to the tab", () => {
    win.fire("click", click(el(doc, s.tasks, "span", { cls: ["bottom-nav-icon"] })))
    expect(pendingEls(doc)).toEqual([s.tasks])
  })

  it("the More button (no href) and modified clicks start nothing", () => {
    win.fire("click", click(s.moreIcon))
    win.fire("click", click(s.tasks, { metaKey: true }))
    expect(pendingEls(doc)).toEqual([])
  })

  it("a control replaced by the destination's render clears quietly at the timeout", () => {
    win.fire("click", click(s.tasks))
    s.nav.remove()
    clock.advance(NAV_PENDING_TIMEOUT_MS)
    expect(api.pending()).toBe(null)
    expect(toasts).toEqual([])
  })
})

describe("rollback toast", () => {
  it("reads one line with the destination label", () => {
    expect(rollbackMessage("Tasks")).toBe("Couldn't open Tasks. Try again.")
    expect(rollbackMessage("")).toBe("Couldn't open that page. Try again.")
  })

  it("renders on the flash toast surface with an error-slot icon, replacing any earlier one", () => {
    const doc = fakeDoc()
    renderToast(doc, "first")
    const t = renderToast(doc, "Couldn't open Tasks. Try again.")
    expect(doc.body.querySelectorAll('[data-role="nav-rollback-toast"]')).toEqual([t])
    expect(t.getAttribute("role")).toBe("alert")
    expect(t.classList.contains("toast")).toBe(true)
    const [alert] = t.children
    const [icon, text] = alert.children
    expect(icon.classList.contains("text-error")).toBe(true)
    expect(icon.classList.contains("hero-exclamation-circle")).toBe(true)
    expect(text.textContent).toBe("Couldn't open Tasks. Try again.")
  })
})
