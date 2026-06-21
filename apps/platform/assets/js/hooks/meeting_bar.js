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

    // Stage 4 (task 019ee06b): route bar-initiated toggles through the
    // canonical server pathway so MeetingHooks (when mounted, e.g. on /chat)
    // sees them and the authoritative post-toggle state fans out via
    // `MeetingState.broadcast_media_state/2`. `pushEvent` (NOT
    // `pushEventTo`) targets the active LiveView, which is ChatLive on
    // /chat and the shell LV's catch-all elsewhere — see ShellLive's
    // `:meeting_toggle_mic` / `:meeting_toggle_camera` clauses for the
    // no-ChatLive fallback. Skipping the direct LiveKit call here means
    // the bar no longer drifts from the in-chat controls.
    this._micHandler = () => {
      this.pushEvent("meeting_toggle_mic", {})
    }

    this._cameraHandler = () => {
      this.pushEvent("meeting_toggle_camera", {})
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
