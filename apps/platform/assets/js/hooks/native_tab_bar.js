/**
 * NativeTabBar — bridges the phone tab bar to the iOS app's native Liquid
 * Glass tab bar (task 01a1557b stage 3).
 *
 * Mounts on `#native-tab-bridge`, a hidden span inside `bottom_rail/1`
 * carrying `data-items` (the bar's tab keys, in order, More last),
 * `data-active-key`, `data-inbox-unread` and `data-more-open`. Those change on
 * every re-render, so `updated()` re-sends the state.
 *
 * ACTIVE ONLY IN A NATIVE BUILD THAT HAS THE BAR: `isNativePlatform()`, a
 * plugin (BurrowNative, else SuiteNative) with a `tabBarState` method, and
 * `<html data-native-tab-bar>` (set by the app's document-start script). A
 * browser, a PWA and an older app build fail that test, and the hook then
 * adds no listener and makes no call, so the web bar behaves as on main.
 *
 * CONTRACT (stage 2, NativeTabBar.swift):
 *   web to native  tabBarState({items, selected, inbox_dot, visible, ink, scheme})
 *   native to web  window event `burrowNativeTab`, detail {key, reselect}
 *
 * `ink` (task 01a174e8 stage 1) is `{selected, unselected}`, each a
 * '#rrggbbaa' string: the inks this bar paints, resolved by app.css onto two
 * hidden probes inside the span (`[data-native-ink]`) and read back with
 * getComputedStyle. A computed colour can be in any CSS syntax (oklab() for a
 * color-mix, color(srgb ...) in WebKit), so it is normalised through a 1x1
 * canvas 2D context (`canvasNormaliser`, injectable for tests). A value that
 * does not normalise drops ITS key; garbage is never sent. `scheme` is
 * 'light' or 'dark': `<html data-theme>` when it is one of those, else
 * prefers-color-scheme, the same rule the app's syncStatusBarWithWebTheme
 * uses. A theme change (data-theme, data-preset, an inline style on <html>,
 * the install theme's <style> swap, or the system appearance) re-pushes.
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
export const SCHEME_QUERY = "(prefers-color-scheme: dark)"
export const INK_KEYS = ["selected", "unselected"]
export const OBSERVED_ATTRIBUTES = [
  "data-fullscreen-viewer",
  "data-in-call",
  "class",
  "data-theme",
  "data-preset",
  "style",
]

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

const hex2 = (n) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, "0")
const toHex = (r, g, b, a) => `#${hex2(r)}${hex2(g)}${hex2(b)}${hex2(a * 255)}`

// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()` and `color(srgb ...)`, the
// forms a canvas fillStyle serialises to, as '#rrggbbaa'; null otherwise.
export function parseSerialisedColour(value) {
  const v = String(value).trim().toLowerCase()
  let m = v.match(/^#([0-9a-f]{3})$/)
  if (m) return toHex(...[...m[1]].map((c) => parseInt(c + c, 16)), 1)
  m = v.match(/^#([0-9a-f]{6})([0-9a-f]{2})?$/)
  if (m) return `#${m[1]}${m[2] || "ff"}`
  const num = "([0-9.]+%?)"
  m = v.match(new RegExp(`^rgba?\\(\\s*${num}[\\s,]+${num}[\\s,]+${num}(?:\\s*[,/]\\s*${num})?\\s*\\)$`))
  if (m) {
    const ch = (x) => (x.endsWith("%") ? (parseFloat(x) * 255) / 100 : parseFloat(x))
    const al = (x) => (x === undefined ? 1 : x.endsWith("%") ? parseFloat(x) / 100 : parseFloat(x))
    const out = [ch(m[1]), ch(m[2]), ch(m[3]), al(m[4])]
    return out.every(Number.isFinite) ? toHex(...out) : null
  }
  m = v.match(new RegExp(`^color\\(srgb\\s+${num}\\s+${num}\\s+${num}(?:\\s*/\\s*${num})?\\s*\\)$`))
  if (m) {
    const ch = (x) => (x.endsWith("%") ? (parseFloat(x) * 255) / 100 : parseFloat(x) * 255)
    const al = (x) => (x === undefined ? 1 : x.endsWith("%") ? parseFloat(x) / 100 : parseFloat(x))
    const out = [ch(m[1]), ch(m[2]), ch(m[3]), al(m[4])]
    return out.every(Number.isFinite) ? toHex(...out) : null
  }
  return null
}

// A normaliser backed by a 1x1 canvas 2D context: any CSS colour the engine
// understands becomes '#rrggbbaa'; anything else becomes null. An invalid
// value leaves fillStyle untouched, so it is set over two different sentinels
// and must read back the same both times. A fillStyle that serialises in a
// form `parseSerialisedColour` does not know (a wide-gamut colour()) is read
// back from the painted pixel instead. Results are memoised per input.
export function canvasNormaliser(doc) {
  const memo = new Map()
  let ctx
  return (value) => {
    if (typeof value !== "string" || value.trim() === "") return null
    if (memo.has(value)) return memo.get(value)
    let out = null
    try {
      if (ctx === undefined) {
        const canvas = doc?.createElement?.("canvas")
        if (canvas) canvas.width = canvas.height = 1
        ctx = canvas?.getContext?.("2d", { willReadFrequently: true }) || null
      }
      if (ctx) {
        ctx.fillStyle = "#000000"
        ctx.fillStyle = value
        const overBlack = ctx.fillStyle
        ctx.fillStyle = "#ffffff"
        ctx.fillStyle = value
        if (ctx.fillStyle === overBlack) {
          out = parseSerialisedColour(overBlack)
          if (out === null) {
            ctx.clearRect(0, 0, 1, 1)
            ctx.fillRect(0, 0, 1, 1)
            const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data
            out = toHex(r, g, b, a / 255)
          }
        }
      }
    } catch (_e) {
      out = null
    }
    memo.set(value, out)
    return out
  }
}

// The two inks app.css resolves onto the bridge's probes. A probe that is
// missing, or a colour that does not normalise, leaves its key out.
export function inksOf(el, win, normalise) {
  const ink = {}
  if (!normalise || typeof el.querySelector !== "function" || !win?.getComputedStyle) return ink
  for (const key of INK_KEYS) {
    const probe = el.querySelector(`[data-native-ink="${key}"]`)
    if (!probe) continue
    let colour = null
    try {
      colour = normalise(win.getComputedStyle(probe).color)
    } catch (_e) {
      colour = null
    }
    if (typeof colour === "string" && /^#[0-9a-f]{8}$/.test(colour)) ink[key] = colour
  }
  return ink
}

// 'light' or 'dark': the web theme when it names one, else the system's.
export function schemeOf(win, doc) {
  const theme = doc?.documentElement?.getAttribute?.("data-theme")
  if (theme === "light" || theme === "dark") return theme
  return win?.matchMedia && win.matchMedia(SCHEME_QUERY).matches ? "dark" : "light"
}

export function stateOf(el, win, doc, normalise = null) {
  const active = el.getAttribute("data-active-key")
  return {
    items: itemsOf(el),
    selected: active ? active : null,
    inbox_dot: el.getAttribute("data-inbox-unread") === "true",
    visible: barVisible(win, doc),
    ink: inksOf(el, win, normalise),
    scheme: schemeOf(win, doc),
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
    this.normalise = this.normalise || canvasNormaliser(this.doc)

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
      attributeFilter: OBSERVED_ATTRIBUTES,
    })

    this.mql = this.win.matchMedia ? this.win.matchMedia(DESKTOP_QUERY) : null
    if (this.mql && this.mql.addEventListener) this.mql.addEventListener("change", this.sync)
    this.schemeMql = this.win.matchMedia ? this.win.matchMedia(SCHEME_QUERY) : null
    if (this.schemeMql && this.schemeMql.addEventListener) this.schemeMql.addEventListener("change", this.sync)

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
    if (this.schemeMql && this.schemeMql.removeEventListener) this.schemeMql.removeEventListener("change", this.sync)

    const plugin = this.plugin
    const state = { ...(this.last || stateOf(this.el, this.win, this.doc, this.normalise)), visible: false }
    if (pendingHide) this.win.clearTimeout(pendingHide)
    pendingHide = this.win.setTimeout(() => {
      pendingHide = null
      send(plugin, state)
    }, DESTROY_GRACE_MS)
  },

  // Send the state when it differs from the last one sent.
  push() {
    const state = stateOf(this.el, this.win, this.doc, this.normalise)
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
