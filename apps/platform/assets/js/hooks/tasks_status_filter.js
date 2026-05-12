// TasksStatusFilter
//
// Persists the active mobile-Tasks status-filter pill across page loads via
// localStorage. The LiveView keeps the source-of-truth assign (`@active_status_filter`,
// default `"in_progress"` on mount) — this hook just:
//
//   - On mount: if there's a stored filter different from the default, push a
//     `filter_by_status` event to LV so the rendered active pill matches what
//     the user last had selected.
//   - On click within the pill nav: write the clicked status to localStorage
//     so the next mount picks it up.
//
// The LV-side `filter_by_status` handler validates the incoming status against
// `@mobile_columns`, so a corrupted/stale localStorage value gets silently
// ignored on the server. No client-side validation needed.

const STORAGE_KEY = "tasks-active-status-filter"

export default {
  mounted() {
    const stored = this.readStored()
    if (stored && stored !== "in_progress") {
      this.pushEvent("filter_by_status", { status: stored })
    }

    this.handleClick = (event) => {
      const btn = event.target.closest("button[phx-click='filter_by_status']")
      if (!btn) return
      const status = btn.getAttribute("phx-value-status")
      if (status) this.writeStored(status)
    }
    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    if (this.handleClick) this.el.removeEventListener("click", this.handleClick)
  },

  readStored() {
    try {
      return localStorage.getItem(STORAGE_KEY)
    } catch (_e) {
      // Private-mode Safari etc. throws on localStorage access; fall back to default.
      return null
    }
  },

  writeStored(status) {
    try {
      localStorage.setItem(STORAGE_KEY, status)
    } catch (_e) {
      // Quota / private-mode failure — silently skip; LV state still updates.
    }
  },
}
