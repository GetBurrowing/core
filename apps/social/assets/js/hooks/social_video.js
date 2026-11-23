// A source is attached only by an explicit Play. Native controls handle playback.
export default {
  mounted() {
    this.video = this.el.querySelector("video")
    this.button = this.el.querySelector("[data-role='video-play']")
    this.status = this.el.querySelector("[data-role='video-status']")
    this.source = this.el.dataset.src
    this.generation = 0
    this.active = false
    this.onClick = () => this.start()
    this.listeners = {
      playing: () => { if (this.active) this.state("playing") },
      waiting: () => { if (this.active) this.state("loading") },
      error: () => { if (this.active) this.state("error") },
      ended: () => { if (this.active) this.state("idle") },
    }
    this.button.addEventListener("click", this.onClick)
    Object.entries(this.listeners).forEach(([event, fn]) => this.video.addEventListener(event, fn))
    this.state("idle")
  },
  updated() {
    const poster = this.el.dataset.poster
    if (poster) this.video.setAttribute("poster", poster)
    else this.video.removeAttribute("poster")
    if (this.source === this.el.dataset.src) return
    this.generation++
    this.active = false
    this.video.pause()
    this.video.removeAttribute("src")
    this.video.load()
    this.source = this.el.dataset.src
    this.state("idle")
  },
  start() {
    const generation = ++this.generation
    this.active = true
    this.state("loading")
    if (this.video.getAttribute("src") !== this.source) this.video.setAttribute("src", this.source)
    else if (this.video.error) this.video.load()
    try {
      Promise.resolve(this.video.play()).catch(() => {
        if (this.active && this.generation === generation) this.state("error")
      })
    } catch (_) { this.state("error") }
  },
  state(kind) {
    // Keep native controls above decorative platform captions while active.
    this.el.style.zIndex = this.active ? "10" : ""
    this.button.hidden = kind === "playing" || kind === "loading"
    this.button.disabled = false
    this.button.textContent = kind === "error" ? "Try video again" : "Play video"
    this.status.hidden = kind !== "loading" && kind !== "error"
    this.status.textContent = kind === "error" ? "Video couldn’t load. Try again." : kind === "loading" ? "Loading video…" : ""
  },
  destroyed() {
    this.active = false
    this.generation++
    this.button.removeEventListener("click", this.onClick)
    Object.entries(this.listeners).forEach(([event, fn]) => this.video.removeEventListener(event, fn))
    this.video.pause()
    this.video.removeAttribute("src")
    this.video.load()
  },
}
