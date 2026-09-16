import { Track } from "livekit-client"

/**
 * MeetingPushToTalk — the press-to-address-an-agent control, and the
 * waveform that proves it is hearing something (task 01a03f4e stage 5).
 *
 * ## The waveform reads the LOCAL track, because there is nowhere else
 *
 * The user's microphone never reaches Suite. It is published to the
 * LiveKit SFU and that is the end of it — there is no `getUserMedia`,
 * `MediaRecorder` or `AudioContext` anywhere else in this codebase, and
 * no server-side level to subscribe to. So the only honest source for a
 * "we can hear you" indicator is an `AnalyserNode` tapped onto the local
 * publication's own `MediaStreamTrack`, client-side. Audio still never
 * leaves the browser; we are reading a level off a stream that was
 * already flowing.
 *
 * ## The failure this hook is written against
 *
 * A push-to-talk button whose UI lights up while nothing is being
 * captured is worse than no button: the speaker believes they were
 * heard. So the press is REFUSED when there is no live microphone
 * publication, and refusal is a distinct, observable outcome — not a
 * button that looks pressed anyway. `lastRejection()` names the reason,
 * and no press event reaches the server.
 *
 * Everything a test needs to see is therefore a measured value or a
 * pushed event, never the button's own appearance. Asserting that the
 * control "looks active" is precisely the assertion that passes in the
 * failure case this hook exists to prevent.
 *
 * ## Touch (task 01a07410 stage 5)
 *
 * On a phone a finger that drifts a few pixels off the 44px target used
 * to fire `pointerleave`, which cancelled the utterance mid-sentence with
 * no feedback. So `pointerdown` now takes POINTER CAPTURE: while it holds,
 * move/up keep flowing to this element wherever the finger goes, and the
 * `pointerleave` cancel is suppressed. `setPointerCapture` throws when
 * the pointer is no longer active — it ended before we got here and no
 * `pointerup` / `pointercancel` will ever arrive for it (the same case
 * `lib/long_press_drag.js` tears down on). Left uncaught, that would be
 * SILENCE: a button that reads as pressed while nothing is listening. On
 * throw the press is torn down and refused with reason `pointer-lost`,
 * which the template renders through the same `data-rejected` slot as
 * every other refusal.
 */

const SILENCE = 128 // getByteTimeDomainData's zero point
const BAR_COUNT = 12

