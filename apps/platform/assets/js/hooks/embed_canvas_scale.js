/**
 * EmbedCanvasScale — auto-scale a sandboxed embed iframe to fit its
 * container, and open a fullscreen overlay on tap-to-expand.
 *
 * Renders an `<iframe srcdoc=... sandbox="">` at its declared natural
 * design width, then applies CSS `transform: scale()` so the iframe
 * fits the available container width. On viewports wider than the
 * declared width, no transform is applied (scale capped at 1.0).
 *
 * If `data-min-scale` is present and the computed scale would fall
 * below it, the iframe renders at natural size with horizontal scroll
 * inside the wrapper instead — a "floor" so embeds never become
 * unreadably small.
 *
 * The wrapper element also embeds an expand button (`[data-embed-expand]`)
 * that opens a fullscreen overlay containing a fresh iframe with the
 * same srcdoc but with a viewport meta tag injected so mobile native
 * pinch-zoom works for detail inspection. The overlay closes on
 * backdrop click, Escape key, or explicit close button.
 *
 * `phx-update="ignore"` on the wrapper means LiveView won't re-render
 * us out from under the inline styles the hook applies.
 *
 * SCRIPTED MODE (task 01a1316b-677a): a `scripts: true` embed's wrapper
 * carries `data-scripted-src="/proto/<id>/<version>/"` and no
 * `data-srcdoc`; its iframe is `<iframe src=... sandbox="allow-scripts">`
 * served under the sealed prototype CSP. In that mode this hook NEVER reads
 * or writes `srcdoc`: `srcdoc` wins over `src`, so writing script-bearing
 * HTML into it would run the script under the Burrow page's CSP instead of
 * the sealed one. `updated()` moves `iframe.src` when the version changes,
 * and the expand overlay frames the same `src` with the same sandbox. The
 * mode is fixed at mount (the server gives each mode its own wrapper id, so
 * toggling `scripts` replaces the element rather than updating it).
 */
