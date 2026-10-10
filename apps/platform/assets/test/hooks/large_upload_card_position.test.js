import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { UploadManager, renderTimeline } from "../../js/hooks/large_upload.js"

/**
 * The pending card must not move on screen across uploading -> done ->
 * posted while the scroller is pinned to the bottom (task 01a120be, review
 * round 3: the card jumped 20px at 'done' when the "Keep this tab open" line
 * was removed, because the shorter content clamped scrollTop).
 *
 * There is no DOM library in this suite, so this file carries a small fake
 * DOM with a block-layout model: heights stack vertically, margins and the
 * paddings that matter are counted, and the scroller clamps scrollTop to
 * [0, scrollHeight - clientHeight] exactly like a browser does. Fixed heights
 * stand in for what CSS would give: a card is 290px, a text line 20px.
 */

// ── fake DOM ────────────────────────────────────────────────────────────

const camelToData = (k) => "data-" + k.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())

class El {
  constructor(tag, doc) {
    this.tagName = tag.toUpperCase()
    this.ownerDocument = doc
    this.children = []
    this.parentNode = null
    this.attrs = new Map()
    this.style = {}
    this.hidden = false
    this._text = ""
    this._classes = new Set()
    const self = this
    this.classList = {
      add: (...c) => c.forEach((x) => self._classes.add(x)),
      remove: (...c) => c.forEach((x) => self._classes.delete(x)),
      contains: (c) => self._classes.has(c),
      toggle: (c, on) => {
        const want = on === undefined ? !self._classes.has(c) : !!on
        if (want) self._classes.add(c)
        else self._classes.delete(c)
        return want
      },
    }
    this.dataset = new Proxy(
      {},
      {
        get: (_t, k) => (typeof k === "string" ? self.getAttribute(camelToData(k)) ?? undefined : undefined),
        set: (_t, k, v) => {
          self.setAttribute(camelToData(k), String(v))
          return true
        },
      },
    )
  }
  set className(v) {
    this._classes = new Set(String(v || "").split(/\s+/).filter(Boolean))
  }
  get className() {
    return [...this._classes].join(" ")
  }
  set id(v) {
    this.setAttribute("id", v)
  }
  get id() {
    return this.getAttribute("id") || ""
  }
  set textContent(v) {
    this._text = String(v)
    this.children = []
  }
  get textContent() {
    return this._text
  }
  set title(v) {
    this.setAttribute("title", v)
  }
  setAttribute(k, v) {
    this.attrs.set(k, String(v))
  }
  getAttribute(k) {
    return this.attrs.has(k) ? this.attrs.get(k) : null
  }
  addEventListener() {}
  get firstChild() {
    return this.children[0] || null
  }
  get firstElementChild() {
    return this.children[0] || null
  }
  _adopt(n) {
    if (n.tagName === "#FRAG") {
      const kids = [...n.children]
      n.children = []
      return kids
    }
    if (n.parentNode) n.remove()
    return [n]
  }
  appendChild(n) {
    for (const k of this._adopt(n)) {
      k.parentNode = this
      this.children.push(k)
    }
    return n
  }
  insertBefore(n, ref) {
    const kids = this._adopt(n)
    const i = ref ? this.children.indexOf(ref) : this.children.length
    kids.forEach((k) => (k.parentNode = this))
    this.children.splice(i < 0 ? this.children.length : i, 0, ...kids)
    return n
  }
  replaceChildren(...ns) {
    this.children.forEach((c) => (c.parentNode = null))
    this.children = []
    ns.forEach((n) => this.appendChild(n))
  }
  remove() {
    if (!this.parentNode) return
    const p = this.parentNode
    p.children = p.children.filter((c) => c !== this)
    this.parentNode = null
  }
  *descendants() {
    for (const c of this.children) {
      yield c
      yield* c.descendants()
    }
  }
  matches(sel) {
    return sel.split(",").some((s) => matchSimple(this, s.trim()))
  }
  querySelectorAll(sel) {
    const out = []
    for (const part of sel.split(",").map((s) => s.trim())) {
      if (part.startsWith(":scope >")) {
        const rest = part.slice(":scope >".length).trim()
        for (const c of this.children) if (matchSimple(c, rest) && !out.includes(c)) out.push(c)
      } else {
        for (const d of this.descendants()) if (matchSimple(d, part) && !out.includes(d)) out.push(d)
      }
    }
    return out
  }
  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }
  closest(sel) {
    let n = this
    while (n && n.tagName !== "#DOC") {
      if (n.matches(sel)) return n
      n = n.parentNode
    }
    return null
  }
  getBoundingClientRect() {
    const sc = this.ownerDocument.scroller
    const y = offsetIn(this, sc) - sc.scrollTop
    const h = height(this)
    return { x: 0, left: 0, y, top: y, width: 448, height: h, bottom: y + h }
  }
}

