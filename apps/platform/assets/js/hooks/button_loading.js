// ButtonLoading
//
// Phoenix LiveView already applies `phx-click-loading` / `phx-submit-loading`
// classes to elements with `phx-click` / `phx-submit` while the round-trip is
// in flight. What LV does NOT do:
//
//   1. Delay-before-show: most Suite operations resolve in < 100ms; flashing
//      a spinner for those feels worse than no feedback at all.
//   2. `aria-busy`: screen readers need an attribute, not a class, to announce
//      the loading state.
//
// This hook fills both gaps. Mount it on a <form> (covers all child submit
// buttons) or directly on a <button> with phx-click (covers itself).
//
// After 100ms of being in the loading class, `aria-busy="true"` is set on the
// target button(s). When the loading class is removed (response arrived or
// the timer hasn't fired yet), the pending timer is cancelled and aria-busy
// is cleared, preventing spinner flicker on near-instant operations.

const LOADING_CLASSES = ["phx-click-loading", "phx-submit-loading"]
const DEFAULT_DELAY_MS = 100

export default {
  mounted() {
    this.delay = parseInt(this.el.dataset.busyDelay || DEFAULT_DELAY_MS, 10)
    this.timer = null
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.el, { attributes: true, attributeFilter: ["class"] })
    this.sync()
  },

  destroyed() {
    if (this.timer != null) clearTimeout(this.timer)
    if (this.observer) this.observer.disconnect()
  },

  targets() {
    if (this.el.tagName === "FORM") {
      return Array.from(this.el.querySelectorAll("button[type='submit']"))
    }
    return [this.el]
  },

  isLoading() {
    return LOADING_CLASSES.some(cls => this.el.classList.contains(cls))
  },

  sync() {
    if (this.isLoading()) {
      if (this.timer == null) {
        this.timer = setTimeout(() => {
          this.targets().forEach(btn => btn.setAttribute("aria-busy", "true"))
          this.timer = null
        }, this.delay)
      }
      return
    }

    if (this.timer != null) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.targets().forEach(btn => btn.removeAttribute("aria-busy"))
  },
}