export default {
  mounted() {
    this.iframe = this.el.querySelector("iframe")
    if (!this.iframe) return

    this.declaredWidth = parseInt(this.el.dataset.declaredWidth || "1080", 10)
    this.declaredHeight = parseInt(
      this.el.dataset.declaredHeight || "400",
      10,
    )
    const rawMinScale = this.el.dataset.minScale
    this.minScale =
      rawMinScale !== undefined && rawMinScale !== ""
        ? parseFloat(rawMinScale)
        : null

    this.applyScale = this.applyScale.bind(this)
    this.openExpand = this.openExpand.bind(this)
    this.closeExpand = this.closeExpand.bind(this)

    this.scripted = this.el.dataset.scriptedSrc !== undefined
    this._appliedScriptedSrc = this.el.dataset.scriptedSrc || ""

    this.applyScale()

    // Track the srcdoc we've actually written to the iframe so updated()
    // can detect real changes vs. no-op re-renders. The wrapper's initial
    // server render already populated the iframe's srcdoc attribute, so
    // seed from the dataset (kept in sync with the iframe by the server).
    this._appliedSrcdoc = this.scripted ? "" : this.el.dataset.srcdoc || ""

    if (typeof ResizeObserver !== "undefined") {
      this.observer = new ResizeObserver(this.applyScale)
      this.observer.observe(this.el)
    } else {
      window.addEventListener("resize", this.applyScale)
    }

    const expandBtn = this.el.querySelector("[data-embed-expand]")
    if (expandBtn) {
      expandBtn.addEventListener("click", this.openExpand)
      this.expandBtn = expandBtn
    }
  },

  // Live-update path: morphdom patches the wrapper's `data-srcdoc`
  // attribute (and any declared-dim props) when the server re-renders
  // after a `:canvas_patched` broadcast. Because the wrapper carries
  // `phx-update="ignore"`, morphdom never touches the <iframe> child —
  // so the iframe's own `srcdoc` attribute is left frozen at whatever
  // the initial render produced. We must propagate the new srcdoc to
  // the iframe element ourselves by assigning the `srcdoc` PROPERTY
  // (forces the browser to reload the iframe with the new content).
  //
  // Gate duplicate writes: only assign when the dataset value actually
  // differs from what we last wrote. Otherwise a non-srcdoc patch
  // (e.g. dims changed, or some unrelated parent LV re-render) would
  // needlessly reload the iframe and flash a blank frame.
  updated() {
    if (!this.iframe) return

    // Refresh cached props in case dims/min-scale changed.
    this.declaredWidth = parseInt(this.el.dataset.declaredWidth || "1080", 10)
    this.declaredHeight = parseInt(
      this.el.dataset.declaredHeight || "400",
      10,
    )
    const rawMinScale = this.el.dataset.minScale
    this.minScale =
      rawMinScale !== undefined && rawMinScale !== ""
        ? parseFloat(rawMinScale)
        : null

    if (this.scripted) {
      // A new version is a new URL; phx-update="ignore" would otherwise
      // freeze the frame at the version it mounted with.
      const nextSrc = this.el.dataset.scriptedSrc || ""
      if (nextSrc && nextSrc !== this._appliedScriptedSrc) {
        this.iframe.src = nextSrc
        this._appliedScriptedSrc = nextSrc
      }
    } else {
      const nextSrcdoc = this.el.dataset.srcdoc || ""
      if (nextSrcdoc !== this._appliedSrcdoc) {
        this.iframe.srcdoc = nextSrcdoc
        this._appliedSrcdoc = nextSrcdoc
      }
    }

    this.applyScale()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    else window.removeEventListener("resize", this.applyScale)

    if (this.expandBtn)
      this.expandBtn.removeEventListener("click", this.openExpand)

    this.closeExpand()
  },

  applyScale() {
    if (!this.iframe) return

    const containerWidth = this.el.clientWidth
    if (!containerWidth) return

    const fitScale = Math.min(1.0, containerWidth / this.declaredWidth)

    if (this.minScale !== null && fitScale < this.minScale) {
      // Below the floor — render at natural size, allow horizontal scroll
      // inside the wrapper. No transform; the iframe stays its declared
      // pixel width and the wrapper provides the scroll affordance.
      this.iframe.style.transform = ""
      this.iframe.style.transformOrigin = ""
      this.iframe.style.width = this.declaredWidth + "px"
      this.iframe.style.height = this.declaredHeight + "px"
      this.el.style.height = this.declaredHeight + "px"
      this.el.style.overflowX = "auto"
      this.el.dataset.scaleApplied = "floor"
      this.el.dataset.scaleValue = "1"
    } else {
      // Apply the scale transform. Wrapper height shrinks proportionally so
      // we don't reserve unused vertical space.
      this.iframe.style.transform = `scale(${fitScale})`
      this.iframe.style.transformOrigin = "top left"
      this.iframe.style.width = this.declaredWidth + "px"
      this.iframe.style.height = this.declaredHeight + "px"
      this.el.style.height = this.declaredHeight * fitScale + "px"
      this.el.style.overflowX = "hidden"
      this.el.dataset.scaleApplied = fitScale < 1.0 ? "scaled" : "natural"
      this.el.dataset.scaleValue = String(fitScale)
    }
  },

  // Tap-to-expand: build a fullscreen overlay client-side. Pure DOM, no
  // server round-trip — keeps the embed kind self-contained and avoids
  // adding a fullscreen-canvas-id assign to every host LiveView.
  //
  // The wrapper that hosts inline embeds carries `phx-click="canvas_open"`
  // (it opens the canvas-detail panel when the inline canvas is clicked),
  // so clicks on the expand button must be stopped from bubbling. Without
  // this, both the expand overlay AND the panel-open event fire.
  openExpand(e) {
    if (e) {
      e.preventDefault()
      e.stopPropagation()
    }
    if (this.overlay) return

    const overlay = document.createElement("div")
    overlay.setAttribute("data-embed-expand-overlay", "")
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-label", "Expanded canvas")
    Object.assign(overlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "9999",
      background: "rgba(0,0,0,0.8)",
      display: "flex",
      flexDirection: "column",
      padding: "0",
    })

    // Header bar with close button.
    const header = document.createElement("div")
    Object.assign(header.style, {
      display: "flex",
      alignItems: "center",
      justifyContent: "flex-end",
      padding: "12px",
      flex: "0 0 auto",
    })
    const closeBtn = document.createElement("button")
    closeBtn.type = "button"
    closeBtn.setAttribute("aria-label", "Close expanded canvas")
    closeBtn.textContent = "Close"
    Object.assign(closeBtn.style, {
      padding: "8px 16px",
      borderRadius: "6px",
      background: "white",
      color: "black",
      border: "0",
      cursor: "pointer",
      fontSize: "14px",
      fontWeight: "600",
    })
    closeBtn.addEventListener("click", this.closeExpand)
    header.appendChild(closeBtn)

    // Scrollable iframe wrapper. The iframe renders at natural width;
    // the wrapper allows pan/scroll to inspect detail. On mobile, the
    // injected viewport meta enables pinch-zoom inside the iframe.
    const scroller = document.createElement("div")
    Object.assign(scroller.style, {
      flex: "1 1 auto",
      overflow: "auto",
      display: "flex",
      justifyContent: "center",
      background: "white",
    })
    scroller.addEventListener("click", (e) => {
      if (e.target === scroller) this.closeExpand()
    })

    const iframe = document.createElement("iframe")
    if (this.scripted) {
      // Same seal as the inline frame; no viewport injection, because the
      // bytes are served by /proto and never pass through this hook.
      iframe.setAttribute("sandbox", "allow-scripts")
      iframe.setAttribute("referrerpolicy", "no-referrer")
      iframe.src = this._appliedScriptedSrc
    } else {
      iframe.setAttribute("sandbox", "")
      iframe.srcdoc = this.injectViewportMeta(this.el.dataset.srcdoc || "")
    }
    Object.assign(iframe.style, {
      width: this.declaredWidth + "px",
      height: this.declaredHeight + "px",
      border: "0",
      display: "block",
      maxWidth: "100%",
    })
    scroller.appendChild(iframe)

    overlay.appendChild(header)
    overlay.appendChild(scroller)

    this.escListener = (e) => {
      if (e.key === "Escape") this.closeExpand()
    }
    document.addEventListener("keydown", this.escListener)

    document.body.appendChild(overlay)
    this.overlay = overlay
  },

  closeExpand() {
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
    if (this.escListener) {
      document.removeEventListener("keydown", this.escListener)
      this.escListener = null
    }
  },

  // Inject `<meta name="viewport">` if not already present, so mobile
  // pinch-zoom works inside the expanded iframe. Mockups authored
  // without a viewport meta default to desktop layout otherwise.
  injectViewportMeta(srcdoc) {
    if (!srcdoc) return srcdoc
    if (/<meta\s+name=["']viewport["']/i.test(srcdoc)) return srcdoc

    const tag =
      '<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=yes">'

    if (/<head[^>]*>/i.test(srcdoc)) {
      return srcdoc.replace(/<head([^>]*)>/i, `<head$1>${tag}`)
    }
    if (/<html[^>]*>/i.test(srcdoc)) {
      return srcdoc.replace(/<html([^>]*)>/i, `<html$1><head>${tag}</head>`)
    }
    return tag + srcdoc
  },
}
