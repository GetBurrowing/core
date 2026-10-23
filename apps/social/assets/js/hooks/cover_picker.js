/**
 * CoverPicker hook: the frame tab of a video post's cover picker (task
 * 01a165ec stage 4, design canvas 01a165ec-76e8). Mounted on
 * `PlatformWeb.SocialLive`'s scrubber (`phx-update="ignore"`, so this hook
 * owns the DOM after mount).
 *
 * Frames are drawn in the browser, never by the server: a hidden <video> on
 * the same-origin /files/blob URL seeks to N evenly spaced times and each
 * frame is drawn onto a <canvas> (drawImage) to make the filmstrip.
 * Dragging or tapping the strip, or the arrow keys (0.1 s; 1 s with
 * Shift), seek the preview <video>. Enter, or the page's "Use this cover"
 * (a `cover:confirm` event dispatched on this element), pushes
 * `cover_frame` with integer milliseconds.
 *
 * The strip is a slider: aria-valuenow is seconds, aria-valuetext is the
 * timecode ("0:07.40 / 0:42").
 */

export const STEP_S = 0.1
export const BIG_STEP_S = 1
export const FRAME_HEIGHT_PX = 56

/** Seconds (a <video>.currentTime) to whole milliseconds. */
export function toMs(seconds) {
  return Math.round(seconds * 1000)
}

/** Clamp a time to [0, duration]; an unknown duration only floors at 0. */
export function clamp(t, duration) {
  const floor = Math.max(0, Number.isFinite(t) ? t : 0)
  return Number.isFinite(duration) && duration > 0 ? Math.min(floor, duration) : floor
}

/** The step one key press moves: 0.1 s, or 1 s with Shift. */
export function stepFor(shiftKey) {
  return shiftKey ? BIG_STEP_S : STEP_S
}

/**
 * The time after a key press, or null for a key the slider ignores.
 * Rounded to the centisecond so repeated 0.1 s steps do not drift.
 */
export function keyStep(current, key, shiftKey, duration) {
  let delta
  if (key === "ArrowRight" || key === "ArrowUp") delta = stepFor(shiftKey)
  else if (key === "ArrowLeft" || key === "ArrowDown") delta = -stepFor(shiftKey)
  else if (key === "Home") return 0
  else if (key === "End") return clamp(duration, duration)
  else return null
  return clamp(Math.round((current + delta) * 100) / 100, duration)
}

function pad2(n) {
  return String(n).padStart(2, "0")
}

/** m:ss for whole seconds (truncated), as the card's label writes it. */
export function clock(seconds) {
  const s = Math.floor(Math.max(0, seconds))
  return `${Math.floor(s / 60)}:${pad2(s % 60)}`
}

/** "0:07.40 / 0:42": centiseconds for the position, m:ss for the length. */
export function timecode(seconds, duration) {
  const cs = Math.floor(toMs(Math.max(0, seconds)) / 10)
  const s = Math.floor(cs / 100)
  const head = `${Math.floor(s / 60)}:${pad2(s % 60)}.${pad2(cs % 100)}`
  return Number.isFinite(duration) && duration > 0 ? `${head} / ${clock(duration)}` : head
}

/** N evenly spaced frame times, each in the middle of its slot. */
export function frameTimes(duration, n) {
  if (!(Number.isFinite(duration) && duration > 0) || n < 1) return []
  return Array.from({ length: n }, (_, i) => ((i + 0.5) * duration) / n)
}

/** The time under a pointer at clientX over a strip's rect. */
export function timeAt(clientX, rect, duration) {
  if (!rect || rect.width <= 0) return 0
  const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width))
  return clamp(ratio * duration, duration)
}

/** The `cover_frame` payload: integer ms, and the browser's duration in ms. */
export function framePayload(postId, seconds, duration) {
  const payload = { post_id: postId, offset_ms: toMs(clamp(seconds, duration)) }
  if (Number.isFinite(duration) && duration > 0) payload.duration_ms = toMs(duration)
  return payload
}

function seek(video, t) {
  return new Promise((resolve) => {
    const done = () => {
      video.removeEventListener("seeked", done)
      resolve()
    }
    video.addEventListener("seeked", done)
    video.currentTime = t
  })
}

