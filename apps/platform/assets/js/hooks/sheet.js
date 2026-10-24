// Sheet hook — focus management, Escape-to-close, focus-trap, and (opt-in)
// swipe-down-to-close.
// Component: lib/platform_web/components/sheet.ex
// Spec: docs/design-system/components/sheet.md §2

// Masters' threshold (master-mobile.html v3 :802-806): a downward drag of MORE
// than this many pixels closes; anything shorter snaps back.
export const SWIPE_CLOSE_PX = 60

const Sheet = {
  mounted() {
    this.previousFocus = null

    this.handleEscape = (e) => {
      if (e.key === "Escape" && this.el.dataset.open === "true") {
        this._pushClose()
      }
    }

    this.handleFocusTrap = (e) => {
      if (this.el.dataset.open !== "true") return
      const focusable = this.el.querySelectorAll(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      )
      if (focusable.length === 0) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (e.key === "Tab") {
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault()
          last.focus()
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault()
          first.focus()
        }
      }
    }

    document.addEventListener("keydown", this.handleEscape)
    this.el.addEventListener("keydown", this.handleFocusTrap)
    this._setupSwipe()

    // If the sheet boots open (rare but valid), still grab focus.
    if (this.el.dataset.open === "true") {
      this._captureFocusInto()
    }
  },

  updated() {
    if (this.el.dataset.open === "true" && !this.previousFocus) {
      this._captureFocusInto()
    } else if (this.el.dataset.open === "false" && this.previousFocus) {
      const target = this.previousFocus
      this.previousFocus = null
      // Defer one frame so the close-button blur doesn't steal it back.
      requestAnimationFrame(() => {
        try { target.focus() } catch (_e) { /* trigger may have unmounted */ }
      })
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleEscape)
    this.el.removeEventListener("keydown", this.handleFocusTrap)
    if (this.swipePanel) {
      this.swipePanel.removeEventListener("pointerdown", this.handleSwipeStart)
      this.swipePanel.removeEventListener("pointermove", this.handleSwipeMove)
      this.swipePanel.removeEventListener("pointerup", this.handleSwipeEnd)
      this.swipePanel.removeEventListener("pointercancel", this.handleSwipeCancel)
      this.swipePanel = null
    }
    this.swipe = null
  },

  // The one close path: Escape and swipe both push `on_close` exactly this way.
  // A sheet rendered inside a LiveComponent must close INTO that component —
  // `pushEvent` would land on the parent LiveView, which no longer carries the
  // handler. `data-on-close-target` is set by `sheet/1` whenever
  // `on_close_target` is given (task 01a008f6 st. 2).
  _pushClose() {
    const target = this.el.dataset.onCloseTarget
    if (target) {
      this.pushEventTo(target, this.el.dataset.onClose)
    } else {
      this.pushEvent(this.el.dataset.onClose)
    }
  },

  _reducedMotion() {
    return (
      typeof window !== "undefined" &&
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    )
  },

  // Swipe-down-to-close (task 01a1557a-807f stage 4), only when the sheet
  // opted in with `swipe_dismiss` (`data-swipe-dismiss="true"`). A drag starts
  // on the handle, or anywhere on the panel while `.sheet-body` is scrolled to
  // its top; a drag that begins while the list is scrolled belongs to the list.
  // The panel follows the finger downward (not under reduced motion); release
  // past SWIPE_CLOSE_PX closes through `_pushClose`, otherwise it snaps back.
  // Upward movement never moves the panel and never closes.
  _setupSwipe() {
    if (this.el.dataset.swipeDismiss !== "true") return
    const panel = this.el.querySelector(".sheet-panel")
    if (!panel) return
    this.swipePanel = panel
    this.swipe = null

    const reset = () => {
      panel.style.transform = ""
      panel.style.transition = ""
    }

    this.handleSwipeStart = (e) => {
      if (this.el.dataset.open !== "true") return
      if (e.pointerType === "mouse" && e.button !== 0) return
      const onHandle =
        e.target && typeof e.target.closest === "function"
          ? e.target.closest(".sheet-handle-button, .sheet-handle")
          : null
      const body = this.el.querySelector(".sheet-body")
      if (!onHandle && body && body.scrollTop > 0) return
      this.swipe = { startY: e.clientY, dy: 0, pointerId: e.pointerId }
    }

    this.handleSwipeMove = (e) => {
      if (!this.swipe || e.pointerId !== this.swipe.pointerId) return
      const dy = Math.max(0, e.clientY - this.swipe.startY)
      this.swipe.dy = dy
      if (this._reducedMotion()) return
      panel.style.transition = "none"
      panel.style.transform = dy > 0 ? `translateY(${dy}px)` : ""
    }

    this.handleSwipeEnd = (e) => {
      if (!this.swipe || e.pointerId !== this.swipe.pointerId) return
      const dy = Math.max(0, e.clientY - this.swipe.startY)
      this.swipe = null
      reset()
      if (dy > SWIPE_CLOSE_PX) this._pushClose()
    }

    this.handleSwipeCancel = () => {
      this.swipe = null
      reset()
    }

    panel.addEventListener("pointerdown", this.handleSwipeStart)
    panel.addEventListener("pointermove", this.handleSwipeMove)
    panel.addEventListener("pointerup", this.handleSwipeEnd)
    panel.addEventListener("pointercancel", this.handleSwipeCancel)
  },

  _captureFocusInto() {
    this.previousFocus = document.activeElement
    const first = this.el.querySelector(
      'button:not([aria-label="Close"]), [href], input, textarea, select'
    )
    if (first) first.focus()
  }
}

export default Sheet
