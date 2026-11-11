import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { DisconnectReason } from "livekit-client"
import MeetingClient, {
  REJOIN_DELAY_MS,
  REJOIN_GIVE_UP_MS,
  REJOIN_TOKEN_TIMEOUT_MS,
} from "../../js/hooks/meeting_client.js"

/**
 * A network drop must not look like the user pressing Leave. Disconnected with
 * a non-deliberate reason keeps the call UI, tries ONE rejoin, then offers
 * Rejoin / Leave. Only a deliberate leave pushes `meeting_left`.
 *
 * Not covered here (needs a real browser + LiveKit): the banner DOM/CSS, the
 * click wiring on its buttons, and a real network kill.
 */

const fake = vi.hoisted(() => ({
  created: [],
  connects: [],
  failConnect: false,
  holdConnect: false,
  release: [],
}))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor() {
      this.name = "space-r"
      this.state = "disconnected"
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.disconnectCalls = 0
      this.localParticipant = {
        identity: "user:me",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map(),
        micCalls: [],
        setCameraEnabled: () => Promise.resolve(),
        setMicrophoneEnabled(on) {
          this.micCalls.push(on)
          return Promise.resolve()
        },
      }
      fake.created.push(this)
    }
    on(e, cb) {
      const l = this._handlers.get(e) || []
      l.push(cb)
      this._handlers.set(e, l)
      return this
    }
    off(e, cb) {
      const l = this._handlers.get(e) || []
      const i = l.indexOf(cb)
      if (i >= 0) l.splice(i, 1)
      return this
    }
    emit(e, ...args) {
      for (const cb of [...(this._handlers.get(e) || [])]) cb(...args)
    }
    connect(url, token) {
      fake.connects.push({ url, token })
      if (fake.failConnect) return Promise.reject(new Error("net down"))
      if (fake.holdConnect) {
        // A slow connect: resolves only when the test calls fake.release.
        return new Promise((resolve) => {
          fake.release.push(() => {
            this.state = "connected"
            resolve()
          })
        })
      }
      this.state = "connected"
      return Promise.resolve()
    }
    disconnect() {
      this.disconnectCalls += 1
      this.state = "disconnected"
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

function fakeNode() {
  return {
    dataset: {},
    style: {},
    children: [],
    classList: { add() {}, remove() {}, contains: () => false },
    appendChild(c) {
      this.children.push(c)
      return c
    },
    remove() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    setAttribute() {},
  }
}

function buildHook() {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
  hook._boundRoom = null
  hook._roomListeners = []
  hook._rejoinTimers = []
  hook._rejoinGen = 0
  hook._leaving = false
  hook.el = { dataset: {} }
  hook._connBanner = { dataset: { state: "idle" } }
  hook.pushed = []
  // The server's answer to `meeting_rejoin_token`: a fresh token by default;
  // `hook.rejoinReply = null` means the server never answers (LiveView down).
  hook.rejoinReply = { token: "fresh-tok", url: "wss://lk.test" }
  hook.pushEvent = (name, _payload, cb) => {
    hook.pushed.push(name)
    if (name === "meeting_rejoin_token" && cb && hook.rejoinReply) cb(hook.rejoinReply)
  }
  return hook
}

const PAYLOAD = { token: "tok", url: "wss://lk.test", room_name: "space-r" }
const left = (hook) => hook.pushed.filter((n) => n === "meeting_left").length

describe("MeetingClient reconnect state machine", () => {
  let prior
  beforeEach(() => {
    vi.useFakeTimers()
    fake.created.length = 0
    fake.connects.length = 0
    fake.failConnect = false
    fake.holdConnect = false
    fake.release.length = 0
    prior = { window: globalThis.window, document: globalThis.document, nav: globalThis.navigator }
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: () => true,
      matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    }
    globalThis.document = {
      createElement: () => fakeNode(),
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
      body: fakeNode(),
    }
    Object.defineProperty(globalThis, "navigator", { value: { onLine: true }, configurable: true })
    globalThis.requestAnimationFrame = (cb) => cb()
    globalThis.CustomEvent = class {
      constructor(type, init) {
        this.type = type
        this.detail = init && init.detail
      }
    }
  })

  afterEach(() => {
    vi.useRealTimers()
    globalThis.window = prior.window
    globalThis.document = prior.document
    Object.defineProperty(globalThis, "navigator", { value: prior.nav, configurable: true })
  })

  it("(a) a network Disconnected schedules one rejoin and does not push meeting_left", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    const first = fake.created[0]

    first.emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    expect(hook.el.dataset.roomState).toBe("reconnecting")
    expect(hook._connBanner.dataset.state).toBe("reconnecting")
    expect(left(hook)).toBe(0)
    expect(fake.created.length).toBe(1)
    expect(hook._room).toBe(first) // roster/tiles state not torn down

    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(fake.created.length).toBe(2) // exactly one rejoin, with the held url/token
    expect(hook.el.dataset.roomState).toBe("connected")
    expect(hook._room).toBe(fake.created[1])
    expect(left(hook)).toBe(0)

    await vi.advanceTimersByTimeAsync(REJOIN_GIVE_UP_MS)
    expect(fake.created.length).toBe(2)
    expect(hook.el.dataset.roomState).toBe("connected")
  })

  it("(b) CLIENT_INITIATED pushes meeting_left as before, no rejoin", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)

    fake.created[0].emit("disconnected", DisconnectReason.CLIENT_INITIATED)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS * 2)

    expect(left(hook)).toBe(1)
    expect(fake.created.length).toBe(1)
    expect(hook._room).toBe(null)
  })

  it("pagehide-style leave never starts the automatic rejoin", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    hook._leaving = true // what _onPageHide sets
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS * 2)
    expect(fake.created.length).toBe(1)
  })

  it("waits for the online event when the browser is offline", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    globalThis.navigator.onLine = false
    fake.created[0].emit("disconnected", undefined)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS * 2)
    expect(fake.created.length).toBe(1)

    const onlineCall = globalThis.window.addEventListener.mock.calls.find((c) => c[0] === "online")
    onlineCall[1]()
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(fake.created.length).toBe(2)
  })

  it("(c) a failed rejoin shows 'lost'; Rejoin runs the join path again", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    fake.failConnect = true

    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(hook.el.dataset.roomState).toBe("lost")
    expect(hook._connBanner.dataset.state).toBe("lost")
    expect(left(hook)).toBe(0)
    expect(fake.created.length).toBe(2)

    fake.failConnect = false
    hook._manualRejoin()
    await vi.advanceTimersByTimeAsync(0)
    expect(fake.created.length).toBe(3)
    expect(hook.el.dataset.roomState).toBe("connected")
    expect(hook._connBanner.dataset.state).toBe("idle")
  })

  it("gives up after 30 s with 'lost' when offline the whole time", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    globalThis.navigator.onLine = false
    fake.created[0].emit("disconnected", undefined)
    await vi.advanceTimersByTimeAsync(REJOIN_GIVE_UP_MS)
    expect(hook.el.dataset.roomState).toBe("lost")
    expect(left(hook)).toBe(0)
  })

  it("(d) Leave from the lost state pushes meeting_left exactly once", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    fake.failConnect = true
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(hook.el.dataset.roomState).toBe("lost")

    hook._leaveAfterLoss()
    hook._leaveAfterLoss()
    expect(left(hook)).toBe(1)
    expect(hook._room).toBe(null)
    expect(hook._connBanner.dataset.state).toBe("idle")
  })

  it("server leave-meeting while reconnecting pushes meeting_left once", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await hook._leave()
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS * 2)
    expect(left(hook)).toBe(1)
    expect(fake.created.length).toBe(1)
  })

  it("(f) a rejoin re-enters with the CURRENT mic/camera intent, not the lobby's", async () => {
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, mic_enabled: true, camera_enabled: true })
    expect(fake.created[0].localParticipant.micCalls).not.toContain(false)

    // Muted mid-call: the server's committed pair lands on the dataset.
    hook.el.dataset.micEnabled = "false"
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)

    expect(hook._room).toBe(fake.created[1])
    expect(fake.created[1].localParticipant.micCalls).toContain(false)
    expect(fake.created[1].localParticipant.micCalls).not.toContain(true) // not the join-time choice
  })

  it("(g) a connect that finishes after the give-up never becomes the live room or pushes meeting_left", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    const first = fake.created[0]

    fake.holdConnect = true
    first.emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(fake.created.length).toBe(2) // the attempt started and is hanging in connect()
    const slow = fake.created[1]

    await vi.advanceTimersByTimeAsync(REJOIN_GIVE_UP_MS)
    expect(hook.el.dataset.roomState).toBe("lost")
    expect(hook._room).toBe(first)

    fake.holdConnect = false
    fake.release.shift()() // the stale connect finally resolves
    await vi.advanceTimersByTimeAsync(0)

    expect(hook._room).toBe(first) // not pinned to the stale room
    expect(hook.el.dataset.roomState).toBe("lost") // no "connected" announced for it
    expect(slow.disconnectCalls).toBe(1)
    slow.emit("disconnected", DisconnectReason.CLIENT_INITIATED) // its own teardown
    expect(left(hook)).toBe(0) // the user is still in the meeting, offered Rejoin / Leave
  })

  describe("rejoin token (a guest token lasts 30 minutes)", () => {
    const tokens = () => fake.connects.map((c) => c.token)

    it("(h) the rejoin connects with the fresh token from the server, not the held one", async () => {
      const hook = buildHook()
      await hook._join(PAYLOAD)
      fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
      await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)

      expect(hook.pushed).toContain("meeting_rejoin_token")
      expect(tokens()).toEqual(["tok", "fresh-tok"])
      expect(fake.connects[1].url).toBe("wss://lk.test")
      expect(hook.el.dataset.roomState).toBe("connected")
    })

    it("(i) with no reply it falls back once to the held token and warns", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const hook = buildHook()
      await hook._join(PAYLOAD)
      hook.rejoinReply = null
      fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
      await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS + REJOIN_TOKEN_TIMEOUT_MS)

      expect(tokens()).toEqual(["tok", "tok"]) // one fallback, with the held token
      expect(warn.mock.calls.some((c) => /held token/.test(String(c[0])))).toBe(true)
      expect(hook.el.dataset.roomState).toBe("connected")
      warn.mockRestore()
    })

    it("(i2) a LiveView that is not connected (pushEvent throws) also falls back", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const hook = buildHook()
      await hook._join(PAYLOAD)
      hook.pushEvent = (name) => {
        if (name === "meeting_rejoin_token") throw new Error("LiveView not connected")
      }
      fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
      await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
      expect(tokens()).toEqual(["tok", "tok"])
      warn.mockRestore()
    })

    it("(i3) a fallback that also fails enters lost, as today", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const hook = buildHook()
      await hook._join(PAYLOAD)
      hook.rejoinReply = null
      fake.failConnect = true
      fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
      await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS + REJOIN_TOKEN_TIMEOUT_MS)
      expect(hook.el.dataset.roomState).toBe("lost")
      expect(tokens()).toEqual(["tok", "tok"]) // exactly one fallback attempt
      warn.mockRestore()
    })

    it("(j) a refused reply goes to lost without connecting", async () => {
      const hook = buildHook()
      await hook._join(PAYLOAD)
      hook.rejoinReply = { error: "not_a_participant" }
      fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
      await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)

      expect(hook.el.dataset.roomState).toBe("lost")
      expect(tokens()).toEqual(["tok"]) // no rejoin connect, fresh or held
      expect(left(hook)).toBe(0)
    })
  })

  it("(k) people who left during the outage lose their tiles after the rejoin", async () => {
    globalThis.document.getElementById = () => grid
    const grid = fakeNode()
    const person = (identity) => ({ identity, isLocal: false, trackPublications: new Map() })
    const hook = buildHook()
    await hook._join(PAYLOAD)
    const first = fake.created[0]

    // Before the drop: alice, bob (with his app companion) and carol.
    for (const id of ["user:alice", "user:bob", "video:user:bob", "user:carol"]) {
      const p = person(id)
      first.remoteParticipants.set(id, p)
      hook._ensureTile(p)
    }
    expect([...hook._tiles.keys()].sort()).toEqual(["user:alice", "user:bob", "user:carol"])

    // After the rejoin the new room holds alice, and carol only through her
    // companion (still her tile). Bob left while we were offline: his
    // Disconnected went to the dead room, so no event will ever remove him.
    const realNewRoom = hook._newRoom.bind(hook)
    hook._newRoom = () => {
      const r = realNewRoom()
      for (const id of ["user:alice", "video:user:carol"]) r.remoteParticipants.set(id, person(id))
      return r
    }
    first.emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)

    expect(hook._room).toBe(fake.created[1])
    expect([...hook._tiles.keys()].sort()).toEqual(["user:alice", "user:carol"])
  })

  it("(k2) the first join does not reconcile away tiles (only a rejoin does)", async () => {
    globalThis.document.getElementById = () => fakeNode()
    const hook = buildHook()
    await hook._join(PAYLOAD)
    expect(hook._tiles.size).toBe(0) // nothing to assert beyond: no throw on an empty roster
  })

  it("(l) Leave during a held rejoin connect: the late room's Disconnected adds no second meeting_left", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    fake.holdConnect = true
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    expect(fake.created.length).toBe(2) // connect is in flight
    const late = fake.created[1]

    hook._leaveAfterLoss()
    expect(left(hook)).toBe(1)
    expect(hook._room).toBe(null)

    fake.holdConnect = false
    fake.release.shift()()
    await vi.advanceTimersByTimeAsync(0)
    late.emit("disconnected", DisconnectReason.CLIENT_INITIATED)
    await vi.advanceTimersByTimeAsync(0)

    expect(left(hook)).toBe(1)
  })

  it("(l2) a Disconnected from a Room that is not the pinned one is ignored, even when nothing is pinned", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    fake.holdConnect = true
    fake.created[0].emit("disconnected", DisconnectReason.UNKNOWN_REASON)
    await vi.advanceTimersByTimeAsync(REJOIN_DELAY_MS)
    const late = fake.created[1]
    hook._leaveAfterLoss()
    expect(hook._room).toBe(null)
    expect(left(hook)).toBe(1)

    // Whatever still holds a reference to the late Room (a listener that
    // outlived cleanup) reports its teardown: it must not push meeting_left.
    hook._handleDisconnected(late, DisconnectReason.CLIENT_INITIATED)
    hook._handleDisconnected(late, DisconnectReason.UNKNOWN_REASON)
    expect(left(hook)).toBe(1)
  })
})
