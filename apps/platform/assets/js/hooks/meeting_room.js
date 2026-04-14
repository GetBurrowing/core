/**
 * MeetingRoom hook — root-level LiveKit Room persistence.
 *
 * This hook is attached to the shell layout (outside per-page LiveViews)
 * so the LiveKit Room instance, audio elements, and connection state
 * survive LiveView navigation.
 *
 * ## Architecture
 *
 * The hook maintains a singleton `window.__meetingRoom` object that holds:
 * - The LiveKit Room instance
 * - Audio/video element references (attached to root DOM)
 * - Connection state and media toggle state
 *
 * Communication with MeetingBarLive happens via:
 * - `push_event` from server → JS (join, leave, toggle commands)
 * - `pushEvent` from JS → server (state sync, participant updates)
 *
 * ## Events
 *
 * Server → Client (handleEvent):
 *   - `meeting:join`          — connect to LiveKit room with token
 *   - `meeting:leave`         — disconnect and clean up
 *   - `meeting:toggle-mic`    — toggle local microphone
 *   - `meeting:toggle-camera` — toggle local camera
 *
 * Client → Server (pushEvent):
 *   - `meeting:state-sync`    — periodic state sync (participant count, media state)
 *   - `meeting:connected`     — room connected successfully
 *   - `meeting:disconnected`  — room disconnected
 *   - `meeting:error`         — connection error
 */

