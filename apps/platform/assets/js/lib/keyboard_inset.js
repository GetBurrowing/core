// Soft-keyboard detection for the phone chat dock (sponsor feedback, 2026-10-23: about
// 85px of empty ground between the composer and the iOS keyboard), and for
// every bottom sheet (the Sheet hook), which clamps itself above the keyboard.
//
// Why CSS alone could not do it. The focused-composer rule in app.css drops
// the tab bar's height from --bottom-nav-clearance but keeps
// env(safe-area-inset-bottom), on the theory that "the keyboard covers the
// home indicator". iOS keeps reporting the 34px inset with the keyboard up,
// and iOS does not shrink the layout viewport for the keyboard (it pans the
// visual viewport instead), so whatever padding sits under the composer at the
// bottom of the layout is what shows above the keyboard. Focus is also only a
// proxy: it cannot tell a raised keyboard from a dismissed one.
//
// visualViewport can. While the keyboard is up its height drops well below the
// tallest height seen at the current width. That comparison works whether the
// browser pans the visual viewport (iOS) or resizes the layout
// (Android with `interactive-widget=resizes-content`), where innerHeight
// shrinks with it and a plain innerHeight - visualViewport.height reads 0.
//
// `inset` is the part of the LAYOUT viewport hidden under the keyboard after
// any pan: 0 once iOS has panned all the way down, positive if it panned less.
// The dock rises by it, so it ends on the keyboard either way.

// A soft keyboard is ~260px and up; browser chrome collapsing or expanding
// is under ~120px. Anything between is ambiguous and reads as "closed".
export const KEYBOARD_MIN_PX = 150

export const KEYBOARD_ATTR = "data-keyboard-open"
export const KEYBOARD_INSET_VAR = "--keyboard-inset"

// Pure, for the tests. `baseline` is the tallest visual viewport height seen
// at the current width (the no-keyboard height).
export function keyboardState({ innerHeight, vvHeight, vvOffsetTop, baseline }) {
  const open = baseline - vvHeight >= KEYBOARD_MIN_PX
  const inset = open ? Math.max(0, Math.round(innerHeight - vvHeight - vvOffsetTop)) : 0
  return { open, inset }
}

// The visible height while the keyboard is up, so a bottom sheet can clamp
// itself to what the viewer can actually see. Set and cleared together with
// KEYBOARD_INSET_VAR.
export const VISUAL_VIEWPORT_H_VAR = "--visual-viewport-h"

// One watcher per visualViewport, shared by every caller (the chat dock and
// every Sheet). Callers attach and detach independently; the listeners and the
// state on <html> live until the LAST caller detaches. Without the count, the
// first caller to detach would clear the attribute under the others.
const watchers = new WeakMap()

function startWatcher(win, vv, root) {
  let width = win.innerWidth
  let baseline = Math.max(vv.height, win.innerHeight || 0)
  let last = { open: false, inset: 0, height: 0 }
  // The no-keyboard height per width, so rotating back to a width already
  // seen restores its real baseline. Without it, a keyboard that stays up
  // through a rotation became the new baseline and read as closed: back in
  // portrait the dock sat behind the keyboard with the @mention list
  // (measured, iOS 26.3 Simulator Safari, task 01a1c863 stage 3: vv 409 of
  // 714 after landscape -> portrait, data-keyboard-open absent).
  const baselines = new Map([[width, baseline]])

  const apply = (state) => {
    if (state.open === last.open && state.inset === last.inset && state.height === last.height) return
    last = state
    if (state.open) {
      root.setAttribute(KEYBOARD_ATTR, "")
      root.style.setProperty(KEYBOARD_INSET_VAR, `${state.inset}px`)
      root.style.setProperty(VISUAL_VIEWPORT_H_VAR, `${state.height}px`)
    } else {
      root.removeAttribute(KEYBOARD_ATTR)
      root.style.removeProperty(KEYBOARD_INSET_VAR)
      root.style.removeProperty(VISUAL_VIEWPORT_H_VAR)
    }
  }

  const update = () => {
    // A rotation or window resize changes what "no keyboard" means.
    if (win.innerWidth !== width) {
      width = win.innerWidth
      baseline = baselines.get(width) ?? vv.height
    }
    const state = keyboardState({
      innerHeight: win.innerHeight,
      vvHeight: vv.height,
      vvOffsetTop: vv.offsetTop || 0,
      baseline,
    })
    if (!state.open) baseline = Math.max(baseline, vv.height)
    baselines.set(width, baseline)
    apply({ ...state, height: state.open ? Math.round(vv.height) : 0 })
  }

  vv.addEventListener("resize", update)
  vv.addEventListener("scroll", update)
  update()

  return {
    count: 0,
    stop() {
      vv.removeEventListener("resize", update)
      vv.removeEventListener("scroll", update)
      apply({ open: false, inset: 0, height: 0 })
    },
  }
}

