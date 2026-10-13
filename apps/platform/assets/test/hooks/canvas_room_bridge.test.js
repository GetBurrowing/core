import { describe, it, expect, beforeEach, afterEach } from "vitest"
import CanvasRoomBridge, {
  validFrameMessage,
  MAX_MESSAGE_BYTES,
} from "../../js/hooks/canvas_room_bridge.js"

/**
 * The parent-page half of the canvas-room bridge (task 01a1316b-84fa
 * stage 2). vitest runs in `node` (no jsdom), so window, the iframe and its
 * contentWindow are small fakes that record what they receive.
 */

function fakeWindow() {
  const listeners = {}
  return {
    posted: [],
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    dispatch(type, event) {
      for (const fn of listeners[type] || []) fn(event)
    },
    postMessage(msg, target) {
      this.posted.push({ msg, target })
    },
    count(type) {
      return (listeners[type] || []).length
    },
  }
}

function fakeIframe() {
  const iframe = fakeWindow()
  iframe.contentWindow = fakeWindow()
  return iframe
}

function mountHook({ canvasId = "c-1", nodeId = "n-1" } = {}) {
  const iframe = fakeIframe()
  const hook = Object.create(CanvasRoomBridge)
  hook.el = {
    id: "frame-test-room-v1",
    dataset: { canvasId, nodeId },
    querySelector: (sel) => (sel === "iframe" ? iframe : null),
  }
  hook.pushes = []
  hook.handlers = {}
  hook.pushEvent = (event, payload, reply) => hook.pushes.push({ event, payload, reply })
  hook.handleEvent = (event, fn) => {
    hook.handlers[event] = fn
  }
  hook.mounted()
  return { hook, iframe }
}

const validOp = {
  suite: 1,
  type: "op",
  req: "r1",
  op: { type: "state.increment", key: "count", by: 1 },
}

let win

beforeEach(() => {
  win = fakeWindow()
  globalThis.window = win
})

afterEach(() => {
  delete globalThis.window
})

describe("CanvasRoomBridge: event.source identity", () => {
  it("ignores a message from any window other than its own iframe", () => {
    const { hook } = mountHook()
    const otherFrame = fakeWindow()

    win.dispatch("message", { source: otherFrame, origin: "null", data: validOp })
    win.dispatch("message", { source: win, origin: "null", data: validOp })
    win.dispatch("message", { source: null, origin: "null", data: validOp })

    expect(hook.pushes).toEqual([])
  })

  it("accepts the same message from its own iframe (positive control)", () => {
    const { hook, iframe } = mountHook()
    win.dispatch("message", { source: iframe.contentWindow, origin: "null", data: validOp })
    expect(hook.pushes.map((p) => p.event)).toEqual(["canvas_room_op"])
  })
})

describe("CanvasRoomBridge: schema", () => {
  it("ignores schema-invalid messages from its own iframe", () => {
    const { hook, iframe } = mountHook()
    const src = iframe.contentWindow
    const bad = [
      null,
      "hello",
      { type: "hello" },
      { suite: 2, type: "hello" },
      { suite: 1, type: "snapshot" },
      { suite: 1, type: "op", req: "r", op: { type: "state.drop", key: "k" } },
      { suite: 1, type: "op", req: "r", op: { type: "state.set", key: 7 } },
      { suite: 1, type: "op", req: "r", op: { type: "state.set", key: "k".repeat(129) } },
      { suite: 1, type: "op", req: "r", op: { type: "collection.add", item: {} } },
      {
        suite: 1,
        type: "op",
        req: "r",
        op: { type: "state.set", key: "k", value: "x".repeat(MAX_MESSAGE_BYTES) },
      },
      { suite: 1, type: "ephemeral", channel: "", payload: {} },
    ]

    for (const data of bad) win.dispatch("message", { source: src, data })
    expect(hook.pushes).toEqual([])
  })

  it("counts bytes, not characters, against the 128-byte key cap", () => {
    expect(validFrameMessage({ ...validOp, op: { type: "state.set", key: "é".repeat(64) } })).toBe(true)
    expect(validFrameMessage({ ...validOp, op: { type: "state.set", key: "é".repeat(65) } })).toBe(false)
  })
})

