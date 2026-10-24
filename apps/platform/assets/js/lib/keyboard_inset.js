// Soft-keyboard detection for the phone chat dock (sponsor feedback, 2026-10-23: about
// 85px of empty ground between the composer and the iOS keyboard).
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

// Attaches to window.visualViewport and mirrors the state onto <html> (which
// LiveView never patches). Returns a detach function. A no-op where there is
// no visualViewport.
export function watchKeyboard(win = globalThis.window, doc = globalThis.document) {
  const vv = win && win.visualViewport
  const root = doc && doc.documentElement
  if (!vv || !root || typeof vv.addEventListener !== "function") return () => {}

  let width = win.innerWidth
  let baseline = Math.max(vv.height, win.innerHeight || 0)
  let last = { open: false, inset: 0 }

  const apply = (state) => {
    if (state.open === last.open && state.inset === last.inset) return
    last = state
    if (state.open) {
      root.setAttribute(KEYBOARD_ATTR, "")
      root.style.setProperty(KEYBOARD_INSET_VAR, `${state.inset}px`)
    } else {
      root.removeAttribute(KEYBOARD_ATTR)
      root.style.removeProperty(KEYBOARD_INSET_VAR)
    }
  }

  const update = () => {
    // A rotation or window resize changes what "no keyboard" means.
    if (win.innerWidth !== width) {
      width = win.innerWidth
      baseline = vv.height
    }
    const state = keyboardState({
      innerHeight: win.innerHeight,
      vvHeight: vv.height,
      vvOffsetTop: vv.offsetTop || 0,
      baseline,
    })
    if (!state.open) baseline = Math.max(baseline, vv.height)
    apply(state)
  }

  vv.addEventListener("resize", update)
  vv.addEventListener("scroll", update)
  update()

  return () => {
    vv.removeEventListener("resize", update)
    vv.removeEventListener("scroll", update)
    apply({ open: false, inset: 0 })
  }
}
