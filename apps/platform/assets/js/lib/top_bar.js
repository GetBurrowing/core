// Top progress bar rules (task 01a166be-b5b9 stage 3; design canvas 01a167b0
// "Press and pending feedback", rule 6 and the m1 palette).
//
// The bar is for navigations NO CONTROL OWNS: deep links (the first join)
// and back/forward. When a tapped tab, rail tile, More row or chat row
// already shows the pending state (stage 2, ./nav_pending.js), the bar stays
// hidden, so there is one indicator, not two.
//
// Decision, per `phx:page-loading-start` (pure, see `topBarDelay`):
//   kind "error"                         -> no bar (a drop is not a load)
//   kind "initial" while reconnecting    -> no bar (quiet reconnect, task
//                                           01a12b10; unchanged)
//   a nav control is pending/loading     -> no bar (control-owned). This also
//                                           covers the "initial" join that a
//                                           live navigate fires for the new
//                                           view: the tapped control is still
//                                           marked until it mounts.
//   anything else                        -> bar after TOP_BAR_DELAY_MS (100)
//
// Look: the `primary` token read from the computed CSS variable each time
// the bar shows (so a theme switch is followed), 3px, no shadow, and placed
// below `env(safe-area-inset-top)` by the `.topbar-progress` rule in app.css.

import {NAV_CONTROL_SELECTOR} from "./nav_pending"

export const TOP_BAR_DELAY_MS = 100
export const TOP_BAR_THICKNESS = 3
export const TOP_BAR_CLASS = "topbar-progress"

export const CONTROL_OWNED_SELECTOR = [
  "[data-nav-pending]",
  ...NAV_CONTROL_SELECTOR.split(",").map(s => `${s.trim()}.phx-click-loading`),
].join(", ")

export function controlOwnsNavigation(doc) {
  return !!doc.querySelector(CONTROL_OWNED_SELECTOR)
}

// Returns the delay in ms before the bar shows, or null for no bar.
export function topBarDelay({kind, reconnecting = false, controlOwned = false} = {}) {
  if (kind === "error") return null
  if (kind === "initial" && reconnecting) return null
  if (controlOwned) return null
  return TOP_BAR_DELAY_MS
}

export function primaryColor(doc, win) {
  const value = win.getComputedStyle(doc.documentElement).getPropertyValue("--color-primary")
  return (value || "").trim() || null
}

// Options for topbar.config(): a flat primary bar. Returns null when the
// token cannot be read (the bar then keeps its previous colours).
export function topBarOptions(doc, win) {
  const color = primaryColor(doc, win)
  if (!color) return null
  return {
    barThickness: TOP_BAR_THICKNESS,
    barColors: {0: color, "1.0": color},
    shadowBlur: 0,
    className: TOP_BAR_CLASS,
  }
}

export function installTopBar({
  topbar,
  win = window,
  doc = document,
  reconnecting = () => false,
}) {
  const base = {barThickness: TOP_BAR_THICKNESS, shadowBlur: 0, className: TOP_BAR_CLASS}
  topbar.config(base)

  const onStart = info => {
    const detail = (info && info.detail) || {}
    const delay = topBarDelay({
      kind: detail.kind,
      reconnecting: reconnecting(),
      controlOwned: controlOwnsNavigation(doc),
    })
    if (delay == null) return
    const opts = topBarOptions(doc, win)
    if (opts) topbar.config(opts)
    topbar.show(delay)
  }
  const onStop = () => topbar.hide()

  win.addEventListener("phx:page-loading-start", onStart)
  win.addEventListener("phx:page-loading-stop", onStop)
  return {
    dispose() {
      win.removeEventListener("phx:page-loading-start", onStart)
      win.removeEventListener("phx:page-loading-stop", onStop)
    },
  }
}
