// Connection status view (task 01a12b10, "Quiet reconnect").
//
// Maps the states emitted by ./reconnect_escalation.js onto the DOM:
//
//   #connection-status[data-state]   the quiet slot (line + pill), one per page
//   [data-connection-status-text]    the pill text, written only on transitions
//   #client-error / #server-error    the red toasts, through their
//                                    data-escalate / data-clear JS commands
//
// Kept apart from app.js so it can be tested with fake element objects (the
// assets test suite has no DOM environment). Every lookup goes through `doc`
// at call time, because a live navigation can replace the slot element.
//
// WHY reassert(): #connection-status is phx-update="ignore", which keeps its
// children, but LiveView 1.1 still merges data-* attributes on an ignored
// element from the server render on every patch (DOM.mergeAttrs with
// isIgnored). The server always renders data-state="idle", so any patch
// during "up_to_date" would silently reset the slot. app.js calls
// reassert() from a MutationObserver on data-state.

export const PILL_TEXT = {
  reconnecting: "Reconnecting…",
  up_to_date: "Up to date",
}

const TOASTS = {client: "#client-error", server: "#server-error"}

// A cheap fingerprint of the refreshed region, compared before and after a
// reconnect to decide whether the content changed.
export function regionOf(doc) {
  return doc.querySelector("[data-scroll-container]") || doc.querySelector("[data-phx-main]")
}

export function fingerprint(doc) {
  const el = regionOf(doc)
  if (!el) return null
  return `${(el.textContent || "").length}:${el.childElementCount || 0}`
}

export function createConnectionStatusView({doc, execJS}) {
  let current = {state: "idle", kind: null}

  function slot() {
    return doc.querySelector("#connection-status")
  }

  function toast(kind) {
    return doc.querySelector(TOASTS[kind])
  }

  function escalateToast(kind) {
    const el = toast(kind)
    if (el && el.dataset && el.dataset.escalate) execJS(el, el.dataset.escalate)
  }

  // Only clear a toast that is showing, so a routine transition does not run
  // a hide transition on an already-hidden element.
  function clearToast(kind) {
    const el = toast(kind)
    if (el && el.dataset && el.dataset.clear && !el.hasAttribute("hidden")) {
      execJS(el, el.dataset.clear)
    }
  }

  function render({state, kind}) {
    current = {state, kind: kind || null}
    const el = slot()
    if (el) {
      el.dataset.state = state
      const text = PILL_TEXT[state]
      const label = el.querySelector("[data-connection-status-text]")
      if (text && label && label.textContent !== text) label.textContent = text
    }

    if (state === "escalated") {
      const k = kind === "server" ? "server" : "client"
      escalateToast(k)
      clearToast(k === "client" ? "server" : "client")
    } else {
      clearToast("client")
      clearToast("server")
    }
  }

  // Put back a data-state the server render overwrote. Returns true when it
  // had to.
  function reassert() {
    const el = slot()
    if (el && el.dataset.state !== current.state) {
      el.dataset.state = current.state
      return true
    }
    return false
  }

  // The 150 ms settle on the refreshed region (app.css .reconnect-settle).
  function settle() {
    const el = regionOf(doc)
    if (!el || !el.classList) return
    el.classList.remove("reconnect-settle")
    // Force a reflow so the animation restarts when the class comes back.
    void el.offsetWidth
    el.classList.add("reconnect-settle")
  }

  return {render, reassert, settle, current: () => current}
}
