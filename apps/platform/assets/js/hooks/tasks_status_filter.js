// TasksStatusFilter
//
// Persists the active mobile-Tasks status-filter pill across page loads via
// Suite.ClientState. The LiveView keeps the source-of-truth assign
// (`@active_status_filter`, default `"in_progress"` on mount) — this hook just:
//
//   - On mount: if there's a stored filter different from the default, push a
//     `filter_by_status` event to LV so the rendered active pill matches what
//     the user last had selected.
//   - On click within the pill nav: write the clicked status to ClientState
//     so the next mount picks it up.
//
// The LV-side `filter_by_status` handler validates the incoming status against
// `@mobile_columns`, so a corrupted/stale ClientState value gets silently
// ignored on the server. No client-side validation needed.
//
// Task 019f3e9a stage 3: migrated off ad-hoc direct-store calls onto
// `Suite.ClientState`. The old un-namespaced key `"tasks-active-status-filter"`
// is read once, mirrored into the new store, and deleted so returning users
// keep their selection across the flag day.

import ClientState from "../client_state.js"

const NAMESPACE = "tasks_ui"
const KEY = "status_filter"
const LEGACY_KEY = "tasks-active-status-filter"

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
    const current = ClientState.get(NAMESPACE, KEY, null)
    if (current != null) return current

    // Legacy-key migration: read once, port to ClientState, delete the raw
    // entry so future reads take the fast path above. Guarded try/catch so
    // private-mode Safari doesn't take out the whole hook.
    try {
      const legacy = globalThis.localStorage?.getItem(LEGACY_KEY) // client-state:allow (legacy migration)
      if (legacy == null) return null
      ClientState.set(NAMESPACE, KEY, legacy)
      globalThis.localStorage.removeItem(LEGACY_KEY) // client-state:allow (legacy migration)
      return legacy
    } catch (_e) {
      return null
    }
  },

  writeStored(status) {
    ClientState.set(NAMESPACE, KEY, status)
  },
}
