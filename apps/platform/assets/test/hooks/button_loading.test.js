import { describe, it, expect } from "vitest"
import ButtonLoading, { installPressHold, createBusySync } from "../../js/hooks/button_loading.js"

/**
 * ButtonLoading + press-hold buttons (task 01a166be-b5b9 stage 3; canvas
 * 01a167b0 rule 5). Plain node: fake elements, a fake MutationObserver the
 * test triggers by hand, and a fake clock.
 */

function el({ tag = "BUTTON", cls = [], matchHold = true } = {}) {
  const attrs = new Map()
  const classes = new Set(cls)
  const e = {
    tagName: tag,
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
    setAttribute: (k, v) => attrs.set(k, v),
    removeAttribute: (k) => attrs.delete(k),
    getAttribute: (k) => (attrs.has(k) ? attrs.get(k) : null),
    closest: (sel) => (sel === ".press-hold" && classes.has("press-hold") ? e : null),
    attrs,
  }
  return e
}

function clock() {
  let now = 0
  let id = 0
  const timers = new Map()
  return {
    setTimer: (fn, ms) => {
      timers.set(++id, { fn, at: now + ms })
      return id
    },
    clearTimer: (t) => timers.delete(t),
    advance(ms) {
      now += ms
      for (const [k, t] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
        if (t.at <= now && timers.has(k)) {
          timers.delete(k)
          t.fn()
        }
      }
    },
    pending: () => timers.size,
  }
}

function observers() {
  const list = []
  return {
    list,
    create: (cb) => {
      const o = { cb, disconnected: false, observe() {}, disconnect() { o.disconnected = true } }
      list.push(o)
      return o
    },
    fireAll: () => list.filter((o) => !o.disconnected).forEach((o) => o.cb()),
  }
}

function fakeWin() {
  const listeners = {}
  return {
    addEventListener: (t, fn) => (listeners[t] = fn),
    removeEventListener: (t) => delete listeners[t],
    click: (target) => listeners.click({ target }),
  }
}

function setup() {
  const c = clock()
  const obs = observers()
  const win = fakeWin()
  const ctl = installPressHold({ win, setTimer: c.setTimer, clearTimer: c.clearTimer, createObserver: obs.create })
  return { c, obs, win, ctl }
}

// LiveView's own click handler runs after the capture listener and adds the class.
function lvClick(win, obs, button) {
  win.click(button)
  button.classList.add("phx-click-loading")
  obs.fireAll()
}

describe("press-hold buttons", () => {
  it("sets aria-busy after 100ms of phx-click-loading and clears it on reply", () => {
    const { c, obs, win } = setup()
    const more = el({ cls: ["bottom-nav-tab", "press-hold"] })
    lvClick(win, obs, more)
    c.advance(99)
    expect(more.getAttribute("aria-busy")).toBeNull()
    c.advance(1)
    expect(more.getAttribute("aria-busy")).toBe("true")
    more.classList.remove("phx-click-loading")
    obs.fireAll()
    expect(more.getAttribute("aria-busy")).toBeNull()
    expect(obs.list[0].disconnected).toBe(true)
  })

  it("a reply under 100ms never sets aria-busy", () => {
    const { c, obs, win } = setup()
    const b = el({ cls: ["press-hold"] })
    lvClick(win, obs, b)
    c.advance(40)
    b.classList.remove("phx-click-loading")
    obs.fireAll()
    c.advance(200)
    expect(b.getAttribute("aria-busy")).toBeNull()
  })

  it("a click that starts no round trip stops watching", () => {
    const { c, obs, win, ctl } = setup()
    const b = el({ cls: ["press-hold"] })
    win.click(b)
    c.advance(0)
    expect(ctl.watching().size).toBe(0)
    expect(obs.list[0].disconnected).toBe(true)
  })

  it("ignores buttons without press-hold", () => {
    const { obs, win, ctl } = setup()
    win.click(el({ cls: ["btn"] }))
    expect(ctl.watching().size).toBe(0)
    expect(obs.list.length).toBe(0)
  })
})

describe("ButtonLoading hook (unchanged contract)", () => {
  it("a form marks its submit buttons busy after the delay", () => {
    const c = clock()
    const submit = el()
    const form = el({ tag: "FORM" })
    form.querySelectorAll = () => [submit]
    const busy = createBusySync({
      source: form,
      targets: () => ButtonLoading.targets.call({ el: form }),
      setTimer: c.setTimer,
      clearTimer: c.clearTimer,
    })
    form.classList.add("phx-submit-loading")
    busy.sync()
    c.advance(100)
    expect(submit.getAttribute("aria-busy")).toBe("true")
    form.classList.remove("phx-submit-loading")
    busy.sync()
    expect(submit.getAttribute("aria-busy")).toBeNull()
  })

  it("a bare button targets itself", () => {
    const b = el()
    expect(ButtonLoading.targets.call({ el: b })).toEqual([b])
  })
})
