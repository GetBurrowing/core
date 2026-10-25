/**
 * NativeTabBar — bridges the phone tab bar to the iOS app's native Liquid
 * Glass tab bar (task 01a1557b stage 3).
 *
 * Mounts on `#native-tab-bridge`, a hidden span inside `bottom_rail/1`
 * carrying `data-items` (the bar's tab keys, in order, More last),
 * `data-active-key`, `data-more-unread` and `data-more-open`. Those change on
 * every re-render, so `updated()` re-sends the state.
 *
 * ACTIVE ONLY IN A NATIVE BUILD THAT HAS THE BAR: `isNativePlatform()`, a
 * plugin (BurrowNative, else SuiteNative) with a `tabBarState` method, and
 * `<html data-native-tab-bar>` (set by the app's document-start script). A
 * browser, a PWA and an older app build fail that test, and the hook then
 * adds no listener and makes no call, so the web bar behaves as on main.
 *
 * CONTRACT (stage 2, NativeTabBar.swift):
 *   web to native  tabBarState({items, selected, more_dot, visible})
 *   native to web  window event `burrowNativeTab`, detail {key, reselect}
 *
 * `visible` is false wherever the web bar itself would be hidden (app.css:
 * a focused ComposeInput, a full-screen viewer, the in-call room), at the
 * desktop width (min-width 1024px, where the web shows its rail), and while
 * any sheet other than the More sheet is open: on the web those sheets cover
 * the bar, and a native bar cannot be covered, so it gets out of the way.
 *
 * A tap clicks the matching `#bottom-nav [data-destination]` element, so it
 * reuses the bar's navigate links and the More button's phx-click. A
 * reselect scrolls the main scroller to the top, or, when it is already at
 * the top, clicks the tab to go back to the module root. More always clicks
 * (it toggles its sheet).
 *
 * Every plugin promise ends in a catch.
 */

export const EVENT = "burrowNativeTab"
export const ATTR = "data-native-tab-bar"
export const DESKTOP_QUERY = "(min-width: 1024px)"
export const HIDE_SELECTOR =
  ':root:has([phx-hook="ComposeInput"]:focus), :root:has([data-fullscreen-viewer]), :root:has([data-in-call])'
export const OTHER_SHEET_SELECTOR = ".sheet-open:not(#more-sheet)"
// A tab change remounts the LiveView, and with it this span. The hide that
// `destroyed()` sends waits this long, and a mount inside it cancels the
// hide, so moving between tabs never blinks the native bar.
export const DESTROY_GRACE_MS = 300

let pendingHide = null

// The plugin when the native bar is available, else null.
export function tabBarPlugin(win = globalThis.window, doc = globalThis.document) {
  const cap = win?.Capacitor
  if (!cap?.isNativePlatform?.()) return null
  const plugin = cap.Plugins?.BurrowNative || cap.Plugins?.SuiteNative
  if (!plugin || typeof plugin.tabBarState !== "function") return null
  if (!doc?.documentElement?.hasAttribute?.(ATTR)) return null
  return plugin
}

function send(plugin, state) {
  try {
    Promise.resolve(plugin.tabBarState(state)).catch(() => {})
  } catch (_e) {
    // A synchronous throw is swallowed the same way.
  }
}

export function itemsOf(el) {
  return (el.getAttribute("data-items") || "").split(",").filter((k) => k !== "")
}

// Whether the bar should show, by the web bar's own hide rules.
export function barVisible(win, doc) {
  if (win.matchMedia && win.matchMedia(DESKTOP_QUERY).matches) return false
  const root = doc.documentElement
  try {
    if (root.matches(HIDE_SELECTOR)) return false
  } catch (_e) {
    // No :has support: fall through to the sheet check.
  }
  if (doc.querySelector(OTHER_SHEET_SELECTOR)) return false
  return true
}

export function stateOf(el, win, doc) {
  const active = el.getAttribute("data-active-key")
  return {
    items: itemsOf(el),
    selected: active ? active : null,
    more_dot: el.getAttribute("data-more-unread") === "true",
    visible: barVisible(win, doc),
  }
}

// The element that scrolls the page: the tallest scrolling element under
// <main data-scroll-container> (the shell's <main> does not scroll itself).
export function mainScroller(win, doc) {
  const main = doc.querySelector("[data-scroll-container]")
  if (!main) return null
  let best = null
  for (const el of [main, ...main.querySelectorAll("*")]) {
    if (!(el.scrollHeight > el.clientHeight)) continue
    const oy = win.getComputedStyle ? win.getComputedStyle(el).overflowY : ""
    if (oy !== "auto" && oy !== "scroll") continue
    if (!best || el.clientHeight > best.clientHeight) best = el
  }
  return best
}

function reducedMotion(win) {
  return !!(win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches)
}

const NativeTabBar = {
  mounted() {
    this.win = this.win || window
    this.doc = this.doc || document
    this.plugin = tabBarPlugin(this.win, this.doc)
    if (!this.plugin) return

    if (pendingHide) {
      this.win.clearTimeout(pendingHide)
      pendingHide = null
    }

    this.sync = () => this.push()

    this.onTab = (e) => this.handleTab(e && e.detail)
    this.win.addEventListener(EVENT, this.onTab)
    this.doc.addEventListener("focusin", this.sync)
    this.doc.addEventListener("focusout", this.sync)

    this.observer = new MutationObserver(this.sync)
    this.observer.observe(this.doc.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["data-fullscreen-viewer", "data-in-call", "class"],
    })

    this.mql = this.win.matchMedia ? this.win.matchMedia(DESKTOP_QUERY) : null
    if (this.mql && this.mql.addEventListener) this.mql.addEventListener("change", this.sync)

    this.last = null
    this.push()
  },

  updated() {
    if (this.plugin) this.push()
  },

  destroyed() {
    if (!this.plugin) return
    this.win.removeEventListener(EVENT, this.onTab)
    this.doc.removeEventListener("focusin", this.sync)
    this.doc.removeEventListener("focusout", this.sync)
    if (this.observer) this.observer.disconnect()
    if (this.mql && this.mql.removeEventListener) this.mql.removeEventListener("change", this.sync)

    const plugin = this.plugin
    const state = { ...(this.last || stateOf(this.el, this.win, this.doc)), visible: false }
    if (pendingHide) this.win.clearTimeout(pendingHide)
    pendingHide = this.win.setTimeout(() => {
      pendingHide = null
      send(plugin, state)
    }, DESTROY_GRACE_MS)
  },

  // Send the state when it differs from the last one sent.
  push() {
    const state = stateOf(this.el, this.win, this.doc)
    const key = JSON.stringify(state)
    if (key === this.lastKey) return
    this.lastKey = key
    this.last = state
    send(this.plugin, state)
  },

  tab(key) {
    return this.doc.querySelector(`#bottom-nav [data-destination="${key}"]`)
  },

  handleTab(detail) {
    if (!detail || typeof detail.key !== "string") return
    const tab = this.tab(detail.key)
    if (!tab) return

    if (detail.reselect !== true || detail.key === "more") {
      tab.click()
      return
    }

    const scroller = mainScroller(this.win, this.doc)
    if (scroller && scroller.scrollTop > 0) {
      scroller.scrollTo({ top: 0, behavior: reducedMotion(this.win) ? "auto" : "smooth" })
    } else {
      tab.click()
    }
  },
}

export default NativeTabBar
