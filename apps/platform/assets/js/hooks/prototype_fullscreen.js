/**
 * PrototypeFullscreen — native fullscreen where the browser has it (iPadOS
 * Safari, desktop, Android), layered on the in-app fixed overlay that the
 * PrototypeFrame component always applies (the only option on iPhone, which
 * has no Fullscreen API for non-video elements).
 *
 * The server owns `@fullscreen` (rendered as `data-fullscreen`). This hook
 * only adds the native step:
 *
 *   - a click on `[data-role="prototype-fullscreen"]` calls requestFullscreen
 *     synchronously (it needs the user gesture); the button's own phx-click
 *     still flips the assign, so with no native support nothing else changes;
 *   - when the browser leaves native fullscreen (Escape, system gesture),
 *     `fullscreenchange` pushes `fullscreen on=false` back to the component;
 *   - when the server turns the assign off (close button, Escape keydown)
 *     while native fullscreen is active, `updated()` exits it.
 *
 * The hook sits on the component root, never on the iframe or the
 * CanvasRoomBridge element, so neither moves or remounts.
 */
export default {
  mounted() {
    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest('[data-role="prototype-fullscreen"]')
      if (!btn || !this.el.contains(btn)) return
      const request = this.el.requestFullscreen || this.el.webkitRequestFullscreen
      const enabled = document.fullscreenEnabled || document.webkitFullscreenEnabled
      if (!enabled || !request) return
      try {
        const p = request.call(this.el)
        if (p && p.catch) p.catch(() => {})
      } catch (_) {
        // Overlay fallback is already in effect via the server assign.
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
  },

  updated() {
    if (this.el.dataset.fullscreen !== "true" && this.nativeElement() === this.el) {
      const exit = document.exitFullscreen || document.webkitExitFullscreen
      try {
        const p = exit && exit.call(document)
        if (p && p.catch) p.catch(() => {})
      } catch (_) {}
    }
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
  },

  nativeElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null
  },
}