describe("CanvasRoomBridge: room key from data attributes", () => {
  it("sends the element's canvas and node ids even when the message names others", () => {
    const { hook, iframe } = mountHook({ canvasId: "mine", nodeId: "node-a" })
    const data = {
      ...validOp,
      canvas_id: "theirs",
      node_id: "node-z",
      actor: { id: "forged" },
      op: { ...validOp.op, canvas_id: "theirs" },
    }

    win.dispatch("message", { source: iframe.contentWindow, data })

    expect(hook.pushes).toHaveLength(1)
    const { event, payload } = hook.pushes[0]
    expect(event).toBe("canvas_room_op")
    expect(payload.canvas_id).toBe("mine")
    expect(payload.node_id).toBe("node-a")
    expect(payload.actor).toBeUndefined()
  })

  it("relays the op ack back to the frame with its req", () => {
    const { hook, iframe } = mountHook()
    win.dispatch("message", { source: iframe.contentWindow, data: validOp })
    hook.pushes[0].reply({ ok: true, seq: 3, result: 3 })

    expect(iframe.contentWindow.posted).toEqual([
      { msg: { ok: true, seq: 3, result: 3, suite: 1, type: "ack", req: "r1" }, target: "*" },
    ])
  })

  it("hello and iframe load both join; destroyed leaves and unbinds", () => {
    const { hook, iframe } = mountHook()
    win.dispatch("message", { source: iframe.contentWindow, data: { suite: 1, type: "hello" } })
    iframe.dispatch("load", {})
    expect(hook.pushes.map((p) => p.event)).toEqual(["canvas_room_join", "canvas_room_join"])
    expect(hook.pushes[0].payload).toEqual({
      canvas_id: "c-1",
      node_id: "n-1",
      hook_id: "frame-test-room-v1",
    })

    hook.destroyed()
    expect(hook.pushes.at(-1).event).toBe("canvas_room_leave")
    expect(win.count("message")).toBe(0)
    expect(iframe.count("load")).toBe(0)
  })
})

describe("CanvasRoomBridge: server events", () => {
  it("forwards server pushes to the iframe's contentWindow only, with target *", () => {
    const { hook, iframe } = mountHook({ canvasId: "c", nodeId: "n" })

    expect(Object.keys(hook.handlers).sort()).toEqual([
      "canvas_room:c:n:diff",
      "canvas_room:c:n:ephemeral",
      "canvas_room:c:n:presence",
      "canvas_room:c:n:snapshot",
    ])

    hook.handlers["canvas_room:c:n:diff"]({ seq: 1, diff: { kind: "key" }, actor: "u" })
    hook.handlers["canvas_room:c:n:ephemeral"]({ channel: "cursor", payload: {}, actor: "u" })

    expect(iframe.contentWindow.posted.map((p) => [p.msg.type, p.target])).toEqual([
      ["diff", "*"],
      ["ephemeral", "*"],
    ])
    expect(win.posted).toEqual([])
    expect(iframe.posted).toEqual([])
  })

  it("posts the join reply as a snapshot, and a refusal as connected: false", () => {
    const { hook, iframe } = mountHook()
    hook.join()
    hook.pushes[0].reply({ ok: true, seq: 4, state: { keys: {} }, presence: [], me: { id: "u" } })
    hook.join()
    hook.pushes[1].reply({ ok: false, error: "forbidden" })

    const [first, second] = iframe.contentWindow.posted.map((p) => p.msg)
    expect(first).toMatchObject({ type: "snapshot", seq: 4, connected: true })
    expect(first.ok).toBeUndefined()
    expect(second).toMatchObject({ type: "snapshot", connected: false, error: "forbidden" })
  })
})
