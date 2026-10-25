// Optimistic navigation feedback (task 01a166be-b5b9 stage 2; design canvas
// 01a167b0 "Press and pending feedback", m2 + rules 2, 3, 4, 7, 8).
//
// WHAT IT DOES. A tap on a nav-shell link (bottom tab, desktop sidebar row, More
// sheet row, Settings row, chat list row) marks that control
// `data-nav-pending` in the same task as the click, before LiveView's round
// trip starts. CSS in app.css ("Optimistic navigation") keys on it:
//
//   * the tapped tab/row takes the current look at once, and the group's
//     current control is marked `data-nav-yielded` and drops it in the same
//     frame, so only one control ever looks current;
//   * the indicator pulses only after 150ms (CSS animation-delay);
//   * a More sheet row starts the sheet closing, and the pending cue moves
//     to the More tab (`.bottom-nav-tab[data-destination="more"]`);
//   * a chat row carries the leading bar, and only one row at a time.
//
// It stays a CLIENT hint: nothing is sent to the server, and the next server
// render (the destination's mount, or the patch reply) owns the current tab.
// A redirect replaces the whole shell, so on success the marked elements are
// simply gone; a patch keeps the row, so success clears the marks.
//
// WHY JS AND NOT ONLY `.phx-click-loading`. LiveView 1.1 does put
// `phx-click-loading` on a trusted-click navigate/patch link, but CSS cannot
// time out, roll back or toast, cannot reach the More tab from a row in the
// sheet's subtree without a document-wide `:has()`, and cannot keep a second
// chat row from also showing a bar while the first is still loading. One
// owner of the pending state means the rollback undoes exactly what was set.
//
// FAILURE CONTRACT (rule 7). A navigation has failed when either
//   (a) a `phx:page-loading-stop` arrives whose `to` is the pending target's
//       path but `window.location.pathname` is not that path afterwards, or
//   (b) no matching stop arrives within NAV_PENDING_TIMEOUT_MS (8000ms).
// On failure the marks and `phx-click-loading` come off, the yielded control
// gets its current look back, and a one-line toast says
// "Couldn't open <label>. Try again." The rollback is never silent. The only
// quiet clear is a control no longer in the document when its timer fires:
// the page around it was replaced, so there is nothing left to roll back.
//
// LATE SUCCESS. A navigation that times out can still land afterwards (the
// server was slow, not gone). When a stop for the rolled-back path arrives and
// the location now IS that path, the failure toast is withdrawn, so the page
// never shows the destination beside "Couldn't open" it.
//
// `onRollback` lets app.js release LiveView's pending link so "Try again"
// is a real retry (LiveView ignores a click on the href it is still loading).

export const NAV_PENDING_TIMEOUT_MS = 8000

export const NAV_CONTROL_SELECTOR =
  ".bottom-nav-tab[href], .sidebar-row[href], .more-sheet-row[href], .more-sheet-settings[href], .chat-list-row[href]"

const GROUP_SELECTOR = ".bottom-nav, [data-sidebar]"
const CURRENT_SELECTOR = ".bottom-nav-tab--active, .sidebar-row--current"
const SHEET_ROW_SELECTOR = ".more-sheet-row, .more-sheet-settings"
const MORE_TAB_SELECTOR = '.bottom-nav-tab[data-destination="more"]'
const TOAST_ID = "nav-rollback-toast"
export const TOAST_MS = 5000

export function rollbackMessage(label) {
  const name = (label || "").trim()
  return name ? `Couldn't open ${name}. Try again.` : "Couldn't open that page. Try again."
}

export function controlLabel(el) {
  const fromData = el.getAttribute("data-nav-label")
  if (fromData) return fromData
  // Chat rows (markup off-limits to this task): the name is the row's first
  // truncating span.
  const name = el.querySelector && el.querySelector("span.truncate")
  if (name && name.textContent && name.textContent.trim()) return name.textContent.trim()
  return el.getAttribute("aria-label") || ""
}

function pathOf(href, base) {
  try {
    return new URL(href, base).pathname
  } catch (_e) {
    return null
  }
}

function plainClick(e) {
  return !(e.button > 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)
}