// Attaches to window.visualViewport and mirrors the state onto <html> (which
// LiveView never patches). Returns this caller's detach function; calling it
// twice counts once. A no-op where there is no visualViewport.
export function watchKeyboard(win = globalThis.window, doc = globalThis.document) {
  const vv = win && win.visualViewport
  const root = doc && doc.documentElement
  if (!vv || !root || typeof vv.addEventListener !== "function") return () => {}

  let watcher = watchers.get(vv)
  if (!watcher) {
    watcher = startWatcher(win, vv, root)
    watchers.set(vv, watcher)
  }
  watcher.count += 1

  let attached = true
  return () => {
    if (!attached) return
    attached = false
    watcher.count -= 1
    if (watcher.count > 0) return
    watchers.delete(vv)
    watcher.stop()
  }
}

// The visible viewport in CLIENT coordinates, the space getBoundingClientRect
// returns (task 01a1c863). Every "room above the composer" measurement must
// subtract this top, never `visualViewport.offsetTop` directly.
//
// Why not offsetTop. Client rects are relative to the layout viewport, and
// offsetTop is the visual viewport's offset from it, so in Chromium (pinch
// zoom, the CDP keyboard of #150) `offsetTop` IS the visible top in client
// space. iOS WebKit with the keyboard up disagrees with itself: it scrolls the
// document (scrollY 337) and reports client rects against that scrolled view,
// so the visible band is client 0..visualViewport.height, yet it still reports
// offsetTop 337. Subtracting it counted the pan twice and clamped the
// @mention list to 0px (measured, iOS 26.3 Simulator Mobile Safari).
//
// `pageTop - scrollY` is the same quantity in both engines: pageTop is the
// visual viewport's top in document coordinates and scrollY is the layout
// viewport's, so their difference is the visible top in client space
// (Chromium: scrollY + offsetTop - scrollY = offsetTop; WebKit: 337 - 337 =
// 0). Where either is missing (older engines, the unit tests' mocks), fall
// back to offsetTop, which is what #150 used.
function clientOffset(page, scroll, offset) {
  if (Number.isFinite(page) && Number.isFinite(scroll)) return page - scroll
  return offset || 0
}

export function visibleViewportRect(win = globalThis.window) {
  const vv = win?.visualViewport
  const width = vv?.width ?? win?.innerWidth ?? Infinity
  const height = vv?.height ?? win?.innerHeight ?? Infinity
  if (!vv) return { top: 0, left: 0, width, height }
  return {
    top: clientOffset(vv.pageTop, win.scrollY, vv.offsetTop),
    left: clientOffset(vv.pageLeft, win.scrollX, vv.offsetLeft),
    width,
    height,
  }
}

// The room for an upward-opening list whose bottom edge sits on `anchorTop`
// (a client y), bounded by the visible viewport's top and by `ceilingTop`
// (a client y such as the chat zone's top, below the header), less `gap`.
// Shared by the channel composer (ChatDock) and the thread reply
// (ComposeInput) so the two cannot drift apart again.
export function roomAbove(anchorTop, { win = globalThis.window, ceilingTop = -Infinity, gap = 0 } = {}) {
  const top = Math.max(visibleViewportRect(win).top, ceilingTop)
  return Math.max(0, Math.floor(anchorTop - top - gap))
}
