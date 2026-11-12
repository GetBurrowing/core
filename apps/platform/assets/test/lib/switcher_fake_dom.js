// A small fake DOM for the install switcher tests (task 01a1ccd4 stage 3).
// vitest runs in plain node here (no jsdom). Elements keep real attribute,
// class, child and listener state; `textContent =` makes one text node;
// `innerHTML =` imitates a browser parser just enough that markup in a
// string becomes ELEMENTS (an `<img ...>` becomes an IMG child), which is
// exactly the difference a textContent-only rule must hold against.

class Node {
  constructor(doc) {
    this.ownerDocument = doc
    this.parentNode = null
    this.childNodes = []
  }

  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node)
    this.childNodes.push(node)
    node.parentNode = this
    return node
  }

  removeChild(node) {
    const i = this.childNodes.indexOf(node)
    if (i !== -1) this.childNodes.splice(i, 1)
    node.parentNode = null
    return node
  }

  replaceChildren(...nodes) {
    for (const c of [...this.childNodes]) this.removeChild(c)
    for (const n of nodes) this.appendChild(n)
  }

  remove() {
    this.parentNode?.removeChild(this)
  }

  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true
    return false
  }
}

class Text extends Node {
  constructor(doc, data) {
    super(doc)
    this.nodeType = 3
    this.data = String(data)
  }

  get textContent() {
    return this.data
  }
}

function classListOf(el) {
  const read = () => new Set((el.getAttribute("class") || "").split(/\s+/).filter(Boolean))
  const write = set => el.setAttribute("class", [...set].join(" "))
  return {
    add: (...cs) => {
      const s = read()
      cs.forEach(c => s.add(c))
      write(s)
    },
    remove: (...cs) => {
      const s = read()
      cs.forEach(c => s.delete(c))
      write(s)
    },
    contains: c => read().has(c)
  }
}

export class El extends Node {
  constructor(doc, tag) {
    super(doc)
    this.nodeType = 1
    this.tagName = tag.toUpperCase()
    this.attrs = new Map()
    this.listeners = {}
    this.style = {}
    this.value = ""
    this.classList = classListOf(this)
    this.innerHTMLWrites = 0
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

  get id() {
    return this.getAttribute("id") || ""
  }

  set id(v) {
    this.setAttribute("id", v)
  }

  get textContent() {
    return this.childNodes.map(c => c.textContent).join("")
  }

  set textContent(v) {
    this.replaceChildren(new Text(this.ownerDocument, v))
  }

  set innerHTML(v) {
    this.innerHTMLWrites++
    const s = String(v)
    const nodes = []
    const re = /<([a-z]+)\b[^>]*>/gi
    let last = 0
    let m
    while ((m = re.exec(s))) {
      if (m.index > last) nodes.push(new Text(this.ownerDocument, s.slice(last, m.index)))
      nodes.push(new El(this.ownerDocument, m[1]))
      last = re.lastIndex
    }
    if (last < s.length) nodes.push(new Text(this.ownerDocument, s.slice(last)))
    this.replaceChildren(...nodes)
  }

  get innerHTML() {
    return this.textContent
  }

  addEventListener(t, fn) {
    ;(this.listeners[t] ||= []).push(fn)
  }

  removeEventListener(t, fn) {
    this.listeners[t] = (this.listeners[t] || []).filter(f => f !== fn)
  }

  fire(t, ev = {}) {
    for (const fn of this.listeners[t] || []) fn({ type: t, target: this, preventDefault() {}, ...ev })
  }

  click() {
    this.fire("click")
  }

  focus() {
    this.ownerDocument.activeElement = this
  }

  closest(sel) {
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (matches(n, sel)) return n
    return null
  }

  getBoundingClientRect() {
    return { top: 10, bottom: 44, left: 8, right: 200, width: 192, height: 34 }
  }

  querySelectorAll(sel) {
    const out = []
    const walk = n => {
      for (const c of n.childNodes) {
        if (c.nodeType !== 1) continue
        if (matches(c, sel)) out.push(c)
        walk(c)
      }
    }
    walk(this)
    return out
  }

  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }
}

// `tag`, `#id`, `[attr]`, `[attr='v']` / `[attr="v"]`, compounds of those.
export function matches(el, selector) {
  return selector.split(",").some(part => {
    const m = part.trim().match(/^([a-z]*)(#[\w-]+)?((?:\[[\w-]+(?:=["']?[^"'\]]*["']?)?\])*)$/i)
    if (!m) return false
    const [, tag, id, attrs] = m
    if (tag && el.tagName !== tag.toUpperCase()) return false
    if (id && el.getAttribute("id") !== id.slice(1)) return false
    for (const [, a, v] of attrs.matchAll(/\[([\w-]+)(?:=["']?([^"'\]]*)["']?)?\]/g)) {
      if (!el.hasAttribute(a)) return false
      if (v !== undefined && el.getAttribute(a) !== v) return false
    }
    return true
  })
}

export function fakeDoc() {
  const listeners = {}
  const doc = {
    activeElement: null,
    visibilityState: "visible",
    listeners,
    createElement: tag => new El(doc, tag),
    createTextNode: data => new Text(doc, data),
    addEventListener: (t, fn) => (listeners[t] ||= []).push(fn),
    removeEventListener: (t, fn) => {
      listeners[t] = (listeners[t] || []).filter(f => f !== fn)
    },
    fire: (t, ev = {}) => (listeners[t] || []).forEach(fn => fn({ type: t, ...ev })),
    getElementById: id => (doc.body.getAttribute("id") === id ? doc.body : doc.body.querySelector("#" + id))
  }
  doc.body = new El(doc, "body")
  doc.head = new El(doc, "head")
  return doc
}

export function fakeStorage(init = {}) {
  const map = new Map(Object.entries(init))
  return {
    map,
    reads: 0,
    getItem(k) {
      this.reads++
      return map.has(k) ? map.get(k) : null
    },
    setItem(k, v) {
      map.set(k, String(v))
    },
    removeItem(k) {
      map.delete(k)
    }
  }
}

/** The switcher button + its `-menu` sibling, as the component renders them. */
export function switchButton(doc, { id = "native-install-switch", variant = "phone", name = "Acme", unread = 0 } = {}) {
  const header = doc.createElement("header")
  const button = doc.createElement("button")
  button.setAttribute("id", id)
  button.setAttribute("class", variant === "phone" ? "hidden -ml-1 items-center" : "flex items-center")
  button.setAttribute("data-variant", variant)
  button.setAttribute("data-install-name", name)
  button.setAttribute("data-current-unread", String(unread))
  const dot = doc.createElement("span")
  dot.setAttribute("data-role", "install-unread-dot")
  dot.setAttribute("class", "hidden size-2 rounded-full bg-primary")
  button.appendChild(dot)
  const menu = doc.createElement("div")
  menu.setAttribute("id", id + "-menu")
  header.appendChild(button)
  header.appendChild(menu)
  doc.body.appendChild(header)
  return { button, dot, menu }
}
