// A minimal DOM for vitest in plain node (this suite has no jsdom): text
// nodes and elements with the tree operations `lib/mention_field.js` and the
// ComposeInput hook's contenteditable path use, nothing more.

class FakeNode {
  constructor(doc) {
    this.ownerDocument = doc
    this.parentNode = null
    this.childNodes = []
  }

  get firstChild() {
    return this.childNodes[0] || null
  }

  get lastChild() {
    return this.childNodes[this.childNodes.length - 1] || null
  }

  get previousSibling() {
    if (!this.parentNode) return null
    const i = this.parentNode.childNodes.indexOf(this)
    return i > 0 ? this.parentNode.childNodes[i - 1] : null
  }

  get nextSibling() {
    if (!this.parentNode) return null
    const i = this.parentNode.childNodes.indexOf(this)
    return this.parentNode.childNodes[i + 1] || null
  }

  insertBefore(node, ref) {
    if (node.parentNode) node.parentNode.removeChild(node)
    const i = ref ? this.childNodes.indexOf(ref) : -1
    if (i === -1) this.childNodes.push(node)
    else this.childNodes.splice(i, 0, node)
    node.parentNode = this
    return node
  }

  appendChild(node) {
    return this.insertBefore(node, null)
  }

  removeChild(node) {
    const i = this.childNodes.indexOf(node)
    if (i === -1) throw new Error("not a child")
    this.childNodes.splice(i, 1)
    node.parentNode = null
    return node
  }

  replaceChildren(...nodes) {
    while (this.firstChild) this.removeChild(this.firstChild)
    for (const n of nodes) this.appendChild(n)
  }

  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true
    return false
  }
}

export class FakeText extends FakeNode {
  constructor(doc, data) {
    super(doc)
    this.nodeType = 3
    this.nodeName = "#text"
    this.data = data
  }

  get textContent() {
    return this.data
  }
}

export class FakeElement extends FakeNode {
  constructor(doc, tag) {
    super(doc)
    this.nodeType = 1
    this.nodeName = tag.toUpperCase()
    this.tagName = this.nodeName
    this.attributes = new Map()
    this.listeners = {}
    this.style = {}
    const self = this
    this.dataset = new Proxy(
      {},
      {
        get(_t, key) {
          const v = self.getAttribute("data-" + kebab(String(key)))
          return v === null ? undefined : v
        },
        set(_t, key, value) {
          self.setAttribute("data-" + kebab(String(key)), String(value))
          return true
        },
      },
    )
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value))
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  hasAttribute(name) {
    return this.attributes.has(name)
  }

  get id() {
    return this.getAttribute("id") || ""
  }

  get isContentEditable() {
    return this.getAttribute("contenteditable") === "true"
  }

  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("")
  }

  get innerHTML() {
    return this.childNodes.map(html).join("")
  }

  addEventListener(type, fn) {
    ;(this.listeners[type] ||= []).push(fn)
  }

  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn)
  }

  dispatchEvent(event) {
    for (const fn of this.listeners[event.type] || []) fn(event)
    if (event.bubbles && this.parentNode && this.parentNode.dispatchEvent) {
      this.parentNode.dispatchEvent(event)
    }
    return true
  }

  // Test helper: fire a listener with a plain event object.
  fire(type, event = {}) {
    for (const fn of this.listeners[type] || []) fn({ type, ...event })
  }

  focus() {
    this.ownerDocument.activeElement = this
  }

  closest(selector) {
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) {
      if (matches(n, selector)) return n
    }
    return null
  }

  querySelectorAll(selector) {
    const out = []
    for (const c of this.childNodes) {
      if (c.nodeType !== 1) continue
      if (matches(c, selector)) out.push(c)
      out.push(...c.querySelectorAll(selector))
    }
    return out
  }

  querySelector(selector) {
    for (const c of this.childNodes) {
      if (c.nodeType !== 1) continue
      if (matches(c, selector)) return c
      const deep = c.querySelector(selector)
      if (deep) return deep
    }
    return null
  }
}

function kebab(s) {
  return s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())
}

// Selector support: `tag`, `#id`, `[attr]`, `[attr="v"]`, `tag[attr="v"]`.
function matches(el, selector) {
  const m = selector.match(/^([a-z]*)(#[\w-]+)?(?:\[([\w-]+)(?:="?([^"\]]*)"?)?\])?$/i)
  if (!m) return false
  const [, tag, id, attr, value] = m
  if (tag && el.nodeName !== tag.toUpperCase()) return false
  if (id && el.getAttribute("id") !== id.slice(1)) return false
  if (attr && !el.hasAttribute(attr)) return false
  if (attr && value !== undefined && el.getAttribute(attr) !== value) return false
  return true
}

function html(node) {
  if (node.nodeType === 3) return node.data.replace(/ /g, "&nbsp;")
  if (node.nodeName === "BR") return "<br>"
  const attrs = Array.from(node.attributes)
    .map(([k, v]) => ` ${k}="${v}"`)
    .join("")
  const tag = node.nodeName.toLowerCase()
  return `<${tag}${attrs}>${node.childNodes.map(html).join("")}</${tag}>`
}

export function fakeDocument() {
  const listeners = {}
  const doc = {
    activeElement: null,
    createElement: (tag) => new FakeElement(doc, tag),
    createTextNode: (data) => new FakeText(doc, data),
    addEventListener: (type, fn) => (listeners[type] ||= []).push(fn),
    removeEventListener: (type, fn) => {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    fire: (type, event = {}) => (listeners[type] || []).forEach((fn) => fn({ type, ...event })),
  }
  return doc
}

/** A collapsed selection-like object at (node, offset). */
export function caret(node, offset) {
  return { anchorNode: node, anchorOffset: offset, isCollapsed: true }
}