const MeetingRoom = {
  mounted() {
    this._userId = this.el.dataset.userId

    // Initialize the singleton meeting state if not present
    if (!window.__meetingRoom) {
      window.__meetingRoom = {
        room: null,
        connected: false,
        audioContainer: null,
        micEnabled: true,
        cameraEnabled: false,
        participantCount: 0,
        roomName: null,
      }
    }

    // Create a persistent audio container in the root DOM
    this._ensureAudioContainer()

    // Register event handlers from server
    this.handleEvent("meeting:join", (payload) => this._handleJoin(payload))
    this.handleEvent("meeting:leave", () => this._handleLeave())
    this.handleEvent("meeting:toggle-mic", (payload) => this._handleToggleMic(payload))
    this.handleEvent("meeting:toggle-camera", (payload) => this._handleToggleCamera(payload))

    // If we already have an active room (e.g., after navigation), sync state
    if (window.__meetingRoom.connected) {
      this._syncStateToServer()
    }

    // Start the duration timer
    this._startDurationTimer()
  },

  /**
   * Ensure a persistent audio container exists in the root DOM.
   * Audio elements are attached here (outside LiveView containers)
   * so they survive navigation.
   */
  _ensureAudioContainer() {
    let container = document.getElementById("meeting-audio-container")
    if (!container) {
      container = document.createElement("div")
      container.id = "meeting-audio-container"
      container.style.display = "none"
      container.setAttribute("aria-hidden", "true")
      document.body.appendChild(container)
    }
    window.__meetingRoom.audioContainer = container
  },

  /**
   * Handle join event — connect to a LiveKit room.
   * In the current implementation, this sets up the meeting state.
   * Full LiveKit integration will be wired when livekit-client is added.
   */
  async _handleJoin(payload) {
    const { token, url, room_name, space_name, space_slug } = payload
    const state = window.__meetingRoom

    // If already connected to a different room, disconnect first
    if (state.connected && state.roomName !== room_name) {
      await this._handleLeave()
    }

    try {
      // Store meeting metadata
      state.roomName = room_name
      state.spaceName = space_name
      state.spaceSlug = space_slug
      state.connected = true
      state.micEnabled = true
      state.cameraEnabled = false
      state.participantCount = 1

      // If livekit-client is available, create and connect the Room
      if (typeof window.LivekitClient !== "undefined") {
        const { Room, RoomEvent } = window.LivekitClient

        state.room = new Room()

        state.room.on(RoomEvent.ParticipantConnected, () => {
          state.participantCount = state.room.numParticipants + 1
          this._syncStateToServer()
        })

        state.room.on(RoomEvent.ParticipantDisconnected, () => {
          state.participantCount = Math.max(1, state.room.numParticipants)
          this._syncStateToServer()
        })

        state.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
          if (track.kind === "audio") {
            const audioEl = track.attach()
            audioEl.dataset.participantId = participant.identity
            state.audioContainer.appendChild(audioEl)
          }
        })

        state.room.on(RoomEvent.TrackUnsubscribed, (track) => {
          track.detach().forEach((el) => el.remove())
        })

        state.room.on(RoomEvent.Disconnected, () => {
          state.connected = false
          this.pushEvent("meeting:disconnected", {})
        })

        await state.room.connect(url, token)
        state.participantCount = state.room.numParticipants + 1
      }

      // Notify server of successful connection
      this.pushEvent("meeting:connected", {
        room_name,
        space_name,
        space_slug,
        participant_count: state.participantCount,
      })
    } catch (error) {
      console.error("[MeetingRoom] Failed to join:", error)
      state.connected = false
      this.pushEvent("meeting:error", { message: error.message })
    }
  },

  /**
   * Handle leave event — disconnect from the LiveKit room and clean up.
   */
  async _handleLeave() {
    const state = window.__meetingRoom

    if (state.room) {
      try {
        await state.room.disconnect()
      } catch (e) {
        console.warn("[MeetingRoom] Error during disconnect:", e)
      }
      state.room = null
    }

    // Clean up audio elements
    if (state.audioContainer) {
      state.audioContainer.innerHTML = ""
    }

    state.connected = false
    state.roomName = null
    state.spaceName = null
    state.spaceSlug = null
    state.participantCount = 0
    state.micEnabled = true
    state.cameraEnabled = false

    this.pushEvent("meeting:disconnected", {})
  },

  /**
   * Handle mic toggle from server.
   */
  async _handleToggleMic({ enabled }) {
    const state = window.__meetingRoom
    state.micEnabled = enabled

    if (state.room && state.room.localParticipant) {
      try {
        await state.room.localParticipant.setMicrophoneEnabled(enabled)
      } catch (e) {
        console.warn("[MeetingRoom] Failed to toggle mic:", e)
      }
    }
  },

  /**
   * Handle camera toggle from server.
   */
  async _handleToggleCamera({ enabled }) {
    const state = window.__meetingRoom
    state.cameraEnabled = enabled

    if (state.room && state.room.localParticipant) {
      try {
        await state.room.localParticipant.setCameraEnabled(enabled)
      } catch (e) {
        console.warn("[MeetingRoom] Failed to toggle camera:", e)
      }
    }
  },

  /**
   * Sync current meeting state to the server.
   */
  _syncStateToServer() {
    const state = window.__meetingRoom
    if (!state.connected) return

    this.pushEvent("meeting:state-sync", {
      room_name: state.roomName,
      space_name: state.spaceName,
      space_slug: state.spaceSlug,
      participant_count: state.participantCount,
      mic_enabled: state.micEnabled,
      camera_enabled: state.cameraEnabled,
    })
  },

  /**
   * Start a timer that updates the duration display.
   * Uses a simple interval since the actual start time is tracked server-side.
   */
  _startDurationTimer() {
    // Clean up any existing timer
    if (this._durationInterval) {
      clearInterval(this._durationInterval)
    }

    this._durationInterval = setInterval(() => {
      const el = document.getElementById("meeting-duration")
      if (!el) return

      const startedAt = el.dataset.startedAt
      if (!startedAt) return

      const start = new Date(startedAt)
      const now = new Date()
      const diffSec = Math.floor((now - start) / 1000)

      if (diffSec < 0) return

      const hours = Math.floor(diffSec / 3600)
      const minutes = Math.floor((diffSec % 3600) / 60)
      const seconds = diffSec % 60

      if (hours > 0) {
        el.textContent = `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
      } else {
        el.textContent = `${minutes}:${String(seconds).padStart(2, "0")}`
      }
    }, 1000)
  },

  /**
   * The hook is never destroyed during normal navigation (it's in the shell),
   * but clean up if it is.
   */
  destroyed() {
    if (this._durationInterval) {
      clearInterval(this._durationInterval)
    }
  },
}

export default MeetingRoom
