// One owner of history and exits for full-window overlays.
//
// This module is the only code in the app that pushes or consumes browser
// history for an overlay. An overlay calls openLayer() when it opens and gets
// a handle back; it never touches history itself.
//
//   - Open pushes exactly one entry per layer, at the SAME url (path and
//     search unchanged), so LiveView's own popstate handler ignores it
//     (live_socket.js registerNewLocation returns false when pathname+search
//     match). The phone's back (Android back, iOS edge swipe in the shell,
//     a desktop browser's back button) then pops that entry.
//   - popstate closes the TOP layer only, never more than one.
//   - Escape closes the top layer only, and is swallowed so a sheet
//     underneath does not also close.
//   - X, swipe-down past SWIPE_CLOSE_PX and handle.close() run onClose and
//     then history.back() once to drop the layer's own entry; the popstate
//     that echoes back is marked consumed so it cannot close the next layer.
//   - Focus moves to the layer's close control on open and returns to
//     returnFocusTo on close.
//
// The close-bar contract both overlay callers use is exported below as class
// names; the rules live in app.css under `.overlay-close-bar` /
// `.overlay-close-control` (bar height 3.5rem PLUS the top safe-area inset,
// padded down by that inset, so the controls always sit below the status
// bar; close control at least 44x44).

export const CLOSE_BAR_CLASS = "overlay-close-bar"
export const CLOSE_CONTROL_CLASS = "overlay-close-control"
export const SWIPE_CLOSE_PX = 120

const stack = []
let installedOn = null
let onPopState = null
let onKeyDown = null
let consumedPops = 0
let nextId = 1

function win() {
  return globalThis.window
}

function install(w) {
  if (installedOn === w) return
  if (installedOn) uninstall()
  onPopState = () => {
    if (consumedPops > 0) {
      consumedPops -= 1
      return
    }
    const top = stack[stack.length - 1]
    // The entry is already gone; close without another history.back().
    if (top) finish(top, { popped: true })
  }
  onKeyDown = (e) => {
    if (e.key !== "Escape" || stack.length === 0) return
    e.preventDefault()
    e.stopImmediatePropagation()
    finish(stack[stack.length - 1], { popped: false })
  }
  w.addEventListener("popstate", onPopState)
  w.addEventListener("keydown", onKeyDown, true)
  installedOn = w
}

function uninstall() {
  if (!installedOn) return
  installedOn.removeEventListener("popstate", onPopState)
  installedOn.removeEventListener("keydown", onKeyDown, true)
  installedOn = null
}

function focusEl(el) {
  if (el && typeof el.focus === "function") {
    try {
      el.focus({ preventScroll: true })
    } catch (_) {}
  }
}

function finish(layer, { popped, runOnClose = true }) {
  if (layer.closed) return
  layer.closed = true
  const i = stack.indexOf(layer)
  if (i !== -1) stack.splice(i, 1)
  layer.unbindSwipe()
  if (runOnClose && typeof layer.onClose === "function") layer.onClose()
  if (!popped) {
    const w = win()
    if (w && w.history && typeof w.history.back === "function") {
      consumedPops += 1
      w.history.back()
    }
  }
  focusEl(layer.returnFocusTo)
}

function bindSwipe(layer, target, canSwipe) {
  if (!target || typeof target.addEventListener !== "function") return () => {}
  const style = layer.el && layer.el.style
  let swipe = null
  let pointers = 0
  const reset = () => {
    swipe = null
    if (style) {
      style.transform = ""
      style.opacity = ""
    }
  }
  const down = (e) => {
    pointers += 1
    if (pointers > 1) {
      // A second finger is a pinch, not a swipe.
      if (swipe) reset()
      return
    }
    if (e.button > 0) return
    if (typeof canSwipe === "function" && !canSwipe(e)) return
    swipe = { id: e.pointerId, y0: e.clientY }
  }
  const move = (e) => {
    if (!swipe || e.pointerId !== swipe.id) return
    const dy = Math.max(0, e.clientY - swipe.y0)
    if (style) {
      style.transform = `translateY(${dy}px)`
      style.opacity = String(1 - Math.min(dy / 400, 0.6))
    }
  }
  const up = (e) => {
    pointers = Math.max(0, pointers - 1)
    if (!swipe || e.pointerId !== swipe.id) return
    const dy = e.clientY - swipe.y0
    swipe = null
    if (dy > SWIPE_CLOSE_PX) {
      finish(layer, { popped: false })
      return
    }
    reset()
  }
  const cancel = () => {
    pointers = Math.max(0, pointers - 1)
    reset()
  }
  target.addEventListener("pointerdown", down)
  target.addEventListener("pointermove", move)
  target.addEventListener("pointerup", up)
  target.addEventListener("pointercancel", cancel)
  return () => {
    target.removeEventListener("pointerdown", down)
    target.removeEventListener("pointermove", move)
    target.removeEventListener("pointerup", up)
    target.removeEventListener("pointercancel", cancel)
  }
}

/**
 * Open a layer. Returns `{ close(), release(), isOpen() }`.
 *
 *   - `el`: the overlay root (its close control is the first
 *     `.overlay-close-control` inside it, or `closeControl`).
 *   - `onClose()`: called exactly once, however the layer closes.
 *   - `swipeTarget`: where swipe-down is read; omit for no swipe.
 *   - `canSwipe(pointerEvent)`: the caller's gate (zoomed image, a mode
 *     whose content owns its gestures); omit to allow every swipe.
 *   - `returnFocusTo`: focused on close.
 */
export function openLayer({ el, onClose, swipeTarget, canSwipe, returnFocusTo, closeControl } = {}) {
  const w = win()
  install(w)
  const layer = {
    id: nextId++,
    el,
    onClose,
    returnFocusTo,
    closed: false,
    unbindSwipe: () => {},
  }
  stack.push(layer)
  if (w && w.history && typeof w.history.pushState === "function") {
    w.history.pushState({ ...(w.history.state || {}), overlayDepth: stack.length }, "", w.location.href)
  }
  layer.unbindSwipe = bindSwipe(layer, swipeTarget, canSwipe)
  const control =
    closeControl || (el && typeof el.querySelector === "function" ? el.querySelector(`.${CLOSE_CONTROL_CLASS}`) : null)
  focusEl(control)

  return {
    close() {
      finish(layer, { popped: false })
    },
    // The overlay is gone without a close (its element was destroyed by a
    // navigation): forget the layer, never call onClose, never go back,
    // because history.back() here would undo the navigation itself.
    release() {
      if (layer.closed) return
      layer.closed = true
      const i = stack.indexOf(layer)
      if (i !== -1) stack.splice(i, 1)
      layer.unbindSwipe()
    },
    isOpen() {
      return !layer.closed
    },
  }
}

/** The number of open layers (for tests and diagnostics). */
export function openLayerCount() {
  return stack.length
}

/** Tests only: drop every layer and listener. */
export function __resetForTests() {
  stack.length = 0
  consumedPops = 0
  uninstall()
}
