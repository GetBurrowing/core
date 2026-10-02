/**
 * Local playback for the inbound game_stream audio track (task 01a0f84e).
 *
 * Audio has its own MediaStream and element. The video element stays muted,
 * so adding audio cannot make video autoplay unreliable. This controller
 * never touches peer signalling: mute is local and cannot renegotiate.
 */

export const AUDIO_LABELS = {
  waiting: "Waiting for audio",
  playing: "Audio playing",
  muted: "Audio muted",
  blocked: "Audio blocked — click Play sound",
  error: "Audio playback failed — click Retry sound",
}

function mediaStreamFor(track, MediaStreamCtor) {
  return new MediaStreamCtor([track])
}

export class AudioPlayback {
  constructor({ element, stateElement, button, MediaStreamCtor = globalThis.MediaStream }) {
    this.element = element
    this.stateElement = stateElement
    this.button = button
    this.MediaStreamCtor = MediaStreamCtor
    this.track = null
    this.trackEnded = null
    this.activated = false
    this.muted = false
    this.state = "waiting"
    this.generation = 0
    this.render()
  }

  attach(track) {
    if (!this.element || !track || track.kind !== "audio") return false
    if (track === this.track) {
      if (this.activated) this.play()
      return true
    }

    this.clearTrack()
    this.track = track
    const generation = ++this.generation
    this.trackEnded = () => {
      if (this.track === track && this.generation === generation) this.detach()
    }
    if (typeof track.addEventListener === "function") track.addEventListener("ended", this.trackEnded)

    this.element.srcObject = mediaStreamFor(track, this.MediaStreamCtor)
    this.element.muted = this.muted
    this.setState(this.muted ? "muted" : "waiting")
    if (this.activated && !this.muted) this.play()
    return true
  }

  gesture() {
    this.activated = true
    if (this.track && !this.muted) return this.play()
    return Promise.resolve(false)
  }

  async play() {
    if (!this.element || !this.track || this.muted) return false
    const generation = this.generation
    this.setState("waiting")
    try {
      await this.element.play()
      if (generation !== this.generation || !this.track || this.muted) return false
      this.setState("playing")
      return true
    } catch (error) {
      if (generation !== this.generation || !this.track || this.muted) return false
      this.setState(error && error.name === "NotAllowedError" ? "blocked" : "error")
      return false
    }
  }

  toggleMute() {
    this.muted = !this.muted
    if (this.element) this.element.muted = this.muted
    if (this.muted) {
      this.setState(this.track ? "muted" : "waiting")
      return this.muted
    }
    if (this.track && this.activated) this.play()
    else this.setState("waiting")
    return this.muted
  }

  action() {
    if (this.track && !this.muted && ["blocked", "error", "waiting"].includes(this.state)) {
      return this.gesture()
    }
    this.toggleMute()
    return Promise.resolve(true)
  }

  clearTrack() {
    if (this.track && this.trackEnded && typeof this.track.removeEventListener === "function") {
      this.track.removeEventListener("ended", this.trackEnded)
    }
    this.track = null
    this.trackEnded = null
    if (this.element && typeof this.element.pause === "function") this.element.pause()
    if (this.element) this.element.srcObject = null
  }

  detach() {
    this.generation++
    this.clearTrack()
    this.setState("waiting")
  }

  setState(state) {
    this.state = state
    this.render()
  }

  render() {
    if (this.stateElement) {
      this.stateElement.textContent = AUDIO_LABELS[this.state]
      this.stateElement.dataset.gsAudioState = this.state
    }
    if (!this.button) return
    const retry = !this.muted && ["blocked", "error"].includes(this.state)
    this.button.disabled = !this.track
    this.button.textContent = retry
      ? this.state === "blocked"
        ? "Play sound"
        : "Retry sound"
      : this.muted
        ? "Unmute"
        : "Mute"
    this.button.setAttribute("aria-pressed", String(this.muted))
    this.button.setAttribute(
      "aria-label",
      retry ? this.button.textContent : this.button.textContent + " game audio",
    )
  }
}

/** Route one inbound WebRTC track without ever attaching audio to muted video. */
export function routeInboundTrack(
  event,
  { video, audio, onVideo, MediaStreamCtor = globalThis.MediaStream },
) {
  const track = event && event.track
  if (!track) return "ignored"

  if (track.kind === "audio") {
    audio.attach(track)
    return "audio"
  }

  if (track.kind !== "video" || !video) return "ignored"
  video.removeAttribute("poster")
  video.muted = true
  video.srcObject =
    (event.streams && event.streams[0]) || mediaStreamFor(track, MediaStreamCtor)
  const played = video.play()
  if (played && typeof played.catch === "function") played.catch(() => {})
  if (onVideo) onVideo()
  return "video"
}
