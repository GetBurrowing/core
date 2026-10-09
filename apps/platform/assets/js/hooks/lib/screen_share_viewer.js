import { VideoQuality } from "livekit-client"

const FALLBACK_STATE = "__suiteScreenShareFullscreen"
const ACTIVE_CLASS = "screen-share-viewer--fallback"
const PAGE_ACTIVE_CLASS = "screen-share-fullscreen-active"

function callSafely(fn) {
  try {
    return fn()
  } catch (_) {
    return undefined
  }
}

/** Ask LiveKit for the highest simulcast layer while focused, then return to
 * a low layer when the focused surface goes away. This never republishes or
 * detaches the track. Local publications simply do not expose these methods. */
export function setFocusedScreenShareQuality(publication, focused) {
  if (!publication || typeof publication.setVideoQuality !== "function") return false

  try {
    if (focused) {
      if (typeof publication.setSubscribed === "function") {
        publication.setSubscribed(true)
      }
      publication.setVideoQuality(VideoQuality.HIGH)
    } else {
      publication.setVideoQuality(VideoQuality.LOW)
    }
    return true
  } catch (error) {
    console.warn("[ScreenShareViewer] unable to select screen-share layer:", error)
    return false
  }
}

/** Progressive fullscreen controller shared by Meeting Center and Quick Meet.
 * Order: standard element API, WebKit element API, iOS video fullscreen, then
 * a fixed-viewport PWA fallback. destroy() removes every listener and lock. */
export class ScreenShareFullscreenController {
  constructor({ root, viewport = root, button, video, publication, env = globalThis }) {
    this.root = root
    this.viewport = viewport
    this.button = button
    this.video = video
    this.publication = publication
    this.env = env
    this.document = env?.document || globalThis.document
    this.mode = null
    this.active = false
    this.historyPushed = false
    this.destroyed = false
    this.restoreFocusTo = null

    this._onToggle = () => void this.toggle()
    this._onFullscreenChange = () => this._syncNativeState()
    this._onWebkitBegin = () => this._setActive("webkit-video")
    this._onWebkitEnd = () => this._finishExit({ restoreFocus: true })
    this._onKeyDown = (event) => {
      if (this.active && event.key === "Escape") {
        event.preventDefault?.()
        void this.exit()
      }
    }
    this._onPopState = () => {
      if (this.active && this.mode === "fallback") {
        this.historyPushed = false
        void this.exit({ consumeHistory: false })
      }
    }
    this._onViewportChange = () => this._sizeFallback()
  }

  mount() {
    if (!this.root || this.destroyed) return this
    setFocusedScreenShareQuality(this.publication, true)

    if (this.button) {
      this.button.hidden = false
      this.button.addEventListener?.("click", this._onToggle)
    }
    this.document?.addEventListener?.("fullscreenchange", this._onFullscreenChange)
    this.document?.addEventListener?.("webkitfullscreenchange", this._onFullscreenChange)
    this.document?.addEventListener?.("keydown", this._onKeyDown)
    this.env?.addEventListener?.("popstate", this._onPopState)
    this.env?.addEventListener?.("orientationchange", this._onViewportChange)
    this.env?.addEventListener?.("resize", this._onViewportChange)
    this.env?.visualViewport?.addEventListener?.("resize", this._onViewportChange)
    this.video?.addEventListener?.("webkitbeginfullscreen", this._onWebkitBegin)
    this.video?.addEventListener?.("webkitendfullscreen", this._onWebkitEnd)
    this._renderButton()
    return this
  }

  async toggle() {
    if (this.active) return this.exit()
    return this.enter()
  }

  async enter() {
    if (this.active || this.destroyed) return this.mode
    this.restoreFocusTo = this.document?.activeElement || null

    if (typeof this.viewport?.requestFullscreen === "function") {
      try {
        await this.viewport.requestFullscreen({ navigationUI: "hide" })
        this._setActive("standard")
        return this.mode
      } catch (_) {
        // Safari versions that implement Fullscreen but reject navigationUI
        // still accept the no-options form.
        try {
          await this.viewport.requestFullscreen()
          this._setActive("standard")
          return this.mode
        } catch (_) {}
      }
    }

    const webkitRequest =
      this.viewport?.webkitRequestFullscreen || this.viewport?.webkitRequestFullScreen
    if (typeof webkitRequest === "function") {
      try {
        await Promise.resolve(webkitRequest.call(this.viewport))
        this._setActive("webkit-element")
        return this.mode
      } catch (_) {}
    }

    if (typeof this.video?.webkitEnterFullscreen === "function") {
      try {
        this.video.webkitEnterFullscreen()
        this._setActive("webkit-video")
        return this.mode
      } catch (_) {}
    }

    this._enterFallback()
    return this.mode
  }

