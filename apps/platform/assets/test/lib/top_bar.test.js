import { describe, it, expect } from "vitest"
import {
  topBarDelay,
  topBarOptions,
  controlOwnsNavigation,
  installTopBar,
  CONTROL_OWNED_SELECTOR,
  TOP_BAR_DELAY_MS,
  TOP_BAR_CLASS,
} from "../../js/lib/top_bar.js"

/**
 * Top progress bar rules (task 01a166be-b5b9 stage 3, ./js/lib/top_bar.js;
 * canvas 01a167b0 rule 6). Plain node (no jsdom): the document is a stub
 * whose querySelector answers whether a control-owned element exists.
 */

function fakeDoc({ owned = false, primary = "oklch(70% 0.2 50)" } = {}) {
  const queried = []
  return {
    queried,
    documentElement: { primary },
    querySelector(sel) {
      queried.push(sel)
      return owned ? {} : null
    },
  }
}

function fakeWin(doc) {
  const listeners = {}
  return {
    listeners,
    addEventListener: (t, fn) => (listeners[t] = fn),
    removeEventListener: (t) => delete listeners[t],
    getComputedStyle: (el) => ({
      getPropertyValue: (name) => (name === "--color-primary" ? ` ${el.primary} ` : ""),
    }),
    fire(type, detail) {
      listeners[type] && listeners[type]({ detail })
    },
  }
}

function fakeTopbar() {
  const calls = []
  return {
    calls,
    config: (o) => calls.push(["config", o]),
    show: (d) => calls.push(["show", d]),
    hide: () => calls.push(["hide"]),
  }
}

describe("topBarDelay", () => {
  it("shows after 100ms for a navigation no control owns (back/forward, deep link)", () => {
    expect(TOP_BAR_DELAY_MS).toBe(100)
    expect(topBarDelay({ kind: "redirect" })).toBe(100)
    expect(topBarDelay({ kind: "patch" })).toBe(100)
    expect(topBarDelay({ kind: "initial", reconnecting: false })).toBe(100)
  })

  it("does not show when a control owns the navigation", () => {
    for (const kind of ["redirect", "patch", "initial", "element"]) {
      expect(topBarDelay({ kind, controlOwned: true })).toBeNull()
    }
  })

  it("keeps the quiet-reconnect suppression: initial while reconnecting, and error", () => {
    expect(topBarDelay({ kind: "initial", reconnecting: true })).toBeNull()
    expect(topBarDelay({ kind: "error" })).toBeNull()
    expect(topBarDelay({ kind: "redirect", reconnecting: true })).toBe(100)
  })
})

describe("controlOwnsNavigation", () => {
  it("keys on the stage-2 pending mark and on phx-click-loading nav controls", () => {
    expect(CONTROL_OWNED_SELECTOR).toContain("[data-nav-pending]")
    for (const c of [".bottom-nav-tab", ".icon-rail-tab", ".more-sheet-row", ".chat-list-row"]) {
      expect(CONTROL_OWNED_SELECTOR).toContain(`${c}[href].phx-click-loading`)
    }
    expect(controlOwnsNavigation(fakeDoc({ owned: true }))).toBe(true)
    expect(controlOwnsNavigation(fakeDoc({ owned: false }))).toBe(false)
  })
})

describe("topBarOptions", () => {
  it("reads the primary token at runtime: flat bar, 3px, no shadow, safe-area class", () => {
    const doc = fakeDoc({ primary: "oklch(61% 0.18 40)" })
    const opts = topBarOptions(doc, fakeWin(doc))
    expect(opts.barColors).toEqual({ 0: "oklch(61% 0.18 40)", "1.0": "oklch(61% 0.18 40)" })
    expect(opts.barThickness).toBe(3)
    expect(opts.shadowBlur).toBe(0)
    expect(opts.className).toBe(TOP_BAR_CLASS)
    expect(JSON.stringify(opts)).not.toMatch(/#[0-9a-f]{3,8}\b/i)
  })

  it("returns null when the token is missing", () => {
    const doc = fakeDoc({ primary: "" })
    expect(topBarOptions(doc, fakeWin(doc))).toBeNull()
  })
})

describe("installTopBar", () => {
  function setup({ owned = false, reconnecting = false } = {}) {
    const doc = fakeDoc({ owned })
    const win = fakeWin(doc)
    const topbar = fakeTopbar()
    installTopBar({ topbar, win, doc, reconnecting: () => reconnecting })
    return { win, topbar }
  }
  const shows = (t) => t.calls.filter((c) => c[0] === "show")

  it("back/forward: shows after 100ms with the primary colour", () => {
    const { win, topbar } = setup()
    win.fire("phx:page-loading-start", { kind: "redirect", to: "/tasks" })
    expect(shows(topbar)).toEqual([["show", 100]])
    const cfg = topbar.calls.filter((c) => c[0] === "config").pop()[1]
    expect(cfg.barColors[0]).toBe("oklch(70% 0.2 50)")
    win.fire("phx:page-loading-stop", {})
    expect(topbar.calls.pop()).toEqual(["hide"])
  })

  it("deep link (first join, not reconnecting): shows", () => {
    const { win, topbar } = setup()
    win.fire("phx:page-loading-start", { kind: "initial" })
    expect(shows(topbar)).toEqual([["show", 100]])
  })

  it("control-owned navigation: no bar, for the redirect and the new view's join", () => {
    const { win, topbar } = setup({ owned: true })
    win.fire("phx:page-loading-start", { kind: "redirect", to: "/tasks" })
    win.fire("phx:page-loading-start", { kind: "initial", to: "/tasks" })
    expect(shows(topbar)).toEqual([])
  })

  it("rejoin while reconnecting: suppressed", () => {
    const { win, topbar } = setup({ reconnecting: true })
    win.fire("phx:page-loading-start", { kind: "initial" })
    win.fire("phx:page-loading-start", { kind: "error" })
    expect(shows(topbar)).toEqual([])
  })

  it("configures 3px and the safe-area class at install, before any show", () => {
    const { topbar } = setup()
    expect(topbar.calls[0]).toEqual([
      "config",
      { barThickness: 3, shadowBlur: 0, className: TOP_BAR_CLASS },
    ])
  })
})
