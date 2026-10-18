// Reconnect escalation engine (task 01a12b10, "Quiet reconnect").
//
// Decides WHEN a dropped LiveView connection deserves the red toast. Stock
// LiveView shows #client-error / #server-error through `phx-disconnected`
// 500 ms into any drop, so a phone radio waking up or a crash plus fast
// remount flashes error red for a routine reconnect. This module is the pure
// part of the replacement: no DOM, no globals, injectable timers (the same
// opts.setTimeout / opts.clearTimeout / opts.now shape as reload_guard.js).
// The app.js controller (stage 2) feeds it socket events and renders the
// states it emits.
//
// STATES, emitted through onState({state, kind}) once per transition:
//
//   idle          nothing is wrong
//   pending       lost, still inside the grace period: nothing is shown
//   reconnecting  lost for longer than graceMs: the quiet line + pill
//   up_to_date    recovered: "Up to date" for upToDateMs, then idle
//   escalated     red toast; kind "client" (#client-error) or "server"
//
// ESCALATION: red when ANY of these holds, whichever comes first:
//
//   failures >= attempts                    (failed RETRIES since the loss)
//   now - firstLossAt >= seconds * 1000     (a deadline timer, so it fires with zero failures)
//   offline for offlineGraceMs (3 s)        (kind "client"; see OFFLINE below)
//
// OFFLINE. navigator.onLine === false (or an offline event) starts a loss
// but goes red only once it has stayed offline for offlineGraceMs, default
// 3000. It used to go red at once, and a phone resuming the app from the
// background often reports offline for a moment while its radio wakes, so
// every resume flashed the red toast (product decision, 2026-10-11). Back online inside
// the grace and the offline clock resets; the ordinary attempt and time
// limits still apply to the loss throughout.
//
// BACKGROUND AND FREEZE. The limits count only time the page is in front
// of someone. Chrome on Android freezes a backgrounded page: no JS runs,
// the socket dies, and on resume the wall clock has jumped by minutes. A
// loss that began before the freeze then read as "lost for minutes" and
// went red at once, a second before the reconnect landed (product decision, 2026-10-11,
// still seen after the offline grace). So:
//   - while isHidden() is true nothing escalates;
//   - resumed() (app.js: visibilitychange to visible, pageshow, resume)
//     restarts the loss clock: failures, time and the offline clock;
//   - check() also restarts the clock when it finds a gap of freezeGapMs
//     (2500) since its last run, because frozen timers can fire before the
//     visibility event does. A 1 s tick runs while lost so that, when
//     visible, consecutive checks are never further apart than that.
//
// WHAT COUNTS AS A FAILURE. socketClosed() is fed every socket close. The
// first close after a loss is the drop itself, not a retry, so it starts the
// loss and is not counted; every later close is one failed retry. (Counting
// the drop made attempts=10 mean "the drop plus 9 retries", which went red
// about 4.3 s into a fast-failing outage such as a deploy restart.)
// attemptFailed() counts unconditionally; app.js uses it for server-side
// join errors, where the socket stays up.
//
// WHY THE DEFAULTS ARE attempts=11, seconds=10 AND NOT attempts=3.
// Phoenix 1.8.5's stock socket backoff (deps/phoenix/assets/js/phoenix/
// socket.js `reconnectAfterMs`, measured 2026-10-11 from the hex tarball
// whose sha256 matches mix.lock; phoenix_live_view 1.1.27 does not override
// it and app.js passes no reconnectAfterMs) is
//
//   [10, 50, 100, 150, 200, 250, 500, 1000, 2000][tries - 1] || 5000
//
// and timer.js waits timerCalc(tries + 1) before retry tries + 1, so retry k
// starts this long after the drop (sum of the first k delays):
//
//   retry k      1    2    3    4    5    6     7     8     9     10    11     12
//   delay ms     10   50   100  150  200  250   500   1000  2000  5000  5000   5000
//   cumulative   10   60   160  310  510  760   1260  2260  4260  9260  14260  19260
//
// plus each try's own connect time. When every retry fails at once (refused
// connections), failed retry n closes at about cumulative[n]. attempts=3
// would go red at about 160 ms, which is the bug this replaces. attempts=10
// would go red at about 9.26 s, before the 10 s limit; with attempts=11 the
// 11th close is not before about 14.26 s, so with fast failures seconds=10
// decides and red comes at 10.0 s. The attempt limit is a backstop for when
// connect times stretch the schedule. Both are runtime config:
// RECONNECT_ESCALATE_ATTEMPTS / RECONNECT_ESCALATE_SECONDS ->
// PlatformWeb.ReconnectEscalation.config/0 -> <meta name="reconnect-escalation">.
// The same defaults and clamps live in PlatformWeb.ReconnectEscalation; keep
// the two in step.

