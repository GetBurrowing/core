/**
 * MeetingBar hook — bridges the mini-bar controls to the LiveKit Room instance.
 *
 * Reads initial mic/camera state from window.__livekitRoom.localParticipant,
 * handles toggle clicks via LiveKit SDK, disconnects on leave, and runs a
 * client-side mm:ss duration timer. Gracefully handles null room.
 */
const MeetingBar = {
  mounted() {
    this._syncState()
    this._startTimer()
    this._bindControls()

    this._onDisconnected = () => {
      // Route to the MeetingBarLive LiveComponent (this.el lives inside it),
      // not the parent ChatLive which doesn't care about mini-bar state.
      this.pushEventTo(this.el, "meeting_bar_state", { mic: false, camera: false, connected: false })
    }
    window.addEventListener("livekit:room-disconnected", this._onDisconnected)

    this._onConnected = () => this._syncState()
    window.addEventListener("livekit:room-connected", this._onConnected)

    this.handleEvent("meeting_bar_sync", () => this._syncState())
  },

  updated() {
    this._stopTimer()
    this._startTimer()
    this._bindControls()
  },

  destroyed() {
    this._stopTimer()
    this._unbindControls()
    window.removeEventListener("livekit:room-disconnected", this._onDisconnected)
    window.removeEventListener("livekit:room-connected", this._onConnected)
  },

  _syncState() {
    const room = window.__livekitRoom
    if (!room || !room.localParticipant) return
    const mic = room.localParticipant.isMicrophoneEnabled ?? true
    const camera = room.localParticipant.isCameraEnabled ?? false
    this.pushEventTo(this.el, "meeting_bar_state", { mic, camera, connected: true })
  },

  _bindControls() {
    this._unbindControls()

    this._micHandler = () => {
      const room = window.__livekitRoom
      if (!room || !room.localParticipant) return
      const current = room.localParticipant.isMicrophoneEnabled
      room.localParticipant.setMicrophoneEnabled(!current).then(() => {
        this.pushEventTo(this.el, "mic_toggled", { enabled: !current })
      }).catch((err) => console.warn("[MeetingBar] mic toggle failed:", err))
    }

    this._cameraHandler = () => {
      const room = window.__livekitRoom
      if (!room || !room.localParticipant) return
      const current = room.localParticipant.isCameraEnabled
      room.localParticipant.setCameraEnabled(!current).then(() => {
        this.pushEventTo(this.el, "camera_toggled", { enabled: !current })
      }).catch((err) => console.warn("[MeetingBar] camera toggle failed:", err))
    }

    this._leaveHandler = () => {
      const room = window.__livekitRoom
      if (room) {
        room.disconnect().catch(() => {})
        window.__livekitRoom = null
        window.dispatchEvent(new CustomEvent("livekit:room-disconnected"))
      }
    }

    const el = this.el
    el.querySelectorAll("[data-bar-mic]").forEach(btn =>
      btn.addEventListener("click", this._micHandler)
    )
    el.querySelectorAll("[data-bar-camera]").forEach(btn =>
      btn.addEventListener("click", this._cameraHandler)
    )
    el.querySelectorAll("[data-bar-leave]").forEach(btn =>
      btn.addEventListener("click", this._leaveHandler)
    )
  },

  _unbindControls() {
    if (this._micHandler) {
      this.el.querySelectorAll("[data-bar-mic]").forEach(btn =>
        btn.removeEventListener("click", this._micHandler)
      )
    }
    if (this._cameraHandler) {
      this.el.querySelectorAll("[data-bar-camera]").forEach(btn =>
        btn.removeEventListener("click", this._cameraHandler)
      )
    }
    if (this._leaveHandler) {
      this.el.querySelectorAll("[data-bar-leave]").forEach(btn =>
        btn.removeEventListener("click", this._leaveHandler)
      )
    }
  },

  _startTimer() {
    const startedAt = this.el.dataset.startedAt
    if (!startedAt) return
    this._startTime = new Date(startedAt).getTime()
    if (isNaN(this._startTime)) return
    this._tick()
    this._timerInterval = setInterval(() => this._tick(), 1000)
  },

  _stopTimer() {
    if (this._timerInterval) {
      clearInterval(this._timerInterval)
      this._timerInterval = null
    }
  },

  _tick() {
    const elapsed = Math.max(0, Math.floor((Date.now() - this._startTime) / 1000))
    const minutes = Math.floor(elapsed / 60)
    const seconds = elapsed % 60
    const display = `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    const timerEl = this.el.querySelector("[data-timer]")
    if (timerEl) timerEl.textContent = display
  },
}

export default MeetingBar
