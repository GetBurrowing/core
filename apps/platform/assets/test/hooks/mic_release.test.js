import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

/**
 * Microphone release, one describe per capture surface (task 01a20b3e
 * stage 1). Every assertion is on the captured MediaStreamTrack itself:
 * `readyState === "ended"` (stop() was called) once the user is done. A
 * track that is merely disabled or muted is still a live capture, and the
 * browser keeps its mic-in-use indicator on for it.
 *
 * livekit-client is replaced by a fake that keeps the 2.18.1 semantics this
 * hinges on (read in node_modules/livekit-client/dist/livekit-client.esm.mjs):
 *
 *   * LocalAudioTrack.mute() stops the MediaStreamTrack ONLY when the track
 *     was published with `publishDefaults.stopMicTrackOnMute`; otherwise it
 *     just sets `enabled = false` and the capture stays live.
 *   * Room.disconnect() unpublishes every local track and stops it
 *     (`stopLocalTrackOnUnpublish` defaults to true).
 *
 * Cases that pass on main are regression pins.
 */

// ── fake capture ─────────────────────────────────────────────────────────

class FakeTrack {
  constructor(kind = "audio") {
    this.kind = kind
    this.readyState = "live"
    this.enabled = true
    this.stop = vi.fn(() => {
      this.readyState = "ended"
    })
  }
  getSettings() {
    return {}
  }
}

const captured = vi.hoisted(() => ({ tracks: [] }))

function newTrack(kind = "audio") {
  const t = new FakeTrack(kind)
  captured.tracks.push(t)
  return t
}

function fakeStream(kinds = ["audio"]) {
  const tracks = kinds.map((k) => newTrack(k))
  return { getTracks: () => tracks, getAudioTracks: () => tracks.filter((t) => t.kind === "audio") }
}

const liveTracks = () => captured.tracks.filter((t) => t.readyState === "live")

function deferred() {
  let resolve
  let reject
  const promise = new Promise((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

// ── fake livekit-client ──────────────────────────────────────────────────

const lk = vi.hoisted(() => ({ rooms: [], gate: null }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts = {}) {
      this.opts = opts
      this.handlers = {}
      this.state = "disconnected"
      this.pub = null
      const room = this
      this.localParticipant = {
        async setMicrophoneEnabled(on) {
          if (lk.gate && lk.gate.mic) await lk.gate.mic.promise
          if (!on || room.pub) return
          const stopOnMute = !!(room.opts.publishDefaults && room.opts.publishDefaults.stopMicTrackOnMute)
          const track = { mediaStreamTrack: newTrack("audio") }
          room.pub = {
            isMuted: false,
            track,
            async mute() {
              if (this.isMuted) return
              if (stopOnMute) track.mediaStreamTrack.stop()
              else track.mediaStreamTrack.enabled = false
              this.isMuted = true
            },
            async unmute() {
              if (track.mediaStreamTrack.readyState === "ended") {
                track.mediaStreamTrack = newTrack("audio")
              }
              track.mediaStreamTrack.enabled = true
              this.isMuted = false
            },
          }
        },
        getTrackPublication() {
          return room.pub
        },
      }
      lk.rooms.push(this)
    }
    on(event, fn) {
      this.handlers[event] = fn
      return this
    }
    async connect() {
      if (lk.gate && lk.gate.connect) await lk.gate.connect.promise
      this.state = "connected"
    }
    async disconnect() {
      if (this.pub && this.pub.track) this.pub.track.mediaStreamTrack.stop()
      this.pub = null
      const was = this.state
      this.state = "disconnected"
      if (was === "connected" && this.handlers.disconnected) this.handlers.disconnected()
    }
    getActiveDevice() {
      return undefined
    }
    switchActiveDevice() {
      return Promise.resolve(true)
    }
  }
  return { ...actual, Room }
})

const settle = () => new Promise((r) => setTimeout(r, 0))
const settleMany = async (n = 6) => {
  for (let i = 0; i < n; i++) await settle()
}

beforeEach(() => {
  captured.tracks = []
  lk.rooms = []
  lk.gate = null
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

// ── (c) the Voice tab ────────────────────────────────────────────────────

const { default: VoiceTab, MIC_TIMEOUT_MS } = await import("../../js/hooks/voice_tab.js")
const { __resetForTests: resetMediaDevices } = await import("../../js/lib/media_devices.js")

let clock = 0

function mountVoice({ gum } = {}) {
  const mic = {
    id: "mic",
    disabled: false,
    setPointerCapture() {},
    releasePointerCapture() {},
    closest() {
      return this
    },
  }
  const listeners = {}
  const handlers = {}
  const pushed = []
  const el = {
    dataset: { userId: "u1", partnerId: "a1" },
    addEventListener(type, fn) {
      listeners[type] = fn
    },
    removeEventListener(type) {
      delete listeners[type]
    },
    querySelector(sel) {
      return sel === "#mic" ? mic : null
    },
    querySelectorAll() {
      return []
    },
  }
  const getUserMedia = vi.fn(gum || (() => Promise.resolve(fakeStream())))
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia } })

  const hook = Object.create(VoiceTab)
  hook.el = el
  hook.pushEvent = (event, _payload, cb) => {
    pushed.push(event)
    if (event === "voice_start" && cb) cb({ ok: true, token: "tok", url: "ws://lk.test", room: "r" })
  }
  hook.handleEvent = (event, fn) => (handlers[event] = fn)
  hook.mounted()
  const fire = (type, e) => listeners[type] && listeners[type](e)
  return {
    hook,
    handlers,
    pushed,
    getUserMedia,
    down(at) {
      clock = at
      fire("pointerdown", { target: mic, button: 0, pointerId: 1, preventDefault() {} })
    },
    up(at) {
      clock = at
      fire("pointerup", { target: mic, pointerId: 1 })
    },
  }
}

