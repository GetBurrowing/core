/**
 * The input-to-photon latency probe, viewer side (task 01a0db5f stage 4).
 *
 * Mirrors Startup-Suite/play-host `internal/probe` (code.go) and the stage 1
 * spike page (`internal/spike/web/probe.js`). A probe is an input message
 * `{t: "probe", seq}`; the Godot addon draws `seq` in the frame's top-left
 * corner for two frames as a 4x4 grid of 16x16 px cells, and the viewer
 * decodes the corner in requestVideoFrameCallback and takes the time since
 * the send.
 *
 * Layout: 16 bits, row-major, MSB at cell (0,0). The value is
 * `seq << 4 | check(seq)` with seq in 1..4095. A white cell is a 1; an
 * all-black corner never decodes, because check(0) != 0. The wire values are
 * pinned against code.go's in `test/game_stream_probe.test.js`.
 */

export const CELLS = 4
export const CELL_PX = 16
export const MAX_SEQ = 4095
export const CORNER_PX = CELLS * CELL_PX

export function check(seq) {
  const s = seq & MAX_SEQ
  return (s ^ (s >> 4) ^ (s >> 8) ^ 0xa) & 0xf
}

/** The 16 cell states for `seq`, row-major, cell (0,0) first. */
export function encode(seq) {
  const v = ((seq & MAX_SEQ) << 4) | check(seq)
  const bits = []
  for (let i = 0; i < CELLS * CELLS; i++) bits.push((v & (1 << (15 - i))) !== 0)
  return bits
}

/** The seq the 16 cells hold, or 0 when they hold no valid code. */
export function decode(bits) {
  let v = 0
  bits.forEach((b, i) => {
    if (b) v |= 1 << (15 - i)
  })
  const seq = v >> 4
  return seq !== 0 && (v & 0xf) === check(seq) ? seq : 0
}

/**
 * Reads the 16 cells from RGBA pixel data of the corner (at least
 * CORNER_PX x CORNER_PX, `width` px per row), sampling each cell's centre
 * and thresholding luma at 128.
 */
export function readCorner(data, width = CORNER_PX) {
  const bits = []
  for (let i = 0; i < CELLS * CELLS; i++) {
    const x = (i % CELLS) * CELL_PX + CELL_PX / 2
    const y = Math.floor(i / CELLS) * CELL_PX + CELL_PX / 2
    const o = (y * width + x) * 4
    bits.push(0.299 * data[o] + 0.587 * data[o + 1] + 0.114 * data[o + 2] >= 128)
  }
  return bits
}

/** The next seq after `seq`, wrapping 4095 -> 1 (0 is never a seq). */
export function nextSeq(seq) {
  return (seq % MAX_SEQ) + 1
}

/** Nearest-rank percentile, as code.go's Summarize computes it. */
export function percentile(samples, p) {
  if (!samples.length) return null
  const s = [...samples].sort((a, b) => a - b)
  return s[Math.max(0, Math.ceil(p * s.length) - 1)]
}

/** A rolling window of round-trip samples with p50 and p95. */
export class RollingStats {
  constructor(size = 60) {
    this.size = size
    this.samples = []
  }

  push(ms) {
    if (typeof ms !== "number" || !isFinite(ms) || ms < 0) return
    this.samples.push(ms)
    if (this.samples.length > this.size) this.samples.shift()
  }

  get count() {
    return this.samples.length
  }

  p50() {
    return percentile(this.samples, 0.5)
  }

  p95() {
    return percentile(this.samples, 0.95)
  }
}

/**
 * The always-on footer readout: round trip, frame rate, path, frame size.
 * The size is what the decoder reports, not what was asked for (the host can
 * clamp it; stage 3 asked for 1280x720 and streamed 1028x720).
 */
export function formatStats({ p50, fps, path, width, height }) {
  const rtt = p50 == null ? "--" : String(Math.round(p50))
  const rate = fps == null ? "--" : String(Math.round(fps))
  const parts = [`${rtt} ms`, `${rate} fps`, path || "--"]
  if (width && height) parts.push(`${width}x${height}`)
  return parts.join(" · ")
}

/** Should the readout warn? Only on a measured p50 above the threshold. */
export function latencyWarn(p50, warnMs) {
  return typeof p50 === "number" && typeof warnMs === "number" && p50 > warnMs
}

/** relay means the pair runs through TURN; anything else is on the LAN. */
export function pathFromCandidateType(type) {
  if (!type) return null
  return type === "relay" ? "TURN" : "LAN"
}

/**
 * Does this candidate carry its traffic through TURN? A `relay` candidate
 * does, and so does a local `prflx` one that carries `relayProtocol`: Chrome
 * reports the selected local candidate that way when the peer answers from
 * the TURN server's LAN address rather than the advertised public relay
 * address. Measured on the stage 5 rig: iceTransportPolicy "relay" selected
 * local "prflx" with relayProtocol "udp" against the host's "host" candidate,
 * so a candidateType-only check read a relayed session as LAN.
 */
export function isRelayed(candidate) {
  return !!candidate && (candidate.candidateType === "relay" || !!candidate.relayProtocol)
}

/** The selected pair's path: TURN if either end is relayed, else LAN (null if unknown). */
export function pairPath(local, remote) {
  if (isRelayed(local) || isRelayed(remote)) return "TURN"
  return pathFromCandidateType(local && local.candidateType)
}

/**
 * The RTCPeerConnection config for a session. `policy` is the attach reply's
 * `ice_transport_policy`: "relay" forces TURN (a LAN viewer measuring the
 * relayed path, task 01a0db5f stage 5); anything else is "all".
 */
export function peerConfig(iceServers, policy) {
  return {
    iceServers: Array.isArray(iceServers) ? iceServers : [],
    iceTransportPolicy: policy === "relay" ? "relay" : "all",
  }
}
