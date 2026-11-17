// Meeting presence (task 01a1e82a stage 2): every exit and every kept call
// says so, a page load that would drop the call asks first, and the top bar
// turns amber while LiveKit reconnects.
//
// Imported by app.js, so it also runs on pages outside the shell (/admin,
// /canvases/:id). There it only shows the one-shot "You left <name>" toast a
// "Leave call and go" stashed before the full page load. Inside the shell the
// MeetingPresence hook (hooks/meeting_presence.js) feeds it the call state
// the server renders on `#meeting-presence`, and relays the server's
// `meeting_presence:toast` push_events.
//
// Toasts and dialogs are appended to <body>, outside every LiveView
// container, so a live navigation does not take them down (the same survival
// technique as `#meeting-audio-sink`).
//
// Persistence goes through `ClientState` only (npm test rejects direct
// localStorage). ClientState already falls back to memory; every call is
// still wrapped so a storage that throws cannot break a toast or the guard.
//
// The logic is `createMeetingPresence(env)`: everything it touches (storage,
// timers, the toast/dialog renderer, the bar element, navigation) comes in
// through `env`, so vitest drives it without a DOM. `installMeetingPresence`
// wires the real browser into it.

import ClientState from "./client_state.js"
import { formatElapsed } from "./hooks/meeting_bar.js"

export const NS = "meeting-presence"
export const RECONNECT_LOST_MS = 30000
export const REJOIN_TOAST_MS = 10000
export const TOAST_MS = 6000
const STASH_KEY = "stash"
const STASH_TTL_MS = 60000
const STILL_IN_TTL_MS = 12 * 60 * 60 * 1000
const LEAVE_REPLY_TIMEOUT_MS = 2500

// ── Copy (approved prototype 01a1e823, direction A; do not paraphrase) ───

// "Dalton, Brosnan and Scribe"; a longer room ends "… and 2 others".
export function joinNames(names = [], count = names.length) {
  const shown = names.slice(0, 3)
  const rest = Math.max(0, count - shown.length)
  if (shown.length === 0) return `${count} ${count === 1 ? "person" : "people"}`
  if (rest > 0) return `${shown.join(", ")} and ${rest} ${rest === 1 ? "other" : "others"}`
  if (shown.length === 1) return shown[0]
  return `${shown.slice(0, -1).join(", ")} and ${shown[shown.length - 1]}`
}

export function joinedToast({ name, mic = true, camera = false }, phone) {
  return {
    kind: "joined",
    title: `You joined ${name}`,
    body: phone
      ? "The call stays on across tabs."
      : `${mic ? "Mic on" : "Mic off"} · ${camera ? "camera on" : "camera off"}. The call stays on while you switch tabs.`,
  }
}

export function stillInToast({ name }, phone) {
  return phone
    ? { kind: "still-in", title: `Still in ${name}`, body: "Tap the green bar to go back." }
    : {
        kind: "still-in",
        title: `You're still in ${name}`,
        body: "Switching tabs never leaves the call. Use Leave to go.",
        action: { label: "Back to call", value: "back" },
      }
}

export function leftToast({ name, names = [], count = names.length }, phone) {
  if (!count) return { kind: "ended", title: "Call ended" }
  const verb = count === 1 ? "is" : "are"
  return {
    kind: "left",
    title: `You left ${name}`,
    body: phone
      ? `${count} ${count === 1 ? "person" : "people"} ${verb} still in the room.`
      : `${joinNames(names, count)} ${verb} still in the room.`,
    action: { label: "Rejoin", value: "rejoin" },
    duration: REJOIN_TOAST_MS,
  }
}

export function endedToast({ host, name }) {
  return { kind: "host-ended", title: `${host || "The host"} ended ${name}` }
}

export function reconnectingToast(phone) {
  return phone
    ? { kind: "reconnecting", title: "Reconnecting…", body: "You haven't left the call.", duration: 0 }
    : {
        kind: "reconnecting",
        title: "Connection dropped. Reconnecting…",
        body: "You haven't left. Others see you as reconnecting.",
        duration: 0,
      }
}

