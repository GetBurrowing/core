import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import installNativeBack, {
  EVENT,
  ATTR,
  MARKER,
  DRAWN_ATTR,
  DUO_ATTR,
  DUO_EVENT,
  DESKTOP_QUERY,
  NAV_EVENT,
  OBSERVED_ATTRIBUTES,
  navBarPlugin,
  wouldBeVisible,
  backTarget,
  stateOf,
} from "../../js/hooks/native_back.js"

/**
 * NativeBack (task 01a1fa7c stage 3). vitest runs in plain node, so window,
 * document and the controls are fakes: each fake node carries `display`
 * (what getComputedStyle reports for it, as if the hide rule did not exist)
 * and a `parentElement` chain up to the root.
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

function node({ parent = null, display = "block", hidden = false, attrs = {} } = {}) {
  return {
    parentElement: parent,
    display,
    hidden,
    isConnected: true,
    attrs,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    click: vi.fn(),
  }
}

function env({ native = true, plugin = { navBarState: vi.fn(() => Promise.resolve()) }, attr = true, duo = true } = {}) {
  const mql = fakeTarget()
  const flags = { desktop: false, drawn: false, duo }
  const root = {
    hasAttribute: (n) => (n === ATTR ? attr : n === DRAWN_ATTR ? flags.drawn : n === DUO_ATTR ? flags.duo : false),
  }
  const body = node({ parent: root })
  root.parentElement = null
  let controls = []

  const win = Object.assign(fakeTarget(), {
    Capacitor: { isNativePlatform: () => native, Plugins: plugin ? { SuiteNative: plugin } : {} },
    matchMedia: (q) => ({
      matches: q === DESKTOP_QUERY ? flags.desktop : false,
      addEventListener: (n, fn) => mql.addEventListener(n, fn),
      removeEventListener: (n, fn) => mql.removeEventListener(n, fn),
    }),
    getComputedStyle: (el) => ({ display: el.display || "block", visibility: el.visibility || "visible" }),
    requestAnimationFrame: (fn) => {
      queued.push(fn)
      return queued.length
    },
    cancelAnimationFrame: () => queued.splice(0),
  })
  // Runs one animation frame.
  const queued = []
  const frame = () => queued.splice(0).forEach((fn) => fn())

  const doc = Object.assign(fakeTarget(), {
    documentElement: root,
    querySelectorAll: (sel) => (sel === `[${MARKER}]` ? controls : []),
  })

  const control = (kind, opts = {}) => {
    const { attrs = {}, ...rest } = opts
    return node({ parent: body, ...rest, attrs: { [MARKER]: kind, ...attrs } })
  }
  const setControls = (list) => {
    controls = list
  }

  return { win, doc, flags, plugin, body, control, setControls, mql, frame, queued }
}

let observers
beforeEach(() => {
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
  delete globalThis.MutationObserver
})

const calls = (e) => e.plugin.navBarState.mock.calls.map((c) => c[0])
const last = (e) => calls(e).at(-1)
const mutate = () => observers.forEach((o) => o.cb([]))

describe("feature test", () => {
  it("no plugin means no call and no listener", () => {
    const e = env({ plugin: null })
    installNativeBack(e.win, e.doc)
    expect(e.win.listeners[EVENT]).toBeUndefined()
    expect(observers).toHaveLength(0)
  })

  it("is off in a browser", () => {
    const e = env({ native: false })
    installNativeBack(e.win, e.doc)
    expect(e.plugin.navBarState).not.toHaveBeenCalled()
    expect(e.win.listeners[EVENT]).toBeUndefined()
  })

  it("is off on an older build whose plugin lacks navBarState", () => {
    const plugin = { tabBarState: vi.fn() }
    const e = env({ plugin })
    installNativeBack(e.win, e.doc)
    expect(e.win.listeners[EVENT]).toBeUndefined()
    expect(navBarPlugin(e.win, e.doc)).toBeNull()
  })

  it("is off without <html data-native-tab-bar>", () => {
    const e = env({ attr: false })
    installNativeBack(e.win, e.doc)
    expect(e.plugin.navBarState).not.toHaveBeenCalled()
  })

  it("prefers BurrowNative over SuiteNative", () => {
    const e = env()
    const burrow = { navBarState: vi.fn() }
    e.win.Capacitor.Plugins.BurrowNative = burrow
    expect(navBarPlugin(e.win, e.doc)).toBe(burrow)
  })
})

describe("Duo only (data-native-duo)", () => {
  it("a regular iPhone (plugin present, no data-native-duo) gets no observer and no call", () => {
    const e = env({ duo: false })
    installNativeBack(e.win, e.doc)
    mutate()
    e.win.fire(NAV_EVENT, {})
    e.frame()
    expect(navBarPlugin(e.win, e.doc)).toBeNull()
    expect(observers).toHaveLength(0)
    expect(e.plugin.navBarState).not.toHaveBeenCalled()
    expect(e.win.listeners[EVENT]).toBeUndefined()
    expect(e.win.listeners[NAV_EVENT]).toBeUndefined()
    expect(e.queued).toHaveLength(0)
  })

  it("on the Duo, several mutations in one frame send exactly one call", () => {
    const e = env()
    installNativeBack(e.win, e.doc)
    expect(calls(e)).toHaveLength(1)
    e.setControls([e.control("back")])
    mutate()
    mutate()
    mutate()
    expect(calls(e)).toHaveLength(1)
    expect(e.queued).toHaveLength(1)
    e.frame()
    expect(calls(e)).toHaveLength(2)
    e.setControls([])
    mutate()
    e.win.fire(NAV_EVENT, {})
    mutate()
    e.frame()
    expect(calls(e)).toHaveLength(3)
    expect(last(e)).toEqual({ back: null })
  })

  it("activates when native marks the document after the install", () => {
    const e = env({ duo: false })
    installNativeBack(e.win, e.doc)
    expect(observers).toHaveLength(0)
    e.flags.duo = true
    e.win.fire(DUO_EVENT, {})
    e.win.fire(DUO_EVENT, {})
    expect(observers).toHaveLength(1)
    expect(calls(e)).toEqual([{ back: null }])
    expect(e.win.listeners[EVENT]).toHaveLength(1)
    expect(e.win.listeners[DUO_EVENT]).toEqual([])
  })

  it("an event without the attribute does not activate", () => {
    const e = env({ duo: false })
    installNativeBack(e.win, e.doc)
    e.win.fire(DUO_EVENT, {})
    expect(observers).toHaveLength(0)
    expect(e.plugin.navBarState).not.toHaveBeenCalled()
  })

  it("off a native build, nothing waits for the Duo event", () => {
    const e = env({ native: false, duo: false })
    installNativeBack(e.win, e.doc)
    expect(e.win.listeners[DUO_EVENT]).toBeUndefined()
  })

  it("uninstall cancels a pending frame", () => {
    const e = env()
    const off = installNativeBack(e.win, e.doc)
    e.setControls([e.control("back")])
    mutate()
    off()
    e.frame()
    expect(calls(e)).toHaveLength(1)
  })
})

describe("state", () => {
  it("a tab root sends null", () => {
    const e = env()
    installNativeBack(e.win, e.doc)
    expect(calls(e)).toEqual([{ back: null }])
  })

  it("a thread sends back, labelled from the control's aria-label", () => {
    const e = env()
    e.setControls([e.control("back", { attrs: { "aria-label": "Back to chat list" } })])
    installNativeBack(e.win, e.doc)
    expect(last(e)).toEqual({ back: { kind: "back", label: "Back to chat list" } })
  })

  it("falls back to 'Back' and 'Close' when there is no aria-label", () => {
    const e = env()
    e.setControls([e.control("back")])
    expect(stateOf(e.win, e.doc)).toEqual({ back: { kind: "back", label: "Back" } })
    e.setControls([e.control("close")])
    expect(stateOf(e.win, e.doc)).toEqual({ back: { kind: "close", label: "Close" } })
  })

  it("a modal sends close, even with the page's Back earlier in the DOM", () => {
    const e = env()
    const back = e.control("back")
    const close = e.control("close", { attrs: { "aria-label": "Close task details" } })
    e.setControls([back, close])
    installNativeBack(e.win, e.doc)
    expect(last(e)).toEqual({ back: { kind: "close", label: "Close task details" } })
    expect(backTarget(e.win, e.doc)).toBe(close)
  })

  it("skips a control inside a hidden ancestor", () => {
    const e = env()
    const closedModal = { ...e.body, display: "none", parentElement: e.doc.documentElement }
    e.setControls([e.control("close", { parent: closedModal }), e.control("back")])
    expect(stateOf(e.win, e.doc).back.kind).toBe("back")
  })

  it("skips a control with the hidden attribute or visibility hidden", () => {
    const e = env()
    const a = e.control("back", { hidden: true })
    const b = e.control("back")
    b.visibility = "hidden"
    e.setControls([a, b])
    expect(stateOf(e.win, e.doc)).toEqual({ back: null })
  })

  it("ignores the control's own display:none while native draws (the hide rule), not before", () => {
    const e = env()
    const el = e.control("back", { display: "none" })
    e.setControls([el])
    expect(wouldBeVisible(el, e.win, e.doc)).toBe(false)
    e.flags.drawn = true
    expect(wouldBeVisible(el, e.win, e.doc)).toBe(true)
  })

  it("reports null at the desktop width", () => {
    const e = env()
    e.setControls([e.control("back")])
    e.flags.desktop = true
    expect(stateOf(e.win, e.doc)).toEqual({ back: null })
  })
})

describe("updates", () => {
  it("navigating to a root re-sends null", () => {
    const e = env()
    e.setControls([e.control("back")])
    installNativeBack(e.win, e.doc)
    expect(last(e).back.kind).toBe("back")
    e.setControls([])
    e.win.fire(NAV_EVENT, {})
    e.frame()
    expect(last(e)).toEqual({ back: null })
  })

  it("re-sends on DOM mutation, and only when the state changed", () => {
    const e = env()
    installNativeBack(e.win, e.doc)
    mutate()
    e.frame()
    expect(calls(e)).toHaveLength(1)
    e.setControls([e.control("back")])
    mutate()
    e.frame()
    expect(calls(e)).toHaveLength(2)
    expect(last(e).back.kind).toBe("back")
  })

  it("observes the whole document for the attributes that change visibility", () => {
    const e = env()
    installNativeBack(e.win, e.doc)
    expect(observers).toHaveLength(1)
    expect(observers[0].target).toBe(e.doc.documentElement)
    expect(observers[0].opts).toMatchObject({ subtree: true, childList: true, attributes: true })
    expect(observers[0].opts.attributeFilter).toEqual(OBSERVED_ATTRIBUTES)
    expect(OBSERVED_ATTRIBUTES).toEqual(expect.arrayContaining([MARKER, "class", "hidden", "style"]))
  })

  it("re-sends when the desktop query flips", () => {
    const e = env()
    e.setControls([e.control("back")])
    installNativeBack(e.win, e.doc)
    e.flags.desktop = true
    e.mql.fire("change", {})
    e.frame()
    expect(last(e)).toEqual({ back: null })
  })

  it("uninstall removes every listener", () => {
    const e = env()
    const off = installNativeBack(e.win, e.doc)
    off()
    expect(e.win.listeners[EVENT]).toEqual([])
    expect(e.win.listeners[NAV_EVENT]).toEqual([])
    expect(observers[0].disconnect).toHaveBeenCalled()
  })
})

describe("native to web", () => {
  it("burrowNativeBack clicks the control, so the web's own navigation runs", () => {
    const e = env()
    const el = e.control("back")
    e.setControls([el])
    installNativeBack(e.win, e.doc)
    e.win.fire(EVENT, new Object())
    expect(el.click).toHaveBeenCalledTimes(1)
  })

  it("clicks the Close when a modal is open", () => {
    const e = env()
    const back = e.control("back")
    const close = e.control("close")
    e.setControls([back, close])
    installNativeBack(e.win, e.doc)
    e.win.fire(EVENT, {})
    expect(close.click).toHaveBeenCalledTimes(1)
    expect(back.click).not.toHaveBeenCalled()
  })

  it("clicks the control even while the hide rule has it display:none", () => {
    const e = env()
    const el = e.control("back", { display: "none" })
    e.setControls([el])
    e.flags.drawn = true
    installNativeBack(e.win, e.doc)
    e.win.fire(EVENT, {})
    expect(el.click).toHaveBeenCalledTimes(1)
  })

  it("does nothing on a tab root", () => {
    const e = env()
    installNativeBack(e.win, e.doc)
    expect(() => e.win.fire(EVENT, {})).not.toThrow()
  })
})

describe("promise safety", () => {
  it("swallows a rejected promise and a synchronous throw", async () => {
    const rejecting = env({ plugin: { navBarState: vi.fn(() => Promise.reject(new Error("x"))) } })
    installNativeBack(rejecting.win, rejecting.doc)
    const throwing = env({
      plugin: {
        navBarState: vi.fn(() => {
          throw new Error("y")
        }),
      },
    })
    expect(() => installNativeBack(throwing.win, throwing.doc)).not.toThrow()
    await Promise.resolve()
  })
})
