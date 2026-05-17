// Double-tap gesture detector for chat messages (mobile).
//
// Fires one of two server events on a double-tap of a message bubble,
// chosen by `data-is-own-message`:
//   * own message  -> `open_message_actions` ({id: messageId}). The
//     server opens the per-message bottom sheet (Edit / Pin / Reply /
//     Add reaction) — same destination as the desktop 3-dot button.
//   * others' msg  -> `open_longpress_menu` ({message_id}). The server
//     opens the quick-react emoji pill over a lifted clone of the row.
//
// The desktop hover action bar is `hidden group-hover:flex`, which
// touch devices never reveal, so on mobile this gesture is the only
// way to reach Edit for your own messages. (Task 019e3233.)
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
    if (this.el.dataset.isOwnMessage === "true") {
      this.pushEvent("open_message_actions", { id: messageId })
    } else {
      this.pushEvent("open_longpress_menu", { message_id: messageId })
    }
  },
}

export default LongpressMenu
