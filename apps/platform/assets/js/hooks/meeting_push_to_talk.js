import { Track } from "livekit-client"
import { paintBars } from "./lib/ptt_waveform"
import { getHold, beginHold, patchHold, clearHold, appendHoldText } from "./lib/ptt_hold_state"

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
// Round 5 (Dalton's PR #1178 re-check, item 6): both reference canvases
// draw exactly FOUR bars. `_buildBars()` below reads whatever `[data-ptt-
// bar]` elements the template actually rendered — `participant_rail.ex`
// is the one place this count is really enforced — so this constant is
// descriptive (tests and callers can read the agreed count off it), not
// the thing that drives rendering.
const BAR_COUNT = 4

// Task 01a0cf5c stage 2, design canvas 01a0cf5e-9cb0: a release before
// this many milliseconds have elapsed is coached ("Hold it down and
// talk...") near the button, not treated as a real ask — and the veil
// never opens for it at all. `MeetingAskFloorVeil` (`meeting_ask_floor_
// veil.js`) waits for the `meeting:push-to-talk-held` event below before
// showing anything, so a hold that never reaches this threshold never
// produces that event and the veil path simply never runs.
const HOLD_THRESHOLD_MS = 380

// Task 01a0f324 stage 3 (item 4) — the copy shown in the full-width
// feedback line under the row, keyed by the SAME `reason` string
// `_reject`/`_serverReject` already stamp onto `data-rejected`. Every
// client-side rejection this hook can raise (`no-microphone`,
// `microphone-muted`, `no-audio-context`, `pointer-lost`) reduces to one
// honest sentence: none of them prove the agent heard anything, and a
// presser cannot tell the four apart from the outside, so there is no
// reason to make them read four different ways. `held-by-other` (the
// one SERVER-side reason, `MeetingPushToTalk._serverReject`) already has
// its own "Held by <name>" chip on the row (`ParticipantRail`), so it is
// deliberately left OUT of this map — it stays a colour-only cue on the
// button, not a second copy of the same fact in the feedback line.
const REJECTION_FEEDBACK = {
  "no-microphone": {
    tone: "error",
    text: "Couldn't hear you. Check that your microphone is on, then hold Ask.",
  },
  "microphone-muted": {
    tone: "error",
    text: "Couldn't hear you. Check that your microphone is on, then hold Ask.",
  },
  "no-audio-context": {
    tone: "error",
    text: "Couldn't hear you. Check that your microphone is on, then hold Ask.",
  },
  "pointer-lost": {
    tone: "error",
    text: "Couldn't hear you. Check that your microphone is on, then hold Ask.",
  },
}

// The early-release nudge (task 01a0cf5c stage 2) is not a rejection —
// nothing was refused, the press just never crossed `HOLD_THRESHOLD_MS`
// — so it is not in `REJECTION_FEEDBACK` above and is shown directly
// where `endPress()` decides that happened.
const EARLY_RELEASE_FEEDBACK = {
  tone: "neutral",
  text: "Hold it down and talk. Let go when you are done.",
}

// Shown on `disconnected()` (a real Phoenix LiveView hook lifecycle
// callback, same one `meeting_client.js` and `viewport_breakpoint.js`
// already rely on for `reconnected()` — see their moduledocs). This is
// the one member of the feedback vocabulary that is not about THIS
// button's own press/reject cycle: the whole page's live connection
// dropped, which for a voice agent whose every word crosses this socket
// reads exactly like the agent itself going quiet.
const OFFLINE_FEEDBACK = {
  tone: "warning",
  text: "Burrow went offline. It will rejoin when it reconnects.",
}

// How long a self-clearing feedback message (a rejection, the
// early-release nudge) stays up before fading — longer than the old
// coach tooltip's 2600ms because the copy it now has to carry
// ("Couldn't hear you. Check that your microphone is on, then hold
// Ask.") is longer than "Hold it down and talk. Let go when you are
// done." was. `disconnected()`'s offline notice does not use this at
// all — see `_showFeedback`'s `autoHide` option.
const FEEDBACK_AUTO_HIDE_MS = 4000

// Ask-row verbatim port: the mockup's `.tr.sent` runs `sent 2.2s`
// (`@keyframes sent{0%,80%{opacity:1}100%{opacity:0}}`), so `data-sent`
// comes off the row once that animation has finished.
const SENT_MS = 2_200
// The mockup's `.vp{max-height:140px}` and its 20px single-line floor.
const VP_CAP_PX = 140
const LINE_PX = 20

