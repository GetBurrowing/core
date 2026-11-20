/**
 * NativeBack — exposes the web header's Back and the phone modal Close to the
 * iOS app over a `navBarState` bridge, so the iPhone Duo can draw the system
 * Back (or Close) at the top of its side strip (task 01a1fa7c stage 3).
 *
 * MOUNT POINT: installed once, globally, from app.js (`installNativeBack`),
 * not as a `phx-hook`. A tab change remounts the LiveView and with it
 * `#native-tab-bridge`, and dead views and pages outside the shell carry
 * Back controls too; a document-level install survives every remount and
 * needs no element of its own. It is separate from native_tab_bar.js, whose
 * `HIDE_SELECTOR` another task owns.
 *
 * ACTIVE ONLY IN A NATIVE BUILD THAT HAS THE BRIDGE: `isNativePlatform()`, a
 * plugin (BurrowNative, else SuiteNative) with a `navBarState` method, and
 * `<html data-native-tab-bar>`. A browser, a PWA, an older app build and a
 * build without the method fail that test; the install then adds no listener
 * and makes no call, so every page behaves as on main.
 *
 * CONTRACT:
 *   web to native  navBarState({back: {kind: "back" | "close", label} | null})
 *   native to web  window event `burrowNativeBack` (no detail needed)
 *
 * Controls opt in with `data-native-back="back"` (a phone page header's
 * chevron) or `data-native-back="close"` (a full-screen phone modal's x).
 * `back` describes the first visible Close if there is one, else the first
 * visible Back, else null (a tab root). Close wins because a full-screen
 * modal sits over the page whose header Back is still in the DOM, and the
 * strip must dismiss the modal, not leave the page under it. `label` is the
 * control's aria-label, else "Back" / "Close".
 *
 * "Visible" means visible WITHOUT the hide rule: native sets
 * `<html data-native-vertical-bar>` in the same frame as it draws the item,
 * and app.css then sets every `[data-native-back]` to `display: none`, which
 * takes it out of the accessibility tree too. So while that attribute is set,
 * a control's own display is not read, only its ancestors' (and its `hidden`
 * attribute). At the desktop width (1024px, where the web shows its rail)
 * nothing is reported.
 *
 * On `burrowNativeBack` the hook re-resolves the control and `.click()`s it,
 * so the native item drives the web's own link or phx-click: one navigation
 * path. State re-sends (only when it changed) on DOM mutation and on
 * LiveView navigation (`phx:page-loading-stop`). Every plugin promise ends in
 * a catch.
 */

export const EVENT = "burrowNativeBack"
export const ATTR = "data-native-tab-bar"
export const MARKER = "data-native-back"
export const DRAWN_ATTR = "data-native-vertical-bar"
export const METHOD = "navBarState"
export const KINDS = ["back", "close"]
export const DEFAULT_LABELS = { back: "Back", close: "Close" }
export const DESKTOP_QUERY = "(min-width: 1024px)"
export const NAV_EVENT = "phx:page-loading-stop"
export const OBSERVED_ATTRIBUTES = [MARKER, DRAWN_ATTR, "class", "hidden", "style", "aria-label"]

// The plugin when native can draw the nav item, else null.
export function navBarPlugin(win = globalThis.window, doc = globalThis.document) {
  const cap = win?.Capacitor
  if (!cap?.isNativePlatform?.()) return null
  const plugin = cap.Plugins?.BurrowNative || cap.Plugins?.SuiteNative
  if (!plugin || typeof plugin[METHOD] !== "function") return null
  if (!doc?.documentElement?.hasAttribute?.(ATTR)) return null
  return plugin
}

function send(plugin, state) {
  try {
    Promise.resolve(plugin.navBarState(state)).catch(() => {})
  } catch (_e) {
    // A synchronous throw is swallowed the same way.
  }
}

function hiddenByStyle(win, node) {
  if (node.hidden) return true
  if (!win?.getComputedStyle) return false
  const style = win.getComputedStyle(node)
  return style.display === "none"
}

// Whether `el` would show if the hide rule did not apply.
export function wouldBeVisible(el, win, doc) {
  if (!el || el.isConnected === false) return false
  if (el.hidden) return false
  const drawn = doc.documentElement.hasAttribute(DRAWN_ATTR)
  if (!drawn && hiddenByStyle(win, el)) return false
  if (win?.getComputedStyle && win.getComputedStyle(el).visibility === "hidden") return false
  for (let node = el.parentElement; node && node !== doc.documentElement; node = node.parentElement) {
    if (hiddenByStyle(win, node)) return false
  }
  return true
}

// The control native should mirror: the first visible Close, else the first
// visible Back, else null.
export function backTarget(win, doc) {
  if (win?.matchMedia && win.matchMedia(DESKTOP_QUERY).matches) return null
  const all = Array.from(doc.querySelectorAll(`[${MARKER}]`))
  for (const kind of ["close", "back"]) {
    const el = all.find((c) => c.getAttribute(MARKER) === kind && wouldBeVisible(c, win, doc))
    if (el) return el
  }
  return null
}

export function labelOf(el, kind) {
  const label = (el.getAttribute("aria-label") || "").trim()
  return label === "" ? DEFAULT_LABELS[kind] : label
}

export function stateOf(win, doc) {
  const el = backTarget(win, doc)
  if (!el) return { back: null }
  const kind = el.getAttribute(MARKER)
  return { back: { kind, label: labelOf(el, kind) } }
}

// Installs the bridge; returns an uninstall function (a no-op when inactive).
export function installNativeBack(win = globalThis.window, doc = globalThis.document) {
  const plugin = navBarPlugin(win, doc)
  if (!plugin) return () => {}

  let lastKey = null
  const push = () => {
    const state = stateOf(win, doc)
    const key = JSON.stringify(state)
    if (key === lastKey) return
    lastKey = key
    send(plugin, state)
  }

  const onBack = () => {
    const el = backTarget(win, doc)
    if (el) el.click()
  }

  win.addEventListener(EVENT, onBack)
  win.addEventListener(NAV_EVENT, push)

  const MO = win.MutationObserver || globalThis.MutationObserver
  const observer = MO ? new MO(push) : null
  if (observer) {
    observer.observe(doc.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: OBSERVED_ATTRIBUTES,
    })
  }

  const mql = win.matchMedia ? win.matchMedia(DESKTOP_QUERY) : null
  if (mql && mql.addEventListener) mql.addEventListener("change", push)

  push()

  return () => {
    win.removeEventListener(EVENT, onBack)
    win.removeEventListener(NAV_EVENT, push)
    if (observer) observer.disconnect()
    if (mql && mql.removeEventListener) mql.removeEventListener("change", push)
  }
}

export default installNativeBack