export function lostToast() {
  return { kind: "lost", title: "Connection lost", duration: 0 }
}

export function guardDialog({ destination, name }) {
  return {
    kind: "guard",
    variant: "dialog",
    title: `${destination} opens outside the app`,
    body: `Going there reloads the page, which would end your place in ${name}. Open it in a new tab to stay in the call.`,
    buttons: [
      { label: "Cancel", value: "cancel", tone: "neutral" },
      { label: "Leave call and go", value: "leave", tone: "error" },
      { label: "Open in new tab", value: "newtab", tone: "primary" },
    ],
  }
}

export function guardSheet({ nativeApp }) {
  return {
    kind: "guard",
    variant: "sheet",
    title: "This page opens outside the app",
    body: "Opening it would end your call.",
    buttons: [
      { label: nativeApp ? "Open in Safari" : "Open in new tab", value: "newtab", tone: "primary" },
      { label: "Leave call and open", value: "leave", tone: "error" },
      { label: "Cancel", value: "cancel", tone: "neutral" },
    ],
  }
}

export function leaveSheet({ name, others = 0, canEnd = false }) {
  const buttons = [{ label: "Leave call", value: "leave", tone: "error" }]
  if (canEnd) buttons.push({ label: "End for everyone", value: "end", tone: "error-outline" })
  buttons.push({ label: "Stay in call", value: "cancel", tone: "neutral" })
  return {
    kind: "leave",
    variant: "sheet",
    title: `Leave ${name}?`,
    body: `${others} ${others === 1 ? "other is" : "others are"} still in the room.`,
    buttons,
  }
}

// "/admin/users" -> "Admin", "/canvases/1" -> "Canvases".
export function destinationLabel(pathname) {
  const first = String(pathname || "/").split("/").filter(Boolean)[0]
  if (!first) return "This page"
  let word = first
  try {
    word = decodeURIComponent(first)
  } catch (_) {
    /* keep the raw segment */
  }
  word = word.replace(/[-_]+/g, " ")
  return word.charAt(0).toUpperCase() + word.slice(1)
}

// ── Routes ───────────────────────────────────────────────────────────────

// `patterns` are the `live_session :authenticated` route paths the server
// renders from the router (`/chat/:space_slug`, …). A `:param` segment
// matches any one segment and a `*glob` the rest.
export function routeMatches(pathname, patterns = []) {
  const segs = String(pathname || "/").split("/").filter(Boolean)
  return patterns.some((pattern) => {
    const parts = String(pattern).split("/").filter(Boolean)
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]
      if (part.startsWith("*")) return true
      if (i >= segs.length) return false
      if (part.startsWith(":")) continue
      if (part !== segs[i]) return false
    }
    return parts.length === segs.length
  })
}

const RAW_ASSET_PATH = /^\/chat\/attachments\/[0-9a-f-]{36}$|^\/files\/blob\/[^/]+/i

// A click that would load a whole new document in this tab, or null.
// Live links (`data-phx-link="patch"`, or a "redirect" that stays inside the
// authenticated live_session) keep the call and are left alone, as are new
// tabs, modifier clicks, downloads, in-page anchors and other origins.
export function classifyClick(event, { location, patterns = [] }) {
  if (!event || event.defaultPrevented) return null
  if (typeof event.button === "number" && event.button !== 0) return null
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return null
  const target = event.target
  const anchor = target && typeof target.closest === "function" ? target.closest("a[href]") : null
  if (!anchor) return null
  const frame = (anchor.getAttribute("target") || "").toLowerCase()
  if (frame && frame !== "_self") return null
  if (anchor.hasAttribute("download")) return null
  const raw = anchor.getAttribute("href")
  if (!raw || raw.startsWith("#") || /^(javascript|mailto|tel|sms):/i.test(raw)) return null
  let url
  try {
    url = new URL(raw, location.href)
  } catch (_) {
    return null
  }
  if (url.origin !== location.origin) return null
  if (url.pathname === location.pathname && url.search === location.search && url.hash) return null

  const phxLink = anchor.getAttribute("data-phx-link")
  if (phxLink === "patch") return null
  const inAppLink = anchor.getAttribute("data-in-app-link") === "path"
  // in_app_links.js opens raw assets in the image layer, not a page load.
  if (inAppLink && RAW_ASSET_PATH.test(url.pathname)) return null
  if ((phxLink === "redirect" || inAppLink) && routeMatches(url.pathname, patterns)) return null

  return { href: url.href, path: url.pathname + url.search + url.hash, pathname: url.pathname }
}