export function renderToast(doc, message) {
  const old = doc.getElementById(TOAST_ID)
  if (old) old.remove()

  const wrap = doc.createElement("div")
  wrap.id = TOAST_ID
  wrap.setAttribute("role", "alert")
  wrap.setAttribute("data-role", "nav-rollback-toast")
  wrap.className = "toast toast-top toast-end z-50"

  const alert = doc.createElement("div")
  alert.className = "alert nav-rollback-toast"

  const icon = doc.createElement("span")
  icon.className = "hero-exclamation-circle size-5 shrink-0 text-error"
  icon.setAttribute("aria-hidden", "true")

  const text = doc.createElement("span")
  text.textContent = message

  alert.appendChild(icon)
  alert.appendChild(text)
  wrap.appendChild(alert)
  wrap.addEventListener("click", () => wrap.remove())
  doc.body.appendChild(wrap)
  return wrap
}

export function installNavPending({
  win = window,
  doc = document,
  timeoutMs = NAV_PENDING_TIMEOUT_MS,
  setTimer = (fn, ms) => win.setTimeout(fn, ms),
  clearTimer = (t) => win.clearTimeout(t),
  showToast = (message) => {
    const el = renderToast(doc, message)
    setTimer(() => el.remove(), TOAST_MS)
  },
  dismissToast = () => {
    const el = doc.getElementById(TOAST_ID)
    if (el) el.remove()
  },
  onRollback = () => {},
} = {}) {
  let pending = null
  // Path of the last timed-out navigation whose toast is still owed a retraction.
  let rolledBackPath = null

  function strip(p) {
    clearTimer(p.timer)
    for (const el of p.marked) {
      el.removeAttribute("data-nav-pending")
      el.classList.remove("phx-click-loading")
    }
    for (const el of p.yielded) el.removeAttribute("data-nav-yielded")
  }

  function clear() {
    if (!pending) return
    strip(pending)
    pending = null
  }

  function rollback(reason) {
    if (!pending) return
    const p = pending
    pending = null
    strip(p)
    if (!p.el.isConnected) return
    rolledBackPath = reason === "timeout" ? p.path : null
    showToast(rollbackMessage(p.label))
    onRollback({reason, path: p.path})
  }

  function yieldCurrent(control, marked, yielded) {
    const group = control.closest(GROUP_SELECTOR)
    if (!group) return
    for (const cur of group.querySelectorAll(CURRENT_SELECTOR)) {
      if (marked.includes(cur)) continue
      cur.setAttribute("data-nav-yielded", "")
      yielded.push(cur)
    }
  }

  function start(el) {
    const path = pathOf(el.getAttribute("href"), win.location.href)
    if (!path) return
    if (pending && pending.el === el) return
    clear()
    rolledBackPath = null

    const marked = [el]
    if (el.matches(SHEET_ROW_SELECTOR)) {
      const more = doc.querySelector(MORE_TAB_SELECTOR)
      if (more) marked.push(more)
    }
    const yielded = []
    for (const m of marked) yieldCurrent(m, marked, yielded)
    for (const m of marked) m.setAttribute("data-nav-pending", "")

    pending = {el, path, label: controlLabel(el), marked, yielded, timer: null}
    pending.timer = setTimer(() => rollback("timeout"), timeoutMs)
  }

  const onClick = (e) => {
    if (!plainClick(e)) return
    const target = e.target && e.target.closest ? e.target.closest(NAV_CONTROL_SELECTOR) : null
    if (!target) return
    start(target)
  }

  const onStop = (e) => {
    const detail = (e && e.detail) || {}
    const to = detail.to ? pathOf(detail.to, win.location.href) : null
    if (!pending) {
      if (rolledBackPath && to === rolledBackPath && win.location.pathname === rolledBackPath) {
        rolledBackPath = null
        dismissToast()
      }
      return
    }
    if (!to || to !== pending.path) return
    if (win.location.pathname === pending.path) {
      clear()
    } else {
      rollback("mismatch")
    }
  }

  // Capture phase: runs before LiveView's bubble-phase window click handler,
  // which calls stopImmediatePropagation on live links.
  win.addEventListener("click", onClick, true)
  win.addEventListener("phx:page-loading-stop", onStop)

  return {
    pending: () => pending,
    dispose() {
      clear()
      win.removeEventListener("click", onClick, true)
      win.removeEventListener("phx:page-loading-stop", onStop)
    },
  }
}
