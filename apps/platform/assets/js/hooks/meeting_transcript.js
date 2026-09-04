/**
 * MeetingTranscript hook — fills the call rail's Transcript tab from the
 * caption events LiveKit already emits (task 01a05b14 stage 5).
 *
 * WHY A HOOK AND NOT A LIVEVIEW LIST. `meeting:caption` is a CLIENT-SIDE
 * DOM CustomEvent, not a PubSub message: `meeting_room.js` dispatches it on
 * `document` from LiveKit's `TranscriptionReceived`, and nothing in `lib/`
 * ever sees the payload. Rendering the pane server-side would mean adding a
 * client-to-server push and a server-side buffer — new pipeline this task
 * explicitly excludes. So the pane is JS-owned, its container carries
 * `phx-update="ignore"` so morphdom never discards our children, and this
 * hook pushes NOTHING to the server. That last part matters: because there
 * is no `pushEvent` call at all, the "hook pushEvent ignores phx-target"
 * hazard (a hook inside a LiveComponent losing its target) cannot apply
 * here. There is no event to lose.
 *
 * Structure deliberately mirrors `meeting_captions.js` rather than
 * inventing a second convention — same rolling buffer, same interim/final
 * rule, same guest-suffix attribution, same HTML escaping. The two are two
 * surfaces over one event stream: the overlay bar shows the last couple of
 * lines over video, this pane keeps scrollback. Both stay.
 *
 * Differences from the overlay, all pane-appropriate:
 *   - MAX_LINES is a scrollback cap, not an occlusion budget
 *   - no auto-hide timer (a pane does not fade out)
 *   - auto-scroll ONLY when the reader is already pinned to the bottom, so
 *     scrolling back to re-read is not yanked away by the next utterance
 */

// Scrollback cap. Bounded because this buffer lives for the length of a
// call and every line is a DOM node; unbounded growth is a slow leak on a
// long meeting. 200 lines is far more scrollback than the 2-line overlay
// keeps while staying cheap to re-render.
const MAX_LINES = 200

// Distance from the bottom, in px, within which the pane counts as
// "pinned" and therefore auto-scrolls. A few px of slack because
// fractional scroll heights mean an exactly-bottomed pane rarely reports
// scrollTop + clientHeight === scrollHeight.
const PIN_SLACK_PX = 24

const MeetingTranscript = {
  mounted() {
    /** @type {{ id: string, speaker: string, text: string, final: boolean }[]} */
    this._lines = []
    this._interimLine = null

    // Server-rendered empty-state markup. Kept verbatim so the pane can
    // fall back to the SAME honest wording the LiveView emitted rather
    // than this hook keeping a second copy that could drift.
    this._emptyHtml = this.el.innerHTML

    this._boundOnCaption = this._onCaption.bind(this)
    document.addEventListener("meeting:caption", this._boundOnCaption)
  },

  destroyed() {
    document.removeEventListener("meeting:caption", this._boundOnCaption)
  },

  // ── Private ──────────────────────────────────────────────────────────

  _onCaption(event) {
    const { id, speaker, identity, text, final } = event.detail || {}
    if (!text || !text.trim()) return

    // Same guest-suffix rule as the overlay bar: MeetingRoom stamps guest
    // LiveKit identities with a `guest:` prefix.
    const displaySpeaker =
      typeof identity === "string" && identity.startsWith("guest:")
        ? `${speaker} (guest)`
        : speaker

    if (!final) {
      this._updateInterim({ id, speaker: displaySpeaker, text })
    } else {
      this._commitLine({ id, speaker: displaySpeaker, text })
    }

    const pinned = this._pinnedToBottom()
    this._render()
    if (pinned) this._scrollToBottom()
  },

  _updateInterim({ id, speaker, text }) {
    if (this._interimLine && this._interimLine.id === id) {
      this._interimLine.text = text
      this._interimLine.speaker = speaker
    } else {
      this._interimLine = { id, speaker, text, final: false }
    }
  },

  _commitLine({ id, speaker, text }) {
    // A final segment ends the current interim segment WHATEVER id it
    // carries. This is `meeting_captions.js`'s rule, not a re-derivation:
    // transcribers do not reliably reuse the interim's id for the final,
    // and the naive `id === this._interimLine.id` guard orphaned the
    // interim so one utterance rendered twice (task 019ff712).
    this._interimLine = null

    // A redelivered final updates the entry it already owns rather than
    // appending a duplicate; a genuinely new id appends, preserving
    // scrollback order.
    const line = { id, speaker, text, final: true }
    const existing = this._lines.findIndex((l) => l.id === id)
    if (existing !== -1) {
      this._lines[existing] = line
    } else {
      this._lines.push(line)
    }

    if (this._lines.length > MAX_LINES) {
      this._lines = this._lines.slice(-MAX_LINES)
    }
  },

  _pinnedToBottom() {
    const { scrollTop, clientHeight, scrollHeight } = this.el
    // A pane shorter than its viewport has nothing to scroll and is
    // trivially pinned.
    if (scrollHeight <= clientHeight) return true
    return scrollHeight - (scrollTop + clientHeight) <= PIN_SLACK_PX
  },

  _scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },

  _render() {
    const displayLines = [...this._lines]
    if (this._interimLine) displayLines.push(this._interimLine)

    if (displayLines.length === 0) {
      this.el.innerHTML = this._emptyHtml
      return
    }

    this.el.innerHTML = displayLines
      .map((line) => {
        const tone = line.final ? "opacity-100" : "opacity-60 italic"
        return `<div class="transcript-line ${tone} py-1 text-xs leading-snug" data-role="transcript-line" data-final="${line.final}">
          <span class="font-semibold text-base-content">${this._escapeHtml(line.speaker)}</span>
          <span class="text-base-content/80">${this._escapeHtml(line.text)}</span>
        </div>`
      })
      .join("")
  },

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str == null ? "" : String(str)
    return div.innerHTML
  },
}

export default MeetingTranscript
export { MAX_LINES }
