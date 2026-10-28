// The in-app viewer (redesign rung 13 stages 2-4). Mounted on #chat-viewer,
// which is always in the DOM (hidden while closed), so it can:
//   - record the chat scroller's scrollTop and the source element the moment
//     anything with [data-viewer-open] is clicked (capture phase, before the
//     open is pushed and before the bottom nav hides);
//   - open same-host canvas / prototype anchors in message text in the app;
//   - close the same way everywhere (back, Esc, ArrowLeft, swipe-down
//     >120px): shrink back into the source card, restore the exact
//     scrollTop after the close patch, return focus and ring the source card
//     for 1s;
//   - swipe-down by mode (direction canvas rule 5): image (when not zoomed),
//     video and file anywhere on the viewer; prototype and link only on the
//     top bar, because a prototype takes gestures of its own;
//   - zoom images (rule 9): pinch and double-tap; while zoomed a drag pans
//     and swipe-down is off;
//   - grow from the source card on open (FLIP); a 150ms fade under
//     prefers-reduced-motion;
//   - share: navigator.share on phones, else copy the absolute link and let
//     the server flash "Link copied".

const SWIPE_CLOSE_PX = 120
const HIGHLIGHT_MS = 1000
const HIGHLIGHT_CLASSES = ["ring-2", "ring-base-300"]
const DOUBLE_TAP_MS = 300
const ZOOM_STEP = 2.5
const ZOOM_MAX = 5

function chatScroller() {
  const list = document.getElementById("message-list")
  if (!list) return null
  return list.closest("[data-scroll-container]") || list.closest("main") || list
}

function reducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