// The call state `#meeting-presence` carries (see shell.html.heex).
export function readState(ds = {}) {
  let patterns = []
  try {
    patterns = JSON.parse(ds.authRoutes || "[]")
  } catch (_) {
    patterns = []
  }
  return {
    inCall: ds.callActive === "true",
    meetingId: ds.meetingId || null,
    name: ds.meetingName || "Meeting",
    returnPath: ds.returnPath || "/meetings",
    inCallRoom: ds.callRoom === "true",
    patterns: Array.isArray(patterns) ? patterns : [],
    othersCount: Math.max(0, parseInt(ds.othersCount || "0", 10) || 0),
    canEnd: ds.canEnd === "true",
  }
}

// ── The controller ───────────────────────────────────────────────────────

const NO_CALL = {
  inCall: false,
  meetingId: null,
  name: "Meeting",
  returnPath: "/meetings",
  inCallRoom: false,
  patterns: [],
  othersCount: 0,
  canEnd: false,
}

export function createMeetingPresence(env = {}) {
  const storage = env.storage || ClientState
  const now = env.now || (() => Date.now())
  const setTimer = env.setTimeout || ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = env.clearTimeout || ((t) => clearTimeout(t))
  const setTick = env.setInterval || ((fn, ms) => setInterval(fn, ms))
  const clearTick = env.clearInterval || ((t) => clearInterval(t))
  const location = env.location || { href: "http://localhost/", origin: "http://localhost", pathname: "/" }
  const isPhone = env.isPhone || (() => false)
  const isNativeApp = env.isNativeApp || (() => false)
  const ui = env.ui || {}
  const openWindow = env.openWindow || (() => {})
  const assign = env.assign || (() => {})
  const disconnectRoom = env.disconnectRoom || (() => {})
  const connectionOwner = env.connectionOwner || (() => null)

  let call = { ...NO_CALL }
  let host = null
  let lastSeenMeetingId = null
  let explicitLeave = false
  let conn = { state: "idle", since: 0, lost: false }
  let connTick = null
  let lostTimer = null
  let connToast = null
  const memory = new Map()

  // Storage that cannot throw: a failing store degrades to this tab's memory.
  const store = {
    get(key) {
      try {
        const v = storage.get(NS, key, null)
        if (v != null) return v
      } catch (_) {
        /* fall through to memory */
      }
      return memory.has(key) ? memory.get(key) : null
    },
    set(key, value, opts) {
      memory.set(key, value)
      try {
        storage.set(NS, key, value, opts)
      } catch (_) {
        /* memory already holds it */
      }
    },
    remove(key) {
      memory.delete(key)
      try {
        storage.remove(NS, key)
      } catch (_) {
        /* nothing to undo */
      }
    },
  }

  function toast(spec) {
    try {
      return (ui.toast && ui.toast(spec, onToastAction)) || null
    } catch (_) {
      return null
    }
  }

  function dismiss(handle) {
    try {
      if (handle && typeof handle.dismiss === "function") handle.dismiss()
    } catch (_) {
      /* already gone */
    }
  }

  function choose(spec) {
    try {
      return Promise.resolve(ui.choose ? ui.choose(spec) : "cancel")
    } catch (_) {
      return Promise.resolve("cancel")
    }
  }

  function navigate(path) {
    if (!path) return
    if (host && typeof host.navigate === "function") host.navigate(path)
    else assign(path)
  }

  function onToastAction(value, spec) {
    if (value === "back") navigate(call.returnPath)
    if (value === "rejoin") navigate((spec && spec.returnPath) || call.returnPath)
  }

  // The guard and the unload prompt are armed only in a call, before any
  // explicit leave, and on a page of the authenticated live_session (the
  // only place a live call survives a navigation).
  function armed() {
    return call.inCall && !explicitLeave && routeMatches(location.pathname, call.patterns)
  }

  function apply(next) {
    const wasInCall = call.inCall
    call = { ...NO_CALL, ...next }
    if (call.inCall && !wasInCall) explicitLeave = false
    if (!call.inCall) resetConnection()
  }

  function maybeStillIn() {
    const key = `still-in:${call.meetingId}`
    if (store.get(key)) return
    store.set(key, true, { ttlMs: STILL_IN_TTL_MS })
    toast(stillInToast(call, isPhone()))
  }

  // ── Bar (reconnecting / lost) ──
  function bar() {
    try {
      return (ui.bar && ui.bar()) || null
    } catch (_) {
      return null
    }
  }

  function syncBar() {
    const el = bar()
    if (!el) return
    if (conn.state === "reconnecting") {
      el.setAttribute("data-state", "reconnecting")
      if (conn.lost) el.setAttribute("data-lost", "true")
      else el.removeAttribute("data-lost")
      const counter = el.querySelector && el.querySelector("[data-conn-timer]")
      if (counter) counter.textContent = formatElapsed((now() - conn.since) / 1000)
    } else {
      el.setAttribute("data-state", "connected")
      el.removeAttribute("data-lost")
    }
  }

  function stopConnTimers() {
    if (connTick != null) clearTick(connTick)
    if (lostTimer != null) clearTimer(lostTimer)
    connTick = null
    lostTimer = null
  }

  function resetConnection() {
    stopConnTimers()
    dismiss(connToast)
    connToast = null
    const was = conn.state
    conn = { state: "idle", since: 0, lost: false }
    if (was !== "idle") syncBar()
  }

  function enterLost() {
    if (conn.state !== "reconnecting") conn = { state: "reconnecting", since: now(), lost: false }
    if (conn.lost) return
    conn.lost = true
    if (lostTimer != null) clearTimer(lostTimer)
    lostTimer = null
    dismiss(connToast)
    connToast = toast(lostToast())
    syncBar()
  }

  function onRoomState(state) {
    if (state === "reconnecting") {
      if (conn.state === "reconnecting") return
      conn = { state: "reconnecting", since: now(), lost: false }
      connTick = setTick(syncBar, 1000)
      lostTimer = setTimer(enterLost, RECONNECT_LOST_MS)
      connToast = toast(reconnectingToast(isPhone()))
      syncBar()
    } else if (state === "lost") {
      if (conn.state !== "reconnecting") {
        conn = { state: "reconnecting", since: now(), lost: false }
        connTick = setTick(syncBar, 1000)
      }
      enterLost()
    } else if (state === "connected" || state === "reconnected" || state === "disconnected") {
      resetConnection()
    }
  }

  function rejoin() {
    const owner = connectionOwner()
    if (owner && owner._connLost && typeof owner._manualRejoin === "function") {
      owner._manualRejoin()
    } else {
      navigate(call.returnPath)
    }
  }

  // The bar's own Leave (`[data-bar-leave]`) runs the server leave through
  // its phx-click; this only disarms the guards and, after a loss, lets the
  // call client drop the dead room the way its old banner did.
  function noteBarLeave() {
    explicitLeave = true
    const owner = connectionOwner()
    if (conn.lost && owner && owner._connLost && typeof owner._leaveAfterLoss === "function") {
      owner._leaveAfterLoss()
    }
    resetConnection()
  }

  // The explicit leave the guard and the phone sheet use: the same server
  // path as the bar's Leave (ShellLive `meeting_presence_leave`, which stamps
  // left_at), then drop the LiveKit room. `done(reply)` runs once, on the
  // server's reply or after a timeout so a lost reply cannot strand the user.
  function explicitLeaveNow(done = () => {}) {
    explicitLeave = true
    let finished = false
    let timer = null
    const finish = (reply) => {
      if (finished) return
      finished = true
      if (timer != null) clearTimer(timer)
      done(reply || null)
    }
    if (host && typeof host.pushLeave === "function") {
      timer = setTimer(() => finish(null), LEAVE_REPLY_TIMEOUT_MS)
      try {
        host.pushLeave((reply) => finish(reply))
      } catch (_) {
        finish(null)
      }
    } else {
      finish(null)
    }
    try {
      disconnectRoom()
    } catch (_) {
      /* already gone */
    }
    resetConnection()
  }

  function leaveAndGo(hit) {
    const name = call.name
    const returnPath = call.returnPath
    explicitLeaveNow((reply) => {
      const left = reply && reply.left ? reply.left : { name, names: [], count: call.othersCount }
      store.set(STASH_KEY, { ...left, name: left.name || name, return_path: left.return_path || returnPath }, { ttlMs: STASH_TTL_MS })
      assign(hit.href)
    })
  }

  function onClick(event) {
    if (!armed()) return null
    const hit = classifyClick(event, { location, patterns: call.patterns })
    if (!hit) return null
    event.preventDefault()
    if (typeof event.stopImmediatePropagation === "function") event.stopImmediatePropagation()
    else if (typeof event.stopPropagation === "function") event.stopPropagation()
    const spec = isPhone()
      ? guardSheet({ nativeApp: isNativeApp() })
      : guardDialog({ destination: destinationLabel(hit.pathname), name: call.name })
    return choose(spec).then((choice) => {
      if (choice === "newtab") openWindow(hit.href)
      else if (choice === "leave") leaveAndGo(hit)
      return choice
    })
  }

  function onBeforeUnload(event) {
    if (!armed()) return undefined
    event.preventDefault()
    // Older engines read returnValue; the text itself is never shown.
    event.returnValue = ""
    return ""
  }

  function openLeaveSheet() {
    if (!call.inCall) return Promise.resolve("cancel")
    return choose(leaveSheet({ name: call.name, others: call.othersCount, canEnd: call.canEnd })).then(
      (choice) => {
        if (choice === "leave") {
          explicitLeaveNow((reply) => {
            if (reply && reply.left) toast(leftToast(reply.left, isPhone()))
          })
        } else if (choice === "end" && host && typeof host.pushEnd === "function") {
          explicitLeave = true
          host.pushEnd()
        }
        return choice
      },
    )
  }

  function onServerEvent(payload = {}) {
    const phone = isPhone()
    if (payload.kind === "joined") {
      toast(joinedToast(payload, phone))
    } else if (payload.kind === "left") {
      explicitLeave = true
      resetConnection()
      toast({ ...leftToast(payload, phone), returnPath: payload.return_path })
    } else if (payload.kind === "ended") {
      explicitLeave = true
      resetConnection()
      try {
        disconnectRoom()
      } catch (_) {
        /* already gone */
      }
      toast(endedToast(payload))
    }
  }

  function showStashed() {
    const stash = store.get(STASH_KEY)
    if (!stash) return
    store.remove(STASH_KEY)
    toast({ ...leftToast(stash, isPhone()), returnPath: stash.return_path })
  }

  return {
    // The shell hook mounted: a NEW LiveView after a live navigation, or the
    // first one of this page load. The same call seen on the previous mount
    // means a navigation kept it, which is when "still in" shows (once per
    // meeting id).
    mount(state, hostApi) {
      host = hostApi || null
      const prev = lastSeenMeetingId
      apply(state)
      if (call.inCall && !call.inCallRoom && prev && prev === call.meetingId) maybeStillIn()
      lastSeenMeetingId = call.inCall ? call.meetingId : null
      syncBar()
    },
    update(state) {
      apply(state)
      lastSeenMeetingId = call.inCall ? call.meetingId : null
      syncBar()
    },
    unmount(hostApi) {
      if (!hostApi || host === hostApi) host = null
    },
    onServerEvent,
    onRoomState,
    onClick,
    onBeforeUnload,
    openLeaveSheet,
    rejoin,
    noteBarLeave,
    showStashed,
    syncBar,
    armed,
    state: () => ({ ...call, conn: { ...conn }, explicitLeave }),
  }
}

