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
 */

const MAX_LINES = 3
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
  },

  destroyed() {
    document.removeEventListener("meeting:caption", this._boundOnCaption)
    this._clearHideTimer()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _onCaption(event) {
    const { id, speaker, text, final } = event.detail
    if (!text || !text.trim()) return

    // Show the container
    this.el.classList.remove("opacity-0", "pointer-events-none")
    this._resetHideTimer()

    if (!final) {
      // Interim: update in place if same ID, or replace the interim slot
      this._updateInterim({ id, speaker, text })
    } else {
      // Final: commit the line
      this._commitLine({ id, speaker, text })
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
          <span class="font-semibold text-primary-content">${this._escapeHtml(line.speaker)}</span>
          <span class="text-primary-content/90">${this._escapeHtml(line.text)}</span>
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

export default MeetingCaptions
