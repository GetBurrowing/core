// A scoped coordinator for actual same-excerpt videos. The hook's ignored anchor
// lives beside server-owned controls; only ignored media regions are mutated.
export default {
  mounted() {
    this.group = document.getElementById(this.el.dataset.previewControls)
    if (!this.group) return
    this.motion = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.bindings = []
    this.onMotion = () => this.restart()
    this.onVisibility = () => this.restart()
    this.motion.addEventListener("change", this.onMotion)
    document.addEventListener("visibilitychange", this.onVisibility)
    this.observer = new MutationObserver(() => {
      const videos = [...this.group.querySelectorAll("[data-preview-video]")]
      if (videos.length !== this.bindings.length || videos.some((v, i) => v !== this.bindings[i].video)) this.bind()
    })
    this.observer.observe(this.group, {childList: true, subtree: true})
    this.bind()
  },
  updated() { if (this.group) this.bind() },
  bind() {
    this.unbind()
    this.bindings = [...this.group.querySelectorAll("[data-preview-video]")].map(video => {
      const media = video.closest("[data-preview-media]")
      video.muted = true
      const images = [...(media.querySelectorAll?.("[data-preview-stills] img") || [])]
      const brokenStill = () => images.some(image => image.complete && image.naturalWidth === 0)
      const ready = () => { media.dataset.previewState = brokenStill() ? "error" : "ready"; this.restart() }
      const error = () => { media.dataset.previewState = "error"; this.restart() }
      video.addEventListener("loadeddata", ready)
      video.addEventListener("error", error)
      images.forEach(image => image.addEventListener("error", error))
      media.dataset.previewState = video.error || brokenStill() ? "error" : video.readyState >= 2 ? "ready" : "loading"
      return {video, media, images, ready, error}
    })
    this.restart()
  },
  restart() {
    this.stop()
    const reduced = this.motion.matches
    for (const {media} of this.bindings) media.dataset.previewMotion = reduced ? "reduced" : "normal"
    if (reduced || document.hidden || !this.bindings.length) return
    if (this.bindings.some(({media}) => media.dataset.previewState === "loading")) return
    const playable = this.bindings.filter(({media}) => media.dataset.previewState === "ready")
    if (!playable.length) return
    this.epoch = performance.now()
    for (const {video, media} of playable) {
      video.currentTime = 0
      const play = video.play()
      if (play?.catch) play.catch(() => {
        if (!this.motion.matches && !document.hidden && !video.paused) return
        // Autoplay rejection leaves a truthful still-frame comparison.
        if (!this.motion.matches && !document.hidden) {
          media.dataset.previewState = "error"
          media.dataset.previewMotion = "reduced"
        }
      })
    }
    this.timer = window.setInterval(() => {
      const elapsed = (performance.now() - this.epoch) / 1000
      for (const {video} of playable) {
        if (!Number.isFinite(video.duration) || video.duration <= 0) continue
        const expected = elapsed % video.duration
        if (Math.abs(video.currentTime - expected) > 0.06) video.currentTime = expected
      }
    }, 250)
  },
  stop() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
    for (const {video} of this.bindings || []) video.pause()
  },
  unbind() {
    this.stop()
    for (const {video, images, ready, error} of this.bindings || []) {
      video.removeEventListener("loadeddata", ready)
      video.removeEventListener("error", error)
      images.forEach(image => image.removeEventListener("error", error))
    }
    this.bindings = []
  },
  destroyed() {
    this.unbind()
    this.observer?.disconnect()
    this.motion?.removeEventListener("change", this.onMotion)
    document.removeEventListener("visibilitychange", this.onVisibility)
  }
}
