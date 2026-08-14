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
 * - Auto-hides after 5 seconds of silence
 * - CSS classes handle positioning (bottom overlay, semi-transparent bg)
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

const MeetingCaptions = {
  mounted() {
    /** @type {{ id: string, speaker: string, text: string, final: boolean }[]} */
    this._lines = []
    this._hideTimer = null
    this._interimLine = null // Track the current interim segment by ID

    this._boundOnCaption = this._onCaption.bind(this)
    document.addEventListener("meeting:caption", this._boundOnCaption)

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
    this._clearHideTimer()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _onCaption(event) {
    const { id, speaker, identity, text, final } = event.detail
    if (!text || !text.trim()) return

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
        const opacity = line.final ? "opacity-100" : "opacity-70"
        const italic = line.final ? "" : "italic"
        return `<div class="caption-line ${opacity} ${italic} py-0.5 transition-opacity duration-200">
          <span class="font-semibold text-base-content">${this._escapeHtml(line.speaker)}</span>
          <span class="text-base-content/90">${this._escapeHtml(line.text)}</span>
        </div>`
      })
      .join("")
  },

  _resetHideTimer() {
    this._clearHideTimer()
    this._hideTimer = setTimeout(() => {
      this.el.classList.add("opacity-0", "pointer-events-none")
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
export { MeetingCaptionsPersist }
