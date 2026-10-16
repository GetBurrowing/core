/**
 * PrototypeFullscreen — native fullscreen on desktop, on Android (the browser
 * and Burrow Android) and in an Apple Safari TAB; elsewhere the in-app
 * overlay that the PrototypeFrame component applies, promoted to the browser
 * TOP LAYER. The overlay is used where there is no Fullscreen API for
 * non-video elements (iPhone Safari) and, by choice, wherever
 * `prefersOverlay()` holds: Burrow iOS and an installed Apple PWA.
 *
 * The server owns `@fullscreen` (rendered as `data-fullscreen`). This hook
 * adds:
 *
 *   - a click on `[data-role="prototype-fullscreen"]` calls requestFullscreen
 *     synchronously (it needs the user gesture), unless `prefersOverlay()`;
 *     the button's own phx-click still flips the assign either way;
 *   - when the browser leaves native fullscreen (Escape, system gesture),
 *     `fullscreenchange` pushes `fullscreen on=false` back to the component;
 *   - when the server turns the assign off (close button, Escape keydown)
 *     while native fullscreen is active, `updated()` exits it;
 *   - on the overlay path, `promote()`: `popover="manual"` + showPopover().
 *
 * WHY THE OVERLAY IN BURROW iOS AND THE INSTALLED APPLE PWA (task 01a1389f
 * v2). Capacitor enables element fullscreen in its WKWebView, so inside
 * Burrow iOS `document.fullscreenEnabled` is true and requestFullscreen hands
 * the prototype to WebKit's own fullscreen UI. That UI brings a
 * drag-to-dismiss gesture and a top-left system X: a fast drag inside the
 * prototype dismisses it, `fullscreenchange` fires, and Suite's state turns
 * off. In an installed context there is no browser chrome for native
 * fullscreen to hide, so the overlay loses nothing. A Safari TAB keeps the
 * native path on purpose: it is the only way to hide the Safari toolbar, and
 * its drag-to-dismiss and system X are an accepted trade-off.
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
 * promote(). The native path is taken on desktop, on Android (browser and
 * Burrow Android) and in an Apple Safari tab; Burrow iOS and the installed
 * Apple PWA never request it.
 *
 * The hook sits on the component root, never on the iframe or the
 * CanvasRoomBridge element, so neither moves or remounts.
 */

/**
 * True where fullscreen should stay on the top-layer overlay even though the
 * Fullscreen API is present:
 *
 *   (a) Burrow iOS: the Capacitor marker Suite already reads in
 *       push_subscribe.js (`isNativePlatform()` and `getPlatform() === "ios"`).
 *       It holds for Burrow iPhone and iPad whatever the UA says, and is false
 *       for Burrow Android.
 *   (b) an installed PWA on an Apple touch device: an iPhone/iPad/iPod UA, or
 *       iPadOS's desktop-class Macintosh UA with more than one touch point,
 *       AND `display-mode: standalone` or `navigator.standalone`.
 */
export function prefersOverlay(win = globalThis.window) {
  if (!win) return false
  const cap = win.Capacitor
  if (cap?.isNativePlatform?.() === true && cap.getPlatform?.() === "ios") return true
  const nav = win.navigator || {}
  const ua = String(nav.userAgent || "")
  const appleTouch =
    /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && (nav.maxTouchPoints || 0) > 1)
  if (!appleTouch) return false
  let standalone = false
  try {
    standalone = win.matchMedia?.("(display-mode: standalone)")?.matches === true
  } catch (_) {}
  return standalone || nav.standalone === true
}

export default {
  mounted() {
    this.nativePending = false
    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest('[data-role="prototype-fullscreen"]')
      if (!btn || !this.el.contains(btn)) return
      // Burrow iOS and the installed Apple PWA stay on the overlay: the
      // phx-click flips the assign and updated() -> sync() -> promote().
      if (prefersOverlay()) return
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
