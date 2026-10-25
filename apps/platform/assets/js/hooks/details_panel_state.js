/**
 * DetailsPanelState hook (Burrow redesign 22 stage 3): the client half of
 * the desktop details panel (`Partials.DetailsPanel`, `DetailsPanelHooks`).
 * Mounted on the always-rendered hidden `#details-panel-state`.
 *
 * Remember (per viewer, through the ClientState store):
 *   namespace "details_panel", key "open:<data-user-id>", value boolean.
 *   The server pushes `details:changed` `{open}` on every open and close;
 *   the hook writes it.
 *
 * Restore: on mount, if the stored value is `true`, the server has it shut
 *   (`data-open` is not "true") and the viewport is at least 1280px wide,
 *   push `details_restore`. Not at 1024-1279px: with the sidebar and the
 *   list pane, an open panel leaves the conversation about 304px at 1024, so
 *   it is never reopened (or opened) by itself there. An explicit open
 *   (`details_open`) still works at any lg width; that is the server's.
 *
 * Escape (master-desktop.html L1312 order): closes the panel only when it is
 *   open and nothing above it is: no open sheet, modal, popover or dialog
 *   (`overlayOpen/1`). A key typed into a field is the field's.
 *
 * F6 / Shift+F6 (direction canvas, edge 2): focus cycles
 *   #sidebar -> #chat-list -> composer (#compose-form) -> #details-panel,
 *   skipping panes that are absent or not displayed.
 */

import ClientState from "../client_state.js"

export const NAMESPACE = "details_panel"
export const RESTORE_QUERY = "(min-width: 1280px)"
export const PANES = ["#sidebar", "#chat-list", "#compose-form", "#details-panel"]

export const keyFor = (userId) => `open:${userId || "anon"}`

export function wideEnough(win = typeof window !== "undefined" ? window : undefined) {
  return !!(win && typeof win.matchMedia === "function" && win.matchMedia(RESTORE_QUERY).matches)
}

// Is the element painted? `getClientRects()` is empty for display:none
// (and for anything under it), which is how a closed popover or modal and a
// `hidden lg:flex` pane below lg read.
function shown(el) {
  return !!el && typeof el.getClientRects === "function" && el.getClientRects().length > 0
}

/**
 * Anything open above the panel. A sheet always renders with
 * aria-modal="true", so its `data-open` decides; anything else counts when
 * it is painted.
 */
export function overlayOpen(doc) {
  if (!doc || typeof doc.querySelectorAll !== "function") return false
  const candidates = doc.querySelectorAll(
    '[aria-modal="true"], [role="dialog"], [role="alertdialog"], dialog[open], [popover]'
  )

  for (const el of candidates) {
    const dataOpen = el.getAttribute && el.getAttribute("data-open")
    if (dataOpen === "false") continue
    if (dataOpen === "true") return true
    if (el.matches && el.matches("[popover]") && !safeMatches(el, ":popover-open")) continue
    if (shown(el)) return true
  }

  return false
}

function safeMatches(el, sel) {
  try {
    return el.matches(sel)
  } catch (_e) {
    return false
  }
}

function editable(target) {
  if (!target) return false
  if (target.isContentEditable) return true
  const tag = (target.tagName || "").toUpperCase()
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
}

const FOCUSABLE =
  'textarea, [aria-current="page"], a[href], button:not([disabled]), input:not([type="hidden"]), [tabindex]:not([tabindex="-1"])'

export function visiblePanes(doc) {
  return PANES.map((sel) => doc.querySelector(sel)).filter(shown)
}

export function nextPane(panes, active, backwards) {
  if (panes.length === 0) return null
  const at = panes.findIndex((p) => p === active || (p.contains && active && p.contains(active)))
  if (at === -1) return backwards ? panes[panes.length - 1] : panes[0]
  const step = backwards ? -1 : 1
  return panes[(at + step + panes.length) % panes.length]
}

function focusPane(pane) {
  const target = (pane.querySelector && pane.querySelector(FOCUSABLE)) || pane
  if (target === pane && pane.setAttribute && !pane.hasAttribute("tabindex")) {
    pane.setAttribute("tabindex", "-1")
  }
  target.focus && target.focus()
}

const DetailsPanelState = {
  mounted() {
    const doc = this.el.ownerDocument || (typeof document !== "undefined" ? document : null)
    this.doc = doc

    this.handleEvent("details:changed", ({ open }) => {
      ClientState.set(NAMESPACE, keyFor(this.el.dataset.userId), open === true)
    })

    this.onKeydown = (event) => {
      if (event.key === "Escape") {
        if (event.defaultPrevented || editable(event.target)) return
        if (!doc || !doc.querySelector("#details-panel")) return
        if (overlayOpen(doc)) return
        this.pushEvent("details_close", {})
        return
      }

      if (event.key === "F6") {
        if (!doc) return
        const pane = nextPane(visiblePanes(doc), doc.activeElement, event.shiftKey)
        if (!pane) return
        event.preventDefault()
        focusPane(pane)
      }
    }

    if (doc && doc.addEventListener) doc.addEventListener("keydown", this.onKeydown)

    const stored = ClientState.get(NAMESPACE, keyFor(this.el.dataset.userId), null)
    if (stored === true && this.el.dataset.open !== "true" && wideEnough()) {
      this.pushEvent("details_restore", {})
    }
  },

  destroyed() {
    if (this.doc && this.doc.removeEventListener) {
      this.doc.removeEventListener("keydown", this.onKeydown)
    }
  },
}

export default DetailsPanelState
