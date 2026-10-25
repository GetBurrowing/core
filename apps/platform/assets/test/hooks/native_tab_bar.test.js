import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import NativeTabBar, {
  EVENT,
  ATTR,
  DESKTOP_QUERY,
  HIDE_SELECTOR,
  OTHER_SHEET_SELECTOR,
  DESTROY_GRACE_MS,
  tabBarPlugin,
  barVisible,
  mainScroller,
} from "../../js/hooks/native_tab_bar.js"

/**
 * NativeTabBar (task 01a1557b stage 3). vitest runs in plain node, so
 * window, document, the bridge span, the tabs and the scroller are fakes.
 * The fake root answers `matches(HIDE_SELECTOR)` from a flag the test sets,
 * standing in for the browser's :has evaluation.
 */

function fakeTarget() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (n, fn) => (listeners[n] ||= []).push(fn),
    removeEventListener: (n, fn) => (listeners[n] = (listeners[n] || []).filter((f) => f !== fn)),
    fire(n, e) {
      for (const fn of listeners[n] || []) fn(e)
    },
  }
}

function fakeSpan(attrs = {}) {
  const a = {
    "data-items": "chat,voice,tasks,meetings,more",
    "data-active-key": "chat",
    "data-more-unread": "false",
    "data-more-open": "false",
    ...attrs,
  }
  return {
    a,
    getAttribute: (n) => (n in a && a[n] !== null ? a[n] : null),
  }
}

function fakeScroller({ scrollTop = 0, scrollHeight = 2000, clientHeight = 700 } = {}) {
  return {
    scrollTop,
    scrollHeight,
    clientHeight,
    overflowY: "auto",
    scrollTo: vi.fn(function ({ top }) {
      this.scrollTop = top
    }),
  }
}