  async exit({ consumeHistory = true } = {}) {
    if (!this.active) return
    const mode = this.mode

    if (mode === "standard" && typeof this.document?.exitFullscreen === "function") {
      try {
        await this.document.exitFullscreen()
      } catch (_) {}
    } else if (mode === "webkit-element") {
      const webkitExit =
        this.document?.webkitExitFullscreen || this.document?.webkitCancelFullScreen
      if (typeof webkitExit === "function") {
        try {
          await Promise.resolve(webkitExit.call(this.document))
        } catch (_) {}
      }
    } else if (mode === "webkit-video" && typeof this.video?.webkitExitFullscreen === "function") {
      callSafely(() => this.video.webkitExitFullscreen())
    }

    const shouldConsumeHistory = mode === "fallback" && consumeHistory && this.historyPushed
    this._finishExit({ restoreFocus: true })
    if (shouldConsumeHistory && typeof this.env?.history?.back === "function") {
      this.env.history.back()
    }
  }

  destroy() {
    if (this.destroyed) return
    this.destroyed = true

    this.button?.removeEventListener?.("click", this._onToggle)
    this.document?.removeEventListener?.("fullscreenchange", this._onFullscreenChange)
    this.document?.removeEventListener?.("webkitfullscreenchange", this._onFullscreenChange)
    this.document?.removeEventListener?.("keydown", this._onKeyDown)
    this.env?.removeEventListener?.("popstate", this._onPopState)
    this.env?.removeEventListener?.("orientationchange", this._onViewportChange)
    this.env?.removeEventListener?.("resize", this._onViewportChange)
    this.env?.visualViewport?.removeEventListener?.("resize", this._onViewportChange)
    this.video?.removeEventListener?.("webkitbeginfullscreen", this._onWebkitBegin)
    this.video?.removeEventListener?.("webkitendfullscreen", this._onWebkitEnd)

    // Only consume history when the current entry is our synthetic fallback
    // marker. That pops to the same route without risking a previous page.
    const consumeFallbackEntry =
      this.mode === "fallback" &&
      this.historyPushed &&
      this.env?.history?.state?.[FALLBACK_STATE] === true
    void this.exit({ consumeHistory: consumeFallbackEntry })
    this._finishExit({ restoreFocus: false })
    if (this.button) this.button.hidden = true
    setFocusedScreenShareQuality(this.publication, false)
  }

  _enterFallback() {
    if (!this.historyPushed && typeof this.env?.history?.pushState === "function") {
      const current = this.env.history.state
      const state = current && typeof current === "object" ? { ...current } : {}
      state[FALLBACK_STATE] = true
      callSafely(() => this.env.history.pushState(state, ""))
      this.historyPushed = true
    }
    this._setActive("fallback")
    this._sizeFallback()
  }

  _setActive(mode) {
    this.mode = mode
    this.active = true
    if (this.root?.dataset) this.root.dataset.fullscreenMode = mode
    if (mode === "fallback") {
      this.root?.classList?.add(ACTIVE_CLASS)
      this.document?.documentElement?.classList?.add(PAGE_ACTIVE_CLASS)
      this.document?.body?.classList?.add(PAGE_ACTIVE_CLASS)
    }
    this._renderButton()
    this.button?.focus?.({ preventScroll: true })
  }

  _finishExit({ restoreFocus }) {
    const wasActive = this.active
    this.active = false
    this.mode = null
    this.historyPushed = false
    this.root?.classList?.remove(ACTIVE_CLASS)
    if (this.root?.dataset) delete this.root.dataset.fullscreenMode
    this.document?.documentElement?.classList?.remove(PAGE_ACTIVE_CLASS)
    this.document?.body?.classList?.remove(PAGE_ACTIVE_CLASS)
    this.root?.style?.removeProperty?.("--screen-share-viewport-height")
    this._renderButton()

    if (restoreFocus && wasActive && this.restoreFocusTo?.isConnected !== false) {
      this.restoreFocusTo?.focus?.({ preventScroll: true })
    }
    this.restoreFocusTo = null
  }

  _syncNativeState() {
    if (!this.active || this.mode === "fallback" || this.mode === "webkit-video") return
    const fullscreenElement = this.document?.fullscreenElement || this.document?.webkitFullscreenElement
    if (!fullscreenElement) this._finishExit({ restoreFocus: true })
  }

  _sizeFallback() {
    if (this.mode !== "fallback") return
    const height = this.env?.visualViewport?.height || this.env?.innerHeight
    if (height) this.root?.style?.setProperty?.("--screen-share-viewport-height", String(height) + "px")
  }

  _renderButton() {
    if (!this.button) return
    const label = this.active ? "Exit full screen" : "Enter full screen"
    this.button.setAttribute?.("aria-label", label)
    this.button.setAttribute?.("aria-pressed", this.active ? "true" : "false")
    this.button.setAttribute?.("title", label)
    if (this.button.dataset) this.button.dataset.fullscreenState = this.active ? "active" : "idle"
    const labelNode = this.button.querySelector?.("[data-screen-share-fullscreen-label]")
    if (labelNode) labelNode.textContent = label
  }
}
