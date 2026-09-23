import { paintBars } from "./lib/ptt_waveform"

/**
 * MeetingAskFloorVeil — the dimmed veil and centred "Asking <agent>…"
 * card while a viewer holds an agent's push-to-talk button (task
 * 01a0cf5c stage 2, design canvas 01a0cf5e-9cb0). Stage 3 adds the live
 * transcript text and the fly-into-the-rail / crumble release outcome.
 *
 * ## A SINGLETON, not one per agent row
 *
 * `MeetingPushToTalk` mounts once per agent row (one hook, one button).
 * This hook mounts exactly ONCE per rendered `ParticipantRail` — there is
 * only ever one veil, because a viewer can only be holding one button at
 * a time. It listens for window-level `CustomEvent`s that whichever
 * `MeetingPushToTalk` instance is actually being held dispatches, and
 * drives this ONE veil element from them. That decoupling (events, not a
 * direct reference) is why `ParticipantRail` can render the hold
 * controls on either the desktop left rail or the mobile People tab
 * without this hook caring which roster produced the press.
 *
 * ## Client-driven while HELD, server-driven at RELEASE
 *
 * The server's `:pressed_agent_id` / `:ask_floor_holders` assigns (task
 * 01a0cf5c stage 1) are the AUTHORITATIVE floor state. This veil's open/
 * close choreography WHILE HELD (the 380ms early-release threshold, the
 * live meter) is pure local timing that cannot wait on a round trip, so
 * it stays driven by the `meeting:push-to-talk-*` window events
 * `MeetingPushToTalk` dispatches. But the RELEASE OUTCOME — did this
 * press become a real answer, or nothing at all — is a fact only the
 * server can know (task 01a0cf5c stage 3): it depends on the transcript
 * segment stream and `PressWindow`'s own empty-press grace timer, which
 * a client has no independent view of. So `meeting:push-to-talk-ended`
 * no longer closes the veil directly; it parks it in `_awaitOutcome()`
 * until the `meeting_ask_transcript_chunk` / `meeting_ask_outcome`
 * LiveView events (`meeting_live.ex`) say what actually happened.
 *
 * ## The 380ms early-release gate lives in `MeetingPushToTalk`, not here
 *
 * `meeting:push-to-talk-held` only fires once a press has been down for
 * `HOLD_THRESHOLD_MS` (`meeting_push_to_talk.js`). This hook opens the
 * veil on THAT event, never on `armed` (the press starting) — so an
 * early release, which never produces a `:held` event, never opens the
 * veil at all, exactly as the design direction requires ("do not run
 * the veil path at all for an early release"). Because of that, an
 * `meeting_ask_outcome` arriving for a press whose veil never opened is
 * a harmless no-op below (`_playOutcome` bails when the veil isn't
 * open) — the server resolves an outcome for EVERY press, held-long-
 * enough or not, and only the ones the veil actually opened for do
 * anything visible with it.
 *
 * ## The meter reuses the SAME measured level, not a second AnalyserNode
 *
 * `meeting:push-to-talk-level` carries the exact RMS level
 * `MeetingPushToTalk.sample()` already measured off the local mic
 * track's `AnalyserNode`. This hook paints its own `[data-ptt-bar]`
 * elements from it via `./lib/ptt_waveform`'s `paintBars` — the SAME
 * function `MeetingPushToTalk` uses for its own small waveform — rather
 * than opening a second `AnalyserNode` on a track that already has one,
 * or reimplementing the bar math. Per the canvas, this is deliberately
 * a LIVE LEVEL, never a duration-filling progress bar: nothing here
 * tracks elapsed hold time or paints toward a ceiling.
 *
 * ## The release outcome: fly into the rail, or crumble
 *
 * Per the canvas's one kept mock element — "it says the thing you said
 * became a thing that exists, and it points at where it went" — a real
 * release with at least one claimed segment flies this card toward the
 * `MeetingCandidate` row `PlatformWeb.Components.Meetings.CandidateRail`
 * already renders for it (`[data-candidate-id]`, found live via
 * `document.querySelector` since the rail is a SEPARATE `phx-update`
 * tree this hook has no assign-level reach into); a release that
 * claimed nothing crumbles the card instead. Both are driven by the
 * `meeting_ask_outcome` event, never guessed from a local segment count
 * — see `meeting_live.ex`'s `resolve_ask_outcome_on_release/1` and
 * `resolve_ask_outcome_on_candidate_closed/2` for why that decision
 * cannot safely be made here. `_outcomeTimer` is a safety net only: if
 * that event is ever lost, the veil still resolves (a plain fade)
 * rather than sitting open forever.
 */
