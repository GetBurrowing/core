// A MutationObserver for fake_dom.js's FakeElement tree (task 01a1f4c5 v2).
//
// Records are delivered in a microtask, batched per observer, as a real
// MutationObserver does. It supports `attributes` (+ `attributeFilter`),
// `childList` and `subtree`, which is what the device panel's mic-toggle
// watch uses. `install()` patches FakeElement / FakeNode in place and
// returns `{ MutationObserver, live, restore }`: `live()` is the number of
// observers still observing something, and `restore()` undoes the patch.

import { FakeElement } from "./fake_dom.js"

export function installFakeMutationObservers() {
  const observers = new Set()
  const pending = new Map()
  let scheduled = false

  const flush = () => {
    scheduled = false
    const batch = [...pending]
    pending.clear()
    for (const [o, records] of batch) if (observers.has(o)) o.callback(records, o)
  }

  const matches = (entry, record) => {
    const { node, opts } = entry
    const inScope = node === record.target || (opts.subtree && node.contains(record.target))
    if (!inScope) return false
    if (record.type === "childList") return !!opts.childList
    if (!(opts.attributes || opts.attributeFilter)) return false
    return !opts.attributeFilter || opts.attributeFilter.includes(record.attributeName)
  }

  const notify = (record) => {
    for (const o of observers) {
      if (!o.entries.some((e) => matches(e, record))) continue
      if (!pending.has(o)) pending.set(o, [])
      pending.get(o).push(record)
      if (!scheduled) {
        scheduled = true
        queueMicrotask(flush)
      }
    }
  }

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback
      this.entries = []
    }

    observe(node, opts = {}) {
      this.entries = this.entries.filter((e) => e.node !== node)
      this.entries.push({ node, opts })
      observers.add(this)
    }

    disconnect() {
      this.entries = []
      observers.delete(this)
      pending.delete(this)
    }

    takeRecords() {
      const r = pending.get(this) || []
      pending.delete(this)
      return r
    }
  }

  const elProto = FakeElement.prototype
  const nodeProto = Object.getPrototypeOf(elProto)
  const orig = {
    setAttribute: elProto.setAttribute,
    removeAttribute: elProto.removeAttribute,
    insertBefore: nodeProto.insertBefore,
    removeChild: nodeProto.removeChild,
  }

  elProto.setAttribute = function (name, value) {
    orig.setAttribute.call(this, name, value)
    notify({ type: "attributes", target: this, attributeName: name })
  }
  elProto.removeAttribute = function (name) {
    orig.removeAttribute.call(this, name)
    notify({ type: "attributes", target: this, attributeName: name })
  }
  nodeProto.insertBefore = function (node, ref) {
    const r = orig.insertBefore.call(this, node, ref)
    notify({ type: "childList", target: this })
    return r
  }
  nodeProto.removeChild = function (node) {
    const r = orig.removeChild.call(this, node)
    notify({ type: "childList", target: this })
    return r
  }

  return {
    MutationObserver: FakeMutationObserver,
    live: () => observers.size,
    restore() {
      elProto.setAttribute = orig.setAttribute
      elProto.removeAttribute = orig.removeAttribute
      nodeProto.insertBefore = orig.insertBefore
      nodeProto.removeChild = orig.removeChild
      observers.clear()
      pending.clear()
    },
  }
}
