import ClientState from "../client_state"

/**
 * MeetingCaptions hook — renders a rolling caption overlay during meetings.
 *
 * Mounted on a container element (typically `#meeting-captions`). Listens for
 * `meeting:caption` custom DOM events dispatched by the MeetingRoom hook and
 * renders them as a rolling buffer of the last 3 caption lines.
 *
 * Behaviour:
 * - Each line shows **speaker name** (bold) + text
 * - Interim (non-final) segments update the current line in place
 * - Final segments scroll up and become permanent
 * - Auto-hides after 5 seconds of silence, DROPPING the buffer as it goes
 * - CSS classes handle positioning (bottom overlay, semi-transparent bg)
 *
 * THREE STATES, not two (task 01a0740e stage 2):
 *
 *   1. FLOWING  — captions arriving; the bar draws them and nothing else.
 *   2. IDLE     — nobody speaking; the bar says NOTHING. No placeholder,
 *                 no spinner, and above all no "Listening". Saru's FE-8
 *                 canvas cut a "Listening…" placeholder from its own first
 *                 pass: a placeholder that appears whether or not a
 *                 transcriber is attached asserts something nobody checked,
 *                 which is the always-on lie `transcript_pane.ex` refuses by
 *                 name in its own moduledoc. An empty visible bar feeling
 *                 unfinished is the reflex; state 2 is silence on purpose.
 *   3. STALLED  — speech is demonstrably happening and no transcript is
 *                 arriving. The bar HOLDS POSITION and says so. See
 *                 `_renderStall`.
 *
 * The bar previously had only 1 and 2, so it could not tell "nobody is
 * speaking" from "the transcriber died" — and neither could the viewer,
 * because both render as an empty screen. The host carries
 * `aria-live="polite"`, so the stall notice is announced; the people most
 * affected by a dead transcriber are the ones least able to notice it any
 * other way.
 *
 * This bar is the ONE caption surface in every stage mode, gallery
 * included (task 019ff712). There is no per-tile fan-out: a single
 * attributed line beneath the video area is the whole contract.
 */

// Two, not three (task 019ff712 stage 4). The 3-line buffer was chosen when
// this bar only ever drew over canvas / screen-share, where the bottom of the
// frame is dead space. It is now the caption surface in gallery too, and
// there the same three lines land on somebody's face — occlusion, not
// headroom. Measured at 1280x800: three lines make the bar 96px tall against
// a 116px band of clear space below the bottom tile row; two make it 72px.
// This is the ONLY knob that was turned — the dedupe in `_commitLine`
// (stage 1) is untouched.
const MAX_LINES = 2
const HIDE_AFTER_MS = 5000

// ── Stall window (task 01a0740e stage 2, retuned task 01a0cf5c stage 2) ──
//
// How long speech may continue with NO caption arriving before the bar
// admits it is not receiving.
//
// CHOSEN, NOT MEASURED, same as before — but no longer chosen blind.
// Task 01a0cf5c stage 1 diagnosed a production false alarm: a real
// `meeting-transcriber` round trip landed at ~8s under load, well inside
// what a human on the call would call "still working", and the old
// 6000ms window read that as a dead pipeline. Production logs/DB were not
// reachable to confirm the exact incident room's `meeting_transcripts`
// rows, so this is still a judgement call — just one anchored to an
// observed ~8s round trip instead of nothing. 12000ms clears that
// observation with a 4s margin on its own, same as `Platform.Meetings.
// PressWindow`'s moduledoc is the honest record for its own grace value.
// If it proves twitchy in a real room, this is the dial.
//
// This number is no longer the only thing standing between a slow
// transcriber and a false alarm, either. Stage 2 layered the
// STALL_CONFIRM_MS re-check below on top of it, and stage 3 added a
// telemetry signal (`_reportStall`, one call per episode) so a REAL
// future outage leaves a record instead of relying on this comment's
// judgement call being right forever. See `docs/contracts/
// meeting-transcript-frame.md` for the triage steps ("nothing is being
// transcribed" reports) this task added, including why the browser UI
// was and remains ruled out from the stale-channel-plugin failure mode.
//
// FLOOR, and it is load-bearing: it MUST stay greater than
// HIDE_AFTER_MS. Below that an ordinary conversational pause — the
// bar's own fade window — would trip the notice. Telling every user in
// a normal pause that their captions are broken is the worst thing this
// feature can do, worse than shipping nothing at all.
//
// NAMED RISK, written down rather than designed away: a hot mic or
// sustained background noise can hold LiveKit's active-speaker slot
// with nobody actually speaking, and that produces a FALSE stall. The
// only mitigation applied is the one `_armStallTimer` implements — the
// speaking window must be SUSTAINED for the whole STALL_AFTER_MS, so a
// momentary level spike cannot trip it. No heuristic is layered on top
// of that; a cleverer detector here would be guessing.
const STALL_AFTER_MS = 12000

