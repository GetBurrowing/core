import { describe, it, expect } from "vitest"
import {
  SessionMemo,
  attachOutcome,
  signalMoved,
} from "../js/hooks/lib/game_stream_session.js"

/**
 * Which window plays (task 01a0db5f stage 6). The restart race: window Y
 * clicks Start again while window X also shows the canvas. Both pages
 * re-render the node onto the new session and attach; X must attach as a
 * follower so the clicking window keeps the stream.
 */

describe("SessionMemo: take vs follow", () => {
  it("a node's first mount on a page takes the session", () => {
    const m = new SessionMemo()
    expect(m.mount("c1", "gs", "s1")).toBe("take")
  })

  it("a node re-rendered onto a DIFFERENT session follows (someone else restarted it)", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    m.attached("c1", "gs", "s1")
    expect(m.mount("c1", "gs", "s2")).toBe("follow")
  })

  it("both copies of a node mounted in one patch get the same answer", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    m.attached("c1", "gs", "s1")
    expect(m.mount("c1", "gs", "s2")).toBe("follow")
    expect(m.mount("c1", "gs", "s2")).toBe("follow")
  })

  it("after the first attach, reopening the same session is the user's own action", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    m.attached("c1", "gs", "s1")
    m.mount("c1", "gs", "s2")
    m.attached("c1", "gs", "s2")
    expect(m.mount("c1", "gs", "s2")).toBe("take")
  })

  it("the window that clicked Start again is not a follower of its own restart", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    m.attached("c1", "gs", "s1")
    m.restarted("c1", "gs", "s2")
    expect(m.mount("c1", "gs", "s2")).toBe("take")
  })

  it("nodes on different canvases or ids do not share memory", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    expect(m.mount("c2", "gs", "s2")).toBe("take")
    expect(m.mount("c1", "other", "s2")).toBe("take")
  })

  it("a node with no session is never a follower", () => {
    const m = new SessionMemo()
    m.mount("c1", "gs", "s1")
    expect(m.mount("c1", "gs", null)).toBe("take")
  })
})

describe("attach replies and refused signals", () => {
  it("the viewer keeps its token", () => {
    expect(attachOutcome({ ok: true, viewer: true, viewer_token: 7 })).toEqual({
      kind: "viewer",
      token: 7,
      peerId: null,
    })
  })

  it("the viewer keeps its core-minted peer id (01a0dbd6)", () => {
    expect(
      attachOutcome({ ok: true, viewer: true, viewer_token: 3, peer_id: "p-1" }),
    ).toEqual({ kind: "viewer", token: 3, peerId: "p-1" })
  })

  it("a watcher that does not hold a v1 stream still owns its peer (for Play here)", () => {
    expect(
      attachOutcome({ ok: true, viewer: false, viewer_token: null, peer_id: "p-2" }),
    ).toEqual({ kind: "takeover", token: null, peerId: "p-2" })
  })

  it("a reply without a viewer flag (older server) is the viewer", () => {
    expect(attachOutcome({ ok: true }).kind).toBe("viewer")
  })

  it("viewer false means another window holds the session", () => {
    expect(attachOutcome({ ok: true, viewer: false, viewer_token: null })).toEqual({
      kind: "takeover",
      token: null,
      peerId: null,
    })
  })

  it("a refusal carries its error", () => {
    expect(attachOutcome({ ok: false, error: "forbidden" })).toEqual({
      kind: "refused",
      error: "forbidden",
    })
  })

  it("only a 'moved' refusal of a signal means the window was superseded", () => {
    expect(signalMoved({ ok: false, error: "moved" })).toBe(true)
    expect(signalMoved({ ok: false, error: "terminal" })).toBe(false)
    expect(signalMoved({ ok: true })).toBe(false)
    expect(signalMoved(undefined)).toBe(false)
  })
})
