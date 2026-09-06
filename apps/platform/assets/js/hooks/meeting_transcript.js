/**
 * MeetingTranscript hook — fills the call rail's Transcript tab from the
 * caption events LiveKit already emits (task 01a05b14 stage 5, extended by
 * task 01a06524 stage 1 with grouping, follow-live and the jump pill).
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
 *   - MAX_LINES is a scrollback cap, not an occlusion budget, and the pane
 *     SAYS when it has dropped the top rather than leaving an ambiguous gap
 *   - no auto-hide timer (a pane does not fade out)
 *   - consecutive utterances from one speaker group under one header (a
 *     chat log, not a table — at ~290px a per-row name column wraps the
 *     text to three words; Saru's canvas 01a068fc)
 *   - FOLLOW-LIVE rather than geometry-at-render: the reader's own scroll
 *     decides whether new lines pull the view down. Scrolling up unpins,
 *     returning to the bottom re-pins, and a reader who scrolled up is
 *     never yanked; instead a pill names who is speaking so they can
 *     decide whether to come back.
 *
 * Colour is semantic tokens only. `base-content` at full strength for
 * finalised text, at reduced opacity for name / timestamp / interim (the
 * dark palette defines no `neutral`, see the canvas), `base-300` for the
 * speaker-change hairline, `primary` ONCE on the pill. Never `info`,
 * `warning` or `error`: those carry agent state on the rail directly above
 * this pane, and a transcript that borrowed them would read as status.
 *
 * THE `meeting:caption` CONTRACT (stated here, where it is consumed, so
 * nobody re-derives it from `meeting_room.js`). It is a `CustomEvent`
 * dispatched on `document` by `meeting_room.js` `_onTranscription()`, once
 * per LiveKit `TranscriptionSegment` of a `transcriptionReceived` event:
 *
 *   detail = { id, speaker, identity, text, final, timestamp }
 *
 *   id        seg.id, falling back to crypto.randomUUID() — the interim /
 *             final pairing key. An interim and its final SHARE an id when
 *             LiveKit says so; a final with a NEW id still replaces the one
 *             pending interim (this hook keeps at most one interim line).
 *   speaker   participant.name || participant.identity || "Unknown"
 *   identity  participant.identity || "" — `user:<uuid>`, `agent:<slug>`
 *             or `guest:<uuid>`; the guest suffix and agent chip key on the
 *             prefix (see AGENT_IDENTITY_PREFIX / GUEST_IDENTITY_PREFIX)
 *   text      seg.text || ""
 *   final     seg.final !== false — DEFAULTS TO TRUE when absent
 *   timestamp seg.startTime || Date.now() — epoch ms
 *
 * SYNTHESISING CAPTIONS WITHOUT LIVEKIT. Because the pane consumes a DOM
 * event, any page context (browser console, CDP `Runtime.evaluate`, a
 * jsdom test) can drive it with no room connected:
 *
 *   document.dispatchEvent(new CustomEvent("meeting:caption", { detail: {
 *     id: "u1", speaker: "Ada", identity: "", text: "first line",
 *     final: true, timestamp: Date.now()
 *   } }))
 *
 * Interim then final: dispatch `{ id: "i-1", final: false, text: "hello th" }`
 * followed by `{ id: "f-9", final: true, text: "hello there" }` — one line
 * results, not two. `meeting_captions.js` consumes the same event, so one
 * dispatch drives both the overlay and this pane. Recipe also in
 * `assets/README.md` ("Meetings: synthesising captions").
 */

// Scrollback cap. Bounded because this buffer lives for the length of a
// call and every line is a DOM node; unbounded growth is a slow leak on a
// long meeting. 200 lines is far more scrollback than the 2-line overlay
// keeps while staying cheap to re-render. The truncation notice derives
// its number from this constant so the sentence cannot drift from it.
const MAX_LINES = 200

