// ChatClip — the inline video player in a chat message (task 01a1655c stage 4).
//
// The server reserves the frame at the stored aspect ratio (else 16:9). Once
// the browser has the clip's header (loadedmetadata), this hook:
//   * resets the frame to the clip's own videoWidth/videoHeight, and caps its
//     width so the box at that ratio still fits under max-height 60vh — a
//     9:16 clip is neither cropped nor shrunk into a 16:9 box;
//   * fills the file line's duration when the server had none to render.
// When the video errors it hides the frame and shows the "Can't play this
// video" card, so a broken file never leaves an empty black rectangle.
//
// The element carries phx-update="ignore", so LiveView re-renders keep what
// this hook did. An error or metadata that arrived before the socket
// connected is picked up from the element's state on mount.

export function formatDuration(seconds) {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0) return null
  const total = Math.round(seconds)
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${String(s).padStart(2, "0")}`
}

// Inline style for a frame showing a w×h clip: its ratio, and a width cap of
// 60vh × w/h so the box at that ratio is never taller than 60vh.
export function frameStyle(w, h) {
  if (!(w > 0 && h > 0)) return null
  return {
    aspectRatio: `${w} / ${h}`,
    maxWidth: `min(100%, calc(60vh * ${w} / ${h}))`,
  }
}

const ChatClip = {
  mounted() {
    this.video = this.el.querySelector("video")
    if (!this.video) return

    this.onMeta = () => this.applyMetadata()
    this.onError = () => this.showFallback()
    this.video.addEventListener("loadedmetadata", this.onMeta)
    this.video.addEventListener("error", this.onError)

    if (this.video.error) this.showFallback()
    else if (this.video.readyState >= 1) this.applyMetadata()
  },

  destroyed() {
    if (!this.video) return
    this.video.removeEventListener("loadedmetadata", this.onMeta)
    this.video.removeEventListener("error", this.onError)
  },

  applyMetadata() {
    const frame = this.el.querySelector('[data-role="clip-frame"]')
    const style = frameStyle(this.video.videoWidth, this.video.videoHeight)
    if (frame && style) Object.assign(frame.style, style)

    const duration = this.el.querySelector('[data-role="clip-duration"]')
    const text = formatDuration(this.video.duration)
    if (duration && text && duration.classList.contains("hidden")) {
      duration.textContent = `· ${text}`
      duration.classList.remove("hidden")
    }
  },

  showFallback() {
    const frame = this.el.querySelector('[data-role="clip-frame"]')
    const fallback = this.el.querySelector('[data-role="clip-fallback"]')
    if (frame) frame.classList.add("hidden")
    if (fallback) fallback.classList.replace("hidden", "flex")
  },
}

export default ChatClip
