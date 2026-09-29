/**
 * Which panel a game_stream frame shows while a session is running, and
 * whether an on-screen copy of the node takes the stream back from a twin
 * (task 01a0dbd6 stage 1). Pure, so the rules are tested without a browser.
 *
 * The cause these rules fix, reproduced on the moon rig with force_relay
 * through hive coturn: the node renders more than once in one page (chat
 * inline, desktop canvas panel, mobile overlay), and the page keeps one
 * claimant per session. A copy that became rendered took the stream and
 * suspended the one on screen into Connecting; nothing ever gave it back.
 * After the window crossed the `lg` breakpoint and came back, the desktop
 * panel sat on Connecting while the hidden overlay copy kept decoding frames
 * on a live RTCPeerConnection, and only a reload recovered it.
 *
 * Rules:
 *   - `panelFor`: Connecting only while the CURRENT peer connection has no
 *     decoded frame in the last `FRESH_MS`. Frames are tracked per pc (no
 *     hook-wide latch), so a frame from a closed pc never counts, and a
 *     status message never demotes a frame that is decoding. `ended` and
 *     `failed` win over everything; `building` and `unavailable` show as
 *     themselves.
 *   - `stuck`: `STUCK_MS` on Connecting with no frame on the current pc.
 *     The frame then offers "Still connecting" and a Reload button.
 *   - `reclaim`: a copy that is on screen, was suspended by a twin in the
 *     same page, and whose holder is no longer on screen (or gone) takes the
 *     stream back; among several such copies, the one that held it last.
 *     It never steals from a twin that is itself on screen, and a window
 *     another WINDOW took over (`suspended: false`) never claims on its
 *     own: that is what "Play here" is for.
 */

export const FRESH_MS = 2000
export const STUCK_MS = 10000

const RUNNING = ["building", "connecting", "live"]

function freshFrame(pcId, lastFrame, now) {
  return pcId != null && !!lastFrame && lastFrame.pcId === pcId && now - lastFrame.at <= FRESH_MS
}

/**
 * The panel for `serverState` (the session's last status) given the current
 * peer connection id and the last decoded frame `{pcId, at}` (ms).
 */
export function panelFor({ serverState, pcId, lastFrame, now }) {
  const state = serverState || "unavailable"
  if (!RUNNING.includes(state) || state === "building") return state
  return freshFrame(pcId, lastFrame, now) ? "live" : "connecting"
}

/**
 * The panel a copy shows when a twin in the same page takes the stream from
 * it (`suspend`), given the session's last status (task 01a0ee4f stage 2).
 * `panelFor` rules only the ACTIVE copy; this rules the one that gave the
 * stream up. A suspended copy has closed its pc, so for a running session
 * it shows "elsewhere" (where the stream went, "Playing in the canvas panel"
 * on the inline copy or "Playing in the chat" on the panel copy, with Play
 * here), never Connecting: a copy that gave its pc up does not say it is
 * connecting.
 * Rowan saw the inline chat copy sit on "Connecting..." beside the canvas
 * sidebar he had opened, which held the stream on its own pc. `ended` and
 * `failed` (and `unavailable`) still win and show as themselves.
 */
export function suspendedPanel({ serverState }) {
  const state = serverState || "unavailable"
  return RUNNING.includes(state) ? "elsewhere" : state
}

/**
 * The panel for a copy that is NOT the claimant while a twin in the same
 * page holds the session (task 01a0ee4f stage 3), or null to leave the
 * panel as it is. A copy that mounted hidden (the desktop canvas panel
 * under `hidden lg:flex` at a phone width) starts suspended and on its
 * mount-time panel, usually Connecting. When a breakpoint crossing renders
 * it while a twin holds the stream (the inline chat copy took it back), it
 * has no pc, so it must say where the stream is ("elsewhere", with Play
 * here), never Connecting. It does not take the stream itself: a resize is
 * not a deliberate open, and taking on every crossing would bounce the
 * stream between copies.
 *
 * Only a suspended copy's RUNNING panel (building / connecting / live) is
 * replaced: takeover (another WINDOW), ended, failed, unavailable and an
 * existing elsewhere are left alone, and a copy with no twin holding the
 * claim returns null so it attaches as before.
 */
export function twinHeldPanel({ active, suspended, twinHolds, serverState, panel }) {
  if (active || !suspended || !twinHolds) return null
  if (!RUNNING.includes(panel)) return null
  return suspendedPanel({ serverState })
}

/**
 * When the stuck clock started: the current pc's LAST decoded frame when it
 * has one (frames stopped then), else `connectingSince` (the pc never
 * decoded a frame, so the clock runs from when Connecting showed), else
 * `now`. Stage 6 (task 01a0dbd6): the clock used to start at whichever was
 * LATER, and Connecting itself shows `FRESH_MS` after the last frame, so
 * "Still connecting" came about 12-13 s after frames stopped, not 10 s.
 */
export function stuckSince({ pcId, lastFrame, connectingSince, now }) {
  if (pcId != null && lastFrame && lastFrame.pcId === pcId) return lastFrame.at
  return typeof connectingSince === "number" ? connectingSince : now
}

/**
 * The time (ms) at which the frame turns stuck if nothing changes: `STUCK_MS`
 * after `stuckSince`. The hook arms a timer for it instead of waiting for
 * its 1 s tick, which would add up to a second.
 */
export function stuckAt(args) {
  return stuckSince(args) + STUCK_MS
}

/**
 * True when the frame is on Connecting and `STUCK_MS` have passed with no
 * frame on the current pc, counted from `stuckSince`.
 */
export function stuck({ serverState, pcId, lastFrame, connectingSince, now }) {
  if (panelFor({ serverState, pcId, lastFrame, now }) !== "connecting") return false
  return now >= stuckAt({ pcId, lastFrame, connectingSince, now })
}

/**
 * Whether this copy should take the session's stream now. `holderOnScreen`
 * is null when no copy in the page holds it. `outranked` is true when another
 * suspended copy that is also on screen held the stream more recently: the
 * copy the person chose last (the canvas panel they opened over the inline
 * chat copy) takes it back, not whichever copy's check runs first.
 * `mountedHidden` is accepted for the record (origin/main keyed the decision
 * on it) and no longer matters: a copy that mounted hidden starts out
 * suspended.
 */
export function reclaim({ onScreen, active, suspended, holderOnScreen, outranked }) {
  return !!onScreen && !active && !!suspended && holderOnScreen !== true && !outranked
}
