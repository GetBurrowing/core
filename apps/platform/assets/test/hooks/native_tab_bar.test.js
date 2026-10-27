import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import NativeTabBar, {
  EVENT,
  ATTR,
  DESKTOP_QUERY,
  HIDE_SELECTOR,
  OTHER_SHEET_SELECTOR,
  DESTROY_GRACE_MS,
  SCHEME_QUERY,
  INK_KEYS,
  OBSERVED_ATTRIBUTES,
  tabBarPlugin,
  barVisible,
  mainScroller,
  stateOf,
  inksOf,
  schemeOf,
  parseSerialisedColour,
  canvasNormaliser,
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

// The two ink probes inside the span: `getComputedStyle(probe).color` reads
// the env's current `flags.inks[probe.ink]`.
function fakeSpan(attrs = {}, { probes = INK_KEYS } = {}) {
  const a = {
    "data-items": "chat,voice,tasks,meetings,more",
    "data-active-key": "chat",
    "data-more-unread": "false",
    "data-more-open": "false",
    ...attrs,
  }
  const found = Object.fromEntries(probes.map((k) => [`[data-native-ink="${k}"]`, { ink: k }]))
  return {
    a,
    getAttribute: (n) => (n in a && a[n] !== null ? a[n] : null),
    querySelector: (sel) => found[sel] || null,
  }
}

// Computed colours as an engine reports them (oklab for the color-mix ink),
// and the '#rrggbbaa' a canvas would turn each into. Anything not in the
// table fails to normalise.
const COMPUTED = {
  light: { selected: "rgb(173, 75, 7)", unselected: "oklab(0 0 0 / 0.55)" },
  dark: { selected: "rgb(244, 119, 33)", unselected: "oklab(0.95 0 -0.002 / 0.55)" },
}
const NORMALISED = {
  "rgb(173, 75, 7)": "#ad4b07ff",
  "oklab(0 0 0 / 0.55)": "#0000008c",
  "rgb(244, 119, 33)": "#f47721ff",
  "oklab(0.95 0 -0.002 / 0.55)": "#eeeff18c",
  "rgb(0, 0, 0)": "#000000ff",
}
const fakeNormalise = (v) => NORMALISED[v] ?? null

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
  const schemeListeners = fakeTarget()
  const flags = {
    hidden: false,
    otherSheet: false,
    desktop,
    reduced,
    theme: "light",
    systemDark: false,
    inks: { ...COMPUTED.light },
  }
  const scroller = fakeScroller()
  const tabs = {}
  for (const k of ["chat", "voice", "tasks", "meetings", "more"]) tabs[k] = { click: vi.fn() }

  const win = Object.assign(fakeTarget(), {
    Capacitor: {
      isNativePlatform: () => native,
      Plugins: plugin ? { SuiteNative: plugin } : {},
    },
    matchMedia: (q) => {
      const target = q === SCHEME_QUERY ? schemeListeners : mqlListeners
      return {
        matches:
          q === DESKTOP_QUERY
            ? flags.desktop
            : q === SCHEME_QUERY
              ? flags.systemDark
              : q.includes("reduced-motion")
                ? flags.reduced
                : false,
        addEventListener: (n, fn) => target.addEventListener(n, fn),
        removeEventListener: (n, fn) => target.removeEventListener(n, fn),
      }
    },
    getComputedStyle: (el) => ({ overflowY: el.overflowY || "visible", color: el.ink ? flags.inks[el.ink] : "" }),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
  })

  const main = { scrollHeight: 700, clientHeight: 700, overflowY: "hidden", querySelectorAll: () => [scroller] }

  const doc = Object.assign(fakeTarget(), {
    documentElement: {
      hasAttribute: (n) => attr && n === ATTR,
      getAttribute: (n) => (n === "data-theme" ? flags.theme : null),
      matches: (sel) => (sel === HIDE_SELECTOR ? flags.hidden : false),
    },
    querySelector: (sel) => {
      if (sel === OTHER_SHEET_SELECTOR) return flags.otherSheet ? {} : null
      if (sel === "[data-scroll-container]") return main
      const m = sel.match(/^#bottom-nav \[data-destination="(\w+)"\]$/)
      return m ? tabs[m[1]] || null : null
    },
  })

  return { win, doc, flags, plugin, tabs, scroller, mqlListeners, schemeListeners, main, normalise: fakeNormalise }
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
  hook.normalise = e.normalise
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
  it("sends items, selected, more_dot, visible, ink and scheme on mount", () => {
    const e = env()
    mount(e)
    expect(calls(e)).toEqual([
      {
        items: ["chat", "voice", "tasks", "meetings", "more"],
        selected: "chat",
        more_dot: false,
        visible: true,
        ink: { selected: "#ad4b07ff", unselected: "#0000008c" },
        scheme: "light",
      },
    ])
  })

  it("ink values are '#rrggbbaa' strings read from the two probes", () => {
    const e = env()
    e.flags.theme = "dark"
    e.flags.inks = { ...COMPUTED.dark }
    mount(e)
    const { ink, scheme } = last(e)
    expect(Object.keys(ink).sort()).toEqual(["selected", "unselected"])
    for (const v of Object.values(ink)) expect(v).toMatch(/^#[0-9a-f]{8}$/)
    expect(ink).toEqual({ selected: "#f47721ff", unselected: "#eeeff18c" })
    expect(scheme).toBe("dark")
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

  it("de-dups on the whole payload: an unchanged theme mutation sends nothing, a changed ink sends once", () => {
    const e = env()
    mount(e)
    e.flags.theme = "light" // a data-theme write with the same value
    observers[0].cb([])
    e.schemeListeners.fire("change")
    expect(calls(e)).toHaveLength(1)

    e.flags.inks = { ...e.flags.inks, selected: "rgb(0, 0, 0)" }
    observers[0].cb([])
    observers[0].cb([])
    expect(calls(e)).toHaveLength(2)
    expect(last(e).ink.selected).toBe("#000000ff")
  })
})

describe("ink and scheme (task 01a174e8 stage 1)", () => {
  it("a colour that does not normalise drops that key, never sends garbage", () => {
    const e = env()
    e.flags.inks = { selected: "rgb(173, 75, 7)", unselected: "nonsense" }
    mount(e)
    expect(last(e).ink).toEqual({ selected: "#ad4b07ff" })
    expect("unselected" in last(e).ink).toBe(false)

    // A normaliser that returns something other than '#rrggbbaa' is ignored too.
    const odd = env()
    odd.normalise = (v) => (v === "rgb(173, 75, 7)" ? "rgb(173, 75, 7)" : NORMALISED[v])
    mount(odd)
    expect(last(odd).ink).toEqual({ unselected: "#0000008c" })
  })

  it("a normaliser that throws, or a missing probe, drops only that key", () => {
    const e = env()
    e.normalise = (v) => {
      if (v.startsWith("oklab")) throw new Error("no canvas")
      return NORMALISED[v]
    }
    mount(e)
    expect(last(e).ink).toEqual({ selected: "#ad4b07ff" })

    const noProbe = env()
    mount(noProbe, fakeSpan({}, { probes: ["unselected"] }))
    expect(last(noProbe).ink).toEqual({ unselected: "#0000008c" })
  })

  it("re-pushes when <html data-theme> flips", () => {
    const e = env()
    mount(e)
    e.flags.theme = "dark"
    e.flags.inks = { ...COMPUTED.dark }
    observers[0].cb([{ type: "attributes", attributeName: "data-theme" }])
    expect(calls(e)).toHaveLength(2)
    expect(last(e)).toMatchObject({ scheme: "dark", ink: { selected: "#f47721ff", unselected: "#eeeff18c" } })
  })

  it("re-pushes when <html data-preset> flips (same scheme, new inks)", () => {
    const e = env()
    mount(e)
    e.flags.inks = { selected: "rgb(0, 0, 0)", unselected: "oklab(0 0 0 / 0.55)" }
    observers[0].cb([{ type: "attributes", attributeName: "data-preset" }])
    expect(calls(e)).toHaveLength(2)
    expect(last(e)).toMatchObject({ scheme: "light", ink: { selected: "#000000ff" } })
  })

  it("re-pushes when the install theme's <style> is replaced (childList)", () => {
    const e = env()
    mount(e)
    e.flags.inks = { ...COMPUTED.dark }
    observers[0].cb([{ type: "childList" }])
    expect(calls(e)).toHaveLength(2)
    expect(last(e).ink).toEqual({ selected: "#f47721ff", unselected: "#eeeff18c" })
  })

  it("re-pushes on a prefers-color-scheme change when the web theme follows the system", () => {
    const e = env()
    e.flags.theme = null
    mount(e)
    expect(last(e).scheme).toBe("light")
    e.flags.systemDark = true
    e.flags.inks = { ...COMPUTED.dark }
    e.schemeListeners.fire("change")
    expect(calls(e)).toHaveLength(2)
    expect(last(e)).toMatchObject({ scheme: "dark", ink: { selected: "#f47721ff" } })
  })

  it("observes data-theme, data-preset and style on top of the hide attributes", () => {
    const e = env()
    mount(e)
    expect(OBSERVED_ATTRIBUTES).toEqual([
      "data-fullscreen-viewer",
      "data-in-call",
      "class",
      "data-theme",
      "data-preset",
      "style",
    ])
    expect(observers[0].opts.attributeFilter).toBe(OBSERVED_ATTRIBUTES)
    expect(observers[0].opts.childList).toBe(true)
    expect(e.schemeListeners.listeners.change).toHaveLength(1)
  })

  it("destroyed removes the prefers-color-scheme listener", () => {
    const e = env()
    const hook = mount(e)
    hook.destroyed()
    expect(e.schemeListeners.listeners.change).toEqual([])
  })

  it("scheme follows data-theme light/dark, else the system", () => {
    const e = env()
    for (const [theme, systemDark, want] of [
      ["light", true, "light"],
      ["dark", false, "dark"],
      [null, true, "dark"],
      [null, false, "light"],
      ["sepia", true, "dark"],
    ]) {
      e.flags.theme = theme
      e.flags.systemDark = systemDark
      expect(schemeOf(e.win, e.doc)).toBe(want)
    }
  })

  it("without a normaliser, or a span without probes, ink is empty and nothing throws", () => {
    const e = env()
    expect(inksOf(fakeSpan(), e.win, null)).toEqual({})
    expect(inksOf({ getAttribute: () => null }, e.win, fakeNormalise)).toEqual({})
    expect(stateOf({ getAttribute: () => null }, e.win, e.doc).ink).toEqual({})
  })
})

describe("canvas normaliser", () => {
  it("parses the forms a canvas fillStyle serialises to", () => {
    expect(parseSerialisedColour("#ad4b07")).toBe("#ad4b07ff")
    expect(parseSerialisedColour("#AD4B07")).toBe("#ad4b07ff")
    expect(parseSerialisedColour("#fff")).toBe("#ffffffff")
    expect(parseSerialisedColour("#0000008c")).toBe("#0000008c")
    expect(parseSerialisedColour("rgba(0, 0, 0, 0.55)")).toBe("#0000008c")
    expect(parseSerialisedColour("rgb(238 239 241 / 55%)")).toBe("#eeeff18c")
    expect(parseSerialisedColour("color(srgb 0.933 0.937 0.945 / 0.55)")).toBe("#eeeff18c")
    expect(parseSerialisedColour("oklab(0 0 0 / 0.55)")).toBe(null)
    expect(parseSerialisedColour("rgba(nope)")).toBe(null)
  })

  // A 2D context fake with the real fillStyle contract: an invalid value is
  // ignored, a valid one serialises (here through `serialise`).
  function fakeDoc(serialise, pixel = [1, 2, 3, 255]) {
    const ctx = {
      _fill: "#000000",
      get fillStyle() {
        return this._fill
      },
      set fillStyle(v) {
        const out = v.startsWith("#") ? v : serialise(v)
        if (out != null) this._fill = out
      },
      clearRect: vi.fn(),
      fillRect: vi.fn(),
      getImageData: vi.fn(() => ({ data: pixel })),
    }
    const canvas = { getContext: vi.fn(() => ctx) }
    return { ctx, canvas, doc: { createElement: vi.fn(() => canvas) } }
  }

  it("normalises through the context, reads back a pixel for an unparsed form, and memoises", () => {
    const { ctx, canvas, doc } = fakeDoc(
      (v) => ({ "oklab(0 0 0 / 0.55)": "rgba(0, 0, 0, 0.55)", "color(display-p3 1 0 0)": "color(display-p3 1 0 0)" })[v],
      [255, 0, 0, 255],
    )
    const n = canvasNormaliser(doc)
    expect(n("oklab(0 0 0 / 0.55)")).toBe("#0000008c")
    expect(n("color(display-p3 1 0 0)")).toBe("#ff0000ff")
    expect(ctx.getImageData).toHaveBeenCalledTimes(1)
    expect(n("oklab(0 0 0 / 0.55)")).toBe("#0000008c")
    expect(canvas.getContext).toHaveBeenCalledTimes(1)
    expect(doc.createElement).toHaveBeenCalledWith("canvas")
  })

  it("an invalid colour, an empty value, or no canvas gives null", () => {
    const { doc } = fakeDoc(() => null)
    const n = canvasNormaliser(doc)
    expect(n("not-a-colour")).toBe(null)
    expect(n("")).toBe(null)
    expect(n(undefined)).toBe(null)
    expect(canvasNormaliser({})("rgb(0, 0, 0)")).toBe(null)
    expect(canvasNormaliser({ createElement: () => ({ getContext: () => null }) })("rgb(0, 0, 0)")).toBe(null)
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
      attributeFilter: ["data-fullscreen-viewer", "data-in-call", "class", "data-theme", "data-preset", "style"],
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
      ink: { selected: "#ad4b07ff", unselected: "#0000008c" },
      scheme: "light",
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
