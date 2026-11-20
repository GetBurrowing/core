import {describe, it, expect, beforeEach, afterEach, vi} from "vitest"
import Face, {mouthHeight, audibleTrack} from "../../js/hooks/meeting_cohost_face"

describe("cohost performance audio", () => {
  beforeEach(() => {
    vi.stubGlobal("window", {__livekit_room: {state: "connected", remoteParticipants: new Map()}})
    vi.stubGlobal("document", {hidden: false})
  })
  afterEach(() => vi.unstubAllGlobals())
  it("closes on silence and scales actual waveform energy with a bounded opening", () => {
    expect(mouthHeight(new Uint8Array(512).fill(128))).toBe(12)
    expect(mouthHeight(new Uint8Array(512).fill(140))).toBeGreaterThan(12)
    expect(mouthHeight(new Uint8Array(512).fill(255))).toBe(86)
  })
  const participant = (change = {}) => ({audioTrackPublications: new Map([["voice", {
    track: {mediaStreamTrack: {readyState: "live"},
      attachedElements: [{paused: false, muted: false, volume: 1}], ...change}
  }]])})
  it("requires a live, actually playing unmuted voice track", () => {
    expect(audibleTrack(participant())).toEqual({readyState: "live"})
    expect(audibleTrack(participant({isMuted: true}))).toBe(null)
    expect(audibleTrack(participant({attachedElements: [{paused: true, volume: 1}]}))).toBe(null)
    expect(audibleTrack(participant({attachedElements: [{muted: true, volume: 1}]}))).toBe(null)
    expect(audibleTrack(participant({mediaStreamTrack: {readyState: "ended"}}))).toBe(null)
    expect(audibleTrack(participant({attachedElements: []}))).toBe(null)
  })
  it("ignores host speech when the cohost identity is absent", () => {
    const states = []
    Face.tick.call({el: {dataset: {identity: "agent:cohost"}},
      disconnectSource() {}, paint: (...state) => states.push(state)})
    expect(states.at(-1)).toEqual(["waiting for cohost", 12])
  })
  it("closes and releases analysis when the room disconnects", () => {
    window.__livekit_room.state = "disconnected"
    const disconnectSource = vi.fn(), paint = vi.fn()
    Face.tick.call({disconnectSource, paint})
    expect(disconnectSource).toHaveBeenCalledOnce()
    expect(paint).toHaveBeenCalledWith("disconnected", 12)
  })
  it("never animates when the call cannot play audio", () => {
    window.__livekit_room.canPlaybackAudio = false
    window.__livekit_room.remoteParticipants.set("agent:cohost", participant())
    const paint = vi.fn()
    Face.tick.call({el: {dataset: {identity: "agent:cohost"}}, disconnectSource() {}, paint})
    expect(paint).toHaveBeenCalledWith("enable call audio", 12)
  })
})
