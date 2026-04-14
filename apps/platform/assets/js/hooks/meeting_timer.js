/**
 * MeetingTimer hook — keeps a live mm:ss duration counter on the mini-bar.
 *
 * Reads `data-started-at` (ISO 8601) from the hook element, then updates
 * the `[data-timer]` child every second with the elapsed time. All updates
 * are purely client-side — no server round-trips.
 */
const MeetingTimer = {
  mounted() {
    this._startTimer()
  },

  updated() {
    // Re-read started-at in case the meeting changed
    this._stopTimer()
    this._startTimer()
  },

  destroyed() {
    this._stopTimer()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _startTimer() {
    const startedAt = this.el.dataset.startedAt
    if (!startedAt) return

    this._startTime = new Date(startedAt).getTime()
    if (isNaN(this._startTime)) return

    // Update immediately, then every second
    this._tick()
    this._interval = setInterval(() => this._tick(), 1000)
  },

  _stopTimer() {
    if (this._interval) {
      clearInterval(this._interval)
      this._interval = null
    }
  },

  _tick() {
    const elapsed = Math.max(0, Math.floor((Date.now() - this._startTime) / 1000))
    const minutes = Math.floor(elapsed / 60)
    const seconds = elapsed % 60
    const display = `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`

    const timerEl = this.el.querySelector("[data-timer]")
    if (timerEl) {
      timerEl.textContent = display
    }
  },
}

export default MeetingTimer
