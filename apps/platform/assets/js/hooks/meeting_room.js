/**
 * MeetingRoom hook — bridges LiveKit transcription events to the caption overlay.
 *
 * When a LiveKit Room instance is available on the element's dataset or via
 * a global `window.__livekitRoom`, this hook subscribes to
 * `RoomEvent.TranscriptionReceived` and emits `meeting:caption` custom DOM
 * events that the MeetingCaptions hook consumes.
 *
 * The hook is resilient to the livekit-client SDK not being loaded — it
 * will attempt to bind when mounted and log a warning if unavailable.
 */
const MeetingRoom = {
  mounted() {
    this._boundOnTranscription = this._onTranscription.bind(this)
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
    const room = window.__livekitRoom
    if (!room) {
      // Room not connected yet — that's fine, we'll get wired up when
      // the meeting infrastructure sets window.__livekitRoom and
      // dispatches a "livekit:room-connected" event.
      if (!this._waitingForRoom) {
        this._waitingForRoom = true
        window.addEventListener("livekit:room-connected", () => {
          this._waitingForRoom = false
          this._tryBind()
        }, { once: true })
      }
      return
    }

    // Avoid double-binding
    if (this._room === room) return
    this._unbind()
    this._room = room

    try {
      // RoomEvent.TranscriptionReceived is the enum value for transcription
      // events in livekit-client >= 1.x. We use the string form for safety.
      room.on("transcriptionReceived", this._boundOnTranscription)
    } catch (e) {
      console.warn("[MeetingRoom] Failed to subscribe to transcription events:", e)
    }
  },

  _unbind() {
    if (this._room) {
      try {
        this._room.off("transcriptionReceived", this._boundOnTranscription)
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

      // Dispatch on document so MeetingCaptions can listen regardless of
      // DOM nesting.
      document.dispatchEvent(new CustomEvent("meeting:caption", { detail }))
    }
  },
}

export default MeetingRoom