const ChatViewer = {
  mounted() {
    this.saved = null
    this.closing = false
    this.wasOpen = this.isOpen()
    this.resetZoom()

    this.onCaptureClick = (e) => {
      if (!e.target.closest || this.isOpen()) return
      const src = e.target.closest("[data-viewer-open], a[data-in-app-link]")
      if (!src) return
      // data-in-app-link="path" is a plain same-install link: let the browser
      // navigate on the current origin (no target, so no new tab).
      if (src.matches('a[data-in-app-link="path"]')) return
      const scroller = chatScroller()
      this.saved = {
        scrollTop: scroller ? scroller.scrollTop : null,
        sourceId: src.id || null,
        rect: src.getBoundingClientRect(),
      }
      // A same-host canvas / prototype link in message text opens in the app,
      // never a page load or a new tab. The server re-checks access.
      if (src.matches("a[data-in-app-link]") && !(e.metaKey || e.ctrlKey || e.shiftKey)) {
        const href = src.getAttribute("href") || ""
        e.preventDefault()
        if (src.dataset.inAppLink === "canvas") {
          const m = href.match(/\/canvases\/([0-9a-fA-F-]{36})/)
          if (m) this.pushEvent("link_card_open_canvas", { "canvas-id": m[1] })
        } else {
          this.pushEvent("viewer_open_link", { href })
        }
      }
    }
    document.addEventListener("click", this.onCaptureClick, true)

    this.onKey = (e) => {
      if (!this.isOpen()) return
      if (e.key === "Escape" || (e.key === "ArrowLeft" && !this.inEditable(e.target))) {
        // Esc must not also close a sheet underneath.
        e.preventDefault()
        e.stopImmediatePropagation()
        this.close()
      }
    }
    window.addEventListener("keydown", this.onKey, true)

    // Back and Share are handled here so a close can animate first; the
    // back button keeps phx-click="viewer_close" for a client without JS.
    this.el.addEventListener(
      "click",
      (e) => {
        if (!e.target.closest) return
        if (e.target.closest("[data-role=viewer-back]")) {
          e.preventDefault()
          e.stopPropagation()
          this.close()
        } else if (e.target.closest("[data-role=viewer-share]")) {
          e.preventDefault()
          this.share()
        }
      },
      true,
    )

    // Pointer capture retargets click/dblclick to the root, so hit-test the
    // point instead of trusting e.target.
    this.el.addEventListener("dblclick", (e) => {
      if (this.el.dataset.mode !== "image" || !this.onImageAt(e.clientX, e.clientY)) return
      // A touch double-tap already toggled in the pointer path; the browser's
      // synthesized dblclick for the same taps must not undo it.
      if (this.tapToggledAt && Date.now() - this.tapToggledAt < 500) return
      this.toggleZoom(e.clientX, e.clientY)
    })

    this.bindPointers()
    if (this.wasOpen) this.onOpened()
  },

  updated() {
    const open = this.isOpen()
    if (open && !this.wasOpen) this.onOpened()
    if (open && this.wasOpen) {
      const img = this.image()
      const src = img && img.getAttribute("src")
      // Paging to another image starts unzoomed; any other patch keeps zoom.
      if (src !== this.lastSrc) this.resetZoom()
      else this.applyZoom()
    }
    if (!open && this.wasOpen) this.restore()
    this.wasOpen = open
  },

  destroyed() {
    document.removeEventListener("click", this.onCaptureClick, true)
    window.removeEventListener("keydown", this.onKey, true)
  },

  isOpen() {
    return this.el.dataset.state === "open"
  },

  inEditable(t) {
    return t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
  },

  onOpened() {
    this.closing = false
    this.resetZoom()
    const back = this.el.querySelector("[data-role=viewer-back]")
    if (back) back.focus({ preventScroll: true })
    this.animateOpen()
  },

  // ── Motion ────────────────────────────────────────────────────────────

  flipFrom(rect) {
    const vw = window.innerWidth
    const vh = window.innerHeight
    if (!rect || !rect.width || !rect.height) return null
    return `translate(${rect.left}px, ${rect.top}px) scale(${rect.width / vw}, ${rect.height / vh})`
  },

  sourceRect() {
    const saved = this.saved
    const el = saved && saved.sourceId && document.getElementById(saved.sourceId)
    return el ? el.getBoundingClientRect() : saved && saved.rect
  },

  animateOpen() {
    if (!this.el.animate) return
    if (reducedMotion()) {
      this.el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150 })
      return
    }
    const from = this.flipFrom(this.sourceRect())
    if (!from) {
      this.el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150 })
      return
    }
    this.el.animate(
      [
        { transformOrigin: "0 0", transform: from, opacity: 0.4, borderRadius: "16px" },
        { transformOrigin: "0 0", transform: "none", opacity: 1, borderRadius: "0px" },
      ],
      { duration: 240, easing: "cubic-bezier(.2,.8,.2,1)" },
    )
  },

  animateClose() {
    if (!this.el.animate) return Promise.resolve()
    const current = this.el.style.transform || "none"
    const currentOpacity = this.el.style.opacity || "1"
    let anim
    if (reducedMotion()) {
      anim = this.el.animate([{ opacity: currentOpacity }, { opacity: 0 }], {
        duration: 150,
        fill: "forwards",
      })
    } else {
      const to = this.flipFrom(this.sourceRect())
      anim = to
        ? this.el.animate(
            [
              { transformOrigin: "0 0", transform: current, opacity: currentOpacity },
              { transformOrigin: "0 0", transform: to, opacity: 0.3, borderRadius: "16px" },
            ],
            { duration: 200, easing: "cubic-bezier(.4,0,.2,1)", fill: "forwards" },
          )
        : this.el.animate([{ opacity: currentOpacity }, { opacity: 0 }], {
            duration: 150,
            fill: "forwards",
          })
    }
    return anim.finished.catch(() => {}).then(() => anim)
  },

  close() {
    if (this.closing || !this.isOpen()) return
    this.closing = true
    this.animateClose().then((anim) => {
      this.pushEvent("viewer_close", {})
      // Drop the held frame once the close patch has hidden the root.
      setTimeout(() => anim && anim.cancel && anim.cancel(), 50)
    })
  },

  restore() {
    const saved = this.saved
    this.saved = null
    this.closing = false
    this.el.style.transform = ""
    this.el.style.opacity = ""
    this.el.getAnimations && this.el.getAnimations().forEach((a) => a.cancel())
    if (!saved) return
    const apply = () => {
      const scroller = chatScroller()
      if (scroller && saved.scrollTop !== null) scroller.scrollTop = saved.scrollTop
    }
    apply()
    requestAnimationFrame(() => {
      apply()
      // Once more after layout settles (the bottom nav comes back).
      requestAnimationFrame(apply)
    })
    const source = saved.sourceId && document.getElementById(saved.sourceId)
    if (source) {
      if (source.focus) source.focus({ preventScroll: true })
      source.classList.add(...HIGHLIGHT_CLASSES)
      source.dataset.viewerHighlight = "true"
      setTimeout(() => {
        source.classList.remove(...HIGHLIGHT_CLASSES)
        delete source.dataset.viewerHighlight
      }, HIGHLIGHT_MS)
    }
  },

  // ── Share ─────────────────────────────────────────────────────────────

  share() {
    const path = this.el.dataset.sharePath
    if (!path) return
    const url = /^https?:\/\//i.test(path) ? path : window.location.origin + path
    const title = (this.el.querySelector("[data-role=viewer-filename]") || {}).textContent
    if (navigator.share && window.matchMedia("(pointer: coarse)").matches) {
      navigator.share({ url, title: title ? title.trim() : undefined }).catch(() => {})
      return
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard
        .writeText(url)
        .then(() => this.pushEvent("viewer_link_copied", {}))
        .catch(() => {})
    }
  },

  // ── Zoom ──────────────────────────────────────────────────────────────

  onImageAt(x, y) {
    const img = this.image()
    if (!img) return false
    const r = img.getBoundingClientRect()
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
  },

  image() {
    return this.el.querySelector("[data-role=viewer-image]")
  },

  resetZoom() {
    this.zoom = { scale: 1, x: 0, y: 0 }
    this.applyZoom()
  },

  zoomed() {
    return this.zoom && this.zoom.scale > 1.01
  },

  applyZoom() {
    const img = this.image && this.image()
    this.lastSrc = img ? img.getAttribute("src") : null
    if (!img) return
    const { scale, x, y } = this.zoom
    img.style.transform = scale > 1.01 ? `translate(${x}px, ${y}px) scale(${scale})` : ""
    this.el.dataset.zoomed = scale > 1.01 ? "true" : "false"
  },

  toggleZoom(cx, cy) {
    const img = this.image()
    if (!img) return
    if (this.zoomed()) {
      this.resetZoom()
      return
    }
    const r = img.getBoundingClientRect()
    const ox = cx - (r.left + r.width / 2)
    const oy = cy - (r.top + r.height / 2)
    this.zoom = { scale: ZOOM_STEP, x: -ox * (ZOOM_STEP - 1), y: -oy * (ZOOM_STEP - 1) }
    this.applyZoom()
  },

  // ── Pointers: swipe-down, pinch, pan, double-tap ──────────────────────

  bindPointers() {
    const pts = new Map()
    let swipe = null
    let pan = null
    let pinch = null
    let lastTap = null

    const resetSwipe = () => {
      swipe = null
      this.el.style.transform = ""
      this.el.style.opacity = ""
    }
    const dist = () => {
      const [a, b] = [...pts.values()]
      return Math.hypot(a.x - b.x, a.y - b.y)
    }

    this.el.addEventListener("pointerdown", (e) => {
      if (!this.isOpen() || this.closing || e.button > 0) return
      if (e.target.closest("button, a, video, iframe, input")) return
      pts.set(e.pointerId, { x: e.clientX, y: e.clientY })
      const mode = this.el.dataset.mode
      const onImage = mode === "image" && !!e.target.closest("[data-role=viewer-stage]")

      if (pts.size === 2 && onImage) {
        resetSwipe()
        pan = null
        pinch = { d0: dist(), s0: this.zoom.scale }
        return
      }
      if (pts.size > 1) return

      if (onImage && this.zoomed()) {
        pan = { x0: e.clientX, y0: e.clientY, zx: this.zoom.x, zy: this.zoom.y }
      } else {
        const onBar = !!e.target.closest("[data-role=viewer-bar]")
        const barOnly = mode === "prototype" || mode === "link"
        if (!barOnly || onBar) swipe = { y0: e.clientY, x0: e.clientX, id: e.pointerId }
      }
      try {
        this.el.setPointerCapture(e.pointerId)
      } catch (_) {}
    })

    this.el.addEventListener("pointermove", (e) => {
      if (!pts.has(e.pointerId)) return
      pts.set(e.pointerId, { x: e.clientX, y: e.clientY })
      if (pinch && pts.size === 2) {
        const scale = Math.min(ZOOM_MAX, Math.max(1, (pinch.s0 * dist()) / (pinch.d0 || 1)))
        this.zoom = { ...this.zoom, scale }
        if (scale <= 1.01) this.zoom = { scale: 1, x: 0, y: 0 }
        this.applyZoom()
      } else if (pan) {
        this.zoom = {
          ...this.zoom,
          x: pan.zx + (e.clientX - pan.x0),
          y: pan.zy + (e.clientY - pan.y0),
        }
        this.applyZoom()
      } else if (swipe && e.pointerId === swipe.id) {
        const dy = Math.max(0, e.clientY - swipe.y0)
        this.el.style.transform = `translateY(${dy}px)`
        this.el.style.opacity = String(1 - Math.min(dy / 400, 0.6))
      }
    })

    // A tap (no travel) on the image; a second one within 300ms toggles zoom.
    const tap = (e, x0, y0) => {
      if (this.el.dataset.mode !== "image" || e.pointerType === "mouse") return
      if (!this.onImageAt(e.clientX, e.clientY)) return
      const now = Date.now()
      if (lastTap && now - lastTap.t < DOUBLE_TAP_MS && Math.hypot(x0 - lastTap.x, y0 - lastTap.y) < 30) {
        lastTap = null
        this.tapToggledAt = now
        this.toggleZoom(e.clientX, e.clientY)
      } else {
        lastTap = { t: now, x: x0, y: y0 }
      }
    }

    const end = (e, cancelled) => {
      if (!pts.has(e.pointerId)) return
      pts.delete(e.pointerId)
      if (pinch) {
        if (pts.size < 2) pinch = null
        return
      }
      if (pan) {
        const moved = Math.hypot(e.clientX - pan.x0, e.clientY - pan.y0)
        const p = pan
        pan = null
        if (!cancelled && moved < 10) tap(e, p.x0, p.y0)
        return
      }
      if (swipe && e.pointerId === swipe.id) {
        const dy = e.clientY - swipe.y0
        const dx = Math.abs(e.clientX - swipe.x0)
        const s = swipe
        swipe = null
        if (!cancelled && dy > SWIPE_CLOSE_PX) {
          this.close()
          return
        }
        this.el.style.transform = ""
        this.el.style.opacity = ""
        if (!cancelled && Math.abs(dy) < 10 && dx < 10) tap(e, s.x0, s.y0)
      }
    }
    this.el.addEventListener("pointerup", (e) => end(e, false))
    this.el.addEventListener("pointercancel", (e) => {
      end(e, true)
      resetSwipe()
    })
  },
}

export default ChatViewer