// ── Browser wiring ───────────────────────────────────────────────────────

const TONE_CLASS = {
  primary: "bg-success text-success-content",
  error: "bg-error text-error-content",
  "error-outline": "border border-error text-error bg-base-100",
  neutral: "bg-base-200 text-base-content",
}

function el(doc, tag, className, text) {
  const node = doc.createElement(tag)
  if (className) node.className = className
  if (text != null) node.textContent = text
  return node
}

// Real-DOM toast + dialog renderer. Token slots only: toasts, dialogs and
// sheets are base-100 / base-content, Leave and destructive actions error,
// the primary action success.
export function createDomUi(doc, win, { isPhone }) {
  function host() {
    let node = doc.getElementById("meeting-presence-toasts")
    if (!node) {
      node = el(
        doc,
        "div",
        "pointer-events-none fixed inset-x-4 bottom-[calc(env(safe-area-inset-bottom)+5rem)] z-[70] flex flex-col items-stretch gap-2 sm:inset-x-auto sm:bottom-4 sm:right-4 sm:w-[22rem]",
      )
      node.id = "meeting-presence-toasts"
      node.setAttribute("aria-live", "polite")
      doc.body.appendChild(node)
    }
    return node
  }

  function toast(spec, onAction) {
    const node = el(
      doc,
      "div",
      "pointer-events-auto flex items-start gap-3 rounded-xl border border-edge bg-base-100 p-3 text-base-content shadow-lg",
    )
    node.setAttribute("role", "status")
    node.dataset.toast = spec.kind
    const text = el(doc, "div", "min-w-0 flex-1")
    text.appendChild(el(doc, "p", "text-sm font-semibold", spec.title))
    if (spec.body) text.appendChild(el(doc, "p", "mt-0.5 text-[13px] opacity-80", spec.body))
    node.appendChild(text)
    let timer = null
    const handle = {
      dismiss() {
        if (timer) win.clearTimeout(timer)
        node.remove()
      },
    }
    if (spec.action) {
      const btn = el(
        doc,
        "button",
        "shrink-0 rounded-lg bg-success px-2.5 py-1 text-[13px] font-semibold text-success-content",
        spec.action.label,
      )
      btn.type = "button"
      btn.dataset.toastAction = spec.action.value
      btn.addEventListener("click", () => {
        handle.dismiss()
        onAction && onAction(spec.action.value, spec)
      })
      node.appendChild(btn)
    }
    const close = el(doc, "button", "shrink-0 px-1 text-base leading-none opacity-60", "×")
    close.type = "button"
    close.setAttribute("aria-label", "Dismiss")
    close.addEventListener("click", () => handle.dismiss())
    node.appendChild(close)
    host().appendChild(node)
    const duration = spec.duration == null ? TOAST_MS : spec.duration
    if (duration > 0) timer = win.setTimeout(() => node.remove(), duration)
    return handle
  }

  function choose(spec) {
    return new Promise((resolve) => {
      const sheet = spec.variant === "sheet" || isPhone()
      const overlay = el(
        doc,
        "div",
        sheet
          ? "fixed inset-0 z-[80] flex items-end bg-base-content/40"
          : "fixed inset-0 z-[80] flex items-center justify-center bg-base-content/40 p-4",
      )
      overlay.id = "meeting-presence-dialog"
      overlay.dataset.dialog = spec.kind
      const panel = el(
        doc,
        "div",
        sheet
          ? "w-full rounded-t-2xl bg-base-100 p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] text-base-content shadow-xl"
          : "w-full max-w-md rounded-2xl bg-base-100 p-5 text-base-content shadow-xl",
      )
      panel.setAttribute("role", "dialog")
      panel.setAttribute("aria-modal", "true")
      const title = el(doc, "h2", "text-base font-semibold", spec.title)
      title.id = "meeting-presence-dialog-title"
      panel.setAttribute("aria-labelledby", title.id)
      panel.appendChild(title)
      panel.appendChild(el(doc, "p", "mt-1.5 text-sm opacity-80", spec.body))
      const row = el(
        doc,
        "div",
        sheet ? "mt-4 flex flex-col gap-2" : "mt-5 flex flex-wrap justify-end gap-2",
      )
      let settled = false
      const finish = (value) => {
        if (settled) return
        settled = true
        doc.removeEventListener("keydown", onKey, true)
        overlay.remove()
        resolve(value)
      }
      const onKey = (e) => {
        if (e.key === "Escape") finish("cancel")
      }
      let focusTarget = null
      for (const b of spec.buttons) {
        const btn = el(
          doc,
          "button",
          `rounded-xl px-4 py-2.5 text-sm font-semibold ${sheet ? "w-full" : ""} ${TONE_CLASS[b.tone] || TONE_CLASS.neutral}`,
          b.label,
        )
        btn.type = "button"
        btn.dataset.choice = b.value
        btn.addEventListener("click", () => finish(b.value))
        if (b.tone === "primary" || (!focusTarget && b.value === "cancel")) focusTarget = btn
        row.appendChild(btn)
      }
      panel.appendChild(row)
      overlay.appendChild(panel)
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay) finish("cancel")
      })
      doc.addEventListener("keydown", onKey, true)
      doc.body.appendChild(overlay)
      if (focusTarget) focusTarget.focus()
    })
  }

  return { toast, choose, bar: () => doc.getElementById("meeting-top-bar") }
}

