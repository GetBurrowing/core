import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import TabPill, {
  STORAGE_KEY,
  SLIDE_MS,
  PRESS_CLASS,
  PILL_INSET_X,
  geometryFor,
  resumeFrom,
  targetIndex,
} from "../../js/hooks/tab_pill.js"

/**
 * TabPill (sliding pill, prototype t1). No DOM library in this suite, so
 * the bar is a small fake: four tabs 90px wide, the pill a style recorder.
 */

function fakeTab(i, { active = false, href = true } = {}) {
  const attrs = new Map()
  if (href) attrs.set("href", `/t${i}`)
  const classes = new Set(["bottom-nav-tab"])
  if (active) classes.add("bottom-nav-tab--active")
  const tab = {
    offsetLeft: i * 90,
    offsetWidth: 90,
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
    hasAttribute: (n) => attrs.has(n),
    setAttribute: (n, v) => attrs.set(n, v),
    removeAttribute: (n) => attrs.delete(n),
    closest: () => tab,
  }
  return tab
}

function fakePill() {
  const props = new Map()
  const pill = {
    animations: [],
    offsetWidth: 0,
    style: {
      transition: "",
      opacity: "",
      setProperty: (k, v) => props.set(k, v),
    },
    props,
    animate: vi.fn((frames, opts) => {
      const a = { frames, opts, currentTime: 0 }
      pill.animations.push(a)
      return a
    }),
  }
  return pill
}

function fakeStorage() {
  const m = new Map()
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    m,
  }
}

function fakeWin({ reduced = false, storage = fakeStorage() } = {}) {
  return {
    sessionStorage: storage,
    matchMedia: () => ({ matches: reduced }),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }
}

function mount({ activeIndex = 0, win = fakeWin() } = {}) {
  const tabs = [0, 1, 2, 3].map((i) => fakeTab(i, { active: i === activeIndex, href: i < 3 }))
  const pill = fakePill()
  const listeners = {}
  const el = {
    querySelector: (sel) => (sel === "[data-tab-pill]" ? pill : null),
    querySelectorAll: () => tabs,
    contains: () => true,
    addEventListener: (type, fn) => (listeners[type] = fn),
  }
  const hook = Object.create(TabPill)
  hook.el = el
  hook.win = win
  hook.mounted()
  return { hook, tabs, pill, listeners, win }
}

let observed
beforeEach(() => {
  observed = []
  globalThis.MutationObserver = class {
    constructor(cb) {
      this.cb = cb
      observed.push(this)
    }
    observe() {}
    disconnect() {}
  }
})

afterEach(() => {
  vi.useRealTimers()
  delete globalThis.MutationObserver
})

describe("targetIndex", () => {
  it("prefers the nav-pending tab, then the active one that has not yielded", () => {
    const tabs = [0, 1, 2, 3].map((i) => fakeTab(i, { active: i === 1 }))
    expect(targetIndex(tabs)).toBe(1)

    tabs[1].setAttribute("data-nav-yielded", "")
    tabs[3].setAttribute("data-nav-pending", "")
    expect(targetIndex(tabs)).toBe(3)

    tabs[3].removeAttribute("data-nav-pending")
    expect(targetIndex(tabs)).toBe(-1)
  })
})

describe("geometryFor", () => {
  it("is the tab's box inset horizontally", () => {
    expect(geometryFor(fakeTab(2))).toEqual({ x: 180 + PILL_INSET_X, w: 90 - 2 * PILL_INSET_X })
    expect(geometryFor(undefined)).toBe(null)
  })
})

describe("resumeFrom", () => {
  it("continues only a fresh tap that landed on this tab from another", () => {
    const tap = { from: 0, to: 2, at: 1000 }
    expect(resumeFrom(tap, 2, 1100)).toEqual({ from: 0, elapsed: 100 })
    expect(resumeFrom(tap, 1, 1100)).toBe(null)
    expect(resumeFrom(tap, 2, 1000 + SLIDE_MS)).toBe(null)
    expect(resumeFrom({ from: 2, to: 2, at: 1000 }, 2, 1100)).toBe(null)
    expect(resumeFrom(null, 2, 1100)).toBe(null)
    expect(resumeFrom({ from: "0", to: 2, at: 1000 }, 2, 1100)).toBe(null)
  })
})

