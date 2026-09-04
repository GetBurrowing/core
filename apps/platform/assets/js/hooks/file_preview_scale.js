/**
 * FilePreviewScale — auto-scale a `src`-based preview iframe to fit its
 * container width (task 01a06a20 stage 3).
 *
 * Reuses the canvas embed's scale-to-fit ALGORITHM
 * (`apps/platform/assets/js/hooks/embed_canvas_scale.js`:
 * `containerWidth / declaredWidth`, capped at 1.0, applied as a CSS
 * `transform: scale()`), not that hook itself. `EmbedCanvasScale` also
 * owns `srcdoc` diffing across LiveView patches and its own
 * tap-to-expand overlay — neither applies here: this iframe's `src` is
 * a stable blob URL for the life of the file selection (no srcdoc to
 * resync), and FilesLive already has a LiveView-driven fullscreen
 * overlay (`open_preview_fullscreen` /
 * `PlatformWeb.Components.FilePreview.preview_fullscreen`). Pulling in
 * the shared hook would mean either stripping those parts out or
 * shipping them dead, and task 01a06a20 explicitly keeps
 * `Platform.Chat.Canvas.Kinds.Embed` (and its hook) untouched so this
 * change stays reviewable on its own.
 *
 * `data-declared-width` / `data-declared-height` are the design pixel
 * dimensions of the framed prototype — same numbers as
 * `PlatformWeb.FilesLive.html_preview_width/0` and
 * `html_preview_height/0`, so the ratio here matches what the server
 * rendered the iframe's own `width`/`height` style at before any
 * transform is applied.
 *
 * No `min_scale` floor: unlike the canvas embed (which falls back to
 * horizontal scroll below its floor), this hook always scales to fit.
 * A flagged prototype is meant to be clicked through, and "Full
 * window" — the attribution bar's one action — is the intended way to
 * actually use one on a narrow viewport; shrinking further than
 * comfortable reading is an acceptable trade for keeping the whole
 * thing in frame there.
 */
export default {
  mounted() {
    this.iframe = this.el.querySelector("iframe")
    if (!this.iframe) return

    this.declaredWidth = parseInt(this.el.dataset.declaredWidth || "1280", 10)
    this.declaredHeight = parseInt(this.el.dataset.declaredHeight || "800", 10)

    this.applyScale = this.applyScale.bind(this)
    this.applyScale()

    if (typeof ResizeObserver !== "undefined") {
      this.observer = new ResizeObserver(this.applyScale)
      this.observer.observe(this.el)
    } else {
      window.addEventListener("resize", this.applyScale)
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    else window.removeEventListener("resize", this.applyScale)
  },

  applyScale() {
    if (!this.iframe) return

    const containerWidth = this.el.clientWidth
    if (!containerWidth) return

    const fitScale = Math.min(1.0, containerWidth / this.declaredWidth)

    this.iframe.style.transform = `scale(${fitScale})`
    this.iframe.style.transformOrigin = "top left"
    this.iframe.style.width = this.declaredWidth + "px"
    this.iframe.style.height = this.declaredHeight + "px"
    this.el.style.height = this.declaredHeight * fitScale + "px"
    this.el.style.overflow = "hidden"
    this.el.dataset.scaleValue = String(fitScale)
  },
}
