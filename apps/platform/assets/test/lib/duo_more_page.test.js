import { describe, it, expect, vi } from "vitest"
import installDuoMorePage, {
  DUO_ATTR,
  DUO_OPEN_ATTR,
  MORE_PATH,
  MORE_SELECTOR,
  openDuo,
} from "../../js/lib/duo_more_page.js"
import * as NativeBack from "../../js/hooks/native_back.js"

/**
 * DuoMorePage (task 01a1fc7f stage 2). vitest runs in plain node, so window,
 * document and the controls are fakes. The gating cases mirror
 * native_back.test.js: the attribute set on <html> decides everything, and it
 * is read at click time.
 */

function env({ duo = true, open = true, path = "/chat" } = {}) {
  const attrs = { [DUO_ATTR]: duo, [DUO_OPEN_ATTR]: open }
  const root = { hasAttribute: (n) => attrs[n] === true }
  const page = { scrollTo: vi.fn() }
  const main = { scrollTo: vi.fn() }
  const navigate = vi.fn()
  const socket = { js: () => ({ navigate }) }
  const listeners = []
  const win = {
    location: { pathname: path, assign: vi.fn() },
    matchMedia: () => ({ matches: false }),
    addEventListener: (name, fn, capture) => listeners.push({ name, fn, capture }),
    removeEventListener: (name, fn) => {
      const i = listeners.findIndex((l) => l.name === name && l.fn === fn)
      if (i >= 0) listeners.splice(i, 1)
    },
  }
  const doc = {
    documentElement: root,
    querySelector: (sel) => (sel === "#more-page" ? page : sel === "main[data-scroll-container]" ? main : null),
  }
  const uninstall = installDuoMorePage(win, doc, () => socket)

  // A click as the browser's window capture phase would deliver it.
  const click = (target) => {
    const e = {
      target,
      defaultPrevented: false,
      propagationStopped: false,
      preventDefault() {
        this.defaultPrevented = true
      },
      stopImmediatePropagation() {
        this.propagationStopped = true
      },
    }
    for (const l of listeners.filter((l) => l.name === "click")) l.fn(e)
    return e
  }

  return { attrs, win, doc, page, main, navigate, listeners, click, uninstall }
}

// A control the More selector matches (the More tab or an open_more_sheet
// Back), and one it does not (any other tab).
const moreTab = { closest: (sel) => (sel === MORE_SELECTOR ? moreTab : null) }
const otherTab = { closest: () => null }

describe("attribute names", () => {
  it("are native_back.js's own bindings, the copy the Swift contract test pins", () => {
    expect(DUO_ATTR).toBe(NativeBack.DUO_ATTR)
    expect(DUO_OPEN_ATTR).toBe(NativeBack.DUO_OPEN_ATTR)
    expect(DUO_OPEN_ATTR).toBe("data-native-duo-open")
  })
})

describe("selector", () => {
  it("catches the More tab button and every open_more_sheet control", () => {
    expect(MORE_SELECTOR).toContain('#bottom-nav button[data-destination="more"]')
    expect(MORE_SELECTOR).toContain('[phx-click="open_more_sheet"]')
  })

  it("installs one window listener, in the capture phase", () => {
    const t = env()
    expect(t.listeners.filter((l) => l.name === "click")).toHaveLength(1)
    expect(t.listeners[0].capture).toBe(true)
  })
})

describe("posture gate", () => {
  it("regular iPhone (no data-native-duo): the click passes through, no navigate", () => {
    const t = env({ duo: false, open: false })
    const e = t.click(moreTab)
    expect(t.navigate).not.toHaveBeenCalled()
    expect(e.defaultPrevented).toBe(false)
    expect(e.propagationStopped).toBe(false)
  })

  it("regular iPhone with a stray -open attribute only: still passes through", () => {
    const t = env({ duo: false, open: true })
    const e = t.click(moreTab)
    expect(t.navigate).not.toHaveBeenCalled()
    expect(e.propagationStopped).toBe(false)
  })

  it("closed Duo (data-native-duo without -open): passes through to the sheet", () => {
    const t = env({ duo: true, open: false })
    const e = t.click(moreTab)
    expect(t.navigate).not.toHaveBeenCalled()
    expect(e.defaultPrevented).toBe(false)
    expect(e.propagationStopped).toBe(false)
  })

  it("open Duo: navigates to /more and the event goes no further", () => {
    const t = env()
    const e = t.click(moreTab)
    expect(t.navigate).toHaveBeenCalledWith(MORE_PATH)
    expect(e.defaultPrevented).toBe(true)
    expect(e.propagationStopped).toBe(true)
  })

  it("open Duo, another control: untouched", () => {
    const t = env()
    const e = t.click(otherTab)
    expect(t.navigate).not.toHaveBeenCalled()
    expect(e.propagationStopped).toBe(false)
  })

  it("removing -open between two clicks flips the behaviour live", () => {
    const t = env()
    t.click(moreTab)
    expect(t.navigate).toHaveBeenCalledTimes(1)

    t.attrs[DUO_OPEN_ATTR] = false
    const e = t.click(moreTab)
    expect(t.navigate).toHaveBeenCalledTimes(1)
    expect(e.propagationStopped).toBe(false)

    t.attrs[DUO_OPEN_ATTR] = true
    t.click(moreTab)
    expect(t.navigate).toHaveBeenCalledTimes(2)
  })

  it("openDuo needs both attributes", () => {
    expect(openDuo(env({ duo: true, open: true }).doc)).toBe(true)
    expect(openDuo(env({ duo: true, open: false }).doc)).toBe(false)
    expect(openDuo(env({ duo: false, open: true }).doc)).toBe(false)
    expect(openDuo(null)).toBe(false)
  })
})

describe("on /more already (More reselect)", () => {
  it("scrolls the page to the top and does not navigate", () => {
    const t = env({ path: MORE_PATH })
    const e = t.click(moreTab)
    expect(t.navigate).not.toHaveBeenCalled()
    expect(t.page.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" })
    expect(e.propagationStopped).toBe(true)
  })
})

describe("from Settings", () => {
  it("More (or Settings' Back) pops to /more", () => {
    const t = env({ path: "/settings" })
    t.click(moreTab)
    expect(t.navigate).toHaveBeenCalledWith(MORE_PATH)
  })
})

describe("uninstall", () => {
  it("removes the listener", () => {
    const t = env()
    t.uninstall()
    t.click(moreTab)
    expect(t.navigate).not.toHaveBeenCalled()
  })
})
