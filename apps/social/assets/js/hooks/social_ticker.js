// Only an explicit motion preference is stored, never account or metric data.
const PAUSE_KEY = "social-ticker-paused"
let sessionPaused = false
function readPause() {
  try {
    const value = window.sessionStorage?.getItem(PAUSE_KEY)
    if (value !== null && value !== undefined) sessionPaused = value === "true"
  } catch (_) { /* Retain the in-memory tab preference when storage is blocked. */ }
  return sessionPaused
}
function savePause(value) {
  sessionPaused = value
  try { window.sessionStorage?.setItem(PAUSE_KEY, String(value)) } catch (_) {}
}

// Motion state stays independent of the DOM so each pause source can be
// checked without manufacturing browser animation or focus events.
export class TickerMotion {
  constructor() {
    this.paused = false
    this.reduced = false
    this.interactions = new Set()
    this.lastAt = null
  }
  get running() { return !this.paused && !this.reduced && this.interactions.size === 0 }
  toggle() { this.paused = !this.paused; this.lastAt = null }
  setReduced(value) { this.reduced = value; this.lastAt = null }
  interact(kind, active) {
    if (active) this.interactions.add(kind)
    else this.interactions.delete(kind)
    this.lastAt = null
  }
  advance(at, position, width, viewportWidth, speed = 0.024) {
    if (!this.running || width <= viewportWidth || width <= 0) {
      this.lastAt = null
      return position
    }
    if (this.lastAt === null) { this.lastAt = at; return position }
    const elapsed = Math.max(0, Math.min(at - this.lastAt, 50))
    this.lastAt = at
    const next = (position + elapsed * speed) % width
    return next < 0 ? next + width : next
  }
}

