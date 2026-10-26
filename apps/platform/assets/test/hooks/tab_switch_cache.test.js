import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import {
  createTabSwitchCache,
  createSnapshotCache,
  skeletonKind,
  CACHE_CAP,
  FAST_MS,
  MAX_AGE_MS,
  TIMEOUT_MS,
  UP_TO_DATE_GONE_MS,
} from "../../js/hooks/tab_switch_cache.js"

/**
 * TabSwitchCache (cached-first + shimmer skeleton). This suite has no DOM
 * library, so the shell is a small element tree below with the operations
 * and the selector forms the module uses (compound selectors, comma lists,
 * `[a]`, `[a="v"]`, `[a*="v"]`). Paint and time are driven by hand.
 */

// ── A minimal element tree ─────────────────────────────────────────────────

function parseCompound(src) {
  const out = { tag: null, parts: [] }
  const re = /^(\*|[a-z][a-z0-9-]*)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:(\*?=)"([^"]*)")?\]/gi
  let m
  let pos = 0
  while ((m = re.exec(src))) {
    if (m.index !== pos) throw new Error(`fake selector cannot parse: ${src}`)
    pos = re.lastIndex
    const [, tag, id, cls, name, op, val] = m
    if (tag) out.tag = tag === "*" ? null : tag.toLowerCase()
    else if (id) out.parts.push((el) => el.getAttribute("id") === id)
    else if (cls) out.parts.push((el) => el.classList.contains(cls))
    else if (name) {
      out.parts.push((el) => {
        if (!el.hasAttribute(name)) return false
        if (!op) return true
        const v = el.getAttribute(name)
        return op === "=" ? v === val : v.includes(val)
      })
    }
  }
  if (pos !== src.length) throw new Error(`fake selector cannot parse: ${src}`)
  return out
}

function matcher(selector) {
  const alts = selector.split(",").map((s) => parseCompound(s.trim()))
  return (el) => alts.some((c) => (!c.tag || el.tagName.toLowerCase() === c.tag) && c.parts.every((p) => p(el)))
}

class El {
  constructor(doc, tag) {
    this.ownerDocument = doc
    this.tagName = tag.toUpperCase()
    this.attrs = new Map()
    this.children = []
    this.parentNode = null
    this.text = ""
    this.style = {}
    this.scrollTop = 0
    if (tag === "template") this.content = new El(doc, "#fragment")
    const self = this
    this.classList = {
      add: (...c) => self._setClasses([...self._classes(), ...c]),
      remove: (...c) => self._setClasses(self._classes().filter((x) => !c.includes(x))),
      contains: (c) => self._classes().includes(c),
    }
  }

  _classes() {
    return (this.attrs.get("class") || "").split(/\s+/).filter(Boolean)
  }

  _setClasses(list) {
    this.attrs.set("class", Array.from(new Set(list)).join(" "))
  }

  get className() {
    return this.attrs.get("class") || ""
  }

  set className(v) {
    this.attrs.set("class", v)
  }

  get textContent() {
    return this.text + this.children.map((c) => c.textContent).join("")
  }

  set textContent(v) {
    this.children = []
    this.text = v
  }

  getAttribute(n) {
    return this.attrs.has(n) ? this.attrs.get(n) : null
  }

  setAttribute(n, v) {
    this.attrs.set(n, String(v))
  }

  hasAttribute(n) {
    return this.attrs.has(n)
  }

  removeAttribute(n) {
    this.attrs.delete(n)
  }

  getAttributeNames() {
    return Array.from(this.attrs.keys())
  }

  appendChild(node) {
    if (node.tagName === "#FRAGMENT") {
      for (const c of [...node.children]) this.appendChild(c)
      return node
    }
    if (node.parentNode) node.remove()
    node.parentNode = this
    this.children.push(node)
    return node
  }

  remove() {
    if (!this.parentNode) return
    const sibs = this.parentNode.children
    sibs.splice(sibs.indexOf(this), 1)
    this.parentNode = null
  }

