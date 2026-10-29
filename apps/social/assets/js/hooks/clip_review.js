/**
 * ClipReview hook: the Clips tab's Review bay (Clip Studio 3/9, task
 * 01a16662-8c00 stage 4; prototype 01a16628-8d70 v2 app.js keydown, `step`,
 * `togglePlay`, `syncScrub`, `drawToast`). Mounted on the bay root
 * (`#social-clips-review-keys` inside `PlatformWeb.SocialClipsReview`).
 *
 * It only navigates, toggles playback, ticks the toast and syncs the URL:
 *   * J / K push "next" / "prev" to the component; Space plays or pauses
 *     the selected clip. Inactive while typing (input, textarea, select,
 *     contenteditable) and with meta, ctrl or alt held. No key decides.
 *   * play / pause / timeupdate on the selected video move the scrubber and
 *     swap the play/pause icons.
 *   * the toast's data-until drives the "Ns" counter and the bar (display
 *     only: nothing is pushed when it reaches 0; the undo window is the
 *     server's).
 *   * "clips:url" replaces the URL's tab/view/clip params.
 * No touch, swipe or pointer gesture decides anything. Everything is inert
 * while the clips pane is hidden (offsetParent is null).
 */

const TYPING_TAGS = new Set(["INPUT", "TEXTAREA", "SELECT"])

/** True when the event target is somewhere the user types. */
export function typingTarget(t) {
  if (!t) return false
  return TYPING_TAGS.has(t.tagName) || t.isContentEditable === true
}

/**
 * The action a key press maps to: "next", "prev", "toggle" or null.
 * Never anything that decides a clip.
 */
export function keyAction(key, target, mods = {}) {
  if (typingTarget(target)) return null
  if (mods.metaKey || mods.ctrlKey || mods.altKey) return null
  if (key === "j" || key === "J") return "next"
  if (key === "k" || key === "K") return "prev"
  if (key === " ") return "toggle"
  return null
}

/** Whole seconds left until `untilMs` (rounded up), never below 0. */
export function secondsLeft(untilMs, nowMs) {
  const left = Number(untilMs) - Number(nowMs)
  if (!Number.isFinite(left) || left <= 0) return 0
  return Math.ceil(left / 1000)
}

/** The scrubber fill, 0..100; 0 unless d is a positive finite number. */
export function scrubPercent(t, d) {
  if (typeof d !== "number" || !Number.isFinite(d) || d <= 0) return 0
  const x = typeof t === "number" && Number.isFinite(t) ? t : 0
  return Math.min(100, Math.max(0, (x / d) * 100))
}

/** m:ss for whole seconds (truncated). */
export function mmss(seconds) {
  const s = Math.floor(Math.max(0, Number.isFinite(seconds) ? seconds : 0))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
}

/**
 * The current query string with tab=clips, view and clip set; every other
 * key is kept. A blank view or clip removes that key. Returns "?…".
 */
export function clipsUrl(search, { view, clip } = {}) {
  const params = new URLSearchParams(search || "")
  params.set("tab", "clips")
  if (view) params.set("view", view)
  else params.delete("view")
  if (clip) params.set("clip", clip)
  else params.delete("clip")
  return `?${params.toString()}`
}

