// Double-tap gesture detector for chat messages (mobile).
//
// Fires `open_message_actions` ({id: messageId}) on a double-tap of any
// message bubble — own, others-human, or AI alike. The server opens the
// per-message bottom sheet (Reply / Pin / Edit for own + text) which is
// the unified mobile entry point for message actions. (Task 019e3402.)
//
// The desktop hover action bar is revealed by opacity under a group-hover
// variant (spelled out rather than quoted: `@source` scans these files as
// plain text, so a utility written literally in a comment is still a build
// candidate). Touch devices never trigger it, so on mobile this gesture is
// the only way to reach the action sheet. The previous own-vs-others split
// (own → bottom sheet, others → lifted-clone quick-react pill from task
// 019e3233) is gone.
//
// NOTE (task 01a000c0): the dashed (+) that used to sit below every message
// is gone — the add-reaction control moved into the desktop hover action row
// in stage 3, and that row is never revealed on a `hover: none` device
// except by keyboard focus inside it (app.css, task 01a0d8de stage 5; until
// then a tap that focused anything in the row revealed it). This
// gesture, and the sheet it opens, are now the ONLY add-reaction path on
// touch. Covered by e2e/tests/chat_message_density.spec.ts and cases 4-5 of
// e2e/tests/chat_reactions.spec.ts; if you change the gesture, those are the
// tests that stand between a phone user and no way to react at all.
//
// Why double-tap (not long-press): the PWA's 450ms long-press detector
// competed with the browser's native text-selection menu (Chrome on
// Android, Safari on iOS). Both open popups on the same gesture, which
// led to duplicate menus and accidentally-triggered actions like "Pin
// to channel". Double-tap has no native overload — tap-to-zoom is
// suppressed by viewport meta + `touch-action: manipulation` — so we
// own the gesture cleanly.
//
// Desktop mouse interaction is intentionally unhandled — the chat keeps
// its existing hover action bar on pointer devices.

const DOUBLE_TAP_MS = 300
const DOUBLE_TAP_MAX_MOVE_PX = 12
const HAPTIC_MS = 20
const FULLSCREEN_PROTOTYPE = '[data-role="prototype-canvas"][data-fullscreen="true"]'

const LongpressMenu = {
  mounted() {
    this._lastTapAt = 0
    this._lastTapX = 0
    this._lastTapY = 0

    this._onTouchEnd = (e) => this.handleTap(e)
    this.el.addEventListener("touchend", this._onTouchEnd, { passive: true })
  },

  destroyed() {
    this.el.removeEventListener("touchend", this._onTouchEnd)
  },

  handleTap(e) {
    const touch = e.changedTouches && e.changedTouches[0]
    if (!touch) return
    // A prototype in fullscreen is promoted to the browser top layer
    // (prototype_fullscreen.js, task 01a1389f) but still sits inside this
    // message in the DOM, so its taps bubble here. The actions sheet would
    // open UNDER the top layer, unreachable, so a double-tap on the
    // fullscreen bar must not count. Reset the pending first tap too.
    if (e.target && e.target.closest && e.target.closest(FULLSCREEN_PROTOTYPE)) {
      this._lastTapAt = 0
      return
    }

    const now = Date.now()
    const dx = touch.clientX - this._lastTapX
    const dy = touch.clientY - this._lastTapY
    const withinTime = now - this._lastTapAt < DOUBLE_TAP_MS
    const withinMove = dx * dx + dy * dy < DOUBLE_TAP_MAX_MOVE_PX ** 2

    if (withinTime && withinMove) {
      this.trigger()
      this._lastTapAt = 0
    } else {
      this._lastTapAt = now
      this._lastTapX = touch.clientX
      this._lastTapY = touch.clientY
    }
  },

  trigger() {
    const messageId = this.el.dataset.messageId
    if (!messageId) return
    if (navigator.vibrate) navigator.vibrate(HAPTIC_MS)
    this.pushEvent("open_message_actions", { id: messageId })
  },
}

export default LongpressMenu