describe("(c) voice_tab.js", () => {
  beforeEach(() => {
    clock = 0
    resetMediaDevices()
    vi.stubGlobal("performance", { now: () => clock })
    vi.stubGlobal("document", Object.assign(new EventTarget(), { getElementById: () => null }))
  })

  it("the permission probe's own stream is stopped as soon as it resolves", async () => {
    const t = mountVoice()
    t.down(0)
    await settleMany()
    expect(t.getUserMedia).toHaveBeenCalledTimes(1)
    const probe = captured.tracks[0]
    expect(probe.stop).toHaveBeenCalled()
    expect(probe.readyState).toBe("ended")
  })

  it("a getUserMedia that resolves after the 10 s timeout has its stream stopped", async () => {
    vi.useFakeTimers()
    const late = deferred()
    const t = mountVoice({ gum: () => late.promise })
    t.down(0)
    await vi.advanceTimersByTimeAsync(MIC_TIMEOUT_MS)
    expect(t.pushed).toContain("voice_mic_failed")
    const stream = fakeStream()
    late.resolve(stream)
    await vi.advanceTimersByTimeAsync(0)
    expect(stream.getTracks()[0].readyState).toBe("ended")
    expect(liveTracks()).toEqual([])
  })

  it("leaving the tab (destroyed) after a press and release ends the published mic track", async () => {
    const t = mountVoice()
    t.down(0)
    await settleMany()
    t.up(1_000)
    await settleMany()
    const published = lk.rooms[0].pub.track.mediaStreamTrack
    t.hook.destroyed()
    await settleMany()
    expect(published.readyState).toBe("ended")
    expect(liveTracks()).toEqual([])
  })

  it("leaving the tab mid-press (destroyed while held) ends the published mic track", async () => {
    const t = mountVoice()
    t.down(0)
    await settleMany()
    expect(t.hook.phase()).toBe("live")
    const published = lk.rooms[0].pub.track.mediaStreamTrack
    t.hook.destroyed()
    await settleMany()
    expect(published.readyState).toBe("ended")
    expect(liveTracks()).toEqual([])
  })

  it("a server voice_disconnect ends the published mic track", async () => {
    const t = mountVoice()
    t.down(0)
    await settleMany()
    t.up(1_000)
    await settleMany()
    const published = lk.rooms[0].pub.track.mediaStreamTrack
    t.handlers.voice_disconnect()
    await settleMany()
    expect(published.readyState).toBe("ended")
  })

  it("LiveKit dropping the room ends the track and the next press starts a fresh room", async () => {
    const t = mountVoice()
    t.down(0)
    await settleMany()
    t.up(1_000)
    await settleMany()
    const room = lk.rooms[0]
    const published = room.pub.track.mediaStreamTrack
    await room.disconnect()
    await settleMany()
    expect(published.readyState).toBe("ended")
    t.down(2_000)
    await settleMany()
    expect(lk.rooms).toHaveLength(2)
  })
})

// ── (a) the meeting window Room, released by meeting_presence.js ─────────

const { disconnectLiveKitRoom } = await import("../../js/meeting_presence.js")

function connectedRoomWithMic() {
  const room = {
    state: "connected",
    track: newTrack("audio"),
    disconnect: vi.fn(function () {
      this.track.stop()
      this.state = "disconnected"
      return Promise.resolve()
    }),
  }
  return room
}

describe("(a) the meeting's window Room (meeting_presence.js disconnectLiveKitRoom)", () => {
  it("ends the mic of the Room pinned on window.__livekit_room and clears BOTH pointers", () => {
    const win = new EventTarget()
    const room = connectedRoomWithMic()
    win.__livekit_room = room
    win.__livekitRoom = room
    disconnectLiveKitRoom(win)
    expect(room.disconnect).toHaveBeenCalledTimes(1)
    expect(room.track.readyState).toBe("ended")
    expect(win.__livekit_room).toBeNull()
    expect(win.__livekitRoom).toBeNull()
  })

  it("ends the mic when only the camel-case pointer is set", () => {
    const win = new EventTarget()
    const room = connectedRoomWithMic()
    win.__livekitRoom = room
    disconnectLiveKitRoom(win)
    expect(room.track.readyState).toBe("ended")
  })
})