const MeetingPushToTalk = {
  mounted() {
    this._levels = []
    this._rejection = null
    this._pressed = false
    this._heldLongEnough = false
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
    this._resumeHoldIfOurs()

    // A server-side refusal (task 01a0cf5c stage 1): another presser
    // already holds THIS agent's floor. Everything up to this point in
    // `beginPress` is client-only evidence (a live mic), so the press
    // already looked accepted — waveform running, `data-pressed="true"`
    // — by the time the server answers. `push_to_talk_press` is pushed
    // to EVERY hook instance on the page (one per agent row), so the
    // `agent_id` in the payload is what narrows this to the one button
    // actually being refused; every other instance's press (if any) is
    // untouched.
    this.handleEvent("push_to_talk_rejected", (payload) => {
      const agentId = this.el && this.el.dataset ? this.el.dataset.agentId : null
      if (!payload || payload.agent_id !== agentId) return
      this._serverReject(payload.reason)
    })

    // Live transcript for THIS agent's press, into the row's `.tx p`.
    // Final segments only (the server filters). The text buffer lives on
    // `window` (`ptt_hold_state`) so a remount mid-hold restores it.
    this.handleEvent("meeting_ask_transcript_chunk", (payload) => {
      if (!payload || payload.agent_id !== this._agentId()) return
      if (typeof payload.text !== "string" || payload.text === "") return
      if (this._pressed) {
        appendHoldText(payload.text)
        const hold = getHold()
        this._setLiveText(hold && hold.text ? hold.text : payload.text)
      } else if (this._sentShowing) {
        // A late final segment inside the server's release grace window.
        this._sentText = this._sentText ? `${this._sentText} ${payload.text}` : payload.text
        this._setSentText(this._sentText)
      }
    })
  },

  destroyed() {
    if (this._sentTimer) clearTimeout(this._sentTimer)
    this._unbind()
    this._teardownAnalyser()
    this._clearHoldThresholdTimer()
    this._clearFeedbackTimer()
  },

  // Task 01a0f324 stage 3 (item 4) — a real Phoenix LiveView hook
  // lifecycle callback (`meeting_client.js` and `viewport_breakpoint.js`
  // already use its `reconnected()` half), not a new detection mechanism:
  // LiveView calls this on the hook when the socket drops, with the DOM
  // left in place, and `reconnected()` when it comes back. Deliberately
  // does not touch `_pressed`/`_rejection` or push any event — the
  // hold-detection state machine is out of this stage's scope; this only
  // says so in the feedback line.
  disconnected() {
    this._showFeedback(OFFLINE_FEEDBACK.tone, OFFLINE_FEEDBACK.text, { autoHide: false })
  },

  reconnected() {
    this._hideFeedback()
  },

  // Round 4 (task 01a0fa7e-afd7 stage 5) — THE actual cause of "the key
  // flashes once then goes dead for the rest of the hold," confirmed by
  // reading LiveView's own `dom.js`/`view.js` (`mergeAttrs`,
  // `triggerBeforeUpdateHook`), not assumed: `phx-update="ignore"` on this
  // `<button>` protects its CHILDREN from being patched, but NOT its own
  // `data-*` attributes — `DOM.mergeAttrs(fromEl, toEl, {isIgnored: true})`
  // still calls `target.setAttribute(name, sourceValue)` for every `data-`
  // attribute the server's fresh render carries, which is `data-pressed=
  // "false"`/`data-held="false"` on EVERY render (`participant_rail.ex`'s
  // literal markup) — those are the two things this hook ever writes to
  // the DOM, and the server's copy is always stale by the time it lands.
  //
  // `handle_event("push_to_talk_press", ...)` (`meeting_live.ex`) sets
  // `:pressed_agent_id` and re-renders this agent's row almost immediately
  // — ~15-35ms in practice, exactly the one "pressed" sample the task
  // 01a0fa7e-afd7 review captured before the attribute reverted and never
  // recovered, because nothing was watching for the server to stomp it a
  // second time. Confirms the dispatch's own morphdom/LiveView-
  // reconciliation hypothesis; `phx-update="ignore"`'s actual contract
  // (children only, never this element's own attributes) is simply
  // narrower than the comment at `participant_rail.ex`'s `ask_floor_holders`
  // doc assumed.
  //
  // The fix leans on the OTHER half of the same mechanism rather than
  // fighting it: LiveView detects that `fromEl.dataset` no longer equals
  // `toEl.dataset` on an ignored node (`view.js#triggerBeforeUpdateHook`)
  // and fires this hook's `updated()` specifically BECAUSE of that
  // mismatch — so `updated()` runs every time, and ONLY when, the server
  // has just overwritten one of these two attributes out from under a live
  // press. Re-asserting them here from `this._pressed`/`this._heldLongEnough`
  // — this hook's own JS state, never the DOM it writes to — closes the
  // window back down to a single patch's duration instead of the rest of
  // the hold. `_setRowPressed` mirrors the same correction onto the row
  // (`<li>`), which has no `phx-update="ignore"` at all and is restomped by
  // the ordinary (non-ignored) merge path on the same patch.
  updated() {
    this.el.dataset.pressed = this._pressed ? "true" : "false"
    this.el.dataset.held = this._pressed ? "true" : "false"
    this._setRowPressed(this._pressed)
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

  // ── Resuming a hold that started on a DIFFERENT DOM node ────────────────

  /**
   * Called once, from `mounted()`. If `window`'s one hold-state record
   * (`./lib/ptt_hold_state`) says THIS agent is currently being held, a
   * press that started before this element existed is still in progress
   * — the previous node was destroyed by a server re-render mid-hold, not
   * released by the finger. Resume locally rather than wait for a
   * `pointerup` that may now never reach any element that remembers it
   * was pressed.
   */
  _resumeHoldIfOurs() {
    const hold = getHold()
    if (!hold || !hold.agentId || hold.agentId !== this._agentId()) return

    const publication = this._localMicPublication()
    if (!publication || this._micOff(publication)) {
      clearHold()
      return
    }

    if (!this._startAnalyser(publication)) {
      clearHold()
      return
    }

    this._rejection = null
    this._pressed = true
    this._levels = []
    this._heldLongEnough = Boolean(hold.heldLongEnough)
    this.el.dataset.pressed = "true"
    this.el.dataset.held = "true"
    this._setRowPressed(true)
    this._setLiveText(hold.text || "")

    // Reacquire real OS-level pointer capture on THIS node for a pointer
    // that is still active but was captured by a node that no longer
    // exists — the spec does not require the capturing element to be the
    // one `pointerdown` originally landed on, only that the pointerId is
    // still live.
    if (typeof hold.pointerId === "number" && typeof this.el.setPointerCapture === "function") {
      try {
        this.el.setPointerCapture(hold.pointerId)
        this._captured = hold.pointerId
      } catch (_err) {
        // Pointer already ended while this node was gone. Nothing to
        // reject here — this is a resume, not a fresh press; the next
        // real pointer event (or the window `blur` cancel) resolves it.
      }
    }

    // `resume: true` on every event dispatched from HERE (never from a
    // genuine fresh press — `beginPress`/`_scheduleHoldThreshold` below
    // never set it) is what tells a sibling singleton hook (the overlay,
    // the veil) that this is the SAME hold continuing, not a new one — see
    // `MeetingAskHeardOverlay._onHeld`'s own guard for why that distinction
    // matters: a sibling that already restored its own state from
    // `getHold()` must not have this redispatch stomp it back to blank.
    this._dispatch("meeting:push-to-talk-armed", {
      agentId: this._agentId(),
      agentName: this._agentName(),
      resume: true,
    })

    if (this._heldLongEnough) {
      // Past the threshold before the remount — the timer that would
      // have announced this belonged to the node that is gone, so
      // announce it now instead of waiting for a timer that will never
      // fire.
      this._dispatch("meeting:push-to-talk-held", {
        agentId: this._agentId(),
        agentName: this._agentName(),
        resume: true,
      })
    } else {
      const elapsed = Date.now() - (hold.pressedAt || Date.now())
      this._clearHoldThresholdTimer()
      this._holdThresholdTimer = setTimeout(
        () => {
          this._holdThresholdTimer = null
          if (!this._pressed) return
          this._heldLongEnough = true
          patchHold({ heldLongEnough: true })
          this._dispatch("meeting:push-to-talk-held", {
            agentId: this._agentId(),
            agentName: this._agentName(),
            resume: true,
          })
        },
        Math.max(0, HOLD_THRESHOLD_MS - elapsed)
      )
    }
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
    this._heldLongEnough = false
    beginHold({
      agentId: this._agentId(),
      agentName: this._agentName(),
      heldLongEnough: false,
    })
    this.el.dataset.pressed = "true"
    // Verbatim port: `data-held` is the mockup's `:active`, so it flips
    // at press. The 380ms send threshold (`_heldLongEnough`) is unchanged
    // and is still what decides whether a release counts as a send.
    this.el.dataset.held = "true"
    this._setRowPressed(true)
    this._clearSent()
    this._setLiveText("")
    // A fresh press supersedes whatever the LAST one left showing (an
    // old rejection, the early-release nudge) — it is either about to
    // succeed or fail on its own terms, not carry forward stale copy.
    this._hideFeedback()
    this.pushEvent("push_to_talk_press", this._pressPayload())
    // Progressive enhancement only — never required for correctness.
    // Where the browser supports it, a 10ms vibration gives a phone the
    // tactile half of the press the moment it registers.
    this._vibrate()

    // Task 01a0cf5c stage 2: announce the press immediately so
    // `MeetingAskFloorVeil` knows WHO is being addressed, before it
    // knows whether this will turn into a real hold or an early
    // release — see `HOLD_THRESHOLD_MS` above.
    this._dispatch("meeting:push-to-talk-armed", {
      agentId: this._agentId(),
      agentName: this._agentName(),
    })
    this._scheduleHoldThreshold()
  },

  _scheduleHoldThreshold() {
    this._clearHoldThresholdTimer()
    this._holdThresholdTimer = setTimeout(() => {
      this._holdThresholdTimer = null
      if (!this._pressed) return
      this._heldLongEnough = true
      patchHold({ heldLongEnough: true })
      this._vibrate()
      this._dispatch("meeting:push-to-talk-held", {
        agentId: this._agentId(),
        agentName: this._agentName(),
      })
    }, HOLD_THRESHOLD_MS)
  },

  // Progressive enhancement (item 1, task 01a0f842 stage 1, canvas
  // 01a0f846-cfb1): a 10ms vibration at press and at the 380ms
  // threshold, where the browser supports `navigator.vibrate` at all —
  // never required for correctness, and silently a no-op everywhere
  // else (most desktop browsers, Safari on iOS).
  _vibrate() {
    if (typeof navigator === "undefined" || typeof navigator.vibrate !== "function") return
    try {
      navigator.vibrate(10)
    } catch (_err) {
      // Best-effort only.
    }
  },

  _clearHoldThresholdTimer() {
    if (this._holdThresholdTimer) {
      clearTimeout(this._holdThresholdTimer)
      this._holdThresholdTimer = null
    }
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

    // Read BEFORE clearing — `_clearHoldThresholdTimer` below cancels
    // the pending `:held` timeout, but does not tell us whether it had
    // already fired.
    const heldLongEnough = this._heldLongEnough
    const hold = getHold()
    const heardText = hold && typeof hold.text === "string" ? hold.text : ""

    this._clearHoldThresholdTimer()
    this._pressed = false
    this._heldLongEnough = false
    clearHold()
    this.el.dataset.pressed = "false"
    this.el.dataset.held = "false"
    this._setRowPressed(false)
    this._resetLiveSize()
    this._teardownAnalyser()
    this._paintBars(0)
    this.pushEvent("push_to_talk_release", {})

    // Task 01a0cf5c stage 2: an early release (never crossed
    // `HOLD_THRESHOLD_MS`, so `meeting:push-to-talk-held` never fired
    // and the veil never opened) gets the feedback line's nudge, near
    // THIS row, instead of `MeetingAskFloorVeil`'s centred card closing —
    // there is nothing for it to close.
    if (heldLongEnough) {
      this._showSent(heardText)
      this._dispatch("meeting:push-to-talk-ended", { agentId: this._agentId() })
    } else {
      this._showFeedback(EARLY_RELEASE_FEEDBACK.tone, EARLY_RELEASE_FEEDBACK.text)
      this._dispatch("meeting:push-to-talk-early-release", {
        agentId: this._agentId(),
        agentName: this._agentName(),
      })
    }
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
      patchHold({ pointerId: event.pointerId })
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
    // A rejection can land before the hold-threshold timer would have
    // fired (a server refusal is typically near-instant) or, in
    // principle, after — either way there is now no press for it to
    // resolve, so the timer must not fire later against stale state.
    this._clearHoldThresholdTimer()
    this._heldLongEnough = false
    this._rejection = reason
    this._pressed = false
    this._levels = []
    clearHold()
    this.el.dataset.pressed = "false"
    this.el.dataset.held = "false"
    this._setRowPressed(false)
    this._resetLiveSize()
    this.el.dataset.rejected = reason
    this._paintBars(0)
    // Item 4 (task 01a0f324 stage 3): `held-by-other` is deliberately
    // absent from `REJECTION_FEEDBACK` (see its moduledoc) — its own
    // "Held by <name>" chip already carries the fact, so `_showFeedback`
    // is simply never called for it and the line stays hidden.
    const feedback = REJECTION_FEEDBACK[reason]
    if (feedback) this._showFeedback(feedback.tone, feedback.text)
    this._dispatch("meeting:push-to-talk-rejected", { reason })
  },

  // The SERVER's refusal (task 01a0cf5c stage 1, `held-by-other`):
  // unlike `_reject`, this fires AFTER `beginPress` already succeeded
  // locally — the mic was live, the analyser started, the waveform is
  // moving — so it has to unwind that state too, not just skip starting
  // it. Renders through the exact same `data-rejected` slot `_reject`
  // does, so the template needs no second case to handle a refusal that
  // arrived a moment later than the others.
  _serverReject(reason) {
    this._teardownAnalyser()
    this._paintBars(0)
    this._reject(reason)
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
    // Task 01a0cf5c stage 2: the SAME measured level, broadcast so
    // `MeetingAskFloorVeil` can paint the centred card's meter off it
    // without opening a second `AnalyserNode` on the same track.
    this._dispatch("meeting:push-to-talk-level", { agentId: this._agentId(), level })
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
  //
  // The actual math lives in `./lib/ptt_waveform` (task 01a0cf5c stage
  // 2) so `MeetingAskFloorVeil`'s card meter can reuse the IDENTICAL
  // formula off the `meeting:push-to-talk-level` event above, rather
  // than a second implementation that could silently drift from this
  // one.
  _paintBars(level) {
    paintBars(this._bars, level)
  },

  // ── Reporting who/what, for the veil and the feedback line ───────────────

  _agentId() {
    return this.el && this.el.dataset ? this.el.dataset.agentId || null : null
  },

  _agentName() {
    return this.el && this.el.dataset ? this.el.dataset.agentName || "" : ""
  },

  _dispatch(name, detail) {
    if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") {
      window.dispatchEvent(new CustomEvent(name, { detail }))
    }
  },

  // ── The row (task 01a0f324 stage 3, item 3b) ──────────────────────────────
  //
  // The closest `[data-participant-type="agent"]` — the `<li>`
  // `ParticipantRail` renders one of per agent. A CSS selector can only
  // read an ATTRIBUTE ON ITSELF OR AN ANCESTOR's own value via
  // `data-[pressed=true]:…`; it cannot climb from a descendant's
  // attribute up to a style rule on the ancestor. So the row needing to
  // clear the hold veil's `z-50` while THIS button is held means the row
  // needs its OWN `data-pressed`, mirrored here whenever the button's is
  // set — the two are kept in lock-step, never a single source re-read
  // twice.
  _rowEl() {
    if (this._rowNode !== undefined) return this._rowNode

    this._rowNode =
      this.el && typeof this.el.closest === "function"
        ? this.el.closest('[data-participant-type="agent"]')
        : null

    return this._rowNode
  },

  // The row's `data-pressed` and `data-held` (the mockup's
  // `.row:has(.ask:active)`), set at press. The row is NOT
  // `phx-update="ignore"`, so a plain write would be stripped by the next
  // LiveView patch of the row; `this.js().setAttribute` is sticky and is
  // re-applied after every patch. The direct write keeps the change in the
  // same frame (and is all a unit-test harness has).
  _setRowAttr(name, value) {
    const row = this._rowEl()
    if (!row) return
    const js = typeof this.js === "function" ? this.js() : null
    if (js && typeof js.setAttribute === "function") {
      try {
        js.setAttribute(row, name, value)
      } catch (_err) {
        // fall through to the direct write
      }
    }
    const key = name.replace(/^data-/, "").replace(/-([a-z])/g, (_m, c) => c.toUpperCase())
    if (row.dataset) row.dataset[key] = value
    else if (typeof row.setAttribute === "function") row.setAttribute(name, value)
  },

  _setRowPressed(pressed) {
    const value = pressed ? "true" : "false"
    this._setRowAttr("data-pressed", value)
    this._setRowAttr("data-held", value)
  },

  // ── Live transcript and the sent confirmation (verbatim port) ──────────
  //
  // `.tr.live .vp > .tx > p` and `.tr.sent .sum` are `phx-update="ignore"`
  // children of this row. The mockup grows `.vp` 20→140px over 9s and `.tx`
  // 20→260px over 14s against scripted text; live speech cannot follow a
  // clock, so `.tx` takes the text's real height (floor 20px) and `.vp`
  // takes that height capped at 140px. `.tx` is bottom-anchored inside
  // `.vp`, so past the cap the oldest lines clip at the top and the newest
  // line stays at the bottom, as in the mockup. `data-overflowing` turns on
  // the mockup's top fade at that point.
  _rowQuery(selector) {
    const row = this._rowEl()
    return row && typeof row.querySelector === "function" ? row.querySelector(selector) : null
  },

  _setLiveText(text) {
    const p = this._rowQuery(".tr.live .tx p")
    if (!p) return
    p.textContent = text || ""
    const tx = p.parentElement
    const vp = tx ? tx.parentElement : null
    if (!tx || !vp || !tx.style || !vp.style) return
    const h = Math.max(LINE_PX, Math.ceil(p.scrollHeight || p.offsetHeight || 0))
    tx.style.height = `${h}px`
    vp.style.height = `${Math.min(h, VP_CAP_PX)}px`
    vp.dataset.overflowing = h > VP_CAP_PX ? "true" : "false"
  },

  // On release the mockup's `.vp`/`.tx`/`::before` animations stop (they
  // only run under `:active`), so the box drops back to its 20px rest size
  // with no top fade. The text stays until the next press clears it.
  _resetLiveSize() {
    const p = this._rowQuery(".tr.live .tx p")
    const tx = p ? p.parentElement : null
    const vp = tx ? tx.parentElement : null
    if (tx && tx.style) tx.style.height = ""
    if (vp && vp.style) vp.style.height = ""
    if (vp && vp.dataset) vp.dataset.overflowing = "false"
  },

  _setSentText(text) {
    const sum = this._rowQuery(".tr.sent .sum")
    if (sum) sum.textContent = text || ""
  },

  // Only a release that actually sent (held past HOLD_THRESHOLD_MS) gets
  // "✓ Sent to <agent>"; an early release gets the coaching line instead.
  _showSent(text) {
    this._clearSent()
    this._sentText = text || ""
    this._setSentText(this._sentText)
    this._sentShowing = true
    this._setRowAttr("data-sent", "true")
    this._sentTimer = setTimeout(() => this._clearSent(), SENT_MS)
  },

  _clearSent() {
    if (this._sentTimer) {
      clearTimeout(this._sentTimer)
      this._sentTimer = null
    }
    if (this._sentShowing) this._setRowAttr("data-sent", "false")
    this._sentShowing = false
  },

  // ── The feedback line (task 01a0f324 stage 3, item 4) ─────────────────────
  //
  // Replaces the old floating `[data-role="meeting-agent-hold-coach"]`
  // tooltip (positioned via `getBoundingClientRect` because its wrapper
  // was `display: contents`). The new element is a plain block
  // `ParticipantRail` renders as a SIBLING of the row's own flex line,
  // full row width, so it needs no JS positioning at all — only its
  // `data-open`/`data-tone` and text content are set here.
  _feedbackEl() {
    if (this._feedbackNode !== undefined) return this._feedbackNode

    const row = this._rowEl()
    this._feedbackNode =
      row && typeof row.querySelector === "function"
        ? row.querySelector('[data-role="meeting-agent-hold-feedback"]')
        : null

    return this._feedbackNode
  },

  // `opts.autoHide` defaults to true (the early-release nudge and every
  // rejection clear themselves). `disconnected()` passes `false`: an
  // offline notice that vanished on its own timer while the socket was
  // still down would be a worse lie than the truncation this stage
  // exists to fix — it is dismissed explicitly by `reconnected()`.
  _showFeedback(tone, text, opts = {}) {
    const el = this._feedbackEl()
    if (!el) return

    const textEl = el.querySelector('[data-role="meeting-agent-hold-feedback-text"]')
    if (textEl) textEl.textContent = text
    el.dataset.tone = tone
    el.dataset.open = "true"

    this._clearFeedbackTimer()
    if (opts.autoHide !== false) {
      this._feedbackTimer = setTimeout(() => this._hideFeedback(), FEEDBACK_AUTO_HIDE_MS)
    }
  },

  _hideFeedback() {
    this._clearFeedbackTimer()
    const el = this._feedbackEl()
    if (el) el.dataset.open = "false"
  },

  _clearFeedbackTimer() {
    if (this._feedbackTimer) {
      clearTimeout(this._feedbackTimer)
      this._feedbackTimer = null
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

export { BAR_COUNT, HOLD_THRESHOLD_MS }
export default MeetingPushToTalk