  replaceWith(node) {
    const parent = this.parentNode
    const i = parent.children.indexOf(this)
    if (node.parentNode) node.remove()
    parent.children.splice(i, 1, node)
    node.parentNode = parent
    this.parentNode = null
  }

  cloneNode(deep) {
    const c = new El(this.ownerDocument, this.tagName.toLowerCase())
    c.attrs = new Map(this.attrs)
    c.text = this.text
    if (deep) for (const ch of this.children) c.appendChild(ch.cloneNode(true))
    if (this.content && deep) c.content = this.content.cloneNode(true)
    return c
  }

  get isConnected() {
    let n = this
    while (n.parentNode) n = n.parentNode
    return n === this.ownerDocument.documentElement
  }

  _descendants() {
    const out = []
    const walk = (n) => {
      for (const c of n.children) {
        out.push(c)
        walk(c)
      }
    }
    walk(this)
    return out
  }

  querySelectorAll(sel) {
    return this._descendants().filter(matcher(sel))
  }

  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }

  matches(sel) {
    return matcher(sel)(this)
  }

  closest(sel) {
    const m = matcher(sel)
    for (let n = this; n && n.tagName !== "#FRAGMENT"; n = n.parentNode) if (n.tagName && m(n)) return n
    return null
  }
}

function h(doc, tag, attrs = {}, ...kids) {
  const el = new El(doc, tag)
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v)
  for (const k of kids) {
    if (typeof k === "string") el.text += k
    else el.appendChild(k)
  }
  return el
}

function fakeDocument() {
  const doc = {}
  doc.documentElement = new El(doc, "html")
  doc.body = new El(doc, "body")
  doc.documentElement.appendChild(doc.body)
  doc.createElement = (tag) => new El(doc, tag)
  doc.getElementById = (id) => doc.documentElement.querySelector(`#${id}`)
  doc.querySelector = (sel) => doc.documentElement.querySelector(sel)
  doc.querySelectorAll = (sel) => doc.documentElement.querySelectorAll(sel)
  return doc
}

function storageSpy() {
  return {
    getItem: vi.fn(() => null),
    setItem: vi.fn(),
    removeItem: vi.fn(),
    clear: vi.fn(),
    key: vi.fn(() => null),
    length: 0,
  }
}

function fakeWindow() {
  const listeners = new Map()
  return {
    localStorage: storageSpy(),
    sessionStorage: storageSpy(),
    addEventListener: (type, fn) => {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type).add(fn)
    },
    removeEventListener: (type, fn) => listeners.get(type)?.delete(fn),
    dispatch(type, event) {
      for (const fn of listeners.get(type) || []) fn(event)
    },
  }
}

// ── The shell ─────────────────────────────────────────────────────────────

const TEMPLATE_ROWS = { chat: 7, tasks: 9, inbox: 4, generic: 7 }

function skeletonTemplates(doc, hook) {
  for (const [kind, rows] of Object.entries(TEMPLATE_ROWS)) {
    const tpl = h(doc, "template", { "data-skeleton": kind })
    for (let i = 0; i < rows; i++) tpl.content.appendChild(h(doc, "div", { class: "tsc-row", "data-skeleton-row": "" }))
    hook.appendChild(tpl)
  }
}

// A page as the destination's LiveView would render it: ids, bindings, a
// scroller, and names in the text.
function page(doc, key, text) {
  const list = h(
    doc,
    "div",
    { id: `${key}-list`, class: "overflow-y-auto", "phx-hook": "ScrollToBottom" },
    h(doc, "a", { id: `${key}-row`, "phx-click": "open", "data-phx-link": "redirect", href: "#" }, text),
    h(doc, "iframe", { src: "/embed", class: "size-40" }),
  )
  return h(doc, "div", { id: `${key}-page`, class: "h-full", "data-in-call": "" }, list)
}

