// Two fake DOMs for vitest in plain node (this suite has no jsdom). They are
// independent and serve different tests:
//
//   - fakeDocument() / FakeElement / FakeText / caret: a node tree with text
//     nodes, used by lib/mention_field.js and the ComposeInput hook's
//     contenteditable path.
//   - createElement() / installFakeDocument() / serialize(): plain-object
//     elements, used by the imperative meeting tiles (meeting_client tests).
//
// Keep them separate: serialize() is the byte-identical observable the
// meeting regression tests pin, and it reads the plain-object shape.

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

// ---- plain-object elements for the meeting tile tests ----

/**
 * A minimal fake DOM for hook tests (the assets workspace runs vitest in the
 * `node` environment; no jsdom is installed).
 *
 * Supports exactly what the imperative meeting tiles touch: `dataset`,
 * `style`, `className` with a `classList` view onto it, `textContent`,
 * `appendChild` / `insertBefore` / `removeChild` / `remove`, `firstChild`,
 * and `querySelector` / `querySelectorAll` for a single simple selector:
 * `tag`, `.class`, `[data-foo]` or `[data-foo='v']`.
 *
 * `serialize(node)` renders a node tree as a stable string (tag, sorted
 * dataset, class, sorted style, text, children). It is the observable the
 * byte-identical regression tests pin.
 */

const camel = (s) => s.replace(/-([a-z])/g, (_, c) => c.toUpperCase())

function matchesSimple(node, selector) {
  if (!node || typeof node !== "object") return false
  if (selector.startsWith(".")) {
    return node.className.split(/\s+/).includes(selector.slice(1))
  }
  const attr = selector.match(/^\[data-([a-z0-9-]+)(?:=['"]?([^'"\]]*)['"]?)?\]$/)
  if (attr) {
    const key = camel(attr[1])
    if (!(key in node.dataset)) return false
    return attr[2] === undefined || String(node.dataset[key]) === attr[2]
  }
  return node.tagName === selector.toUpperCase()
}

export function createElement(tag = "div") {
  const node = {
    tagName: String(tag).toUpperCase(),
    dataset: {},
    style: {},
    className: "",
    textContent: "",
    children: [],
    parentElement: null,
    get parentNode() {
      return this.parentElement
    },
    get firstChild() {
      return this.children[0] || null
    },
    get isConnected() {
      return true
    },
    classList: null,
    appendChild(child) {
      if (child.parentElement) child.parentElement.removeChild(child)
      child.parentElement = this
      this.children.push(child)
      return child
    },
    insertBefore(child, ref) {
      if (child.parentElement) child.parentElement.removeChild(child)
      const i = ref ? this.children.indexOf(ref) : -1
      child.parentElement = this
      if (i < 0) this.children.push(child)
      else this.children.splice(i, 0, child)
      return child
    },
    removeChild(child) {
      const i = this.children.indexOf(child)
      if (i >= 0) this.children.splice(i, 1)
      child.parentElement = null
      return child
    },
    remove() {
      if (this.parentElement) this.parentElement.removeChild(this)
    },
    setAttribute(name, value) {
      if (name.startsWith("data-")) this.dataset[camel(name.slice(5))] = String(value)
    },
    querySelectorAll(selector) {
      const out = []
      const walk = (n) => {
        for (const c of n.children) {
          if (matchesSimple(c, selector)) out.push(c)
          walk(c)
        }
      }
      walk(this)
      return out
    },
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null
    },
  }
  node.classList = {
    _list: () => node.className.split(/\s+/).filter(Boolean),
    contains(c) {
      return this._list().includes(c)
    },
    add(c) {
      if (!this.contains(c)) node.className = [...this._list(), c].join(" ")
    },
    remove(c) {
      node.className = this._list()
        .filter((x) => x !== c)
        .join(" ")
    },
    toggle(c, force) {
      const on = force === undefined ? !this.contains(c) : !!force
      if (on) this.add(c)
      else this.remove(c)
      return on
    },
  }
  return node
}

/** Install `globalThis.document` with `createElement`; returns an uninstaller. */
export function installFakeDocument(extra = {}) {
  const previous = globalThis.document
  globalThis.document = { createElement, ...extra }
  return () => {
    if (previous === undefined) delete globalThis.document
    else globalThis.document = previous
  }
}

export function serialize(node) {
  if (!node || typeof node !== "object") return String(node)
  const data = Object.keys(node.dataset || {})
    .sort()
    .map((k) => `${k}=${node.dataset[k]}`)
    .join(",")
  const style = Object.keys(node.style || {})
    .sort()
    .map((k) => `${k}:${node.style[k]}`)
    .join(";")
  const kids = (node.children || []).map(serialize).join("")
  return `<${node.tagName || "?"} data="${data}" class="${node.className || ""}" style="${style}" text="${node.textContent || ""}">${kids}</>`
}