function matchSimple(el, s) {
  if (!el.tagName || el.tagName.startsWith("#")) return false
  const re = /^([a-zA-Z]+)?((?:#[\w-]+|\.[\w-]+|\[[^\]]+\])*)$/
  const m = s.match(re)
  if (!m) throw new Error(`fake DOM cannot parse selector: ${s}`)
  if (m[1] && el.tagName !== m[1].toUpperCase()) return false
  for (const t of m[2].match(/#[\w-]+|\.[\w-]+|\[[^\]]+\]/g) || []) {
    if (t[0] === "#" && el.id !== t.slice(1)) return false
    if (t[0] === "." && !el.classList.contains(t.slice(1))) return false
    if (t[0] === "[") {
      const a = t.slice(1, -1).match(/^([\w-]+)(?:(\^?=)"?([^"]*)"?)?$/)
      const v = el.getAttribute(a[1])
      if (v == null) return false
      if (a[2] === "=" && v !== a[3]) return false
      if (a[2] === "^=" && !v.startsWith(a[3])) return false
    }
  }
  return true
}

const px = (v) => (v ? parseFloat(v) || 0 : 0)

// Fixed heights standing in for CSS.
function fixedHeight(el) {
  const role = el.getAttribute("data-role")
  if (role === "large-upload-card" || role === "video-attachment") return 290
  if (role === "large-upload-status") return 20
  // The chip's counter line under the card.
  if (el.tagName === "DIV" && el.parentNode && el.parentNode.getAttribute("data-role") === "large-upload-below") return 20
  if (el.tagName === "P") return 20
  if (el.classList.contains("js-date-separator")) return 44
  if (el.getAttribute("data-fixed-h")) return parseFloat(el.getAttribute("data-fixed-h"))
  return null
}

function pads(el) {
  if (el.classList.contains("message-row-inner")) return [8, 8]
  if (el.id === "message-list") return [16, 16]
  return [0, px(el.style.paddingBottom)]
}

function margins(el) {
  let mt = px(el.style.marginTop)
  let mb = px(el.style.marginBottom)
  const p = el.parentNode
  if (p && p.id === "message-list" && p.children[p.children.length - 1] !== el) mb += 4 // space-y-1
  return [mt, mb]
}

function height(el) {
  if (el.hidden || el.style.display === "none") return 0
  const f = fixedHeight(el)
  if (f != null) return f
  const [pt, pb] = pads(el)
  let h = pt + pb
  for (const c of el.children) {
    const [mt, mb] = margins(c)
    h += mt + height(c) + mb
  }
  return h
}

function offsetIn(el, ancestor) {
  if (el === ancestor) return 0
  const p = el.parentNode
  let y = offsetIn(p, ancestor) + pads(p)[0]
  for (const c of p.children) {
    const [mt, mb] = margins(c)
    if (c === el) return y + mt
    y += mt + height(c) + mb
  }
  throw new Error("not a child")
}

function makeDocument() {
  const doc = { tagName: "#DOC" }
  doc.createElement = (t) => new El(t, doc)
  doc.createDocumentFragment = () => new El("#frag", doc)
  doc.body = new El("body", doc)
  doc.body.parentNode = doc
  doc.getElementById = (id) => (id === doc.body.id ? doc.body : doc.body.querySelector(`#${id}`))
  doc.querySelector = (s) => doc.body.querySelector(s)
  return doc
}

function makeScroller(doc, clientHeight) {
  const sc = doc.createElement("div")
  sc.id = "chat-message-scroller"
  sc.setAttribute("data-scroll-container", "")
  sc.clientHeight = clientHeight
  let top = 0
  Object.defineProperty(sc, "scrollHeight", { get: () => height(sc) })
  // A browser clamps scrollTop whenever the content gets shorter, not only on
  // assignment.
  Object.defineProperty(sc, "scrollTop", {
    get: () => {
      top = Math.max(0, Math.min(top, sc.scrollHeight - sc.clientHeight))
      return top
    },
    set: (v) => {
      top = Math.max(0, Math.min(Number(v), sc.scrollHeight - sc.clientHeight))
    },
  })
  doc.scroller = sc
  return sc
}

// ── the scenario ────────────────────────────────────────────────────────

function setup({ video }) {
  const doc = makeDocument()
  globalThis.document = doc
  globalThis.CSS = { escape: (s) => s }
  const sc = makeScroller(doc, 500)
  doc.body.appendChild(sc)
  const list = doc.createElement("div")
  list.id = "message-list"
  sc.appendChild(list)
  // Older messages from someone else, today, so the posted row needs no
  // day separator and is not grouped with them.
  const today = new Date().toISOString().slice(0, 10)
  for (let i = 0; i < 6; i++) {
    const r = doc.createElement("div")
    r.id = `messages-old-${i}`
    r.setAttribute("data-participant-id", "someone-else")
    r.setAttribute("data-date", today)
    r.setAttribute("data-message-id", `old-${i}`)
    r.setAttribute("data-fixed-h", "120")
    list.appendChild(r)
  }
  const container = doc.createElement("div")
  container.id = "large-upload-timeline-s1"
  container.setAttribute("data-space-id", "s1")
  sc.appendChild(container)

  const m = new UploadManager({
    now: () => 0,
    waitForOnline: async () => {},
    sleep: async () => {},
    isConnected: () => true,
  })
  m.addView(() => renderTimeline(container, m))
  const u = {
    key: "k1",
    ref: "k1",
    id: "att-1",
    file: { size: 1000 },
    filename: video ? "clip.mp4" : "deck.pdf",
    contentType: video ? "video/mp4" : "application/pdf",
    byteSize: 1000,
    spaceId: "s1",
    participantId: "me",
    content: "",
    startedAt: 0,
    status: "uploading",
    offset: 400,
    samples: [],
    active: true,
    messageId: null,
  }
  return { doc, sc, list, container, m, u }
}

// The posted message, as chat_message/1 renders it: row > padded inner >
// body > attachments > card.
function postMessage(doc, list, { video }) {
  const row = doc.createElement("div")
  row.id = "messages-m1"
  row.setAttribute("data-message-id", "m1")
  row.setAttribute("data-participant-id", "me")
  row.setAttribute("data-date", new Date().toISOString().slice(0, 10))
  const inner = doc.createElement("div")
  inner.className = "message-row-inner"
  const body = doc.createElement("div")
  const wrap = doc.createElement("div")
  wrap.style.marginTop = "0px"
  const card = doc.createElement(video ? "div" : "a")
  if (video) {
    card.setAttribute("data-role", "video-attachment")
    const v = doc.createElement("video")
    v.setAttribute("src", "/chat/attachments/att-1")
    card.appendChild(v)
  } else {
    card.setAttribute("href", "/chat/attachments/att-1")
    card.setAttribute("data-fixed-h", "290")
  }
  wrap.appendChild(card)
  body.appendChild(wrap)
  inner.appendChild(body)
  row.appendChild(inner)
  list.appendChild(row)
  return card
}

let savedURL
beforeEach(() => {
  savedURL = globalThis.URL
  globalThis.URL = { createObjectURL: () => "blob:x", revokeObjectURL: () => {} }
})
afterEach(() => {
  globalThis.URL = savedURL
  delete globalThis.document
  delete globalThis.CSS
})

for (const video of [true, false]) {
  describe(`pending card position (${video ? "video" : "other file"}), scroller pinned to the bottom`, () => {
    it("the card's on-screen y is unchanged across uploading -> done -> posted", () => {
      const { doc, sc, list, container, m, u } = setup({ video })
      m.uploads.set(u.key, u)
      m.changed() // first render pins the scroller to the bottom (Send does too)
      sc.scrollTop = sc.scrollHeight
      const pendingCard = () => container.querySelector('[data-role="large-upload-card"]')
      const yUploading = pendingCard().getBoundingClientRect().y
      expect(sc.scrollTop).toBe(sc.scrollHeight - sc.clientHeight)

      u.status = "done"
      u.offset = u.byteSize
      u.active = false
      u.messageId = "m1"
      m.changed()
      const yDone = pendingCard().getBoundingClientRect().y

      // The posted message lands; ScrollToBottom keeps the list pinned
      // (synchronously, in its updated()) before the observer drops the card.
      const posted = postMessage(doc, list, { video })
      sc.scrollTop = sc.scrollHeight
      m.drop(u)
      const yPosted = posted.getBoundingClientRect().y

      expect(container.querySelector('[data-role="large-upload-card"]')).toBe(null)
      expect({ yDone, yPosted }).toEqual({ yDone: yUploading, yPosted: yUploading })
    })
  })
}