// ── (b) the persistent bar's Leave ───────────────────────────────────────

const { default: MeetingBar } = await import("../../js/hooks/meeting_bar.js")

describe("(b) meeting_bar.js Leave", () => {
  it("ends the call's mic track", async () => {
    const room = connectedRoomWithMic()
    vi.stubGlobal("window", Object.assign(new EventTarget(), { __livekitRoom: room, __livekit_room: room }))
    const hook = Object.create(MeetingBar)
    // Only the Leave handler is under test; build it the way mounted() does
    // without the rest of the bar's DOM.
    hook.el = { querySelectorAll: () => [], querySelector: () => null, dataset: {} }
    hook.pushEvent = () => {}
    hook.pushEventTo = () => {}
    hook.handleEvent = () => {}
    try {
      hook.mounted()
    } catch (_e) {
      // mounted() touches DOM this harness does not build; the handler is
      // assigned before that.
    }
    expect(typeof hook._leaveHandler).toBe("function")
    hook._leaveHandler()
    await settle()
    expect(room.track.readyState).toBe("ended")
  })
})

// ── (d) the device panel's previews ──────────────────────────────────────

const { default: MeetingDevicePanel } = await import("../../js/hooks/meeting_device_panel.js")

function panelHook() {
  const hook = Object.create(MeetingDevicePanel)
  hook._previews = new Map()
  hook._open = { panel: { querySelector: () => null } }
  hook._attachPreview = vi.fn()
  return hook
}

describe("(d) meeting_device_panel.js _capture", () => {
  it("a mic preview that resolves after the panel closed is stopped", async () => {
    const pending = deferred()
    vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: () => pending.promise } })
    const hook = panelHook()
    const capture = hook._capture("audioinput", "mic-1", "probe")
    hook._open = null
    const stream = fakeStream()
    pending.resolve(stream)
    await capture
    expect(stream.getTracks()[0].readyState).toBe("ended")
    expect(hook._attachPreview).not.toHaveBeenCalled()
  })

  it("a mic preview that resolves after a reopen (a different open) is stopped", async () => {
    const pending = deferred()
    vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: () => pending.promise } })
    const hook = panelHook()
    const capture = hook._capture("audioinput", "mic-1", "probe")
    hook._open = { panel: { querySelector: () => null } }
    const stream = fakeStream()
    pending.resolve(stream)
    await capture
    expect(stream.getTracks()[0].readyState).toBe("ended")
  })
})

// ── (e) the lobby preview's mic ──────────────────────────────────────────

const { default: MeetingLobbyPreview } = await import("../../js/hooks/meeting_lobby_preview.js")

function lobbyHook({ wantMic = () => true } = {}) {
  const hook = Object.create(MeetingLobbyPreview)
  hook._blocked = {}
  hook._wantMic = wantMic
  hook._setCheck = () => {}
  hook._renderRows = () => {}
  hook._meter = () => null
  hook._attachMeter = () => {}
  return hook
}

describe("(e) meeting_lobby_preview.js mic", () => {
  beforeEach(() => resetMediaDevices())

  function stubGum(impl) {
    vi.stubGlobal("navigator", {
      mediaDevices: { getUserMedia: impl, enumerateDevices: () => Promise.resolve([]) },
    })
  }

  it("a mic stream that resolves after the lobby is destroyed (Join or navigation) is stopped", async () => {
    const pending = deferred()
    stubGum(() => pending.promise)
    const hook = lobbyHook()
    hook._startMic()
    await settleMany()
    hook._destroyed = true
    hook._stopMic()
    const stream = fakeStream()
    pending.resolve(stream)
    await settleMany()
    expect(stream.getTracks()[0].readyState).toBe("ended")
  })

  it("a mic stream that resolves after the toggle went off is stopped", async () => {
    const pending = deferred()
    stubGum(() => pending.promise)
    let want = true
    const hook = lobbyHook({ wantMic: () => want })
    hook._startMic()
    await settleMany()
    want = false
    const stream = fakeStream()
    pending.resolve(stream)
    await settleMany()
    expect(stream.getTracks()[0].readyState).toBe("ended")
  })

  it("a mic stream already open is stopped when the lobby goes", async () => {
    stubGum(() => Promise.resolve(fakeStream()))
    const hook = lobbyHook()
    hook._startMic()
    await settleMany()
    expect(liveTracks()).toHaveLength(1)
    hook._stopMic()
    expect(liveTracks()).toEqual([])
  })
})
