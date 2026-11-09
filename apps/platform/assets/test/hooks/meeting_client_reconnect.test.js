import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { DisconnectReason } from "livekit-client"
import MeetingClient, {
  REJOIN_DELAY_MS,
  REJOIN_GIVE_UP_MS,
} from "../../js/hooks/meeting_client.js"

/**
 * A network drop must not look like the user pressing Leave. Disconnected with
 * a non-deliberate reason keeps the call UI, tries ONE rejoin, then offers
 * Rejoin / Leave. Only a deliberate leave pushes `meeting_left`.
 *
 * Not covered here (needs a real browser + LiveKit): the banner DOM/CSS, the
 * click wiring on its buttons, and a real network kill.
 */

const fake = vi.hoisted(() => ({ created: [], failConnect: false }))

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
        setCameraEnabled: () => Promise.resolve(),
        setMicrophoneEnabled: () => Promise.resolve(),
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
    connect() {
      if (fake.failConnect) return Promise.reject(new Error("net down"))
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
  hook.pushEvent = (name) => hook.pushed.push(name)
  return hook
}

const PAYLOAD = { token: "tok", url: "wss://lk.test", room_name: "space-r" }
const left = (hook) => hook.pushed.filter((n) => n === "meeting_left").length

describe("MeetingClient reconnect state machine", () => {
  let prior
  beforeEach(() => {
    vi.useFakeTimers()
    fake.created.length = 0
    fake.failConnect = false
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
})