const CoverPicker = {
  mounted() {
    this.postId = this.el.dataset.postId
    this.src = this.el.dataset.src
    const knownMs = parseInt(this.el.dataset.durationMs, 10)
    this.duration = Number.isFinite(knownMs) && knownMs > 0 ? knownMs / 1000 : NaN
    this.t = (parseInt(this.el.dataset.offsetMs, 10) || 0) / 1000

    this.preview = this.el.querySelector("[data-cover-preview]")
    this.strip = this.el.querySelector("[data-cover-strip]")
    this.frames = this.el.querySelector("[data-cover-frames]")
    this.playhead = this.el.querySelector("[data-cover-playhead]")
    this.code = this.el.querySelector("[data-cover-timecode]")

    this.onMeta = () => {
      if (!(this.duration > 0) && Number.isFinite(this.preview.duration)) {
        this.duration = this.preview.duration
      }
      this.setTime(this.t)
      this.drawStrip()
    }
    if (this.preview.readyState >= 1) this.onMeta()
    else this.preview.addEventListener("loadedmetadata", this.onMeta, { once: true })

    this.dragging = false
    this.onDown = (e) => {
      this.dragging = true
      this.strip.setPointerCapture?.(e.pointerId)
      this.strip.dataset.dragging = "true"
      this.setTime(timeAt(e.clientX, this.strip.getBoundingClientRect(), this.duration))
    }
    this.onMove = (e) => {
      if (!this.dragging) return
      this.setTime(timeAt(e.clientX, this.strip.getBoundingClientRect(), this.duration))
    }
    this.onUp = () => {
      this.dragging = false
      delete this.strip.dataset.dragging
    }
    this.onKey = (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.confirm()
        return
      }
      const next = keyStep(this.t, e.key, e.shiftKey, this.duration)
      if (next === null) return
      e.preventDefault()
      this.setTime(next)
    }
    this.onConfirm = () => this.confirm()

    this.strip.addEventListener("pointerdown", this.onDown)
    this.strip.addEventListener("pointermove", this.onMove)
    this.strip.addEventListener("pointerup", this.onUp)
    this.strip.addEventListener("pointercancel", this.onUp)
    this.strip.addEventListener("keydown", this.onKey)
    this.el.addEventListener("cover:confirm", this.onConfirm)
  },

  destroyed() {
    this.cancelled = true
    if (this.sampler) {
      this.sampler.removeAttribute("src")
      this.sampler.load?.()
    }
  },

  setTime(t) {
    this.t = clamp(t, this.duration)
    if (this.preview && Math.abs(this.preview.currentTime - this.t) > 0.001) {
      this.preview.currentTime = this.t
    }
    const pct = this.duration > 0 ? (this.t / this.duration) * 100 : 0
    if (this.playhead) this.playhead.style.left = `${pct}%`
    const text = timecode(this.t, this.duration)
    if (this.code) this.code.textContent = text
    this.strip.setAttribute("aria-valuenow", this.t.toFixed(2))
    if (this.duration > 0) this.strip.setAttribute("aria-valuemax", this.duration.toFixed(2))
    this.strip.setAttribute("aria-valuetext", text)
  },

  confirm() {
    this.pushEvent("cover_frame", framePayload(this.postId, this.t, this.duration))
  },

  // A hidden <video> seeks to each frame time; each frame is drawn onto a
  // <canvas> sized to the strip's slot. Sequential, so one decoder.
  async drawStrip() {
    if (!(this.duration > 0) || !this.frames) return
    const height = Math.max(FRAME_HEIGHT_PX, this.strip.clientHeight || FRAME_HEIGHT_PX)
    const ratio =
      this.preview.videoWidth > 0 ? this.preview.videoWidth / this.preview.videoHeight : 9 / 16
    const slot = Math.max(16, height * ratio)
    const n = Math.max(4, Math.min(24, Math.ceil((this.strip.clientWidth || 320) / slot)))

    const sampler = document.createElement("video")
    sampler.muted = true
    sampler.playsInline = true
    sampler.preload = "auto"
    sampler.src = this.src
    this.sampler = sampler
    await new Promise((resolve) => {
      if (sampler.readyState >= 1) resolve()
      else sampler.addEventListener("loadedmetadata", resolve, { once: true })
    })

    this.frames.replaceChildren()
    for (const time of frameTimes(this.duration, n)) {
      if (this.cancelled) return
      const canvas = document.createElement("canvas")
      canvas.width = Math.round(slot * (window.devicePixelRatio || 1))
      canvas.height = Math.round(height * (window.devicePixelRatio || 1))
      canvas.className = "h-full min-w-0 flex-1 border-r border-base-300 object-cover"
      canvas.setAttribute("aria-hidden", "true")
      this.frames.appendChild(canvas)
      await seek(sampler, time)
      const ctx = canvas.getContext("2d")
      // Cover-fit the frame into the slot.
      const vw = sampler.videoWidth
      const vh = sampler.videoHeight
      const scale = Math.max(canvas.width / vw, canvas.height / vh)
      const dw = vw * scale
      const dh = vh * scale
      ctx.drawImage(sampler, (canvas.width - dw) / 2, (canvas.height - dh) / 2, dw, dh)
    }
  },
}

export default CoverPicker