export default {
  mounted() {
    this._motion = new TickerMotion()
    this._wikiMotion = new TickerMotion()
    this._motion.paused = readPause()
    this._listeners = []
    this._frame = null
    this._scopeKey = this.el.dataset.scopeKey
    this._position = this.el.querySelector("[data-ticker-viewport]").scrollLeft
    this._writtenScroll = this._position
    this._wikiPosition = this.el.querySelector("[data-wiki-viewport]")?.scrollLeft ?? 0
    this._wikiWrittenScroll = this._wikiPosition
    this.handleEvent?.("social:focus_trends", () => {
      const heading = document.querySelector("[data-role='studio-trends-heading']")
      heading?.focus({preventScroll: true})
      heading?.scrollIntoView({block: "start", inline: "nearest"})
    })
    this._media = window.matchMedia("(prefers-reduced-motion: reduce)")
    this._motion.setReduced(this._media.matches)
    this._bind(this._media, "change", event => {
      this._motion.setReduced(event.matches)
      this._reconcile()
    })
    this._bind(this.el, "pointerenter", event => {
      if (event.pointerType === "mouse") this._interact("hover", true)
    })
    this._bind(this.el, "pointerleave", event => {
      if (event.pointerType === "mouse") this._interact("hover", false)
    })
    // Keyboard activity may change modality while the same entry keeps focus.
    this._bind(this.el, "keydown", event => this._interact("focus", this._viewportContains(event.target)))
    this._bind(this.el, "focusin", event => this._interact("focus", this._keyboardFocusWithin(event.target)))
    this._bind(this.el, "focusout", event => {
      this._interact("focus", this._keyboardFocusWithin(event.relatedTarget))
    })
    this._bind(this.el, "pointerdown", event => {
      if (event?.pointerType !== "mouse") this._interact("hover", false)
      this._touching = true
      this._interact("touch", true)
    })
    const release = () => {
      if (!this._touching) return
      this._touching = false
      // Pointer activation can change focus modality without another focus event.
      this._interact("focus", this._keyboardFocusWithin(document.activeElement))
      this._interact("touch", false)
      this._manualPause()
    }
    this._bind(window, "pointerup", release)
    this._bind(window, "pointercancel", release)
    this._bind(this.el, "wheel", () => this._manualPause(), {passive: true})
    this._bind(this.el, "click", event => {
      if (event.target.closest("[data-ticker-toggle]")) {
        this._motion.toggle()
        savePause(this._motion.paused)
        this._reconcile()
        return
      }
      const entry = event.target.closest("[data-account-id][data-metric]")
      if (!entry || !this.el.contains(entry)) return
      if (event.button > 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) {
        // Keep native new-tab/window actions without also changing this LiveView.
        event.stopPropagation()
        return
      }
      // LiveView handles the bubbled phx-click; suppress only native navigation.
      event.preventDefault()
    })
    this._bind(document, "visibilitychange", () => this._interact("hidden", document.hidden))
    this._motion.interact("hidden", document.hidden)
    this._motion.interact("focus", this._keyboardFocusWithin(document.activeElement))
    const mouseHover = window.matchMedia("(hover: hover) and (pointer: fine)").matches
    this._motion.interact("hover", mouseHover && Boolean(this.el.matches?.(":hover")))
    if (typeof ResizeObserver !== "undefined") {
      this._resize = new ResizeObserver(() => this._reconcile())
      this._resize.observe(this.el)
      this._resize.observe(this.el.querySelector("[data-ticker-original]"))
      const wiki = this.el.querySelector("[data-wiki-original]")
      if (wiki) this._resize.observe(wiki)
    }
    this.el.dataset.tickerReady = "true"
    this._reconcile()
  },
  updated() {
    if (this.el.dataset.scopeKey !== this._scopeKey) {
      this.el.querySelector("[data-ticker-viewport]").scrollLeft = 0
      this._scopeKey = this.el.dataset.scopeKey
      this._position = 0
      this._writtenScroll = 0
      this._motion.lastAt = null
      const wiki = this.el.querySelector("[data-wiki-viewport]")
      if (wiki) wiki.scrollLeft = 0
      this._wikiPosition = 0
      this._wikiWrittenScroll = 0
      this._wikiMotion.lastAt = null
    }
    this._reconcile()
  },
  destroyed() {
    this._destroyed = true
    if (this._frame !== null) window.cancelAnimationFrame(this._frame)
    if (this._manualTimer) window.clearTimeout(this._manualTimer)
    this._resize?.disconnect()
    for (const [target, name, callback, opts] of this._listeners) target.removeEventListener(name, callback, opts)
    this._listeners = []
  },
  _bind(target, name, callback, opts) {
    target.addEventListener(name, callback, opts)
    this._listeners.push([target, name, callback, opts])
  },
  _viewportContains(target) { return Boolean(this.el.querySelector("[data-ticker-viewport]").contains?.(target) || this.el.querySelector("[data-wiki-viewport]")?.contains?.(target)) },
  _keyboardFocusWithin(target) { return this._viewportContains(target) && Boolean(target.matches?.(":focus-visible")) },
  _interact(kind, active) { this._motion.interact(kind, active); this._reconcile() },
  _manualPause() {
    this._interact("manual", true)
    if (this._manualTimer) window.clearTimeout(this._manualTimer)
    this._manualTimer = window.setTimeout(() => this._interact("manual", false), 750)
  },
  _reconcile() {
    if (this._destroyed) return
    this.el.dataset.tickerReady = "true"
    const viewport = this.el.querySelector("[data-ticker-viewport]")
    const original = this.el.querySelector("[data-ticker-original]")
    const width = original.getBoundingClientRect().width
    const overflow = width > viewport.clientWidth
    const wikiViewport = this.el.querySelector("[data-wiki-viewport]")
    const wikiOriginal = this.el.querySelector("[data-wiki-original]")
    const wikiWidth = wikiOriginal?.getBoundingClientRect().width ?? 0
    const wikiOverflow = Boolean(wikiViewport && wikiWidth > wikiViewport.clientWidth)
    const wikiCopy = this.el.querySelector("[data-wiki-copy]")
    if (wikiCopy) wikiCopy.hidden = !wikiOverflow || this._motion.reduced
    this.el.querySelector("[data-ticker-copy]").hidden = !overflow || this._motion.reduced
    this.el.dataset.tickerReduced = String(this._motion.reduced)
    const button = this.el.querySelector("[data-ticker-toggle]")
    button.textContent = this._motion.paused || this._motion.reduced ? "Play" : "Pause"
    button.disabled = this._motion.reduced || !(overflow || wikiOverflow)
    button.setAttribute("aria-pressed", String(this._motion.paused))
    if (!this._motion.running || !(overflow || wikiOverflow)) {
      if (this._frame !== null) window.cancelAnimationFrame(this._frame)
      this._frame = null
      this._motion.lastAt = null
      this._wikiMotion.lastAt = null
      return
    }
    if (this._frame !== null) return
    this._frame = window.requestAnimationFrame(at => {
      this._frame = null
      // Keep subpixel progress even when the browser quantizes scrollLeft.
      // A change from our last observed write belongs to manual/native scrolling.
      if (viewport.scrollLeft !== this._writtenScroll) this._position = viewport.scrollLeft
      this._position = this._motion.advance(at, this._position, width, viewport.clientWidth)
      viewport.scrollLeft = this._position
      this._writtenScroll = viewport.scrollLeft
      if (wikiOverflow) {
        if (wikiViewport.scrollLeft !== this._wikiWrittenScroll) this._wikiPosition = wikiViewport.scrollLeft
        this._wikiMotion.paused = this._motion.paused
        this._wikiMotion.reduced = this._motion.reduced
        this._wikiMotion.interactions = this._motion.interactions
        this._wikiPosition = this._wikiMotion.advance(at, this._wikiPosition, wikiWidth, wikiViewport.clientWidth, -0.016)
        wikiViewport.scrollLeft = this._wikiPosition
        this._wikiWrittenScroll = wikiViewport.scrollLeft
      } else {
        this._wikiMotion.lastAt = null
      }
      this._reconcile()
    })
  },
}
