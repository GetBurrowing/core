// Visual subscriber only: never captures a microphone, joins a second room,
// attaches another audio element, or connects the analyser to a speaker.
export function mouthHeight(samples) {
  if (!samples?.length) return 12
  let sum = 0
  for (const value of samples) sum += ((value - 128) / 128) ** 2
  return 12 + Math.min(1, Math.sqrt(sum / samples.length) * 5) * 74
}

export function audibleTrack(participant) {
  for (const publication of participant?.audioTrackPublications?.values() || []) {
    const track = publication.track
    if (!track || publication.isMuted || track.isMuted) continue
    if (track.mediaStreamTrack?.readyState !== "live") continue
    const playing = track.attachedElements?.some(el =>
      !el.paused && !el.muted && el.volume > 0 && !el.ended)
    if (playing) return track.mediaStreamTrack
  }
  return null
}

const MeetingCohostFace = {
  mounted() {
    this.dialog = this.el.querySelector("[data-face-dialog]")
    this.stage = this.el.querySelector("[data-face-stage]")
    this.mouth = this.el.querySelector("[data-face-mouth]")
    this.status = this.el.querySelector("[data-face-status]")
    this.openButton = this.el.querySelector("[data-face-open]")
    this.closeButton = this.el.querySelector("[data-face-close]")
    this.fullButton = this.el.querySelector("[data-face-fullscreen]")
    this.onOpen = () => {
      this.dialog.showModal()
      // Construct/resume from a human gesture, before the first remote word.
      const Context = window.AudioContext || window.webkitAudioContext
      if (Context && !this.context) this.context = new Context()
      this.context?.resume().catch(() => this.paint("audio unavailable", 12))
      this.timer = window.setInterval(() => this.tick(), 40)
      this.tick()
    }
    this.onClose = () => this.dialog.close()
    this.onClosed = () => {
      this.stop()
      if (document.fullscreenElement === this.dialog) {
        document.exitFullscreen?.().catch(() => {})
      }
      this.openButton.focus()
    }
    this.onFullscreen = () => {
      this.dialog.requestFullscreen?.().catch(() => {})
    }
    this.openButton.addEventListener("click", this.onOpen)
    this.closeButton.addEventListener("click", this.onClose)
    this.fullButton.addEventListener("click", this.onFullscreen)
    this.dialog.addEventListener("close", this.onClosed)
  },

  paint(state, height) {
    this.stage.dataset.state = state
    if (this.status.textContent !== state) this.status.textContent = state
    this.mouth.setAttribute("height", height.toFixed(1))
    this.mouth.setAttribute("y", (395 - height / 2).toFixed(1))
    this.mouth.setAttribute("rx", Math.min(20, height / 2).toFixed(1))
  },

  disconnectSource() {
    this.source?.disconnect()
    this.analyser?.disconnect()
    this.source = this.analyser = this.track = null
  },

  tick() {
    const room = window.__livekit_room || window.__livekitRoom
    if (document.hidden || !room || room.state !== "connected") {
      this.disconnectSource()
      this.paint("disconnected", 12)
      return
    }
    const identity = this.el.dataset.identity
    const participant = room.getParticipantByIdentity?.(identity) || room.remoteParticipants?.get(identity)
    if (!participant) {
      this.disconnectSource()
      this.paint("waiting for cohost", 12)
      return
    }
    const track = room.canPlaybackAudio === false ? null : audibleTrack(participant)
    if (!track || this.context?.state !== "running") {
      this.disconnectSource()
      this.paint(room.canPlaybackAudio === false ? "enable call audio" : "ready", 12)
      return
    }
    if (track !== this.track) {
      this.disconnectSource()
      try {
        this.source = this.context.createMediaStreamSource(new MediaStream([track]))
        this.analyser = this.context.createAnalyser()
        this.analyser.fftSize = 512
        this.source.connect(this.analyser)
        this.samples = new Uint8Array(this.analyser.fftSize)
        this.track = track
      } catch (_) {
        this.disconnectSource()
        this.paint("audio unavailable", 12)
        return
      }
    }
    this.analyser.getByteTimeDomainData(this.samples)
    const height = mouthHeight(this.samples)
    this.paint(height > 15 ? "speaking" : "ready", height)
  },

  stop() {
    window.clearInterval(this.timer)
    this.timer = null
    this.disconnectSource()
    this.context?.close().catch(() => {})
    this.context = null
    this.paint("disconnected", 12)
  },

  destroyed() {
    this.stop()
    this.openButton.removeEventListener("click", this.onOpen)
    this.closeButton.removeEventListener("click", this.onClose)
    this.fullButton.removeEventListener("click", this.onFullscreen)
    this.dialog.removeEventListener("close", this.onClosed)
    if (this.dialog.open) this.dialog.close()
  }
}

export default MeetingCohostFace
