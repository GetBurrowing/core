// One real rendered file; the immutable content bounds locate its seam.
export function previewWindow(seam, total) {
  const content = Number(seam), duration = Number(total)
  if (!Number.isFinite(content) || !Number.isFinite(duration) || content <= 0 || duration < content) return null
  return {start: Math.max(0, content - 2), seam: content, total: duration, fraction: content / duration}
}
export default {
  mounted() {
    this.video = this.el.querySelector("video")
    this.progress = this.el.querySelector('[data-role="closing-playhead"]')
    this.status = this.el.querySelector('[data-role="closing-media-error"]')
    this.marker = this.el.querySelector('[data-role="closing-seam"]')
    this.position = () => {
      if (this.video) {
        this.video.hidden = false
        if (this.el.dataset.audio) this.video.muted = this.el.dataset.audio === "mute"
      }
      if (this.status) this.status.hidden = true
      const w = previewWindow(this.el.dataset.seam, this.el.dataset.total)
      if (!w || !this.video) return
      this.video.currentTime = w.start
      if (this.marker) this.marker.style.left = `${w.fraction * 100}%`
    }
    this.track = () => {if (this.progress && this.video.duration) this.progress.value = this.video.currentTime / this.video.duration}
    this.failed = () => {
      if (this.video) this.video.hidden = true
      if (this.status) this.status.hidden = false
    }
    this.video?.addEventListener("error", this.failed)
    this.video?.addEventListener("loadedmetadata", this.position)
    this.video?.addEventListener("timeupdate", this.track)
    if (this.video?.readyState >= 1) this.position()
  },
  updated() { this.position() },
  destroyed() {
    this.video?.removeEventListener("error", this.failed)
    this.video?.removeEventListener("loadedmetadata", this.position)
    this.video?.removeEventListener("timeupdate", this.track)
  }
}