function mountShell(doc, { current, user = "u1", masked = false, text = "Sample Person" }) {
  const root = h(doc, "div", { id: "shell" })
  const hook = h(doc, "div", {
    id: "tab-switch-cache",
    "phx-hook": "TabSwitchCache",
    "data-current": current,
    "data-user": user,
    "data-masked": String(masked),
  })
  skeletonTemplates(doc, hook)
  const main = h(
    doc,
    "main",
    { "data-scroll-container": "" },
    h(doc, "div", { id: "connection-status" }),
    page(doc, current, text),
  )
  const nav = h(doc, "nav", { class: "bottom-nav", "data-bottom-rail": "" })
  for (const key of ["chat", "tasks", "meetings"]) {
    nav.appendChild(
      h(doc, "a", { class: "bottom-nav-tab", href: `/${key}`, "data-destination": key, "data-nav-label": key.toUpperCase() }, key),
    )
  }
  nav.appendChild(h(doc, "button", { class: "bottom-nav-tab", "data-destination": "more" }, "More"))
  const sheet = h(doc, "nav", { class: "more-sheet-list" })
  for (const key of ["inbox", "files", "skills", "agents", "context", "changelog"]) {
    sheet.appendChild(h(doc, "a", { class: "more-sheet-row", href: `/${key}`, "data-destination": key }, key))
  }
  const title = h(doc, "span", { "data-role": "phone-top-bar-title" }, current)
  root.appendChild(title)
  const mask = h(doc, "button", { "phx-click": "toggle_mask_names" }, "Mask names")
  const logout = h(doc, "a", { href: "/auth/logout" }, "Log out")
  root.appendChild(hook)
  root.appendChild(main)
  root.appendChild(nav)
  root.appendChild(sheet)
  root.appendChild(mask)
  root.appendChild(logout)
  // Replace any previous shell, as a navigate's replaceMain does.
  const old = doc.getElementById("shell")
  if (old) old.replaceWith(root)
  else doc.body.appendChild(root)
  return { root, hook, main }
}

const mainOf = (doc) => doc.querySelector("main")
const layerOf = (doc) => doc.querySelector(".tab-switch-layer")
const control = (doc, key) => doc.querySelector(`[data-destination="${key}"]`)

function setup(opts = {}) {
  const doc = fakeDocument()
  const win = fakeWindow()
  let t = 0
  const timers = []
  const paints = []
  const ctl = createTabSwitchCache({
    win,
    doc,
    now: () => t,
    setTimer: (fn, ms) => {
      const timer = { at: t + ms, fn, done: false }
      timers.push(timer)
      return timer
    },
    clearTimer: (timer) => {
      if (timer) timer.done = true
    },
    afterPaint: (fn) => paints.push(fn),
    ...opts,
  })
  const env = {
    doc,
    win,
    ctl,
    paint() {
      while (paints.length) paints.shift()()
    },
    advance(ms) {
      t += ms
      for (const timer of timers) {
        if (!timer.done && timer.at <= t) {
          timer.done = true
          timer.fn()
        }
      }
    },
    shell(o) {
      const s = mountShell(doc, o)
      ctl.sync(s.hook)
      return s
    },
    tap(key, extra = {}) {
      const target = control(doc, key)
      win.dispatch("click", { target, button: 0, ...extra })
      return target
    },
    // The server's answer: LiveView swaps the shell for the destination's,
    // then sends the stop.
    land(key, o = {}, ms = 200) {
      env.advance(ms)
      env.shell({ current: key, ...o })
      win.dispatch("phx:page-loading-stop", { detail: { kind: "redirect", to: `/${key}` } })
    },
    // Tap and land, painting in between so the departure is snapshotted.
    visit(key, o = {}, ms = 200) {
      env.tap(key)
      env.paint()
      env.land(key, o, ms)
    },
  }
  return env
}

