// Send feel "4g: Ring + flash" (the variant picked from the 2026-10-23
// prototypes). Decoration only: nothing here can delay or block a send.
//
//   press (pointerdown)  -> Send depresses: scale(.9), brightness(.8), 70ms
//   release              -> it springs back over the same 70ms
//   an actual send       -> a .32s flash-and-overshoot on the button, a ring
//                           going out to 2.3x over .45s, and a vibrate tick
//                           where the platform has one
//
// The state lives on <html> as two attributes (`data-send-down`,
// `data-send-go`), not as classes on the button. The button is
// server-rendered, and the send itself re-renders it (the cleared field
// disables it), so LiveView's patch would strip a class added here mid
// animation. <html> sits outside every LiveView container, the same reason
// ChatDock writes --chat-dock-h there. There is one `.compose-pill-send` in
// the app; app.css keys every rule to it.
//
// Haptics: navigator.vibrate(10) where it exists (Android); iOS ignores it.
// The iOS 18 workaround (clicking the label of a hidden
// `<input type="checkbox" switch>`) was built and DROPPED: in Chromium the
// label click moves focus from the field to the switch (one blur, measured),
// and on iOS a focus move off the field drops the keyboard mid-conversation.
// Restoring focus afterwards would still flicker the keyboard, so there is no
// iOS haptic until there is a native bridge to call.

export const DOWN_ATTR = "data-send-down"
export const GO_ATTR = "data-send-go"
export const SEND_SELECTOR = ".compose-pill-send"

// The longest of the two animations (the ring, .45s), plus a frame. After
// it, `data-send-go` comes off so a disabled Send drops back to its resting
// paint: while the attribute is on, app.css keeps the button lit.
export const GO_MS = 470

export function haptic({ nav = globalThis.navigator } = {}) {
  try {
    if (nav && typeof nav.vibrate === "function") nav.vibrate(10)
  } catch (_e) {
    // A browser that throws on vibrate just gets no tick.
  }
}

// Wires press/release on `form`'s Send and returns `go()` for the caller's
// submit listener plus `detach()`.
export function attachSendFeel(form, { doc = globalThis.document, nav = globalThis.navigator } = {}) {
  const root = doc && doc.documentElement
  if (!form || !root || typeof form.addEventListener !== "function") {
    return { go() {}, detach() {} }
  }

  let timer = null

  const sendOf = (target) =>
    target && typeof target.closest === "function" ? target.closest(SEND_SELECTOR) : null

  const onDown = (e) => {
    const send = sendOf(e.target)
    if (send && !send.disabled) root.setAttribute(DOWN_ATTR, "")
  }
  const onUp = () => root.removeAttribute(DOWN_ATTR)
  // pointerleave does not bubble; pointerout leaving Send for outside it does.
  const onOut = (e) => {
    const send = sendOf(e.target)
    if (send && !(e.relatedTarget && send.contains(e.relatedTarget))) onUp()
  }

  form.addEventListener("pointerdown", onDown)
  form.addEventListener("pointerup", onUp)
  form.addEventListener("pointercancel", onUp)
  form.addEventListener("pointerout", onOut)

  const go = () => {
    haptic({ nav })

    // Restart: off, reflow, on. A rapid second send restarts cleanly.
    root.removeAttribute(GO_ATTR)
    void root.offsetWidth
    root.setAttribute(GO_ATTR, "")
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      root.removeAttribute(GO_ATTR)
    }, GO_MS)
  }

  const detach = () => {
    form.removeEventListener("pointerdown", onDown)
    form.removeEventListener("pointerup", onUp)
    form.removeEventListener("pointercancel", onUp)
    form.removeEventListener("pointerout", onOut)
    if (timer) clearTimeout(timer)
    timer = null
    root.removeAttribute(DOWN_ATTR)
    root.removeAttribute(GO_ATTR)
  }

  return { go, detach }
}
