/**
 * CandidateRing hook — makes a meeting task card's countdown actually tick.
 *
 * The server renders the number that was true at render time and stamps the
 * real deadline into `data-acts-at`. Before this hook the number simply sat
 * there: a card that said "Starting in 30s" said it until the next LiveView
 * patch, whenever that happened to be.
 *
 * Everything here is derived from `data-acts-at`, which is the same
 * `meeting_candidates.acts_at` the server's sweeper fires on. That is the
 * point: the ring is a rendering of the server's deadline, not a second
 * clock that was started at mount and would drift away from it. No polling —
 * a per-card server round trip every second is exactly what a client-side
 * countdown exists to avoid.
 *
 * Reaching zero deliberately does NOT ask the server for anything. The
 * sweeper fires on its own and broadcasts a candidate event, and the rail
 * refetches on that. A hook that pushed at zero would give every connected
 * participant's browser its own opinion about when a card fired.
 */
const CandidateRing = {
  mounted() {
    this._start()
  },

  updated() {
    // The deadline can move (an utterance attached and extended it) or the
    // card can be re-rendered for unrelated reasons. Re-read rather than
    // trusting what was captured at mount.
    this._stop()
    this._start()
  },

  destroyed() {
    this._stop()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _start() {
    const actsAt = this.el.dataset.actsAt
    if (!actsAt) return

    this._deadline = new Date(actsAt).getTime()
    if (isNaN(this._deadline)) return

    this._total = parseInt(this.el.dataset.totalSeconds, 10)
    if (!this._total || this._total <= 0) return

    this._circumference = parseFloat(this.el.dataset.circumference)
    if (isNaN(this._circumference)) return

    this._tick()
    this._interval = setInterval(() => this._tick(), 1000)
  },

  _stop() {
    if (this._interval) {
      clearInterval(this._interval)
      this._interval = null
    }
  },

  _tick() {
    const remaining = Math.max(
      0,
      Math.ceil((this._deadline - Date.now()) / 1000)
    )

    for (const el of this.el.querySelectorAll(
      "[data-role='meeting-candidate-remaining'], [data-role='meeting-candidate-remaining-word']"
    )) {
      el.textContent = String(remaining)
      if (el.dataset.remaining !== undefined) {
        el.dataset.remaining = String(remaining)
      }
    }

    const progress = this.el.querySelector(
      "[data-role='meeting-candidate-ring-progress']"
    )
    if (progress) {
      // Same arithmetic as `dash_offset/2` on the server: a full ring at
      // t=total, an empty one at t=0. They have to agree or the first tick
      // visibly jumps.
      const fraction = Math.min(remaining / this._total, 1)
      const offset = this._circumference * (1 - fraction)
      progress.setAttribute("stroke-dashoffset", offset.toFixed(2))
    }

    if (remaining <= 0) this._stop()
  },
}

export default CandidateRing