// ── Confirmation re-check (task 01a0cf5c stage 2) ────────────────────
//
// A single timeout crossing is not the stall condition any more — it is
// the CANDIDATE. `_armStallTimer` treats a STALL_AFTER_MS crossing as "go
// look again in STALL_CONFIRM_MS", and only renders the notice if speech
// is STILL sustained (no `meeting:speaking` false->true/off transition,
// no caption) at that second checkpoint. A transcriber that is merely
// slow finishes and clears the candidate before the confirm fires; a
// genuinely dead one is still silent at the confirm check and the notice
// still renders — later, but reliably. This is layered on top of the
// STALL_AFTER_MS raise above rather than instead of it: the raise
// absorbs the specific ~8s round trip already observed, the confirm
// window absorbs the NEXT one nobody has measured yet.
const STALL_CONFIRM_MS = 5000

// ── Caption palette — THEME-INVARIANT BY INTENT (task 01a0740e stage 1) ──
//
// These slots deliberately do NOT follow the daisyUI theme. That is the
// design decision, not an oversight: Saru's FE-8 canvas keeps it in its
// own self-critique, and this comment exists so the next tidy-up does
// not undo it.
//
// WHY: this bar sits over arbitrary VIDEO in both themes, not over a
// theme surface. Over video you want a dark scrim and light text
// whatever the shell is doing. Routing these through `base-content` is
// the tidy instinct and it is the wrong one here.
//
// It has already gone wrong exactly that way once. The host div in
// `meeting_live.html.heex` carried `text-white`, but `_render` used to
// write `text-base-content`, at full and at 90% strength, on the CHILD
// spans, and a colour declared on a child always beats one inherited
// from a parent — so the host's `text-white` was dead. In the light
// theme (`default: true` in app.css) `--color-base-content` is
// `oklch(0% 0 0)`, i.e. #000000. Net result: black caption text on a
// `bg-black/75` scrim. Not a contrast complaint — invisible.
//
//   SLOT                  VALUE                   WHERE
//   caption scrim         viewer at 75%           `bg-viewer/75`, on the
//                                                 `#meeting-captions` host in
//                                                 meeting_live.html.heex — the
//                                                 bar's ground, not written here
//   caption text          --on-viewer             CAPTION_TEXT
//   caption attribution   the SAME on-viewer, semibold  CAPTION_ATTRIBUTION —
//                                                 separated from the text by
//                                                 WEIGHT, never by colour: on
//                                                 this surface colour is spent
//                                                 on state
//   caption interim       on-viewer at 70%        CAPTION_TEXT composed with
//                                                 CAPTION_INTERIM on the line
//                                                 wrapper (+ italic)
//
// Rung 18: the viewer tokens. `text-on-viewer` on `bg-viewer/75` (masters
// burrow-meeting.js `.bm-caps .bm-bar`). --viewer / --on-viewer are black
// and white in every theme block, so they are theme-invariant by
// declaration, which is the exact property being asked for. No raw hex.
const CAPTION_TEXT = "text-on-viewer"
const CAPTION_ATTRIBUTION = "font-semibold text-on-viewer"
const CAPTION_INTERIM = "opacity-70"