const ClipReview = {
  mounted() {
    this.toastUntil = null
    this.toastTotal = null
    this.raf = null

    this.onKey = (e) => this.key(e)
    window.addEventListener("keydown", this.onKey)
    this.onLayout = () => {
      if (this.layoutFrame) cancelAnimationFrame(this.layoutFrame)
      this.layoutFrame = requestAnimationFrame(() => this.fitViewport())
    }
    window.addEventListener("resize", this.onLayout)
    window.visualViewport?.addEventListener("resize", this.onLayout)
    this.layoutObserver = new ResizeObserver(this.onLayout)
    this.layoutObserver.observe(this.el)

    // Media events do not bubble; capture them on the bay root so a swapped
    // player (a new clip) needs no re-binding.
    this.onMedia = (e) => {
      if (e.target === this.video()) this.sync()
    }
    for (const type of ["play", "pause", "timeupdate", "loadedmetadata"])
      this.el.addEventListener(type, this.onMedia, true)

    // The hero and scrubber play buttons toggle playback; nothing else.
    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest('[data-role="clip-play"], [data-role="clip-scrub-play"]')
      if (btn && this.el.contains(btn)) this.toggle()
    }
    this.el.addEventListener("click", this.onClick)

    this.handleEvent("clips:url", ({ view, clip }) => {
      if (!this.active()) return
      const url = window.location.pathname + clipsUrl(window.location.search, { view, clip })
      window.history.replaceState(window.history.state, "", url)
    })

    this.sync()
    this.tickToast()
    this.onLayout()
  },

  updated() {
    this.sync()
    this.tickToast()
    this.onLayout()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("resize", this.onLayout)
    window.visualViewport?.removeEventListener("resize", this.onLayout)
    this.layoutObserver.disconnect()
    if (this.layoutFrame) cancelAnimationFrame(this.layoutFrame)
    for (const type of ["play", "pause", "timeupdate", "loadedmetadata"])
      this.el.removeEventListener(type, this.onMedia, true)
    this.el.removeEventListener("click", this.onClick)
    if (this.raf) cancelAnimationFrame(this.raf)
  },

  active() {
    return this.el.offsetParent !== null
  },

  fitViewport() {
    this.layoutFrame = null
    const bay = this.el.querySelector('[data-role="clips-bay"]')
    if (!bay || !this.active() || !window.matchMedia("(min-width: 761px)").matches) {
      this.el.style.removeProperty("--clips-bay-height")
      return
    }
    // The desktop desk uses the actual remaining space, not a guessed
    // shell/header height. Leave one spacing token below the bay.
    const bottomGap = parseFloat(getComputedStyle(document.documentElement).fontSize)
    const viewportBottom = window.visualViewport
      ? window.visualViewport.height + window.visualViewport.offsetTop
      : window.innerHeight
    const height = Math.max(0, viewportBottom - bay.getBoundingClientRect().top - bottomGap)
    const value = `${Math.floor(height)}px`
    if (this.el.style.getPropertyValue("--clips-bay-height") !== value)
      this.el.style.setProperty("--clips-bay-height", value)
  },

  video() {
    return this.el.querySelector('[data-role="clip-player"] video')
  },

  key(e) {
    if (!this.active()) return
    const action = keyAction(e.key, e.target, e)
    if (!action) return
    e.preventDefault()
    if (action === "toggle") this.toggle()
    else this.pushEventTo(this.el, action, {})
  },

  toggle() {
    const v = this.video()
    if (!v) return
    if (v.paused) {
      this.el.querySelectorAll("video").forEach((o) => {
        if (o !== v && !o.paused) o.pause()
      })
      const p = v.play()
      if (p && p.catch)
        p.catch(() => {
          v.muted = true
          v.play().catch(() => {})
        })
    } else {
      v.pause()
    }
  },

  // [syncScrub] the fill, the elapsed time and the play/pause icons.
  sync() {
    const v = this.video()
    const paused = !v || v.paused
    const t = v ? v.currentTime : 0
    const d = v ? v.duration : NaN

    const fill = this.el.querySelector('[data-role="clip-scrub-fill"]')
    if (fill) fill.style.width = `${scrubPercent(t, d)}%`
    const time = this.el.querySelector('[data-role="clip-time"]')
    if (time) time.textContent = mmss(t)

    this.el.querySelectorAll('[data-role="clip-icon-play"]').forEach((i) => i.classList.toggle("hidden", !paused))
    this.el.querySelectorAll('[data-role="clip-icon-pause"]').forEach((i) => i.classList.toggle("hidden", paused))
  },

  // [drawToast] counts the toast's data-until down; display only.
  tickToast() {
    const toast = this.el.querySelector('[data-role="clip-toast"]')
    const until = toast && Number(toast.dataset.until)
    if (!toast || !toast.querySelector('[data-role="clip-toast-undo"]') || !Number.isFinite(until)) {
      this.toastUntil = null
      return
    }
    if (until !== this.toastUntil) {
      this.toastUntil = until
      this.toastTotal = Math.max(until - Date.now(), 1)
    }
    if (this.raf) cancelAnimationFrame(this.raf)

    const frame = () => {
      this.raf = null
      const el = this.el.querySelector('[data-role="clip-toast"]')
      if (!el || Number(el.dataset.until) !== this.toastUntil) return
      const now = Date.now()
      const secs = el.querySelector('[data-role="clip-toast-secs"]')
      if (secs) secs.textContent = `${secondsLeft(this.toastUntil, now)}s`
      const bar = el.querySelector('[data-role="clip-toast-bar"]')
      const left = Math.max(this.toastUntil - now, 0)
      if (bar) {
        bar.style.transition = "none"
        bar.style.scale = `${left / this.toastTotal} 1`
      }
      if (left > 0 && this.active()) this.raf = requestAnimationFrame(frame)
    }
    frame()
  },
}

export default ClipReview
