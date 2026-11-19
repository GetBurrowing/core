import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Room, RemoteAudioTrack, RemoteParticipant } from "livekit-client"
import MeetingClient from "../../js/hooks/meeting_client.js"
import { __resetForTests as resetClientState } from "../../js/client_state.js"
import { registerRoom, selectDevice, __resetForTests } from "../../js/lib/media_devices.js"
import { asDeviceInfos } from "../lib/fake_media_devices.js"

/**
 * Speaker selection reaches remote audio (task 01a1f4c5 stage 1).
 *
 * Remote audio is played by elements `track.attach()` creates and
 * MeetingClient parks in the body-level `#meeting-audio-sink`. Picking a
 * speaker calls livekit's `Room.switchActiveDevice('audiooutput', id)`. This
 * file uses the REAL livekit Room and RemoteAudioTrack (no mock) to pin that:
 *
 *   1. an element attached BEFORE the switch is moved to the new sink;
 *   2. an element attached AFTER the switch, for a track that already
 *      existed, starts on the new sink;
 *   3. a track from someone who joins AFTER the switch starts on it too.
 *
 * If livekit ever stops applying the sink on attach, (2) and (3) go red and
 * `_attachTrack` has to call `el.setSinkId` itself.
 */

class FakeAudioElement {
  constructor() {
    this.sinks = []
    this.style = {}
    this.dataset = {}
    this.parentElement = null
    this.isConnected = true
  }
  setSinkId(id) {
    this.sinks.push(id)
    this.sinkId = id
    return Promise.resolve()
  }
  setAttribute() {}
  play() {
    return Promise.resolve()
  }
  addEventListener() {}
  removeEventListener() {}
}

function fakeSink() {
  return {
    id: "meeting-audio-sink",
    children: [],
    appendChild(el) {
      this.children.push(el)
      el.parentElement = this
      return el
    },
    querySelector: () => null,
  }
}

const MST = (id) => ({
  id,
  kind: "audio",
  enabled: true,
  readyState: "live",
  muted: false,
  addEventListener() {},
  removeEventListener() {},
  getSettings: () => ({}),
})

// A remote participant as livekit holds it: the real `setAudioOutput`, over
// a map of its audio publications.
function remoteParticipant(room, identity, tracks) {
  const p = Object.create(RemoteParticipant.prototype)
  p.identity = identity
  p.audioTrackPublications = new Map(tracks.map((t) => [t.sid, { track: t }]))
  room.remoteParticipants.set(identity, p)
  return p
}

let sink

beforeEach(() => {
  resetClientState()
  __resetForTests()
  sink = fakeSink()
  vi.stubGlobal("navigator", {
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    mediaDevices: {
      enumerateDevices: () =>
        Promise.resolve(asDeviceInfos([
          { kind: "audiooutput", deviceId: "out-1", label: "MacBook Pro Speakers" },
          { kind: "audiooutput", deviceId: "out-2", label: "AirPods Pro" },
        ])),
    },
  })
  vi.stubGlobal("document", {
    createElement: () => new FakeAudioElement(),
    getElementById: (id) => (id === "meeting-audio-sink" ? sink : null),
    querySelector: () => null,
    querySelectorAll: () => [],
    visibilityState: "visible",
    addEventListener() {},
    removeEventListener() {},
    body: { appendChild: (el) => el },
  })
  vi.stubGlobal("window", new EventTarget())
  vi.stubGlobal("HTMLAudioElement", FakeAudioElement)
  vi.stubGlobal("HTMLVideoElement", class {})
  vi.stubGlobal("localStorage", {
    getItem: () => null,
    setItem() {},
    removeItem() {},
    key: () => null,
    length: 0,
  })
  vi.stubGlobal(
    "MediaStream",
    class {
      constructor(tracks = []) {
        this.tracks = [...tracks]
      }
      getTracks() {
        return this.tracks
      }
      getAudioTracks() {
        return this.tracks
      }
      getVideoTracks() {
        return []
      }
      addTrack(t) {
        this.tracks.push(t)
      }
      removeTrack() {}
    },
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

function buildHook() {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._audioEls = new Map()
  hook.el = { dataset: {} }
  hook.pushEvent = () => {}
  return hook
}

describe("switching the speaker reaches #meeting-audio-sink", () => {
  it("before and after the switch, every remote audio element plays on the chosen output", async () => {
    const room = new Room({ disconnectOnPageLeave: false })
    registerRoom(room, "meeting")
    const hook = buildHook()

    // Bob is already talking: his audio is attached BEFORE the switch.
    const bobTrack = new RemoteAudioTrack(MST("m-bob"), "TR_bob", undefined, undefined, undefined)
    const bob = remoteParticipant(room, "user:bob", [bobTrack])
    hook._attachTrack(bobTrack, bob)
    const before = sink.children[0]
    expect(before).toBeInstanceOf(FakeAudioElement)

    const result = await selectDevice("audiooutput", "out-2")
    expect(result).toEqual({ ok: true })

    // (1) attached before the switch: moved.
    expect(before.sinkId).toBe("out-2")

    // (2) attached after the switch, for a track that already existed (a
    // LiveView remount drops the element and attaches a fresh one).
    hook._audioEls.clear()
    sink.children.length = 0
    hook._attachTrack(bobTrack, bob)
    const reattached = sink.children[0]
    expect(reattached).not.toBe(before)
    expect(reattached.sinkId).toBe("out-2")

    // (3) Carol joins after the switch. livekit hands a new participant the
    // room's audioOutput (`participant.setAudioOutput(options.audioOutput)`)
    // and builds her tracks with it.
    const carol = remoteParticipant(room, "user:carol", [])
    await carol.setAudioOutput(room.options.audioOutput)
    const carolTrack = new RemoteAudioTrack(
      MST("m-carol"),
      "TR_carol",
      undefined,
      undefined,
      carol.audioOutput,
    )
    hook._attachTrack(carolTrack, carol)
    const after = sink.children.find((el) => el !== reattached)
    expect(after.sinkId).toBe("out-2")
  })
})