// ── The stalled notice — state 3 ─────────────────────────────────────
//
// Copy is VERBATIM from Saru's FE-8 canvas, which calls this the
// signature element of the whole ticket: everything else on FE-8 is
// restraint and the boldness is spent here. Do not reword it.
//
// `warning`, never `error` and never `info`: the meeting is fine, the
// transcript is not. This is the ONE slot on this surface that reads a
// theme token, and that is deliberate rather than a leak of the
// tidy-instinct the block above warns about — `--color-warning` is
// declared with the SAME value in both the light and dark theme blocks
// in app.css, so `bg-warning` is already theme-invariant and needs no
// special handling. Rung 18: the hue is on the dot only; the words are
// `text-on-viewer`, as every caption line is, because a status hue never
// sits on text (R3). No raw hex.
//
// Utility type at `text-[12.5px]`, matching the rail's transcript pane,
// so the two caption surfaces speak in one voice. Semibold, preceded by
// a small round dot.
//
// `data-role="caption-stall"` so tests and e2e query the state rather
// than matching on the copy.
const STALL_COPY = "Captions stopped. Nothing is being transcribed."
const STALL_MARKUP =
  '<div data-role="caption-stall" class="flex items-center gap-2 py-0.5 text-[12.5px] font-semibold text-on-viewer">' +
  '<span class="h-[7px] w-[7px] shrink-0 rounded-full bg-warning"></span>' +
  STALL_COPY +
  "</div>"

