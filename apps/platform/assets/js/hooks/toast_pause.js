/**
 * ToastPause hook — holds the Inbox toast open while it is hovered or
 * holds focus (task 01a15ee1 stage 5; direction canvas 01a15ee2, node
 * "states": "The toast pauses while hovered or focused").
 *
 * The toast is server-driven: InboxLive schedules its auto-dismiss with a
 * nonce. This hook only reports two facts, `toast_pause` when the pointer
 * enters or focus moves inside, and `toast_resume` when neither is true
 * any more; the server keeps the time left and re-arms on resume. It
 * pushes nothing on a same-state change, so a pointer that moves within
 * the toast sends one event, not one per movement.
 */
const ToastPause = {
  mounted() {
    this._hover = false
    this._focus = false
    this._paused = false

    this._sync = () => {
      const want = this._hover || this._focus
      if (want === this._paused) return
      this._paused = want
      this.pushEvent(want ? "toast_pause" : "toast_resume", {})
    }

    this._enter = () => { this._hover = true; this._sync() }
    this._leave = () => { this._hover = false; this._sync() }
    this._focusIn = () => { this._focus = true; this._sync() }
    this._focusOut = (e) => {
      if (e.relatedTarget && this.el.contains(e.relatedTarget)) return
      this._focus = false
      this._sync()
    }

    this.el.addEventListener("mouseenter", this._enter)
    this.el.addEventListener("mouseleave", this._leave)
    this.el.addEventListener("focusin", this._focusIn)
    this.el.addEventListener("focusout", this._focusOut)
  },

  // A newer toast replaces the content under the same element; the
  // server's `data-paused` says whether THAT toast is paused, so re-sync
  // against it (the pointer may still be resting on the toast).
  updated() {
    this._paused = this.el.dataset.paused === "true"
    this._sync()
  },

  destroyed() {
    this.el.removeEventListener("mouseenter", this._enter)
    this.el.removeEventListener("mouseleave", this._leave)
    this.el.removeEventListener("focusin", this._focusIn)
    this.el.removeEventListener("focusout", this._focusOut)
  },
}

export default ToastPause
