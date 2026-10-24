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

function matches(node, selector) {
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
          if (matches(c, selector)) out.push(c)
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
