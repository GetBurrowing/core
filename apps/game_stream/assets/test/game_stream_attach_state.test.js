import { describe, it, expect } from "vitest"
import {
  panelFor,
  stuck,
  stuckAt,
  stuckSince,
  reclaim,
  suspendedPanel,
  twinHeldPanel,
  STUCK_MS,
  FRESH_MS,
} from "../js/hooks/lib/game_stream_attach_state.js"

/**
 * The attach state of a game_stream frame (task 01a0dbd6 stage 1).
 *
 * Reproduced on the test-host rig (force_relay through build-host coturn): with the
 * chat canvas panel open, the node renders twice (desktop panel + mobile
 * overlay, and the inline chat copy). When the window narrows below `lg`
 * the overlay copy becomes rendered and takes the stream; widening back
 * leaves the desktop panel ON SCREEN showing Connecting forever while the
 * now-hidden overlay copy keeps decoding frames on a live
 * RTCPeerConnection. Only a reload recovered it.
 */

const T = 1_000_000

describe("reclaim: an on-screen copy takes the stream back from a hidden twin", () => {
  it("NAMED CAUSE: the copy on screen, suspended by a twin that is now hidden, takes the stream back", () => {
    expect(
      reclaim({ onScreen: true, active: false, suspended: true, holderOnScreen: false, mountedHidden: false }),
    ).toBe(true)
  })

  it("the copy on screen takes the stream when no copy holds it (the holder was destroyed)", () => {
    expect(
      reclaim({ onScreen: true, active: false, suspended: true, holderOnScreen: null, mountedHidden: false }),
    ).toBe(true)
  })

  it("never steals from a twin that is itself on screen (no ping-pong)", () => {
    expect(
      reclaim({ onScreen: true, active: false, suspended: true, holderOnScreen: true, mountedHidden: false }),
    ).toBe(false)
  })

  it("among on-screen copies, the one that held the stream last takes it back (the panel, not the inline copy)", () => {
    const base = { onScreen: true, active: false, suspended: true, holderOnScreen: false, mountedHidden: false }
    expect(reclaim({ ...base, outranked: true })).toBe(false)
    expect(reclaim({ ...base, outranked: false })).toBe(true)
  })

  it("a copy that is not on screen never claims", () => {
    expect(
      reclaim({ onScreen: false, active: false, suspended: true, holderOnScreen: false, mountedHidden: true }),
    ).toBe(false)
  })

  it("a window another WINDOW took over (not suspended by a twin) never claims on its own", () => {
    expect(
      reclaim({ onScreen: true, active: false, suspended: false, holderOnScreen: null, mountedHidden: false }),
    ).toBe(false)
  })

  it("the active copy has nothing to claim", () => {
    expect(
      reclaim({ onScreen: true, active: true, suspended: false, holderOnScreen: true, mountedHidden: false }),
    ).toBe(false)
  })
})

describe("panelFor: Connecting only while the CURRENT pc has no recent decoded frame", () => {
  it("a connecting status after frames on the current pc stays live", () => {
    expect(panelFor({ serverState: "connecting", pcId: 2, lastFrame: { pcId: 2, at: T - 100 }, now: T })).toBe(
      "live",
    )
  })

  it("a live status with frames on the current pc is live", () => {
    expect(panelFor({ serverState: "live", pcId: 2, lastFrame: { pcId: 2, at: T - 1999 }, now: T })).toBe("live")
  })

  it("frames from a closed pc do not count", () => {
    expect(panelFor({ serverState: "live", pcId: 3, lastFrame: { pcId: 2, at: T - 10 }, now: T })).toBe(
      "connecting",
    )
  })

  it("no peer at all is connecting", () => {
    expect(panelFor({ serverState: "live", pcId: null, lastFrame: { pcId: 2, at: T - 10 }, now: T })).toBe(
      "connecting",
    )
  })

  it("a frame older than 2 s on the current pc no longer holds live", () => {
    expect(panelFor({ serverState: "live", pcId: 2, lastFrame: { pcId: 2, at: T - 2001 }, now: T })).toBe(
      "connecting",
    )
  })

  it("ended and failed win over fresh frames", () => {
    const lastFrame = { pcId: 2, at: T - 10 }
    expect(panelFor({ serverState: "ended", pcId: 2, lastFrame, now: T })).toBe("ended")
    expect(panelFor({ serverState: "failed", pcId: 2, lastFrame, now: T })).toBe("failed")
  })

  it("building and unavailable show as themselves", () => {
    expect(panelFor({ serverState: "building", pcId: null, lastFrame: null, now: T })).toBe("building")
    expect(panelFor({ serverState: undefined, pcId: null, lastFrame: null, now: T })).toBe("unavailable")
  })
})

