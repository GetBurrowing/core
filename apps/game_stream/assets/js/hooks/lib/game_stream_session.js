/**
 * Which window plays a game_stream session (task 01a0db5f stage 6).
 *
 * A node's DOM id carries its session id, so when anyone clicks "Start
 * again" EVERY page showing that canvas re-renders the node onto the new
 * session and mounts a fresh hook, which attaches at once. Without a way to
 * tell those automatic attaches from a user's own action, whichever window
 * attached last took the stream, and the window that clicked Start again
 * could be left on "Connecting…".
 *
 * `SessionMemo` remembers, per page, the last session each node (canvas id
 * plus node id) showed. A hook mounting onto a DIFFERENT session than the
 * one its node showed before on this page was re-rendered by someone's
 * restart: it attaches as `follow`, which the server grants only when
 * nobody holds the session. Anything else (the node's first mount on this
 * page, the same session again after a panel reopen, "Play here", the
 * window that clicked Start again) attaches as `take`.
 */

export class SessionMemo {
  constructor() {
    this.last = new Map()
  }

  static key(canvasId, nodeId) {
    return `${canvasId || ""}:${nodeId || ""}`
  }

  /**
   * Records that the node now shows `sessionId` and returns the mode its
   * first attach should use. Both copies of a node (panel and mobile
   * overlay) mount in the same patch and get the same answer, so it does
   * not matter which of them is on screen.
   */
  mount(canvasId, nodeId, sessionId) {
    const key = SessionMemo.key(canvasId, nodeId)
    const prev = this.last.get(key)
    if (!sessionId) return "take"
    if (prev && prev.sessionId === sessionId) return prev.mode
    const mode = prev ? "follow" : "take"
    this.last.set(key, { sessionId, mode })
    return mode
  }

  /**
   * The node's first attach has been sent: any later mount of the same
   * session on this page (a panel closed and reopened) is the user's own.
   */
  attached(canvasId, nodeId, sessionId) {
    const key = SessionMemo.key(canvasId, nodeId)
    const prev = this.last.get(key)
    if (prev && prev.sessionId === sessionId) prev.mode = "take"
  }

  /**
   * The window that clicked Start again moves its node to the new session
   * itself, so its own re-rendered copy is not mistaken for a follower.
   */
  restarted(canvasId, nodeId, sessionId) {
    if (sessionId) this.last.set(SessionMemo.key(canvasId, nodeId), { sessionId, mode: "take" })
  }
}

/**
 * What an attach reply means for the window: `viewer` when it receives the
 * stream (and must send `token` and `peerId` with every signal), `takeover`
 * when another window holds a v1 host's single stream.
 *
 * `peerId` is the core-minted peer this LiveView owns (task 01a0dbd6). Every
 * attach, including `takeover`, has one: "Play here" takes a slot over for
 * that peer.
 */
export function attachOutcome(reply) {
  if (!reply || !reply.ok) return { kind: "refused", error: reply && reply.error }
  const peerId = reply.peer_id == null ? null : reply.peer_id
  if (reply.viewer === false) return { kind: "takeover", token: null, peerId }
  return {
    kind: "viewer",
    token: reply.viewer_token == null ? null : reply.viewer_token,
    peerId,
  }
}

/** A signal the server refused because this window is no longer the viewer. */
export function signalMoved(reply) {
  return !!reply && reply.ok === false && reply.error === "moved"
}
