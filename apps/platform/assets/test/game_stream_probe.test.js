import { describe, it, expect } from "vitest"
import {
  CELL_PX,
  CORNER_PX,
  MAX_SEQ,
  RollingStats,
  check,
  decode,
  encode,
  formatStats,
  latencyWarn,
  nextSeq,
  pairPath,
  pathFromCandidateType,
  peerConfig,
  percentile,
  readCorner,
} from "../js/hooks/lib/game_stream_probe.js"

/**
 * The viewer's latency probe (task 01a0db5f stage 4). Its wire values must
 * match Startup-Suite/play-host internal/probe/code.go, which the Godot
 * addon draws; the pinned cases below are code.go's TestPinnedWireValues.
 */

describe("probe code", () => {
  it("matches code.go's pinned check nibbles", () => {
    expect(check(1)).toBe(0xb)
    expect(check(2)).toBe(0x8)
    expect(check(0x123)).toBe(0xa)
  })

  it("round-trips every seq", () => {
    for (let seq = 1; seq <= MAX_SEQ; seq++) expect(decode(encode(seq))).toBe(seq)
  })

  it("an all-black or all-white corner never decodes", () => {
    expect(decode(new Array(16).fill(false))).toBe(0)
    expect(decode(new Array(16).fill(true))).toBe(0)
  })

  it("a flipped check bit is rejected", () => {
    const bits = encode(0x123)
    bits[15] = !bits[15]
    expect(decode(bits)).toBe(0)
  })

  it("wraps 4095 to 1, never 0", () => {
    expect(nextSeq(0)).toBe(1)
    expect(nextSeq(4094)).toBe(4095)
    expect(nextSeq(4095)).toBe(1)
  })
})

// Paints `seq` into RGBA pixels the way the addon draws it: 16x16 cells,
// white for 1, black for 0, with some encoder noise on every pixel.
function paint(seq, noise = 30) {
  const data = new Uint8ClampedArray(CORNER_PX * CORNER_PX * 4)
  const bits = encode(seq)
  for (let y = 0; y < CORNER_PX; y++) {
    for (let x = 0; x < CORNER_PX; x++) {
      const cell = Math.floor(y / CELL_PX) * 4 + Math.floor(x / CELL_PX)
      const v = bits[cell] ? 255 - noise : noise
      const o = (y * CORNER_PX + x) * 4
      data[o] = data[o + 1] = data[o + 2] = v
      data[o + 3] = 255
    }
  }
  return data
}

describe("probe decode from pixels", () => {
  it("reads the corner back to its seq", () => {
    for (const seq of [1, 2, 0x123, 777, 4095]) {
      expect(decode(readCorner(paint(seq), CORNER_PX))).toBe(seq)
    }
  })

  it("an idle (black) corner reads as no probe", () => {
    expect(decode(readCorner(new Uint8ClampedArray(CORNER_PX * CORNER_PX * 4), CORNER_PX))).toBe(0)
  })

  it("reads from a wider buffer by row stride", () => {
    const width = 128
    const src = paint(321)
    const wide = new Uint8ClampedArray(width * CORNER_PX * 4)
    for (let y = 0; y < CORNER_PX; y++) {
      wide.set(src.subarray(y * CORNER_PX * 4, (y + 1) * CORNER_PX * 4), y * width * 4)
    }
    expect(decode(readCorner(wide, width))).toBe(321)
  })
})

describe("rolling p50/p95", () => {
  it("is nearest-rank, as code.go's Summarize", () => {
    const s = [5, 1, 4, 2, 3, 10, 9, 8, 7, 6]
    expect(percentile(s, 0.5)).toBe(5)
    expect(percentile(s, 0.95)).toBe(10)
    expect(percentile([], 0.5)).toBe(null)
  })

  it("keeps only the last N samples and drops junk", () => {
    const r = new RollingStats(3)
    for (const ms of [100, 100, 100, 10, 20, 30, NaN, -1, "x"]) r.push(ms)
    expect(r.count).toBe(3)
    expect(r.p50()).toBe(20)
    expect(r.p95()).toBe(30)
  })
})

describe("readout", () => {
  it("formats rtt, fps, path and the decoded frame size", () => {
    expect(formatStats({ p50: 18.4, fps: 60, path: "LAN", width: 1028, height: 720 })).toBe(
      "18 ms · 60 fps · LAN · 1028x720",
    )
    expect(formatStats({})).toBe("-- ms · -- fps · --")
  })

  it("warns only on a measured p50 above the threshold", () => {
    expect(latencyWarn(51, 50)).toBe(true)
    expect(latencyWarn(50, 50)).toBe(false)
    expect(latencyWarn(null, 50)).toBe(false)
  })

  it("relay is TURN, every other candidate type is LAN", () => {
    expect(pathFromCandidateType("relay")).toBe("TURN")
    for (const t of ["host", "srflx", "prflx"]) expect(pathFromCandidateType(t)).toBe("LAN")
    expect(pathFromCandidateType(undefined)).toBe(null)
  })
})

describe("peer config (stage 5)", () => {
  it("forces relay only for the literal relay policy", () => {
    const servers = [{ urls: ["turn:turn.example:3479"], username: "u", credential: "c" }]
    expect(peerConfig(servers, "relay")).toEqual({ iceServers: servers, iceTransportPolicy: "relay" })
    expect(peerConfig(servers, "all").iceTransportPolicy).toBe("all")
    expect(peerConfig(servers, undefined).iceTransportPolicy).toBe("all")
    expect(peerConfig(servers, "RELAY").iceTransportPolicy).toBe("all")
  })

  it("tolerates a missing server list", () => {
    expect(peerConfig(undefined, "all")).toEqual({ iceServers: [], iceTransportPolicy: "all" })
    expect(peerConfig(null, "relay").iceServers).toEqual([])
  })
})

describe("selected pair path (stage 5)", () => {
  it("a relay candidate at either end is TURN", () => {
    expect(pairPath({ candidateType: "relay", relayProtocol: "udp" }, { candidateType: "host" })).toBe("TURN")
    expect(pairPath({ candidateType: "host" }, { candidateType: "relay" })).toBe("TURN")
  })

  it("a local prflx carrying relayProtocol is TURN: the shape measured with iceTransportPolicy relay", () => {
    const local = { candidateType: "prflx", relayProtocol: "udp", port: 40077 }
    const remote = { candidateType: "host", address: "192.0.2.107", port: 40308 }
    expect(pairPath(local, remote)).toBe("TURN")
  })

  it("host, srflx and a plain prflx are LAN; no local candidate is unknown", () => {
    expect(pairPath({ candidateType: "host" }, { candidateType: "host" })).toBe("LAN")
    expect(pairPath({ candidateType: "srflx" }, { candidateType: "host" })).toBe("LAN")
    expect(pairPath({ candidateType: "prflx" }, { candidateType: "host" })).toBe("LAN")
    expect(pairPath(undefined, { candidateType: "host" })).toBe(null)
  })
})
