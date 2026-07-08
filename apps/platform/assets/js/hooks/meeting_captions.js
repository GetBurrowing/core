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
 * Stage 2 (task 019f3f17): in addition to the central rolling buffer, the
 * hook fans each incoming segment out to a matching per-speaker overlay
 * slot on the gallery tile — `[data-participant='<identity>']
 * [data-caption-slot]`. When gallery mode is active AND the speaker is
 * a visible tile, the tile-slot displays the latest line beneath the
 * speaker's face. When the speaker is off-page (paged out, or a non-
 * gallery mode is active), no matching slot exists in the DOM and the
 * per-tile render silently no-ops — the central bar still carries the
 * transcript so the viewer never loses a line.
 */

const MAX_LINES = 3
const HIDE_AFTER_MS = 5000
const SPEAKER_SLOT_HIDE_AFTER_MS = 5000

const MeetingCaptions = {
  mounted() {
    /** @type {{ id: string, speaker: string, text: string, final: boolean }[]} */
    this._lines = []
    this._hideTimer = null
    this._interimLine = null // Track the current interim segment by ID
    /** @type {Map<string, { text: string, speaker: string, timerId: number|null }>} */
    this._speakerSlots = new Map()

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
    // Clear every pending speaker-slot fade timer so a tile that
    // remounts under a fresh identity doesn't inherit a stale scheduled
    // clear from a previous session.
    for (const slot of this._speakerSlots.values()) {
      if (slot.timerId) clearTimeout(slot.timerId)
    }
    this._speakerSlots.clear()
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

    // Stage 2 fan-out: mirror the SAME segment (interim OR final) into
    // the speaker's per-tile overlay slot when one is mounted. The slot
    // is only present in gallery layout AND when the speaker's tile is
    // visible — the query silently returns null in every other case, so
    // this is a no-op fallback path (central bar continues rendering).
    if (typeof identity === "string" && identity !== "") {
      this._renderSpeakerSlot({ identity, speaker: displaySpeaker, text })
    }
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
    // If this was the interim line, promote it
    if (this._interimLine && this._interimLine.id === id) {
      this._interimLine = null
    }

    // Add to the finalized lines buffer
    this._lines.push({ id, speaker, text, final: true })

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

  // ── Per-speaker slot fan-out (stage 2) ───────────────────────────────
  //
  // Look up the tile carrying `data-participant="<identity>"` and, if
  // it has a `[data-caption-slot]` overlay child (opted in via the
  // video_tile `caption_slot?={true}` attr), write the speaker's latest
  // line into it and schedule a fade after SPEAKER_SLOT_HIDE_AFTER_MS
  // of silence. Silently no-ops when either the tile or the slot is
  // missing — that's the fallback path (off-page speaker, non-gallery
  // layout) where the central bar carries the transcript on its own.
  _renderSpeakerSlot({ identity, speaker, text }) {
    // Escape the identity into a valid CSS attribute selector — LiveKit
    // identities can contain characters like `:` (`user:<uuid>`,
    // `guest:<slug>`) which are structural in selectors. `CSS.escape` is
    // the browser-native way to quote them.
    const safeIdentity = window.CSS && window.CSS.escape
      ? window.CSS.escape(identity)
      : identity.replace(/["\\]/g, "\\$&")

    // Prefer a gallery-tile scope so the strip's identical
    // `data-participant` attribute (see meeting_live.html.heex bottom
    // strip) never picks up the slot query — the strip never carries a
    // `[data-caption-slot]` today, but a `querySelector` traversing the
    // page would still traverse that subtree unnecessarily.
    const tile = document.querySelector(
      `[data-participant="${safeIdentity}"] [data-caption-slot]`
    )
    if (!tile) return

    tile.textContent = `${speaker}: ${text}`
    tile.classList.remove("opacity-0")
    tile.classList.add("opacity-100")

    // Track + clear on a fade timer per identity so a burst of interim
    // segments doesn't stack listeners; each new segment resets the
    // timer to keep the slot visible while the speaker is still going.
    const existing = this._speakerSlots.get(identity)
    if (existing && existing.timerId) {
      clearTimeout(existing.timerId)
    }

    const timerId = setTimeout(() => {
      // The tile might have unmounted (mode swap, participant left) —
      // re-resolve rather than caching a possibly-stale reference.
      const slot = document.querySelector(
        `[data-participant="${safeIdentity}"] [data-caption-slot]`
      )
      if (slot) {
        slot.classList.remove("opacity-100")
        slot.classList.add("opacity-0")
        slot.textContent = ""
      }
      this._speakerSlots.delete(identity)
    }, SPEAKER_SLOT_HIDE_AFTER_MS)

    this._speakerSlots.set(identity, { text, speaker, timerId })
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