describe("mount", () => {
  it("places the pill on the current tab with no transition and no animation", () => {
    const { pill } = mount({ activeIndex: 1 })

    expect(pill.props.get("--pill-x")).toBe(`${90 + PILL_INSET_X}px`)
    expect(pill.props.get("--pill-w")).toBe(`${90 - 2 * PILL_INSET_X}px`)
    expect(pill.style.opacity).toBe("1")
    // The transition is suspended for the jump and restored afterwards.
    expect(pill.style.transition).toBe("")
    expect(pill.animate).not.toHaveBeenCalled()
  })

  it("continues a slide the previous page started, at its elapsed time", () => {
    vi.useFakeTimers()
    vi.setSystemTime(10_000)
    const win = fakeWin()
    win.sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ from: 0, to: 2, at: 9_900 }))

    const { pill } = mount({ activeIndex: 2, win })

    expect(pill.props.get("--pill-x")).toBe(`${180 + PILL_INSET_X}px`)
    expect(pill.animations).toHaveLength(2)
    const [slide, width] = pill.animations
    expect(slide.frames[0].transform).toBe(`translateX(${PILL_INSET_X}px)`)
    expect(slide.frames[1].transform).toBe(`translateX(${180 + PILL_INSET_X}px)`)
    expect(slide.opts).toEqual({ duration: SLIDE_MS, easing: "cubic-bezier(.3,1.5,.5,1)" })
    expect(slide.currentTime).toBe(100)
    expect(width.currentTime).toBe(100)
    // The tap is consumed.
    expect(win.sessionStorage.getItem(STORAGE_KEY)).toBe(null)
  })

  it("a stale tap or a reload of the same tab just places", () => {
    vi.useFakeTimers()
    vi.setSystemTime(10_000)
    const win = fakeWin()
    win.sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ from: 0, to: 2, at: 1_000 }))
    expect(mount({ activeIndex: 2, win }).pill.animate).not.toHaveBeenCalled()

    win.sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ from: 0, to: 1, at: 9_990 }))
    expect(mount({ activeIndex: 2, win }).pill.animate).not.toHaveBeenCalled()
  })

  it("reduced motion never slides on mount", () => {
    vi.useFakeTimers()
    vi.setSystemTime(10_000)
    const win = fakeWin({ reduced: true })
    win.sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ from: 0, to: 2, at: 9_990 }))
    expect(mount({ activeIndex: 2, win }).pill.animate).not.toHaveBeenCalled()
  })

  it("hides the pill when no tab is current", () => {
    const { pill } = mount({ activeIndex: -1 })
    expect(pill.style.opacity).toBe("0")
  })
})

describe("in-session changes", () => {
  it("a tab change slides: geometry moves and the transition stays on", () => {
    const { hook, tabs, pill } = mount({ activeIndex: 0 })

    tabs[0].classList.remove("bottom-nav-tab--active")
    tabs[3].classList.add("bottom-nav-tab--active")
    pill.style.transition = "sentinel"
    hook.updated()

    expect(pill.props.get("--pill-x")).toBe(`${270 + PILL_INSET_X}px`)
    // animate=true leaves the CSS transition alone.
    expect(pill.style.transition).toBe("sentinel")
  })

  it("the optimistic nav-pending mark moves the pill via the observer", () => {
    const { tabs, pill } = mount({ activeIndex: 0 })
    tabs[0].setAttribute("data-nav-yielded", "")
    tabs[1].setAttribute("data-nav-pending", "")
    observed[0].cb([])
    expect(pill.props.get("--pill-x")).toBe(`${90 + PILL_INSET_X}px`)
  })

  it("under reduced motion a change is placed with no transition", () => {
    const { hook, tabs, pill } = mount({ activeIndex: 0, win: fakeWin({ reduced: true }) })
    tabs[0].classList.remove("bottom-nav-tab--active")
    tabs[2].classList.add("bottom-nav-tab--active")
    pill.style.transition = "sentinel"
    hook.updated()
    expect(pill.props.get("--pill-x")).toBe(`${180 + PILL_INSET_X}px`)
    expect(pill.style.transition).toBe("")
  })

  it("resize re-places with no transition", () => {
    const { hook, tabs, pill } = mount({ activeIndex: 1 })
    tabs[1].offsetLeft = 120
    pill.style.transition = "sentinel"
    hook.onResize()
    expect(pill.props.get("--pill-x")).toBe(`${120 + PILL_INSET_X}px`)
    expect(pill.style.transition).toBe("")
  })
})

describe("taps", () => {
  it("a link-tab click records {from: current, to: tapped} for the next mount", () => {
    const { tabs, listeners, win } = mount({ activeIndex: 0 })
    listeners.click({ target: tabs[2] })
    const tap = JSON.parse(win.sessionStorage.getItem(STORAGE_KEY))
    expect(tap.from).toBe(0)
    expect(tap.to).toBe(2)
    expect(typeof tap.at).toBe("number")
  })

  it("More (no href) and the current tab record nothing", () => {
    const { tabs, listeners, win } = mount({ activeIndex: 0 })
    listeners.click({ target: tabs[3] })
    listeners.click({ target: tabs[0] })
    expect(win.sessionStorage.getItem(STORAGE_KEY)).toBe(null)
  })

  it("pointerdown presses the tab; leaving or releasing un-presses it", () => {
    const { hook, tabs, listeners } = mount({ activeIndex: 0 })
    listeners.pointerdown({ target: tabs[1] })
    expect(tabs[1].classList.contains(PRESS_CLASS)).toBe(true)

    listeners.pointerleave({ target: tabs[1] })
    expect(tabs[1].classList.contains(PRESS_CLASS)).toBe(false)

    listeners.pointerdown({ target: tabs[2] })
    hook.release()
    expect(tabs[2].classList.contains(PRESS_CLASS)).toBe(false)
  })
})