const MeetingCaptions = {
  mounted() {
    /** @type {{ id: string, speaker: string, text: string, final: boolean }[]} */
    this._lines = []
    this._hideTimer = null
    this._interimLine = null // Track the current interim segment by ID

    // Stall detection state. `_speaking` is the last thing the SFU told
    // us about audio levels, NOT anything the transcriber said.
    this._stallTimer = null
    this._confirmTimer = null
    this._speaking = false

    // Room/meeting identifier for the stall signal (task 01a0cf5c stage
    // 2), read once from the host's dataset rather than threaded through
    // every event — `meeting_live.html.heex` stamps `data-meeting-id`
    // on this same element.
    this._meetingId = this.el.dataset ? this.el.dataset.meetingId : undefined

    this._boundOnCaption = this._onCaption.bind(this)
    document.addEventListener("meeting:caption", this._boundOnCaption)

    this._boundOnSpeaking = this._onSpeaking.bind(this)
    document.addEventListener("meeting:speaking", this._boundOnSpeaking)

    // Start hidden
    this.el.classList.add("opacity-0", "pointer-events-none")

    // Persistence is owned by the always-mounted `MeetingCaptionsPersist`
    // hook (below). Keeping it out of THIS hook is deliberate: the
    // `#meeting-captions` element is `:if={@captions_visible}`-gated, so
    // on a reload with server default `false` this hook never mounts and
    // any localStorage restore that lived here would silently no-op — the
    // exact chicken-and-egg bug the stage-1 reviewer flagged. The
    // sibling persist hook lives on an always-mounted host div.
  },

  destroyed() {
    document.removeEventListener("meeting:caption", this._boundOnCaption)
    document.removeEventListener("meeting:speaking", this._boundOnSpeaking)
    this._clearHideTimer()
    this._clearStallTimer()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _onCaption(event) {
    const { id, speaker, identity, text, final } = event.detail
    if (!text || !text.trim()) return

    // A caption arriving is the ONLY thing that clears a stall, and it
    // clears it immediately: `_render` below overwrites the notice, and
    // the buffer was emptied when the notice was drawn, so no pre-stall
    // line can come back beside this one. Restarting the countdown here
    // is also half the stall rule — see `_armStallTimer`.
    this._armStallTimer()

    // Show the container
    this.el.classList.remove("opacity-0", "pointer-events-none")
    this._resetHideTimer()

    // Guest-suffix render: MeetingHooks stamps guest LiveKit identities
    // with a `guest:` prefix (mirrors participant_rail.ex's
    // `via_guest_link?` predicate). Threading identity through the
    // custom event lets the central bar attribute the line as
    // `Name (guest): text` without a server round-trip.
    const displaySpeaker =
      typeof identity === "string" && identity.startsWith("guest:")
        ? `${speaker} (guest)`
        : speaker

    if (!final) {
      // Interim: update in place if same ID, or replace the interim slot
      this._updateInterim({ id, speaker: displaySpeaker, text })
    } else {
      // Final: commit the line
      this._commitLine({ id, speaker: displaySpeaker, text })
    }

    this._render()
  },

  _updateInterim({ id, speaker, text }) {
    // If we have an existing interim line, update it
    if (this._interimLine && this._interimLine.id === id) {
      this._interimLine.text = text
      this._interimLine.speaker = speaker
    } else {
      // New interim segment — replace any previous interim
      this._interimLine = { id, speaker, text, final: false }
    }
  },

  _commitLine({ id, speaker, text }) {
    // A final segment ends the current interim segment, whatever id it
    // carries. Transcribers do not reliably reuse the interim's id for
    // the final (task 019ff712): the previous `id === this._interimLine.id`
    // guard left the interim orphaned whenever the ids differed, and
    // `_render` then emitted it alongside the committed final — one
    // utterance, two visible `.caption-line` nodes.
    this._interimLine = null

    // Add to the finalized lines buffer. A redelivered final must update
    // the entry it already owns rather than append a second identical
    // one; a genuinely new id still appends, so scrollback is preserved.
    const line = { id, speaker, text, final: true }
    const existing = this._lines.findIndex((l) => l.id === id)
    if (existing !== -1) {
      this._lines[existing] = line
    } else {
      this._lines.push(line)
    }

    // Keep only the last MAX_LINES finalized lines
    if (this._lines.length > MAX_LINES) {
      this._lines = this._lines.slice(-MAX_LINES)
    }
  },

  _render() {
    // Build display lines: finalized + optional interim
    const displayLines = [...this._lines]
    if (this._interimLine) {
      displayLines.push(this._interimLine)
    }

    // Keep only MAX_LINES visible
    const visible = displayLines.slice(-MAX_LINES)

    this.el.innerHTML = visible
      .map((line) => {
        // Interim treatment is unchanged: `opacity-70` + `italic` on the
        // LINE WRAPPER. Once the base colour is white that composes to
        // the canvas's "caption interim = white at 70%" on its own — it
        // does not need (and must not get) a second colour slot.
        const opacity = line.final ? "opacity-100" : CAPTION_INTERIM
        const italic = line.final ? "" : "italic"
        return `<div class="caption-line ${opacity} ${italic} py-0.5 transition-opacity duration-200">
          <span class="${CAPTION_ATTRIBUTION}">${this._escapeHtml(line.speaker)}</span>
          <span class="${CAPTION_TEXT}">${this._escapeHtml(line.text)}</span>
        </div>`
      })
      .join("")
  },

  /**
   * `meeting:speaking` — the SECOND, INDEPENDENT liveness signal.
   *
   * Dispatched by `MeetingRoom._onActiveSpeaker` off LiveKit's
   * `activeSpeakersChanged`, which is derived from the SFU's audio levels
   * and NOT from the transcriber. That is the entire reason the stall
   * detector can be honest: absence of captions on its own cannot
   * distinguish a silent room from a dead transcriber, because absence
   * looks identical in both. Only a signal that keeps reporting after the
   * transcriber dies separates them.
   *
   * The EMPTY set is a real transition, and it is how this hook learns
   * everyone stopped talking. It disarms the detector, which is what keeps
   * the stall claim tied to positive evidence of speech.
   */
  _onSpeaking(event) {
    const identities = (event && event.detail && event.detail.identities) || []
    const speaking = identities.length > 0

    // Only TRANSITIONS matter. Re-arming on every membership change inside
    // an ongoing conversation would push the deadline out each time
    // somebody new took the floor, and the stall would never fire in a
    // busy room — which is exactly the room where it matters.
    if (speaking === this._speaking) return
    this._speaking = speaking

    if (speaking) {
      this._armStallTimer()
    } else {
      this._clearStallTimer()
    }
  },

  /**
   * Arm the sustained-speech countdown.
   *
   * Restarted by exactly two things: speech STARTING (false -> true), and
   * a caption ARRIVING. So when the STALL_AFTER_MS leg fires, both halves
   * of the rule hold at once — speech has been continuous for the full
   * window (there has been no false -> true transition inside it) and no
   * caption landed in that window. The stall claim is therefore only ever
   * made on positive evidence that speech is occurring while no
   * transcript arrives, and never in a silent room. That asymmetry is the
   * point of the feature.
   *
   * The "sustained for the full window" requirement is also the whole
   * hot-mic mitigation described at STALL_AFTER_MS.
   *
   * task 01a0cf5c stage 2: a STALL_AFTER_MS crossing no longer renders
   * directly. It arms a SECOND, shorter countdown (STALL_CONFIRM_MS) and
   * only renders if speech is still sustained (no caption, no
   * speaking->false transition — both of which call `_clearStallTimer`,
   * which now clears this leg too) when THAT fires. One timeout crossing
   * used to be enough to declare a dead pipeline; now two are required,
   * a fixed STALL_AFTER_MS + STALL_CONFIRM_MS apart, before the viewer is
   * told anything is wrong.
   */
  _armStallTimer() {
    this._clearStallTimer()
    if (!this._speaking) return
    this._stallTimer = setTimeout(() => {
      this._stallTimer = null
      if (!this._speaking) return
      this._confirmTimer = setTimeout(() => {
        this._confirmTimer = null
        if (!this._speaking) return
        this._renderStall()
      }, STALL_CONFIRM_MS)
    }, STALL_AFTER_MS)
  },

  _clearStallTimer() {
    if (this._stallTimer) {
      clearTimeout(this._stallTimer)
      this._stallTimer = null
    }
    if (this._confirmTimer) {
      clearTimeout(this._confirmTimer)
      this._confirmTimer = null
    }
  },

  /**
   * State 3. The bar HOLDS POSITION instead of fading: the hide timer is
   * cancelled and `opacity-0` / `pointer-events-none` come off. Geometry
   * is untouched — `max-w-2xl`, the centring, `rounded-xl`, the offset and
   * the safe-area / bottom-nav terms all live on the shell in
   * `meeting_live.html.heex` and are not this hook's business.
   *
   * The transcript is DROPPED first. An old utterance sitting beside
   * "nothing is being transcribed" reads as something just said, which is
   * the precise defect this ticket exists to remove.
   *
   * It holds until a caption arrives. It is deliberately NOT dismissed
   * when the room falls quiet: the claim it makes is still true then, and
   * fading it out would restore the silent disappearance.
   */
  _renderStall() {
    this._lines = []
    this._interimLine = null
    this._clearHideTimer()
    this.el.classList.remove("opacity-0", "pointer-events-none")
    this.el.innerHTML = STALL_MARKUP
    this._reportStall()
  },

  /**
   * The stall signal (task 01a0cf5c stage 2).
   *
   * Fired exactly once per stall EPISODE, right here at the point the bar
   * enters state 3 — never per tick, never per re-render. `_renderStall`
   * is only reachable via the STALL_AFTER_MS + STALL_CONFIRM_MS timer
   * chain in `_armStallTimer`, and that chain is fully torn down by
   * `_clearStallTimer` the moment a caption arrives or speech stops, so
   * one episode can only ever produce one call here — a second episode
   * needs a fresh speaking transition to rearm the chain at all.
   *
   * `pushEvent` reaches `MeetingLive`, which logs it server-side
   * (`handle_event("meeting_captions_stalled", ...)`), because a
   * browser-console line does not survive to be read after the fact —
   * which is exactly the gap this closes: today nobody can tell a real
   * future outage from a false one after it happened. Payload is
   * intentionally low-cardinality: a meeting id and a duration, no
   * per-tick data.
   */
  _reportStall() {
    if (typeof this.pushEvent !== "function") return
    this.pushEvent("meeting_captions_stalled", {
      meeting_id: this._meetingId || null,
      elapsed_ms: STALL_AFTER_MS + STALL_CONFIRM_MS,
    })
  },

  _resetHideTimer() {
    this._clearHideTimer()
    this._hideTimer = setTimeout(() => {
      this.el.classList.add("opacity-0", "pointer-events-none")

      // Drop the buffer WITH the fade (task 01a0740e stage 2).
      //
      // `_onCaption` removes `opacity-0` BEFORE calling `_render`, and
      // `_render` emits `[...this._lines]`. Leaving the buffer intact here
      // meant the first caption after ANY gap re-showed the bar with the
      // pre-gap line rendered beside the new one, identically, with no age
      // marker — a line from twenty minutes ago reading as something just
      // said. Not solved with timestamps on purpose: `_onCaption` drops the
      // `timestamp` field `meeting_room.js` dispatches, and age-marking a
      // two-line overlay is a bigger design change than this carries.
      //
      // A faded-out bar has no scrollback obligation. Scrollback is owned
      // by the rail's transcript pane, which keeps 200 lines and is a
      // separate surface.
      // `_lines` and `innerHTML` are each independently load-bearing and
      // each has a case pinning it (mutating either one alone goes red).
      // `_interimLine` is state hygiene rather than a fixed defect: every
      // path back into `_render` goes through `_commitLine` (which nulls
      // the interim outright) or `_updateInterim` (which replaces it), so
      // a surviving stale interim is not reachable on screen. It is
      // cleared anyway so the buffer state is not half-reset, and that is
      // said here rather than pretended about in a test.
      this._lines = []
      this._interimLine = null
      this.el.innerHTML = ""
    }, HIDE_AFTER_MS)
  },

  _clearHideTimer() {
    if (this._hideTimer) {
      clearTimeout(this._hideTimer)
      this._hideTimer = null
    }
  },

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  },
}