function env({
  native = true,
  plugin = { tabBarState: vi.fn(() => Promise.resolve()) },
  attr = true,
  desktop = false,
  reduced = false,
} = {}) {
  const mqlListeners = fakeTarget()
  const flags = { hidden: false, otherSheet: false, desktop, reduced }
  const scroller = fakeScroller()
  const tabs = {}
  for (const k of ["chat", "voice", "tasks", "meetings", "more"]) tabs[k] = { click: vi.fn() }

  const win = Object.assign(fakeTarget(), {
    Capacitor: {
      isNativePlatform: () => native,
      Plugins: plugin ? { SuiteNative: plugin } : {},
    },
    matchMedia: (q) => ({
      matches: q === DESKTOP_QUERY ? flags.desktop : q.includes("reduced-motion") ? flags.reduced : false,
      addEventListener: (n, fn) => mqlListeners.addEventListener(n, fn),
      removeEventListener: (n, fn) => mqlListeners.removeEventListener(n, fn),
    }),
    getComputedStyle: (el) => ({ overflowY: el.overflowY || "visible" }),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
  })

  const main = { scrollHeight: 700, clientHeight: 700, overflowY: "hidden", querySelectorAll: () => [scroller] }

  const doc = Object.assign(fakeTarget(), {
    documentElement: {
      hasAttribute: (n) => attr && n === ATTR,
      matches: (sel) => (sel === HIDE_SELECTOR ? flags.hidden : false),
    },
    querySelector: (sel) => {
      if (sel === OTHER_SHEET_SELECTOR) return flags.otherSheet ? {} : null
      if (sel === "[data-scroll-container]") return main
      const m = sel.match(/^#bottom-nav \[data-destination="(\w+)"\]$/)
      return m ? tabs[m[1]] || null : null
    },
  })

  return { win, doc, flags, plugin, tabs, scroller, mqlListeners, main }
}

let observers
beforeEach(() => {
  vi.useFakeTimers()
  observers = []
  globalThis.MutationObserver = class {
    constructor(cb) {
      this.cb = cb
      this.disconnect = vi.fn()
      observers.push(this)
    }
    observe(target, opts) {
      this.target = target
      this.opts = opts
    }
  }
})

afterEach(() => {
  vi.runOnlyPendingTimers()
  vi.useRealTimers()
  delete globalThis.MutationObserver
})

function mount(e, span = fakeSpan()) {
  const hook = Object.create(NativeTabBar)
  hook.el = span
  hook.win = e.win
  hook.doc = e.doc
  hook.mounted()
  return hook
}

const calls = (e) => e.plugin.tabBarState.mock.calls.map((c) => c[0])
const last = (e) => calls(e).at(-1)

describe("feature test", () => {
  it("is off in a browser: no listener, no call", () => {
    const e = env({ native: false })
    mount(e)
    expect(e.plugin.tabBarState).not.toHaveBeenCalled()
    expect(e.win.listeners[EVENT]).toBeUndefined()
    expect(e.doc.listeners.focusin).toBeUndefined()
    expect(observers).toHaveLength(0)
  })

  it("is off on an old build whose plugin lacks tabBarState", () => {
    const e = env({ plugin: { installBadges: vi.fn() } })
    expect(tabBarPlugin(e.win, e.doc)).toBe(null)
    mount(e)
    expect(e.win.listeners[EVENT]).toBeUndefined()
    expect(observers).toHaveLength(0)
  })

  it("is off when <html data-native-tab-bar> is missing", () => {
    const e = env({ attr: false })
    mount(e)
    expect(e.plugin.tabBarState).not.toHaveBeenCalled()
    expect(e.win.listeners[EVENT]).toBeUndefined()
  })

  it("prefers BurrowNative over SuiteNative", () => {
    const e = env()
    const burrow = { tabBarState: vi.fn(() => Promise.resolve()) }
    e.win.Capacitor.Plugins.BurrowNative = burrow
    expect(tabBarPlugin(e.win, e.doc)).toBe(burrow)
  })
})

describe("state payload", () => {
  it("sends items, selected, more_dot and visible on mount", () => {
    const e = env()
    mount(e)
    expect(calls(e)).toEqual([
      { items: ["chat", "voice", "tasks", "meetings", "more"], selected: "chat", more_dot: false, visible: true },
    ])
  })

  it("follows each attribute on update", () => {
    const e = env()
    const span = fakeSpan()
    const hook = mount(e, span)

    span.a["data-active-key"] = "tasks"
    hook.updated()
    expect(last(e).selected).toBe("tasks")

    span.a["data-active-key"] = null
    hook.updated()
    expect(last(e).selected).toBe(null)

    span.a["data-more-unread"] = "true"
    hook.updated()
    expect(last(e).more_dot).toBe(true)

    span.a["data-items"] = "chat,tasks,more"
    hook.updated()
    expect(last(e).items).toEqual(["chat", "tasks", "more"])
  })

  it("does not resend an unchanged state", () => {
    const e = env()
    const hook = mount(e)
    hook.updated()
    observers[0].cb([])
    expect(calls(e)).toHaveLength(1)
  })
})

describe("hide predicate", () => {
  it("hides for the web bar's own hide rules, re-evaluated on focus and mutation", () => {
    const e = env()
    mount(e)

    e.flags.hidden = true // composer focused
    e.doc.fire("focusin")
    expect(last(e).visible).toBe(false)

    e.flags.hidden = false
    e.doc.fire("focusout")
    expect(last(e).visible).toBe(true)

    e.flags.hidden = true // viewer or in-call node added
    observers[0].cb([])
    expect(last(e).visible).toBe(false)
    e.flags.hidden = false
    observers[0].cb([])
    expect(last(e).visible).toBe(true)
  })

  it("observes the root for the viewer, in-call and class changes, and added nodes", () => {
    const e = env()
    mount(e)
    expect(observers[0].target).toBe(e.doc.documentElement)
    expect(observers[0].opts).toMatchObject({
      subtree: true,
      childList: true,
      attributeFilter: ["data-fullscreen-viewer", "data-in-call", "class"],
    })
  })

  it("hides at the desktop width and returns below it", () => {
    const e = env()
    mount(e)
    e.flags.desktop = true
    e.mqlListeners.fire("change")
    expect(last(e).visible).toBe(false)
    e.flags.desktop = false
    e.mqlListeners.fire("change")
    expect(last(e).visible).toBe(true)
  })

  it("on a wide iPad (>= 1024pt, the desktop rail) the first state is already hidden", () => {
    const e = env({ desktop: true })
    mount(e)
    expect(calls(e)).toHaveLength(1)
    expect(last(e).visible).toBe(false)
    expect(calls(e).some((s) => s.visible)).toBe(false)
  })

  it("hides for a sheet other than More, not for the More sheet", () => {
    const e = env()
    expect(barVisible(e.win, e.doc)).toBe(true)
    e.flags.otherSheet = true
    expect(barVisible(e.win, e.doc)).toBe(false)
    expect(OTHER_SHEET_SELECTOR).toBe(".sheet-open:not(#more-sheet)")
  })

  it("mirrors app.css's three hide rules", () => {
    expect(HIDE_SELECTOR).toContain(':has([phx-hook="ComposeInput"]:focus)')
    expect(HIDE_SELECTOR).toContain(":has([data-fullscreen-viewer])")
    expect(HIDE_SELECTOR).toContain(":has([data-in-call])")
  })
})

describe("burrowNativeTab", () => {
  for (const key of ["chat", "voice", "tasks", "meetings", "more"]) {
    it(`a tap on ${key} clicks its #bottom-nav tab`, () => {
      const e = env()
      mount(e)
      e.win.fire(EVENT, { detail: { key, reselect: false } })
      expect(e.tabs[key].click).toHaveBeenCalledTimes(1)
      for (const other of Object.keys(e.tabs)) {
        if (other !== key) expect(e.tabs[other].click).not.toHaveBeenCalled()
      }
    })
  }

  it("More toggles: every More tap clicks the button, reselect included", () => {
    const e = env()
    mount(e)
    e.win.fire(EVENT, { detail: { key: "more", reselect: false } })
    e.win.fire(EVENT, { detail: { key: "more", reselect: true } })
    expect(e.tabs.more.click).toHaveBeenCalledTimes(2)
  })

  it("a More reselect below the top still toggles the sheet and does not scroll", () => {
    // Kills the mutant that drops `|| detail.key === "more"`: at the top a
    // reselect clicks anyway, so only a scrolled page tells the two apart.
    const e = env()
    mount(e)
    e.scroller.scrollTop = 500
    e.win.fire(EVENT, { detail: { key: "more", reselect: true } })
    expect(e.tabs.more.click).toHaveBeenCalledTimes(1)
    expect(e.scroller.scrollTo).not.toHaveBeenCalled()
    expect(e.scroller.scrollTop).toBe(500)
  })

  it("reselect below the top scrolls the main scroller to the top and does not navigate", () => {
    const e = env()
    mount(e)
    e.scroller.scrollTop = 500
    e.win.fire(EVENT, { detail: { key: "chat", reselect: true } })
    expect(e.scroller.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" })
    expect(e.tabs.chat.click).not.toHaveBeenCalled()
  })

  it("reselect at the top clicks the tab (module root)", () => {
    const e = env()
    mount(e)
    e.win.fire(EVENT, { detail: { key: "tasks", reselect: true } })
    expect(e.scroller.scrollTo).not.toHaveBeenCalled()
    expect(e.tabs.tasks.click).toHaveBeenCalledTimes(1)
  })

  it("reduced motion scrolls without smoothing", () => {
    const e = env({ reduced: true })
    mount(e)
    e.scroller.scrollTop = 10
    e.win.fire(EVENT, { detail: { key: "chat", reselect: true } })
    expect(e.scroller.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "auto" })
  })

  it("ignores an unknown key, a missing tab and a malformed detail", () => {
    const e = env()
    mount(e)
    e.win.fire(EVENT, { detail: { key: "admin", reselect: false } })
    e.win.fire(EVENT, { detail: null })
    e.win.fire(EVENT, {})
    for (const t of Object.values(e.tabs)) expect(t.click).not.toHaveBeenCalled()
  })

  it("picks the tallest scrolling element under <main>", () => {
    const e = env()
    expect(mainScroller(e.win, e.doc)).toBe(e.scroller)
  })
})

describe("destroyed", () => {
  it("sends visible:false and removes its listeners", () => {
    const e = env()
    const hook = mount(e)
    hook.destroyed()
    expect(e.win.listeners[EVENT]).toEqual([])
    expect(observers[0].disconnect).toHaveBeenCalled()
    vi.advanceTimersByTime(DESTROY_GRACE_MS)
    expect(last(e)).toEqual({
      items: ["chat", "voice", "tasks", "meetings", "more"],
      selected: "chat",
      more_dot: false,
      visible: false,
    })
  })

  it("a remount inside the grace (a tab change) cancels the hide", () => {
    const e = env()
    const hook = mount(e)
    hook.destroyed()
    mount(e, fakeSpan({ "data-active-key": "tasks" }))
    vi.advanceTimersByTime(DESTROY_GRACE_MS * 2)
    expect(calls(e).every((s) => s.visible)).toBe(true)
    expect(last(e).selected).toBe("tasks")
  })
})

describe("plugin failures", () => {
  it("ends every tabBarState promise in a catch", async () => {
    // Kills the mutant that drops the `.catch`: a native Promise passes
    // through Promise.resolve unchanged, so the catch lands on this one.
    // A plain function, not vi.fn: the spy chains its own .then onto a
    // returned promise, which would itself reject unhandled.
    const handled = []
    let sent = 0
    const tabBarState = () => {
      sent += 1
      const p = Promise.reject(new Error("bridge gone"))
      const realCatch = p.catch.bind(p)
      p.catch = (fn) => {
        handled.push(fn)
        return realCatch(fn)
      }
      return p
    }
    const e = env({ plugin: { tabBarState } })
    const hook = mount(e)
    expect(handled).toHaveLength(1)
    expect(typeof handled[0]).toBe("function")

    e.flags.desktop = true
    e.mqlListeners.fire("change")
    hook.destroyed()
    vi.advanceTimersByTime(DESTROY_GRACE_MS)
    expect(sent).toBe(3)
    expect(handled).toHaveLength(3)
    await Promise.resolve()
  })

  it("swallows a rejected promise and a synchronous throw", async () => {
    const rejecting = env({ plugin: { tabBarState: vi.fn(() => Promise.reject(new Error("x"))) } })
    expect(() => mount(rejecting)).not.toThrow()
    await Promise.resolve()

    const throwing = env({
      plugin: {
        tabBarState: vi.fn(() => {
          throw new Error("y")
        }),
      },
    })
    expect(() => mount(throwing)).not.toThrow()
  })
})