// Distance from the bottom, in px, within which the pane counts as
// "at the live edge". A few px of slack because fractional scroll heights
// mean an exactly-bottomed pane rarely reports
// scrollTop + clientHeight === scrollHeight.
const PIN_SLACK_PX = 24

// LiveKit identity prefixes. `meeting_hooks.ex` mints `user:<uuid>` for a
// signed-in viewer, `Platform.Meetings.generate_agent_token/3` mints
// `agent:<slug>` for a voice runtime (`Meetings.agent_identity?/1` is the
// server-side twin of this check), and guests get `guest:<uuid>`. The
// agent chip and the guest suffix key on these and on nothing else.
const AGENT_IDENTITY_PREFIX = "agent:"
const GUEST_IDENTITY_PREFIX = "guest:"

// Set on the host while it holds at least one line. `app.css` hides the
// wrap's sibling `[data-role="transcript-empty"]` when its host carries
// it; the string must match that rule.
const HAS_LINES_CLASS = "transcript-has-lines"

const MeetingTranscript = {
  mounted() {
    /** @type {{ id: string, speaker: string, identity: string, text: string, final: boolean, at: number }[]} */
    this._lines = []
    this._interimLine = null

    // Set the first time the cap drops a line and never cleared: once the
    // record has a hole at the top it stays holed for the rest of the call.
    this._truncated = false

    // Follow-live model. True at mount: a pane that has never been
    // scrolled follows the conversation. The `scroll` listener below is
    // the ONLY thing that flips it — a render never re-decides on the
    // reader's behalf from geometry, because geometry at render time
    // cannot tell "the reader scrolled up" from "the pane is hidden and
    // reports 0 height".
    this._followLive = true

    // Speaker of the most recent line that arrived while the reader was
    // unpinned; null once they return. Drives the jump-to-live pill.
    this._pendingSpeaker = null

    // The empty state is NOT inside this host. It is a LiveView-owned
    // sibling `<p data-role="transcript-empty">` in the wrap (task
    // 01a0693d), so a server re-render can still change its wording. This
    // hook hides it by toggling `transcript-has-lines` on ITS OWN host —
    // a class added client-side on a `phx-update="ignore"` element is
    // preserved across patches, whereas an attribute set on the sibling
    // would be stripped by morphdom on the next patch — and one `:has()`
    // rule in app.css does the rest. Nothing is added at mount: the copy
    // stays visible until the first line, see `_render`.

    this._boundOnCaption = this._onCaption.bind(this)
    this._boundOnScroll = this._onScroll.bind(this)
    this._boundOnClick = this._onClick.bind(this)
    document.addEventListener("meeting:caption", this._boundOnCaption)

    // The host is the scroll container. Guarded because the vitest
    // harness stubs the host with a plain object (no jsdom).
    if (typeof this.el.addEventListener === "function") {
      this.el.addEventListener("scroll", this._boundOnScroll, { passive: true })
      this.el.addEventListener("click", this._boundOnClick)
    }

    // Tab reveal. The host is `display: none` while People or Canvas is
    // active, and a hidden element cannot be scrolled: `_scrollToBottom`
    // during that time is a no-op on a 0-height box. When the wrap drops
    // `hidden` the pane goes from 0 height to visible and, if the reader
    // was still following live, must land on the live edge rather than on
    // whatever scrollTop the browser restores. A reader who had scrolled
    // up keeps their place — `_followLive` is false and nothing moves.
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => {
        if (this._followLive && this.el.clientHeight > 0) this._scrollToBottom()
      })
      this._resizeObserver.observe(this.el)
    }
  },

  destroyed() {
    document.removeEventListener("meeting:caption", this._boundOnCaption)
    if (typeof this.el.removeEventListener === "function") {
      this.el.removeEventListener("scroll", this._boundOnScroll)
      this.el.removeEventListener("click", this._boundOnClick)
    }
    if (this._resizeObserver) this._resizeObserver.disconnect()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _onCaption(event) {
    const { id, speaker, identity, text, final, timestamp } = event.detail || {}
    if (!text || !text.trim()) return

    const ident = typeof identity === "string" ? identity : ""

    // Same guest-suffix rule as the overlay bar: MeetingRoom stamps guest
    // LiveKit identities with a `guest:` prefix.
    const displaySpeaker = ident.startsWith(GUEST_IDENTITY_PREFIX) ? `${speaker} (guest)` : speaker

    const at = this._normaliseTimestamp(timestamp)

    if (!final) {
      this._updateInterim({ id, speaker: displaySpeaker, identity: ident, text, at })
    } else {
      this._commitLine({ id, speaker: displaySpeaker, identity: ident, text, at })
    }

    if (!this._followLive) this._pendingSpeaker = displaySpeaker

    this._render()
    if (this._followLive) this._scrollToBottom()
  },

  _onScroll() {
    const was = this._followLive
    this._followLive = this._atBottom()
    if (was === this._followLive) return

    // The flag flipped. Returning to the live edge retires the pill;
    // leaving it arms nothing yet — the pill only appears once a line
    // actually arrives while the reader is away, so scrolling up in a
    // quiet room shows no button to nowhere.
    if (this._followLive) this._pendingSpeaker = null
    this._render()
  },

  _onClick(event) {
    const target = event && event.target
    const pill =
      target && typeof target.closest === "function"
        ? target.closest('[data-role="transcript-jump-live"]')
        : null
    if (!pill) return
    if (typeof event.preventDefault === "function") event.preventDefault()
    this._jumpToLive()
  },

  _jumpToLive() {
    this._followLive = true
    this._pendingSpeaker = null
    this._render()
    this._scrollToBottom()
  },

  _updateInterim({ id, speaker, identity, text, at }) {
    if (this._interimLine && this._interimLine.id === id) {
      this._interimLine.text = text
      this._interimLine.speaker = speaker
      this._interimLine.identity = identity
    } else {
      this._interimLine = { id, speaker, identity, text, at, final: false }
    }
  },

  _commitLine({ id, speaker, identity, text, at }) {
    // A final segment ends the current interim segment WHATEVER id it
    // carries. This is `meeting_captions.js`'s rule, not a re-derivation:
    // transcribers do not reliably reuse the interim's id for the final,
    // and the naive `id === this._interimLine.id` guard orphaned the
    // interim so one utterance rendered twice (task 019ff712).
    this._interimLine = null

    // A redelivered final updates the entry it already owns rather than
    // appending a duplicate; a genuinely new id appends, preserving
    // scrollback order.
    const line = { id, speaker, identity, text, at, final: true }
    const existing = this._lines.findIndex((l) => l.id === id)
    if (existing !== -1) {
      this._lines[existing] = line
    } else {
      this._lines.push(line)
    }

    if (this._lines.length > MAX_LINES) {
      this._lines = this._lines.slice(-MAX_LINES)
      this._truncated = true
    }
  },

  _atBottom() {
    const { scrollTop, clientHeight, scrollHeight } = this.el
    // A pane shorter than its viewport has nothing to scroll and is
    // trivially at the live edge.
    if (scrollHeight <= clientHeight) return true
    return scrollHeight - (scrollTop + clientHeight) <= PIN_SLACK_PX
  },

  _scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },

  // `detail.timestamp` is LiveKit's `seg.startTime` when present (epoch
  // milliseconds in current livekit-client) and `Date.now()` otherwise.
  // Anything that is not a plausible epoch-ms number falls back to the
  // arrival time so the header always shows a real clock, never `NaN:NaN`.
  _normaliseTimestamp(value) {
    const n = typeof value === "number" ? value : Number(value)
    if (Number.isFinite(n) && n > 1e11) return n
    return Date.now()
  },

  _formatTime(ms) {
    const d = new Date(ms)
    const hh = String(d.getHours()).padStart(2, "0")
    const mm = String(d.getMinutes()).padStart(2, "0")
    return `${hh}:${mm}`
  },

  _render() {
    const displayLines = [...this._lines]
    if (this._interimLine) displayLines.push(this._interimLine)

    // Reached with no lines by `_onScroll` (a reader dragging an empty
    // pane) before any caption. The buffer never empties once a line has
    // landed, but the remove keeps the branch honest either way: the
    // sibling copy is visible exactly while the host has nothing to show.
    if (displayLines.length === 0) {
      this.el.classList.remove(HAS_LINES_CLASS)
      return
    }

    this.el.classList.add(HAS_LINES_CLASS)

    const parts = []

    if (this._truncated) {
      parts.push(
        `<p class="px-3 pt-3 pb-1 text-[11px] leading-normal text-base-content/50" data-role="transcript-truncated">Showing the last ${MAX_LINES} lines. Earlier speech is not kept.</p>`
      )
    }

    // Group consecutive lines from one speaker. The key is the identity
    // when LiveKit gave us one (two humans can share a display name) and
    // the display name otherwise.
    const groups = []
    for (const line of displayLines) {
      const key = line.identity || line.speaker
      const last = groups[groups.length - 1]
      if (last && last.key === key) {
        last.lines.push(line)
      } else {
        groups.push({ key, speaker: line.speaker, identity: line.identity, at: line.at, lines: [line] })
      }
    }

    groups.forEach((group, index) => {
      // The hairline sits above each SPEAKER CHANGE, so the first group
      // has none: there is no change above it to mark.
      const rule = index === 0 ? "" : " border-t border-edge"
      const agent = group.identity && group.identity.startsWith(AGENT_IDENTITY_PREFIX)
      const chip = agent
        ? `<span class="badge badge-outline badge-xs text-[9px] font-bold uppercase tracking-wide text-base-content/60" data-role="transcript-agent-chip">agent</span>`
        : ""

      const rows = group.lines
        .map((line) => {
          // Interim text is the same words at reduced strength; it snaps
          // to full `base-content` on final. No italics, no caret, no
          // spinner — the darkening IS the explanation.
          const tone = line.final ? "text-base-content" : "text-base-content/60"
          return `<p class="transcript-line ${tone} mb-1.5 text-[13px] leading-normal" data-role="transcript-line" data-speaker="${this._escapeAttr(line.speaker)}" data-final="${line.final}">${this._escapeHtml(line.text)}</p>`
        })
        .join("")

      parts.push(
        `<section class="px-3 pt-2${rule}" data-role="transcript-group" data-speaker="${this._escapeAttr(group.speaker)}">
          <div class="mb-1 flex items-baseline gap-1.5">
            <span class="text-[11.5px] font-semibold text-base-content/60" data-role="transcript-speaker">${this._escapeHtml(group.speaker)}</span>
            ${chip}
            <span class="ml-auto font-mono text-[10px] tabular-nums text-base-content/60" data-role="transcript-time">${this._formatTime(group.at)}</span>
          </div>
          ${rows}
        </section>`
      )
    })

    // Jump-to-live pill: only while the reader is away from the live edge
    // AND someone has spoken since they left. It names the speaker, not a
    // count — "are you missing something that matters" is the question a
    // reader scrolled up in a live call actually has. Sticky inside the
    // scroll container so it rides the pane's bottom edge; the only
    // `primary` and the only clickable thing in the pane.
    if (!this._followLive && this._pendingSpeaker) {
      parts.push(
        `<div class="pointer-events-none sticky bottom-2 flex justify-center pt-2">
          <button type="button" class="btn btn-xs btn-primary rounded-full pointer-events-auto shadow-md" data-role="transcript-jump-live">${this._escapeHtml(this._pendingSpeaker)} is speaking ↓</button>
        </div>`
      )
    }

    this.el.innerHTML = parts.join("")
  },

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str == null ? "" : String(str)
    return div.innerHTML
  },

  _escapeAttr(str) {
    return this._escapeHtml(str).replace(/"/g, "&quot;")
  },
}

export default MeetingTranscript
export { MAX_LINES, PIN_SLACK_PX, HAS_LINES_CLASS }