export const DEFAULT_ATTEMPTS = 11
export const DEFAULT_SECONDS = 10
export const MAX_ATTEMPTS = 100
export const MAX_SECONDS = 300

const LOST = new Set(["pending", "reconnecting", "escalated"])

// A positive whole number from a number or a decimal string, else null.
function positiveInt(value) {
  let n
  if (typeof value === "number") {
    n = value
  } else if (typeof value === "string" && /^\s*-?\d+\s*$/.test(value)) {
    n = Number.parseInt(value, 10)
  } else {
    return null
  }
  if (!Number.isInteger(n) || n <= 0) return null
  return n
}

function threshold(value, fallback, max) {
  const n = positiveInt(value)
  if (n == null) return fallback
  return Math.min(Math.max(n, 1), max)
}

// raw is {attempts, seconds}, usually the meta tag's dataset (strings).
// Missing, non-numeric, 0 or negative values fall back to 11/10; attempts is
// clamped to 1..100 and seconds to 1..300.
export function parseThresholds(raw) {
  const r = raw || {}
  return {
    attempts: threshold(r.attempts, DEFAULT_ATTEMPTS, MAX_ATTEMPTS),
    seconds: threshold(r.seconds, DEFAULT_SECONDS, MAX_SECONDS),
  }
}

export function createReconnectEscalation(opts = {}) {
  const { attempts, seconds } = parseThresholds({ attempts: opts.attempts, seconds: opts.seconds })
  const graceMs = opts.graceMs == null ? 300 : opts.graceMs
  const upToDateMs = opts.upToDateMs == null ? 1500 : opts.upToDateMs
  const offlineGraceMs = opts.offlineGraceMs == null ? 3000 : opts.offlineGraceMs
  const freezeGapMs = opts.freezeGapMs == null ? 2500 : opts.freezeGapMs
  const tickMs = opts.tickMs == null ? 1000 : opts.tickMs
  const isHidden = opts.isHidden || (() => false)
  const isOnline = opts.isOnline || (() => true)
  const now = opts.now || (() => Date.now())
  const setT = opts.setTimeout || ((fn, ms) => setTimeout(fn, ms))
  const clearT = opts.clearTimeout || ((t) => clearTimeout(t))
  const onState = opts.onState || (() => {})

  let state = "idle"
  let kind = null
  let failures = 0
  let firstLossAt = null
  let dropClosed = false
  let graceTimer = null
  let deadlineTimer = null
  let upToDateTimer = null
  let offlineSince = null
  let offlineTimer = null
  let tickTimer = null
  let lastCheckAt = null
  let emitted = { state: "idle", kind: null }

  function clear(t) {
    if (t != null) clearT(t)
    return null
  }

  function clearAll() {
    graceTimer = clear(graceTimer)
    deadlineTimer = clear(deadlineTimer)
    upToDateTimer = clear(upToDateTimer)
    offlineTimer = clear(offlineTimer)
    tickTimer = clear(tickTimer)
  }

  // Emit only when the visible pair changes, so a screen reader announces
  // each state once rather than on every retry.
  function go(next, nextKind = null) {
    state = next
    kind = nextKind
    if (emitted.state === next && emitted.kind === nextKind) return
    emitted = { state: next, kind: nextKind }
    onState({ state: next, kind: nextKind })
  }

  function escalate(k) {
    graceTimer = clear(graceTimer)
    deadlineTimer = clear(deadlineTimer)
    offlineTimer = clear(offlineTimer)
    tickTimer = clear(tickTimer)
    go("escalated", k)
  }

  // Re-evaluate every escalation rule. Returns true when it escalated.
  function check() {
    if (!LOST.has(state)) return false
    if (state !== "escalated") {
      const t = now()
      if (lastCheckAt != null && t - lastCheckAt >= freezeGapMs) restartClock()
      lastCheckAt = t
      if (isHidden()) return false
    }
    if (offlineExpired()) {
      escalate("client")
      return true
    }
    if (state === "escalated") return true
    if (failures >= attempts || now() - firstLossAt >= seconds * 1000) {
      escalate(kind)
      return true
    }
    return false
  }

  // True once the browser has been offline for offlineGraceMs. The offline
  // clock starts at the first offline reading or offline() event and stops
  // only at online() or recovery, so a flapping navigator.onLine cannot
  // restart it. Starting it arms a timer so check() runs when the grace
  // ends even if no other event arrives.
  function offlineExpired() {
    if (offlineSince == null) {
      if (isOnline() !== false) return false
      startOffline()
    }
    return now() - offlineSince >= offlineGraceMs
  }

  function startOffline() {
    offlineSince = now()
    armOffline(offlineGraceMs)
  }

  function armOffline(ms) {
    offlineTimer = clear(offlineTimer)
    offlineTimer = setT(() => {
      offlineTimer = null
      if (state !== "pending" && state !== "reconnecting") return
      if (check()) return
      if (offlineSince != null) armOffline(Math.max(1, offlineGraceMs - (now() - offlineSince)))
    }, ms)
  }

  // A client loss outranks a server one: with the socket down, the server
  // error is moot. A server loss never downgrades a client one.
  function mergeKind(k) {
    if (kind === "client") return "client"
    return k === "client" ? "client" : k || kind || "client"
  }

  // Start the loss clock over: a resume or a detected freeze. The loss
  // itself (state, kind, dropClosed) is unchanged.
  function restartClock() {
    failures = 0
    firstLossAt = now()
    lastCheckAt = now()
    if (offlineSince != null) startOffline()
    armDeadline(seconds * 1000)
  }

  function tick() {
    tickTimer = clear(tickTimer)
    tickTimer = setT(() => {
      tickTimer = null
      if (state !== "pending" && state !== "reconnecting") return
      if (check()) return
      tick()
    }, tickMs)
  }

  // The page came back to the foreground.
  function resumed() {
    if (state !== "pending" && state !== "reconnecting") return
    restartClock()
    check()
  }

  function begin(k) {
    upToDateTimer = clear(upToDateTimer)
    failures = 0
    dropClosed = false
    firstLossAt = now()
    lastCheckAt = null
    go("pending", k)
    if (check()) return
    graceTimer = setT(() => {
      graceTimer = null
      if (state !== "pending") return
      if (check()) return
      go("reconnecting", kind)
    }, graceMs)
    armDeadline(seconds * 1000)
    tick()
  }

  // The time limit is enforced by check() alone (one comparison); the timer
  // only makes sure check() runs at the deadline when no event arrives. A
  // timer that fires a little early re-arms for the remainder.
  function armDeadline(ms) {
    deadlineTimer = clear(deadlineTimer)
    deadlineTimer = setT(() => {
      deadlineTimer = null
      if (state !== "pending" && state !== "reconnecting") return
      if (check()) return
      armDeadline(Math.max(1, seconds * 1000 - (now() - firstLossAt)))
    }, ms)
  }

  // Record a new kind. Only the red toast depends on kind, so only an
  // escalated state re-emits; reconnecting looks the same either way.
  function setKind(k) {
    const merged = mergeKind(k)
    if (merged === kind) return
    if (state === "escalated") go(state, merged)
    else kind = merged
  }

  function socketLost(k = "client") {
    if (!LOST.has(state)) {
      begin(k === "server" ? "server" : "client")
      return
    }
    setKind(k)
    check()
  }

  function attemptFailed(k = "client") {
    if (!LOST.has(state)) begin(k === "server" ? "server" : "client")
    else setKind(k)
    failures += 1
    check()
  }

  // A socket close. The first one after a loss is the drop's own close and
  // only starts (or joins) the loss; each later one is a failed retry.
  function socketClosed(k = "client") {
    if (!LOST.has(state)) begin(k === "server" ? "server" : "client")
    else setKind(k)
    if (!dropClosed) {
      dropClosed = true
      check()
      return
    }
    failures += 1
    check()
  }

  // navigator.onLine went false: a loss that goes red after offlineGraceMs.
  function offline() {
    if (!LOST.has(state)) begin("client")
    else setKind("client")
    if (offlineSince == null && LOST.has(state) && state !== "escalated") startOffline()
    check()
  }

  // Back online. connected says whether the LiveView is live right now
  // (socket open and the main view joined). An offline blip, or CDP offline
  // emulation, often never closes the websocket, so no rejoin and no
  // page-loading-stop follow: the connection is fine and red would stay
  // forever. Then recover here. Otherwise the socket still has to reconnect
  // and recovered() from the rejoin clears the red, as before.
  function online({ connected = false } = {}) {
    offlineSince = null
    offlineTimer = clear(offlineTimer)
    if (connected && LOST.has(state)) recovered({ changed: false })
  }

  function recovered({ changed = false } = {}) {
    if (!LOST.has(state)) return
    const wasPending = state === "pending"
    clearAll()
    failures = 0
    dropClosed = false
    firstLossAt = null
    offlineSince = null
    if (wasPending && !changed) {
      go("idle")
      return
    }
    go("up_to_date")
    upToDateTimer = setT(() => {
      upToDateTimer = null
      if (state === "up_to_date") go("idle")
    }, upToDateMs)
  }

  function destroy() {
    clearAll()
  }

  return {
    socketLost,
    socketClosed,
    attemptFailed,
    offline,
    online,
    recovered,
    resumed,
    destroy,
    getState: () => ({ state, kind, failures }),
    thresholds: { attempts, seconds },
  }
}
