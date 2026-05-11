// Sheet hook — focus management, Escape-to-close, focus-trap.
// Component: lib/platform_web/components/sheet.ex
// Spec: docs/design-system/components/sheet.md §2

const Sheet = {
  mounted() {
    this.previousFocus = null

    this.handleEscape = (e) => {
      if (e.key === "Escape" && this.el.dataset.open === "true") {
        this.pushEvent(this.el.dataset.onClose)
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
