import { RoomEvent } from "livekit-client"

/**
 * MeetingBar hook — bridges the in-call top bar controls to the LiveKit Room instance.
 *
 * Reads initial mic/camera state from window.__livekitRoom.localParticipant,
 * handles toggle clicks via LiveKit SDK, disconnects on leave, and runs a
 * client-side m:ss (h:mm:ss) duration timer. Gracefully handles null room.
 */
/**
 * Elapsed call time as the top bar shows it (task 01a1e82a stage 1):
 * m:ss, then h:mm:ss past an hour ("12:04", "1:02:09").
 */
export function formatElapsed(totalSeconds) {
  const s = Math.max(0, Math.floor(totalSeconds))
  const hours = Math.floor(s / 3600)
  const minutes = Math.floor((s % 3600) / 60)
  const seconds = String(s % 60).padStart(2, "0")
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}`
    : `${minutes}:${seconds}`
}

// The local publication events that change what "Mic on" / "Cam off" should
// read (task 01a1e82a remediation). `room-connected` fires BEFORE the join
// publishes its tracks, so a read there sees mic and camera off; these are
// the moments the live state actually moves.
export const LOCAL_MEDIA_EVENTS = [
  RoomEvent.LocalTrackPublished,
  RoomEvent.LocalTrackUnpublished,
  RoomEvent.TrackMuted,
  RoomEvent.TrackUnmuted,
]

// The live mic / camera state of the local participant, or null with no room.
export function liveMediaState(room) {
  const lp = room && room.localParticipant
  if (!lp) return null
  return { mic: lp.isMicrophoneEnabled === true, camera: lp.isCameraEnabled === true }
}

// Call `onChange(room)` whenever the local participant's mic / camera state
// can have changed: on every room the page connects (window
// `livekit:room-connected`) and on each local publish / unpublish / mute /
// unmute in it. Remote mutes are ignored. Returns a stop function that takes
// every listener back off the room and the window.
export function watchLocalMedia(win, onChange) {
  let bound = null
  let handlers = []
  const currentRoom = () => win.__livekit_room || win.__livekitRoom || null

  const release = () => {
    if (bound && typeof bound.off === "function") {
      for (const [event, fn] of handlers) {
        try {
          bound.off(event, fn)
        } catch (_) {
          /* already gone */
        }
      }
    }
    bound = null
    handlers = []
  }

  const bind = (room) => {
    if (!room || bound === room || typeof room.on !== "function") return
    release()
    bound = room
    for (const event of LOCAL_MEDIA_EVENTS) {
      const fn = (_pub, participant) => {
        const lp = room.localParticipant
        // TrackMuted / TrackUnmuted fire for remote participants too.
        if (participant && lp && participant !== lp && participant.identity !== lp.identity) return
        onChange(room)
      }
      room.on(event, fn)
      handlers.push([event, fn])
    }
  }

  const onConnected = (e) => {
    const room = (e && e.detail && e.detail.room) || currentRoom()
    bind(room)
    if (room) onChange(room)
  }
  const onDisconnected = () => release()

  win.addEventListener("livekit:room-connected", onConnected)
  win.addEventListener("livekit:room-disconnected", onDisconnected)
  bind(currentRoom())

  return () => {
    release()
    win.removeEventListener("livekit:room-connected", onConnected)
    win.removeEventListener("livekit:room-disconnected", onDisconnected)
  }
}

const MeetingBar = {
  mounted() {
    this._syncState()
    this._startTimer()
    this._bindControls()

    // Re-read mic / camera on every local publish and mute change, not only
    // at mount and room-connected (task 01a1e82a remediation, finding 1).
    this._stopWatch = watchLocalMedia(window, () => this._syncState())

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
    if (this._stopWatch) this._stopWatch()
    this._stopWatch = null
  },

  _syncState() {
    const state = liveMediaState(window.__livekit_room || window.__livekitRoom)
    if (!state) return
    // Never deduplicated against the last push: the server can repaint the
    // bar in between (a `:meeting_media_state` from a dropped publication
    // during a reconnect), and the republish that follows must win.
    this.pushEventTo(this.el, "meeting_bar_state", { ...state, connected: true })
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
    const display = formatElapsed(elapsed)
    const timerEl = this.el.querySelector("[data-timer]")
    if (timerEl) timerEl.textContent = display
  },
}

export default MeetingBar