describe("TabSwitchCache", () => {
  let env

  beforeEach(() => {
    env = setup()
  })

  afterEach(() => {
    env.ctl.dispose()
  })

  it("shows the cached snapshot on a revisit, inert and stripped of live bindings", () => {
    env.shell({ current: "chat", text: "Sample Person" })
    env.visit("tasks")
    expect(env.ctl.cache.keys()).toEqual(["chat"])

    env.tap("chat")
    const layer = layerOf(env.doc)
    expect(layer).not.toBeNull()
    expect(layer.parentNode).toBe(mainOf(env.doc))
    expect(layer.getAttribute("data-mode")).toBe("cached")
    expect(layer.getAttribute("aria-busy")).toBe("true")

    const snap = layer.querySelector(".tab-switch-snapshot")
    expect(snap.hasAttribute("inert")).toBe(true)
    expect(snap.textContent).toContain("Sample Person")
    // No ids, no phx bindings, no document-wide signals, no live media.
    for (const el of [snap, ...snap.querySelectorAll("*")]) {
      for (const name of el.getAttributeNames()) {
        expect(name === "id" || name.startsWith("phx-") || name.startsWith("data-phx-")).toBe(false)
        expect(name).not.toBe("data-in-call")
      }
    }
    expect(snap.querySelectorAll("iframe")).toHaveLength(0)
    // The Updating chip.
    const chip = layer.querySelector('[data-role="tab-switch-updating"]')
    expect(chip.textContent).toBe("Updating")
    expect(chip.getAttribute("role")).toBe("status")
  })

  it("restores the snapshot's scroll position", () => {
    const { main } = env.shell({ current: "chat" })
    main.querySelector("#chat-list").scrollTop = 420
    env.visit("tasks")
    env.tap("chat")
    const scroller = layerOf(env.doc).querySelector(".overflow-y-auto")
    expect(scroller.scrollTop).toBe(420)
  })

  it("shows a skeleton shaped like the destination on a first visit", () => {
    env.shell({ current: "chat" })
    env.tap("tasks")
    let layer = layerOf(env.doc)
    expect(layer.getAttribute("data-mode")).toBe("skeleton")
    const body = layer.querySelector(".tab-switch-skeleton")
    expect(body.getAttribute("data-skeleton")).toBe("tasks")
    expect(body.hasAttribute("inert")).toBe(true)
    expect(body.classList.contains("tab-switch-shimmer")).toBe(true)
    expect(body.querySelectorAll("[data-skeleton-row]")).toHaveLength(TEMPLATE_ROWS.tasks)
    expect(layer.querySelector('[data-role="tab-switch-updating"]')).toBeNull()

    env.tap("inbox")
    layer = layerOf(env.doc)
    expect(layer.querySelector(".tab-switch-skeleton").getAttribute("data-skeleton")).toBe("inbox")

    env.tap("meetings")
    layer = layerOf(env.doc)
    expect(layer.querySelector(".tab-switch-skeleton").getAttribute("data-skeleton")).toBe("generic")
  })

  it("maps destinations to skeleton shapes", () => {
    expect(skeletonKind("chat")).toBe("chat")
    expect(skeletonKind("tasks")).toBe("tasks")
    expect(skeletonKind("inbox")).toBe("inbox")
    expect(skeletonKind("meetings")).toBe("generic")
    expect(skeletonKind("settings")).toBe("generic")
  })

  it("leaves the More button, the current destination and modified clicks alone", () => {
    env.shell({ current: "chat" })
    env.tap("more")
    env.tap("chat")
    env.tap("tasks", { metaKey: true })
    expect(layerOf(env.doc)).toBeNull()
  })

  it("removes the placeholder when the live render lands", () => {
    env.shell({ current: "chat" })
    env.tap("tasks")
    expect(layerOf(env.doc)).not.toBeNull()
    env.land("tasks")
    expect(layerOf(env.doc)).toBeNull()
    expect(env.ctl.pending()).toBeNull()
  })

  it("shows Up to date after a cached view that was on screen, not after a fast one", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.visit("chat", {}, FAST_MS - 30)
    expect(env.doc.querySelector('[data-role="tab-switch-done"]')).toBeNull()

    env.visit("tasks", {}, FAST_MS + 200)
    const done = env.doc.querySelector('[data-role="tab-switch-done"]')
    expect(done).not.toBeNull()
    expect(done.textContent).toBe("Up to date")
    // On <body>, out of reach of the new page's patches.
    expect(done.parentNode).toBe(env.doc.body)
    expect(done.classList.contains("tab-switch-chip--floating")).toBe(true)
    // The next tap takes it down at once, ahead of its own timer.
    env.tap("chat")
    expect(env.doc.querySelector('[data-role="tab-switch-done"]')).toBeNull()
    env.advance(UP_TO_DATE_GONE_MS)
    expect(env.doc.querySelector('[data-role="tab-switch-done"]')).toBeNull()
  })

  it("waits for the new pane when the stop arrives before it", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.tap("chat")
    env.paint()
    env.advance(FAST_MS + 200)
    // LiveView's redirect stop, with the old shell gone and the new one not in yet.
    env.doc.getElementById("shell").remove()
    env.win.dispatch("phx:page-loading-stop", { detail: { kind: "redirect", to: "/chat" } })
    expect(env.doc.querySelector('[data-role="tab-switch-done"]')).toBeNull()
    env.shell({ current: "chat" })
    env.advance(16)
    expect(env.doc.querySelector('[data-role="tab-switch-done"]')).not.toBeNull()
  })

  it("lets the latest tap win", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.visit("chat")
    expect(env.ctl.cache.keys()).toEqual(["tasks"])

    env.tap("tasks")
    env.tap("inbox")
    env.tap("files")
    const layers = mainOf(env.doc).querySelectorAll(".tab-switch-layer")
    expect(layers).toHaveLength(1)
    expect(layers[0].getAttribute("data-destination")).toBe("files")
    // The superseded cached view went back in the cache, unconsumed.
    expect(env.ctl.cache.has("tasks")).toBe(true)

    env.paint()
    env.land("files")
    expect(layerOf(env.doc)).toBeNull()
    expect(env.ctl.pending()).toBeNull()
  })

  it("gives up after the timeout and keeps the cached view", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.tap("chat")
    expect(env.ctl.cache.has("chat")).toBe(false)
    expect(env.doc.querySelector('[data-role="phone-top-bar-title"]').textContent).toBe("CHAT")
    env.advance(TIMEOUT_MS)
    expect(layerOf(env.doc)).toBeNull()
    expect(env.ctl.cache.has("chat")).toBe(true)
    // The top strip gets its own page name back.
    expect(env.doc.querySelector('[data-role="phone-top-bar-title"]').textContent).toBe("tasks")
  })

  it("holds the cache at its cap, least recent out first", () => {
    env.shell({ current: "chat" })
    const keys = ["tasks", "meetings", "inbox", "files", "skills", "agents", "context", "changelog"]
    for (const key of keys) env.visit(key)
    expect(env.ctl.cache.size).toBe(CACHE_CAP)
    // Left in order: chat, tasks, meetings, inbox, files, skills, agents, context.
    expect(env.ctl.cache.keys()).toEqual(["meetings", "inbox", "files", "skills", "agents", "context"])

    const lru = createSnapshotCache(2)
    lru.set("a", 1)
    lru.set("b", 2)
    lru.set("a", 3)
    lru.set("c", 4)
    expect(lru.keys()).toEqual(["a", "c"])
  })

  it("treats an old snapshot as a miss", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.advance(MAX_AGE_MS + 1)
    env.tap("chat")
    expect(layerOf(env.doc).getAttribute("data-mode")).toBe("skeleton")
  })

  it("never touches localStorage or sessionStorage", () => {
    const globalLocal = storageSpy()
    const globalSession = storageSpy()
    vi.stubGlobal("localStorage", globalLocal)
    vi.stubGlobal("sessionStorage", globalSession)
    try {
      env.shell({ current: "chat" })
      for (const key of ["tasks", "chat", "inbox", "tasks", "meetings", "chat"]) env.visit(key)
      env.tap("files")
      env.tap("tasks")
      env.advance(TIMEOUT_MS)
      env.win.dispatch("click", { target: env.doc.querySelector('[phx-click="toggle_mask_names"]'), button: 0 })
      env.win.dispatch("click", { target: env.doc.querySelector('a[href="/auth/logout"]'), button: 0 })

      for (const store of [env.win.localStorage, env.win.sessionStorage, globalLocal, globalSession]) {
        for (const fn of ["getItem", "setItem", "removeItem", "clear", "key"]) {
          expect(store[fn]).not.toHaveBeenCalled()
        }
      }
    } finally {
      vi.unstubAllGlobals()
    }
  })

  it("clears the cache when the user changes", () => {
    env.shell({ current: "chat", user: "u1" })
    env.visit("tasks")
    env.visit("inbox")
    expect(env.ctl.cache.size).toBe(2)

    env.shell({ current: "inbox", user: "u2" })
    expect(env.ctl.cache.size).toBe(0)
    env.tap("chat")
    expect(layerOf(env.doc).getAttribute("data-mode")).toBe("skeleton")
  })

  it("does not file a snapshot taken under another user", () => {
    const { hook } = env.shell({ current: "chat", user: "u1" })
    env.tap("tasks")
    hook.setAttribute("data-user", "u2")
    env.ctl.sync(hook)
    env.paint()
    expect(env.ctl.cache.size).toBe(0)
  })

  it("clears the cache on Log out", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.win.dispatch("click", { target: env.doc.querySelector('a[href="/auth/logout"]'), button: 0 })
    expect(env.ctl.cache.size).toBe(0)
  })

  it("invalidates on a mask toggle and never shows a snapshot from the other mask state", () => {
    env.shell({ current: "chat", text: "Sample Person" })
    env.visit("tasks")
    expect(env.ctl.cache.size).toBe(1)

    // The toggle tap clears at once and suspends snapshots until it lands.
    env.win.dispatch("click", { target: env.doc.querySelector('[phx-click="toggle_mask_names"]'), button: 0 })
    expect(env.ctl.cache.size).toBe(0)
    expect(env.ctl.maskSettling()).toBe(true)
    env.tap("inbox")
    env.paint()
    expect(env.ctl.cache.size).toBe(0)

    // The server's masked render lands.
    env.land("inbox", { masked: true, text: "S. P." })
    expect(env.ctl.maskSettling()).toBe(false)

    env.visit("chat", { masked: true, text: "S. P." })
    env.tap("inbox")
    const snap = layerOf(env.doc).querySelector(".tab-switch-snapshot")
    expect(snap.textContent).toContain("S. P.")
    expect(snap.textContent).not.toContain("Sample Person")
  })

  it("clears on a mask change it did not see the tap for", () => {
    const { hook } = env.shell({ current: "chat" })
    env.visit("tasks")
    expect(env.ctl.cache.size).toBe(1)
    const now = env.doc.getElementById("tab-switch-cache")
    now.setAttribute("data-masked", "true")
    env.ctl.sync(now)
    expect(env.ctl.cache.size).toBe(0)
    expect(hook).toBeDefined()
  })

  it("reads the mask state at the tap, before the hook's update has run", () => {
    env.shell({ current: "chat" })
    env.visit("tasks")
    env.doc.getElementById("tab-switch-cache").setAttribute("data-masked", "true")
    env.tap("chat")
    expect(layerOf(env.doc).getAttribute("data-mode")).toBe("skeleton")
  })

  it("snapshots on a back/forward navigation too", () => {
    env.shell({ current: "chat" })
    env.win.dispatch("phx:page-loading-start", { detail: { kind: "redirect", to: "/tasks" } })
    env.paint()
    expect(env.ctl.cache.keys()).toEqual(["chat"])
  })
})