describe("stuck: 10 s on Connecting with no frame on the current pc", () => {
  it("10 s with no frame gives still connecting", () => {
    expect(stuck({ serverState: "connecting", pcId: 1, lastFrame: null, connectingSince: T - 10_000, now: T })).toBe(
      true,
    )
  })

  it("9.9 s is not yet stuck", () => {
    expect(stuck({ serverState: "connecting", pcId: 1, lastFrame: null, connectingSince: T - 9_900, now: T })).toBe(
      false,
    )
  })

  it("frames from an older pc do not reset the clock", () => {
    expect(
      stuck({
        serverState: "live",
        pcId: 2,
        lastFrame: { pcId: 1, at: T - 500 },
        connectingSince: T - 12_000,
        now: T,
      }),
    ).toBe(true)
  })

  it("a stall on the current pc counts from its last frame", () => {
    expect(
      stuck({ serverState: "live", pcId: 2, lastFrame: { pcId: 2, at: T - 5_000 }, connectingSince: T - 60_000, now: T }),
    ).toBe(false)
    expect(
      stuck({ serverState: "live", pcId: 2, lastFrame: { pcId: 2, at: T - 10_000 }, connectingSince: T - 60_000, now: T }),
    ).toBe(true)
  })

  // Stage 6 (task 01a0dbd6): the review measured "Still connecting" 13.4 s
  // after the pc was closed. Connecting shows FRESH_MS after the last frame,
  // and the clock used to start then (the later of the two), not at the frame.
  it("counts from the current pc's last frame, not from when Connecting showed", () => {
    const lastFrame = { pcId: 2, at: T - STUCK_MS }
    const connectingSince = lastFrame.at + FRESH_MS + 900
    expect(stuck({ serverState: "live", pcId: 2, lastFrame, connectingSince, now: T })).toBe(true)
    expect(stuck({ serverState: "live", pcId: 2, lastFrame, connectingSince, now: T - 100 })).toBe(false)
    expect(stuckSince({ pcId: 2, lastFrame, connectingSince, now: T })).toBe(lastFrame.at)
    expect(stuckAt({ pcId: 2, lastFrame, connectingSince, now: T })).toBe(lastFrame.at + 10_000)
  })

  it("a pc that never decoded a frame counts from when Connecting showed", () => {
    expect(stuckSince({ pcId: 3, lastFrame: { pcId: 2, at: T - 30_000 }, connectingSince: T - 4_000, now: T })).toBe(
      T - 4_000,
    )
    expect(stuckAt({ pcId: 3, lastFrame: null, connectingSince: T - 4_000, now: T })).toBe(T + 6_000)
    expect(stuckSince({ pcId: null, lastFrame: null, connectingSince: null, now: T })).toBe(T)
  })

  it("live frames are never stuck", () => {
    expect(
      stuck({ serverState: "live", pcId: 2, lastFrame: { pcId: 2, at: T - 100 }, connectingSince: T - 60_000, now: T }),
    ).toBe(false)
  })

  it("ended, failed and building are never stuck", () => {
    for (const serverState of ["ended", "failed", "building"]) {
      expect(stuck({ serverState, pcId: null, lastFrame: null, connectingSince: T - 60_000, now: T })).toBe(false)
    }
  })
})

// Task 01a0ee4f stage 2: the copy a twin in the same page took the stream
// from has closed its pc, so a running session must not show Connecting.
describe("suspendedPanel: the copy that gave the stream to a twin", () => {
  it.each(["building", "connecting", "live"])("a running session (%s) shows elsewhere, never connecting", state => {
    expect(suspendedPanel({ serverState: state })).toBe("elsewhere")
  })

  it.each(["ended", "failed", "unavailable"])("%s still wins and shows as itself", state => {
    expect(suspendedPanel({ serverState: state })).toBe(state)
  })

  it("no status yet reads as unavailable, like panelFor", () => {
    expect(suspendedPanel({ serverState: undefined })).toBe("unavailable")
    expect(suspendedPanel({})).toBe("unavailable")
  })
})

describe("twinHeldPanel: a suspended copy while a twin holds the stream (task 01a0ee4f stage 3)", () => {
  const base = { active: false, suspended: true, twinHolds: true, serverState: "live" }

  it.each(["building", "connecting", "live"])("a suspended copy on %s shows elsewhere", panel => {
    expect(twinHeldPanel({ ...base, panel })).toBe("elsewhere")
  })

  it.each(["takeover", "elsewhere", "ended", "failed", "unavailable"])("a %s panel is left alone", panel => {
    expect(twinHeldPanel({ ...base, panel })).toBeNull()
  })

  it("no twin holding the claim: null, so the copy attaches as before", () => {
    expect(twinHeldPanel({ ...base, twinHolds: false, panel: "connecting" })).toBeNull()
  })

  it("the claimant itself, or a copy that is not suspended (another window took over): null", () => {
    expect(twinHeldPanel({ ...base, active: true, panel: "connecting" })).toBeNull()
    expect(twinHeldPanel({ ...base, suspended: false, panel: "connecting" })).toBeNull()
  })

  it("an ended or failed session wins over elsewhere, as in suspendedPanel", () => {
    expect(twinHeldPanel({ ...base, serverState: "ended", panel: "connecting" })).toBe("ended")
    expect(twinHeldPanel({ ...base, serverState: "failed", panel: "live" })).toBe("failed")
  })
})