// The bar's Leave, written as its MeetingBar hook does it, for paths that
// leave without that button (the guard, the phone sheet, a host end).
export function disconnectLiveKitRoom(win) {
  const room = win.__livekit_room || win.__livekitRoom
  if (!room) return
  try {
    const p = room.disconnect()
    if (p && typeof p.catch === "function") p.catch(() => {})
  } catch (_) {
    /* already gone */
  }
  win.__livekitRoom = null
  win.__livekit_room = null
  win.dispatchEvent(new CustomEvent("livekit:room-disconnected"))
}

let installed = null

export function installMeetingPresence(win = window, doc = document) {
  if (installed) return installed
  const phoneQuery = win.matchMedia ? win.matchMedia("(max-width: 639px)") : null
  const isPhone = () => !!(phoneQuery && phoneQuery.matches)
  const presence = createMeetingPresence({
    location: win.location,
    isPhone,
    isNativeApp: () => !!win.Capacitor?.isNativePlatform?.(),
    ui: createDomUi(doc, win, { isPhone }),
    openWindow: (href) => win.open(href, "_blank", "noopener"),
    assign: (href) => win.location.assign(href),
    disconnectRoom: () => disconnectLiveKitRoom(win),
    // MeetingClient registers itself as the owner of the (now hidden)
    // connection-state element; its Rejoin / Leave-after-loss live there.
    connectionOwner: () => doc.getElementById("meeting-connection-banner")?._owner || null,
  })

  // Capture phase on window: ahead of nav_pending.js and of LiveView's own
  // bubble-phase link handler, so a guarded click never starts a navigation.
  win.addEventListener("click", (e) => presence.onClick(e), true)
  // Registered at import, before any hook mounts: MeetingClient and the
  // watchdog skip their page-exit teardown on a beforeunload this listener
  // already cancelled, so "Stay" on the native prompt keeps the call.
  win.addEventListener("beforeunload", (e) => presence.onBeforeUnload(e))
  doc.addEventListener("livekit:state", (e) => presence.onRoomState(e?.detail?.state))
  doc.addEventListener("click", (e) => {
    const t = e.target
    if (!t || typeof t.closest !== "function") return
    if (t.closest("[data-bar-rejoin]")) presence.rejoin()
    else if (t.closest("[data-meeting-leave-sheet]")) presence.openLeaveSheet()
    else if (t.closest("[data-bar-leave]")) presence.noteBarLeave()
  })

  const show = () => presence.showStashed()
  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", show, { once: true })
  else show()

  installed = presence
  win.__meetingPresence = presence
  return presence
}

export function meetingPresence() {
  return installed
}
