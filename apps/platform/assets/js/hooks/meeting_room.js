/**
 * MeetingRoom hook — bridges LiveKit events to the Phoenix LiveView.
 *
 * Subscribes to:
 * 1. `TranscriptionReceived` — emits `meeting:caption` custom DOM events
 *    that the MeetingCaptions hook consumes.
 * 2. `activeSpeakersChanged` — pushes active speaker identities to the
 *    LiveView for speaking indicator rendering.
 *
 * The LiveKit Room object is expected at `window.__livekit_room` (or the
 * legacy `window.__livekitRoom`). The hook gracefully no-ops when no room
 * is available, and binds once a `livekit:room-connected` event fires.
 */
const MeetingRoom = {
  mounted() {
    this._boundOnTranscription = this._onTranscription.bind(this)
    this._boundOnActiveSpeaker = this._onActiveSpeaker.bind(this)
    this._tryBind()
  },

  updated() {
    // Re-bind if the room reference changed
    this._tryBind()
  },

  destroyed() {
    this._unbind()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _tryBind() {
    const room = window.__livekit_room || window.__livekitRoom
    if (!room) {
      if (!this._waitingForRoom) {
        this._waitingForRoom = true
        this._roomListener = (e) => {
          this._waitingForRoom = false
          if (e.detail && e.detail.room) {
            window.__livekit_room = e.detail.room
          }
          this._tryBind()
        }
        document.addEventListener("livekit:room-connected", this._roomListener, { once: true })
      }
      return
    }

    // Avoid double-binding
    if (this._room === room) return
    this._unbind()
    this._room = room

    try {
      room.on("transcriptionReceived", this._boundOnTranscription)
      room.on("activeSpeakersChanged", this._boundOnActiveSpeaker)
    } catch (e) {
      console.warn("[MeetingRoom] Failed to subscribe to room events:", e)
    }
  },

  _unbind() {
    if (this._room) {
      try {
        this._room.off("transcriptionReceived", this._boundOnTranscription)
        this._room.off("activeSpeakersChanged", this._boundOnActiveSpeaker)
      } catch (_) { /* room may already be disconnected */ }
      this._room = null
    }
  },

  /**
   * Handle a TranscriptionReceived event from LiveKit.
   *
   * The event payload contains an array of TranscriptionSegment objects:
   *   { id, text, language, startTime, endTime, final, firstReceivedTime }
   * and a Participant reference.
   */
  _onTranscription(segments, participant) {
    if (!segments || segments.length === 0) return

    const speakerName = participant?.name || participant?.identity || "Unknown"

    for (const seg of segments) {
      const detail = {
        id: seg.id || crypto.randomUUID(),
        speaker: speakerName,
        text: seg.text || "",
        final: seg.final !== false,
        timestamp: seg.startTime || Date.now(),
      }

      document.dispatchEvent(new CustomEvent("meeting:caption", { detail }))
    }
  },

  /**
   * Handle activeSpeakersChanged — push the list of speaking identities
   * to the LiveView for rendering speaking indicators.
   */
  _onActiveSpeaker(speakers) {
    const identities = speakers.map(p => p.identity)
    this.pushEvent("meeting_active_speaker", { identities })
  },
}

export default MeetingRoom
