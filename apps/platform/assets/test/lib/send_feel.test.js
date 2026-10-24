import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { attachSendFeel, haptic, DOWN_ATTR, GO_ATTR, GO_MS } from "../../js/lib/send_feel.js"

// vitest runs in plain node here (no jsdom), so the DOM is stubbed.

function fakeRoot() {
  const log = []
  return {
    log,
    attrs: {},
    get offsetWidth() {
      log.push("reflow")
      return 0
    },
    setAttribute(k, v) {
      log.push(`+${k}`)
      this.attrs[k] = v
    },
    removeAttribute(k) {
      log.push(`-${k}`)
      delete this.attrs[k]
    },
  }
}

function fakeDoc() {
  const created = []
  const body = {
    children: [],
    appendChild(c) {
      this.children.push(c)
    },
  }
  const doc = {
    created,
    body,
    documentElement: fakeRoot(),
    getElementById(id) {
      return body.children.find((c) => c.id === id) || null
    },
    createElement(tag) {
      const el = {
        tag,
        attrs: {},
        style: {},
        children: [],
        clicks: 0,
        setAttribute(k, v) {
          this.attrs[k] = v
        },
        appendChild(c) {
          this.children.push(c)
        },
        click() {
          this.clicks++
        },
      }
      created.push(el)
      return el
    },
  }
  return doc
}

function fakeForm(send) {
  const listeners = {}
  return {
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    fire(type, e = {}) {
      for (const fn of listeners[type] || []) fn(e)
    },
    count() {
      return Object.values(listeners).reduce((n, l) => n + l.length, 0)
    },
    send,
  }
}

function fakeSend({ disabled = false } = {}) {
  const send = {
    disabled,
    closest: (sel) => (sel === ".compose-pill-send" ? send : null),
    contains: (n) => n === send,
  }
  return send
}

describe("send feel", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it("presses on pointerdown and releases on up, cancel and leaving Send", () => {
    const doc = fakeDoc()
    const send = fakeSend()
    const form = fakeForm(send)
    attachSendFeel(form, { doc, nav: {} })
    const root = doc.documentElement

    for (const release of ["pointerup", "pointercancel"]) {
      form.fire("pointerdown", { target: send })
      expect(root.attrs[DOWN_ATTR]).toBe("")
      form.fire(release, { target: send })
      expect(root.attrs[DOWN_ATTR]).toBeUndefined()
    }

    form.fire("pointerdown", { target: send })
    form.fire("pointerout", { target: send, relatedTarget: null })
    expect(root.attrs[DOWN_ATTR]).toBeUndefined()
  })

  it("does not press a disabled Send or another control", () => {
    const doc = fakeDoc()
    const form = fakeForm()
    attachSendFeel(form, { doc, nav: {} })
    form.fire("pointerdown", { target: fakeSend({ disabled: true }) })
    form.fire("pointerdown", { target: { closest: () => null } })
    expect(doc.documentElement.attrs[DOWN_ATTR]).toBeUndefined()
  })

  it("restarts go on every send (off, reflow, on) and clears it after the ring", () => {
    const doc = fakeDoc()
    const feel = attachSendFeel(fakeForm(), { doc, nav: {} })
    const root = doc.documentElement

    feel.go()
    feel.go()
    const goOps = root.log.filter((x) => x.includes(GO_ATTR) || x === "reflow")
    expect(goOps).toEqual([`-${GO_ATTR}`, "reflow", `+${GO_ATTR}`, `-${GO_ATTR}`, "reflow", `+${GO_ATTR}`])

    vi.advanceTimersByTime(GO_MS - 1)
    expect(root.attrs[GO_ATTR]).toBe("")
    vi.advanceTimersByTime(1)
    expect(root.attrs[GO_ATTR]).toBeUndefined()
  })

  it("ticks vibrate(10) on a send, and adds nothing to the page for it", () => {
    const doc = fakeDoc()
    const vibrate = vi.fn()
    const feel = attachSendFeel(fakeForm(), { doc, nav: { vibrate } })
    feel.go()
    expect(vibrate).toHaveBeenCalledWith(10)
    // The iOS hidden-switch haptic was dropped: it took focus off the field.
    expect(doc.body.children).toEqual([])
  })

  it("a platform without vibrate, or one that throws, still animates", () => {
    const doc = fakeDoc()
    for (const nav of [{}, { vibrate: () => { throw new Error("nope") } }]) {
      attachSendFeel(fakeForm(), { doc, nav }).go()
      expect(doc.documentElement.attrs[GO_ATTR]).toBe("")
    }
    expect(haptic({ nav: undefined })).toBeUndefined()
  })

  it("detach removes its listeners and both states", () => {
    const doc = fakeDoc()
    const form = fakeForm()
    const feel = attachSendFeel(form, { doc, nav: {} })
    feel.go()
    feel.detach()
    expect(form.count()).toBe(0)
    expect(doc.documentElement.attrs).toEqual({})
  })
})