/**
 * MeetingCaptionsPersist hook — ClientState-backed CC preference.
 *
 * Split out of MeetingCaptions (task 019f3f17 stage 2 review fix) so
 * persistence survives page reload. `MeetingCaptions` mounts on
 * `#meeting-captions`, which is `:if={@captions_visible}`-gated — on a
 * fresh reload the server assign defaults to `false`, that div isn't in
 * the DOM, and the persistence branch that used to live in
 * `MeetingCaptions.mounted()` never ran. Users toggled captions on,
 * navigated away, came back, and captions were off again.
 *
 * The fix: mount THIS hook on a small always-present host div in the
 * meeting shell. It fires `meeting_captions_hydrate` on mount whenever
 * ClientState carries a different value than the server's default, and
 * mirrors subsequent server-pushed `meeting_captions_persist` events
 * into ClientState. No visible UI — pure preference bridge.
 *
 * Task 019f3e9a stage 4 follow-up: migrated off ad-hoc direct-store
 * calls onto `Suite.ClientState` under the `meeting` namespace. The old raw
 * key was `suite.meeting.captions_visible` (dots) — the ClientState
 * canonical key is `suite:meeting:captions_visible` (colons), so we
 * read-once from the legacy key on first hydrate, rewrite, and delete.
 */
const MeetingCaptionsPersist = {
  mounted() {
    const persistKey = this.el.dataset.persistKey
    if (!persistKey) return
    const stateKey = persistKey.replace(/^suite\./, "").replace(/\./g, ":")
    const [namespace, ...rest] = stateKey.split(":")
    const key = rest.join(":") || "value"

    let stored = ClientState.get(namespace, key, null)
    if (stored === null) {
      // Read-once migration path for the legacy raw key.
      try {
        const legacy = window.localStorage.getItem(persistKey) // client-state:allow (legacy migration)
        if (legacy === "true" || legacy === "false") {
          stored = legacy === "true"
          ClientState.set(namespace, key, stored)
          window.localStorage.removeItem(persistKey) // client-state:allow (legacy migration)
        }
      } catch (_) {
        // Private mode / no localStorage; fall through.
      }
    }
    if (typeof stored === "boolean") {
      this.pushEvent("meeting_captions_hydrate", { visible: stored })
    }

    this.handleEvent("meeting_captions_persist", ({ visible }) => {
      ClientState.set(namespace, key, !!visible)
    })
  },
}

export default MeetingCaptions
// The timing constants are exported so the vitest suite can pin the
// FLOOR invariant (STALL_AFTER_MS > HIDE_AFTER_MS) and the two-stage
// confirmation window directly instead of duplicating the numbers and
// drifting from them.
export { MeetingCaptionsPersist, HIDE_AFTER_MS, STALL_AFTER_MS, STALL_CONFIRM_MS }