const MeetingPushToTalk = {
  mounted() {
    this._levels = []
    this._rejection = null
    this._pressed = false
    this._captured = null
    this._bars = this._buildBars()

    this._onPointerDown = (event) => {
      // Left button / touch / pen only — a right-click is a context menu,
      // not a press.
      if (event && typeof event.button === "number" && event.button !== 0) return
      if (event && typeof event.preventDefault === "function") event.preventDefault()
      this.beginPress()
      if (this._pressed) this._capture(event)
    }

    this._onPointerUp = () => {
      this._releaseCapture()
      this.endPress()
    }

    // With capture held, leaving the hit box is not a release — that is
    // the whole point of taking it. Without capture (no pointerId, or an
    // element that cannot capture) the old behaviour stands.
    this._onPointerLeave = () => {
      if (this._captured === null) this._onCancel()
    }

    // Space and Enter, matching a native button. `repeat` is ignored: a
    // held key fires keydown continuously and each one would otherwise
    // re-enter beginPress.
    this._onKeyDown = (event) => {
      if (!event || (event.key !== " " && event.key !== "Enter")) return
      if (event.repeat) return
      if (typeof event.preventDefault === "function") event.preventDefault()
      this.beginPress()
    }

    this._onKeyUp = (event) => {
      if (!event || (event.key !== " " && event.key !== "Enter")) return
      this.endPress()
    }

    // Releasing outside the button, or the tab losing focus mid-press,
    // must still end the press — otherwise the window stays open and the
    // rest of the meeting is attributed to it.
    this._onCancel = () => {
      this._releaseCapture()
      if (this._pressed) this.endPress()
    }

    this._bind()
  },

  destroyed() {
    this._unbind()
    this._teardownAnalyser()
  },

  // ── Public, for tests and for the rest of the page ──────────────────────

  /** Every level sampled during the current or most recent press. */
  levels() {
    return this._levels.slice()
  },

  /** The loudest level sampled, 0 when nothing was heard. */
  peakLevel() {
    return this._levels.reduce((max, level) => (level > max ? level : max), 0)
  },

  /** Why the last press was refused, or null if it was accepted. */
  lastRejection() {
    return this._rejection
  },

  pressed() {
    return this._pressed
  },

  // ── Press lifecycle ────────────────────────────────────────────────────

  beginPress() {
    if (this._pressed) return

    const publication = this._localMicPublication()

    if (!publication) {
      this._reject("no-microphone")
      return
    }

    if (this._micOff(publication)) {
      this._reject("microphone-muted")
      return
    }

    const started = this._startAnalyser(publication)

    if (!started) {
      this._reject("no-audio-context")
      return
    }

    this._rejection = null
    this._pressed = true
    this._levels = []
    this.el.dataset.pressed = "true"
    this.pushEvent("push_to_talk_press", this._pressPayload())
  },

  // Per-agent hold-to-talk: the control sits on a specific agent's row
  // and carries that agent's id in `data-agent-id`, so the server knows
  // WHO the press is addressed to up front rather than working it out
  // from the transcript afterwards. A control with no id (an untargeted
  // press) sends an empty payload and takes the configured default
  // downstream, which is the pre-per-agent behaviour.
  _pressPayload() {
    const agentId = this.el && this.el.dataset ? this.el.dataset.agentId : null
    return typeof agentId === "string" && agentId !== "" ? { agent_id: agentId } : {}
  },

  endPress() {
    if (!this._pressed) return

    this._pressed = false
    this.el.dataset.pressed = "false"
    this._teardownAnalyser()
    this._paintBars(0)
    this.pushEvent("push_to_talk_release", {})
  },

  // ── Pointer capture ────────────────────────────────────────────────────

  /**
   * Hold the pointer so drift off the target does not end the press.
   * Mirrors `lib/long_press_drag.js`: `setPointerCapture` throws when the
   * pointer already ended, and then nothing will ever release us — so the
   * press is torn down here and marked refused rather than left armed and
   * deaf.
   */
  _capture(event) {
    const el = this.el
    if (!event || typeof event.pointerId !== "number") return
    if (!el || typeof el.setPointerCapture !== "function") return

    try {
      el.setPointerCapture(event.pointerId)
      this._captured = event.pointerId
    } catch (_err) {
      // Pointer no longer active — it ended before capture was taken and
      // no pointerup/cancel will ever arrive for it. Abort the phantom
      // press: tear down, clear data-pressed, and say so.
      this._captured = null
      this.endPress()
      this._reject("pointer-lost")
    }
  },

  _releaseCapture() {
    if (this._captured === null) return
    const id = this._captured
    this._captured = null
    const el = this.el
    if (!el || typeof el.releasePointerCapture !== "function") return
    try {
      el.releasePointerCapture(id)
    } catch (_err) {
      // No capture held — nothing to release.
    }
  },

  // ── Rejection ──────────────────────────────────────────────────────────

  // A refused press changes NO server state, samples nothing, and paints
  // a flat waveform. The reason is recorded and announced so the page can
  // explain itself; the one thing it must never do is look like a press
  // that worked.
  _reject(reason) {
    this._rejection = reason
    this._pressed = false
    this._levels = []
    this.el.dataset.pressed = "false"
    this.el.dataset.rejected = reason
    this._paintBars(0)

    if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") {
      window.dispatchEvent(
        new CustomEvent("meeting:push-to-talk-rejected", { detail: { reason } })
      )
    }
  },

  // ── Microphone lookup ──────────────────────────────────────────────────

  // The local AUDIO publication, or null. Mirrors
  // `MeetingClient._localCameraPublication`: LiveKit exposes local
  // publications on `localParticipant.trackPublications`, with `tracks`
  // as the older name.
  _localMicPublication() {
    const room = window.__livekitRoom
    const lp = room && room.localParticipant
    const pubs = lp && (lp.trackPublications || lp.tracks)
    if (!pubs || typeof pubs.values !== "function") return null

    for (const pub of pubs.values()) {
      if (!pub) continue
      const kind = pub.kind
      if (kind !== Track.Kind.Audio && kind !== "audio") continue
      const source = (pub.track && pub.track.source) || pub.source
      // Screen-share audio is not the speaker's microphone.
      if (source === Track.Source.ScreenShareAudio || source === "screen_share_audio") continue
      return pub
    }

    return null
  },

  // POSITIVE evidence that the mic is not capturing. Unknown shapes read
  // as "on" nowhere — this gate refuses the press, so the safe default
  // when we cannot tell is to treat a missing MediaStreamTrack as off
  // rather than promise the user they were heard.
  _micOff(pub) {
    if (pub.isMuted === true) return true
    if (pub.track && pub.track.isMuted === true) return true
    const mst = pub.track && pub.track.mediaStreamTrack
    if (!mst) return true
    if (mst.readyState === "ended") return true
    if (mst.enabled === false) return true
    return false
  },

  // ── Analyser ───────────────────────────────────────────────────────────

  _startAnalyser(pub) {
    const Ctor =
      (typeof window !== "undefined" && (window.AudioContext || window.webkitAudioContext)) || null

    if (!Ctor) return false

    const mst = pub.track && pub.track.mediaStreamTrack
    if (!mst) return false

    try {
      this._audioContext = new Ctor()
      const stream = new MediaStream([mst])
      this._source = this._audioContext.createMediaStreamSource(stream)
      this._analyser = this._audioContext.createAnalyser()
      this._analyser.fftSize = 256
      this._source.connect(this._analyser)
      this._buffer = new Uint8Array(this._analyser.fftSize)
      this._scheduleSample()
      return true
    } catch (_err) {
      this._teardownAnalyser()
      return false
    }
  },

  _scheduleSample() {
    const raf =
      (typeof window !== "undefined" && window.requestAnimationFrame) ||
      ((fn) => setTimeout(fn, 16))

    this._frame = raf(() => this.sample())
  },

  /**
   * Read one frame and paint it. Public so a test can step the loop
   * deterministically instead of racing requestAnimationFrame.
   */
  sample() {
    if (!this._analyser || !this._pressed) return

    this._analyser.getByteTimeDomainData(this._buffer)

    // RMS deviation from the silence midpoint, normalised to 0..1.
    // Silence is a buffer of 128s, which gives exactly 0 — so a flat
    // track cannot produce a non-zero level by rounding.
    let sum = 0
    for (let i = 0; i < this._buffer.length; i++) {
      const deviation = (this._buffer[i] - SILENCE) / SILENCE
      sum += deviation * deviation
    }

    const level = Math.sqrt(sum / this._buffer.length)

    this._levels.push(level)
    this._paintBars(level)
    this._scheduleSample()
  },

  _teardownAnalyser() {
    const cancel =
      (typeof window !== "undefined" && window.cancelAnimationFrame) || clearTimeout

    if (this._frame) {
      cancel(this._frame)
      this._frame = null
    }

    if (this._source && typeof this._source.disconnect === "function") {
      this._source.disconnect()
    }

    if (this._audioContext && typeof this._audioContext.close === "function") {
      this._audioContext.close()
    }

    this._source = null
    this._analyser = null
    this._audioContext = null
    this._buffer = null
  },

  // ── Waveform painting ──────────────────────────────────────────────────

  _buildBars() {
    if (!this.el || typeof this.el.querySelectorAll !== "function") return []
    return Array.from(this.el.querySelectorAll("[data-ptt-bar]"))
  },

  // Bars are scaled, never recoloured: colour is carried by the semantic
  // token classes in the template, and a hook that wrote colours would
  // put a second palette in JS where the theme cannot reach it.
  _paintBars(level) {
    if (!this._bars || this._bars.length === 0) return

    const count = this._bars.length

    for (let i = 0; i < count; i++) {
      // A little shape either side of centre so the meter reads as a
      // waveform rather than a single block.
      const distance = Math.abs(i - (count - 1) / 2) / ((count - 1) / 2 || 1)
      const weight = 1 - distance * 0.55
      const scaled = Math.max(0.08, Math.min(1, level * weight * 2.2))
      this._bars[i].style.transform = `scaleY(${scaled.toFixed(3)})`
    }
  },

  // ── Binding ────────────────────────────────────────────────────────────

  _bind() {
    const el = this.el
    el.addEventListener("pointerdown", this._onPointerDown)
    el.addEventListener("pointerup", this._onPointerUp)
    el.addEventListener("pointercancel", this._onCancel)
    el.addEventListener("pointerleave", this._onPointerLeave)
    el.addEventListener("keydown", this._onKeyDown)
    el.addEventListener("keyup", this._onKeyUp)
    if (typeof window !== "undefined" && window.addEventListener) {
      window.addEventListener("blur", this._onCancel)
    }
  },

  _unbind() {
    const el = this.el
    if (!el || typeof el.removeEventListener !== "function") return
    el.removeEventListener("pointerdown", this._onPointerDown)
    el.removeEventListener("pointerup", this._onPointerUp)
    el.removeEventListener("pointercancel", this._onCancel)
    el.removeEventListener("pointerleave", this._onPointerLeave)
    el.removeEventListener("keydown", this._onKeyDown)
    el.removeEventListener("keyup", this._onKeyUp)
    if (typeof window !== "undefined" && window.removeEventListener) {
      window.removeEventListener("blur", this._onCancel)
    }
  },
}

export { BAR_COUNT }
export default MeetingPushToTalk