const OUTCOME_SAFETY_NET_MS = 4_500

const MeetingAskFloorVeil = {
  mounted() {
    this._activeAgentId = null
    this._activeAgentName = ""
    this._outcomeTimer = null

    this._label = this.el.querySelector('[data-role="meeting-ask-label"]')
    this._bars = Array.from(this.el.querySelectorAll("[data-ptt-bar]"))
    this._transcript = this.el.querySelector('[data-role="meeting-ask-transcript"]')
    this._card = this.el.querySelector('[data-role="meeting-ask-card"]')

    this._onArmed = (event) => {
      const detail = event && event.detail
      if (!detail) return
      // Record who might be about to be held — the veil does not open
      // yet. If this never reaches `:held` (an early release), this is
      // just bookkeeping nothing ever reads.
      this._activeAgentId = detail.agentId || null
      this._activeAgentName = detail.agentName || ""
    }

    this._onHeld = (event) => {
      const detail = event && event.detail
      if (!detail || detail.agentId !== this._activeAgentId) return
      this._open(detail.agentName || this._activeAgentName)
    }

    this._onLevel = (event) => {
      const detail = event && event.detail
      if (!detail || detail.agentId !== this._activeAgentId) return
      if (!this.isOpen()) return
      paintBars(this._bars, detail.level || 0)
    }

    // A real hold ending no longer closes the veil directly (task
    // 01a0cf5c stage 3) — see the moduledoc's "client-driven while
    // held, server-driven at release". The meter stops (nothing more
    // will be sampled), but the card stays up until the server says
    // what happened.
    this._onEnded = (event) => {
      const detail = event && event.detail
      if (detail && detail.agentId !== this._activeAgentId) return
      this._awaitOutcome()
    }

    // An early release never opened the veil (see moduledoc), so there
    // is nothing to close visually — just forget the tracked press so a
    // stale `:level` from a torn-down analyser cannot paint anything.
    this._onEarlyRelease = (event) => {
      const detail = event && event.detail
      if (detail && detail.agentId !== this._activeAgentId) return
      this._activeAgentId = null
    }

    // The existing rejection event (a server-side `held-by-other`, or a
    // client-side `no-microphone` / `pointer-lost` / etc. that never
    // even reached `:armed` for a DIFFERENT press) carries no `agentId`
    // by contract — `meeting_push_to_talk.test.js` pins its shape to
    // `{ reason }`. Unconditional close is correct here: whatever THIS
    // viewer's press was doing, a rejection means it is over.
    this._onRejected = () => {
      this._clearOutcomeTimer()
      this._close()
    }

    window.addEventListener("meeting:push-to-talk-armed", this._onArmed)
    window.addEventListener("meeting:push-to-talk-held", this._onHeld)
    window.addEventListener("meeting:push-to-talk-level", this._onLevel)
    window.addEventListener("meeting:push-to-talk-ended", this._onEnded)
    window.addEventListener("meeting:push-to-talk-early-release", this._onEarlyRelease)
    window.addEventListener("meeting:push-to-talk-rejected", this._onRejected)

    // Task 01a0cf5c stage 3 — the live segment feed, and the release
    // verdict. Both are filtered on `agent_id` for the same reason
    // `push_to_talk_rejected` already is (`meeting_push_to_talk.js`):
    // this is one hook instance reacting to a push meant for whichever
    // agent is actually held, on a page that can render more than one
    // hold control.
    this.handleEvent("meeting_ask_transcript_chunk", (payload) => {
      if (!payload || payload.agent_id !== this._activeAgentId) return
      this._appendTranscript(payload.text)
    })

    this.handleEvent("meeting_ask_outcome", (payload) => {
      if (!payload || payload.agent_id !== this._activeAgentId) return
      this._clearOutcomeTimer()
      this._resolvedCandidateId = payload.candidate_id || null
      this._playOutcome(payload.outcome)
    })
  },

  destroyed() {
    window.removeEventListener("meeting:push-to-talk-armed", this._onArmed)
    window.removeEventListener("meeting:push-to-talk-held", this._onHeld)
    window.removeEventListener("meeting:push-to-talk-level", this._onLevel)
    window.removeEventListener("meeting:push-to-talk-ended", this._onEnded)
    window.removeEventListener("meeting:push-to-talk-early-release", this._onEarlyRelease)
    window.removeEventListener("meeting:push-to-talk-rejected", this._onRejected)
    this._clearOutcomeTimer()
  },

  /** Public, for tests: is the veil currently showing. */
  isOpen() {
    return this.el.dataset.open === "true"
  },

  _open(name) {
    if (this._label) {
      this._label.textContent = name ? `Asking ${name}…` : "Asking…"
    }
    if (this._transcript) {
      this._transcript.textContent = ""
    }
    this.el.dataset.open = "true"
    paintBars(this._bars, 0)
  },

  _appendTranscript(text) {
    if (!this._transcript || typeof text !== "string" || text === "") return

    const existing = this._transcript.textContent || ""
    this._transcript.textContent = existing ? `${existing} ${text}` : text
  },

  // The meter stops moving (nothing more will be sampled) but the card
  // stays open until `meeting_ask_outcome` resolves it — see the
  // moduledoc. `_outcomeTimer` is the safety net if that event is ever
  // lost: `PressWindow.release_grace_ms/0` is 3000ms on the server, so
  // this waits comfortably past it before giving up and fading.
  _awaitOutcome() {
    paintBars(this._bars, 0)
    this._clearOutcomeTimer()
    this._outcomeTimer = setTimeout(() => this._playOutcome("fade"), OUTCOME_SAFETY_NET_MS)
  },

  _clearOutcomeTimer() {
    if (this._outcomeTimer) {
      clearTimeout(this._outcomeTimer)
      this._outcomeTimer = null
    }
  },

  // `outcome` is `"fly"`, `"crumble"`, or the local safety-net `"fade"`.
  _playOutcome(outcome) {
    const card = this._card

    if (!card || typeof card.getBoundingClientRect !== "function") {
      this._close()
      return
    }

    if (outcome === "fly") {
      this._flyCard(card)
    } else if (outcome === "crumble") {
      card.style.transition = "transform 260ms ease-in, opacity 260ms ease-in"
      card.style.transform = "scale(0.85) rotate(-2deg)"
      card.style.opacity = "0"
    } else {
      card.style.transition = "opacity 200ms ease-out"
      card.style.opacity = "0"
    }

    setTimeout(() => this._finishOutcome(card), 340)
  },

  // Flies the card toward the spot its `MeetingCandidate` row already
  // renders in the candidate rail — no new markup, just a transform
  // toward wherever `[data-candidate-id]` for this press currently
  // sits. The rail can legitimately not be mounted at all (it renders
  // only inside the Canvas tab on a narrow viewport), in which case
  // this degrades to the same plain fade the safety net uses — the
  // card still resolves, it just does not have anywhere to point at.
  _flyCard(card) {
    const targetId = this._resolvedCandidateId
    const canQuery =
      typeof targetId === "string" &&
      targetId !== "" &&
      typeof document !== "undefined" &&
      typeof document.querySelector === "function" &&
      typeof CSS !== "undefined" &&
      typeof CSS.escape === "function"

    const target = canQuery
      ? document.querySelector(`[data-candidate-id="${CSS.escape(targetId)}"]`)
      : null

    if (target && typeof target.getBoundingClientRect === "function") {
      const cardRect = card.getBoundingClientRect()
      const targetRect = target.getBoundingClientRect()
      const dx = targetRect.left + targetRect.width / 2 - (cardRect.left + cardRect.width / 2)
      const dy = targetRect.top + targetRect.height / 2 - (cardRect.top + cardRect.height / 2)

      card.style.transition = "transform 320ms ease-in, opacity 320ms ease-in"
      card.style.transform = `translate(${dx}px, ${dy}px) scale(0.18)`
      card.style.opacity = "0"
    } else {
      card.style.transition = "opacity 220ms ease-out"
      card.style.opacity = "0"
    }
  },

  _finishOutcome(card) {
    this._close()
    card.style.transition = ""
    card.style.transform = ""
    card.style.opacity = ""
  },

  _close() {
    this.el.dataset.open = "false"
    this._activeAgentId = null
    this._resolvedCandidateId = null
    paintBars(this._bars, 0)
  },
}

export default MeetingAskFloorVeil
