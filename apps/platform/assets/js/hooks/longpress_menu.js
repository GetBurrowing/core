// Long-press gesture detector for chat messages (mobile).
//
// Fires `open_longpress_menu` with the hook element's `data-message-id`
// when the user holds a finger on the bubble for LONGPRESS_MS without
// moving. Any touchmove or early touchend cancels the timer — which
// preserves native iOS text selection: short hold = our menu, long hold
// (past iOS's ~500ms threshold) = iOS selection takes over since we've
// already fired and moved on, and drag-to-select cancels our timer on
// the first move.
//
// Desktop mouse interaction is intentionally unhandled — the chat keeps
// its existing hover action bar on pointer devices.

const LONGPRESS_MS = 450
const HAPTIC_MS = 30

const LongpressMenu = {
  mounted() {
    this._timer = null

    this._onTouchStart = (e) => this.startTimer(e)
    this._onCancel = () => this.clearTimer()

    this.el.addEventListener("touchstart", this._onTouchStart, { passive: true })
    this.el.addEventListener("touchmove", this._onCancel, { passive: true })
    this.el.addEventListener("touchend", this._onCancel, { passive: true })
    this.el.addEventListener("touchcancel", this._onCancel, { passive: true })
  },

  destroyed() {
    this.clearTimer()
    this.el.removeEventListener("touchstart", this._onTouchStart)
    this.el.removeEventListener("touchmove", this._onCancel)
    this.el.removeEventListener("touchend", this._onCancel)
    this.el.removeEventListener("touchcancel", this._onCancel)
  },

  startTimer() {
    this.clearTimer()
    this._timer = setTimeout(() => this.trigger(), LONGPRESS_MS)
  },

  clearTimer() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
  },

  trigger() {
    this._timer = null
    const messageId = this.el.dataset.messageId
    if (!messageId) return
    if (navigator.vibrate) navigator.vibrate(HAPTIC_MS)
    this.pushEvent("open_longpress_menu", { message_id: messageId })
  },
}

export default LongpressMenu
