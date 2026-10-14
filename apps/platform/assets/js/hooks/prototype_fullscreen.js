/**
 * PrototypeFullscreen — native fullscreen where the browser has it (iPadOS
 * Safari, desktop, Android); elsewhere (iPhone, which has no Fullscreen API
 * for non-video elements) the in-app overlay that the PrototypeFrame
 * component applies, promoted to the browser TOP LAYER.
 *
 * The server owns `@fullscreen` (rendered as `data-fullscreen`). This hook
 * adds:
 *
 *   - a click on `[data-role="prototype-fullscreen"]` calls requestFullscreen
 *     synchronously (it needs the user gesture); the button's own phx-click
 *     still flips the assign;
 *   - when the browser leaves native fullscreen (Escape, system gesture),
 *     `fullscreenchange` pushes `fullscreen on=false` back to the component;
 *   - when the server turns the assign off (close button, Escape keydown)
 *     while native fullscreen is active, `updated()` exits it;
 *   - on the overlay path, `promote()`: `popover="manual"` + showPopover().
 *
 * WHY THE TOP LAYER (task 01a1389f). The overlay is `fixed inset-0` on an
 * element that still sits inside its host. Any ancestor with a transform or
 * an individual `scale` (the chat row's `active:scale-[0.99]`, applied while
 * a finger is down) becomes the containing block and stacking context of
 * every fixed descendant, so the "fullscreen" box collapsed to the chat row
 * and the chat drew over it. A top-layer element's containing block is the
 * viewport whatever its ancestors do, and it paints above the whole page.
 * The element does not move in the DOM, so the iframe does not reload.
 *
 * `manual` popovers have no light-dismiss and no native Escape close: the
 * server's Escape keydown and close button stay the only exits, and there is
 * no second open/closed state to keep in sync.
 *
 * The attribute is set through `this.js().setAttribute`, a LiveView sticky
 * operation, so a later server patch of the root (a version-menu toggle, a
 * canvas patch) re-applies it to the incoming element instead of stripping
 * it; removing `popover` from an open popover would hide it.
 *
 * The native path NEVER gets the attribute: an unopened `[popover]` is
 * `display: none` by UA style, and stacking fullscreen and popover on one
 * element is avoidable risk. A rejected native request falls back to
 * promote().
 *
 * The hook sits on the component root, never on the iframe or the
 * CanvasRoomBridge element, so neither moves or remounts.
 */
export default {
  mounted() {
    this.nativePending = false
    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest('[data-role="prototype-fullscreen"]')
      if (!btn || !this.el.contains(btn)) return
      const request = this.el.requestFullscreen || this.el.webkitRequestFullscreen
      const enabled = document.fullscreenEnabled || document.webkitFullscreenEnabled
      if (!enabled || !request) return
      this.nativePending = true
      const fallback = () => {
        this.nativePending = false
        this.sync()
      }
      try {
        const p = request.call(this.el)
        if (p && p.then) {
          p.then(
            () => (this.nativePending = false),
            () => fallback(),
          )
        } else {
          // Legacy webkitRequestFullscreen returns undefined; fullscreenchange
          // (or its absence) settles it.
          this.nativePending = false
        }
      } catch (_) {
        fallback()
      }
    }
    this.onChange = () => {
      if (this.nativeElement() !== this.el && this.el.dataset.fullscreen === "true") {
        this.pushEventTo(this.el, "fullscreen", { on: "false" })
      }
    }
    this.el.addEventListener("click", this.onClick)
    document.addEventListener("fullscreenchange", this.onChange)
    document.addEventListener("webkitfullscreenchange", this.onChange)
    this.sync()
  },

  updated() {
    if (this.el.dataset.fullscreen !== "true" && this.nativeElement() === this.el) {
      const exit = document.exitFullscreen || document.webkitExitFullscreen
      try {
        const p = exit && exit.call(document)
        if (p && p.catch) p.catch(() => {})
      } catch (_) {}
    }
    this.sync()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("fullscreenchange", this.onChange)
    document.removeEventListener("webkitfullscreenchange", this.onChange)
    if (this.nativeElement() === this.el) {
      const exit = document.exitFullscreen || document.webkitExitFullscreen
      try {
        const p = exit && exit.call(document)
        if (p && p.catch) p.catch(() => {})
      } catch (_) {}
    }
    this.hide()
  },

  /** Promote or demote to match `data-fullscreen` and the native state. */
  sync() {
    if (this.el.dataset.fullscreen === "true") {
      if (!this.nativePending && this.nativeElement() !== this.el) this.promote()
    } else {
      this.demote()
    }
  },

  promote() {
    if (typeof this.el.showPopover !== "function") return
    if (this.el.getAttribute("popover") !== "manual") {
      this.js().setAttribute(this.el, "popover", "manual")
    }
    if (!this.isOpen()) {
      try {
        this.el.showPopover()
      } catch (_) {
        // Not connected or already showing: nothing to promote.
      }
    }
  },

  demote() {
    this.hide()
    if (this.el.hasAttribute("popover")) this.js().removeAttribute(this.el, "popover")
  },

  hide() {
    if (typeof this.el.hidePopover === "function" && this.isOpen()) {
      try {
        this.el.hidePopover()
      } catch (_) {}
    }
  },

  isOpen() {
    try {
      return this.el.matches(":popover-open")
    } catch (_) {
      return false
    }
  },

  nativeElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null
  },
}
