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
