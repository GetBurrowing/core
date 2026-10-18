import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import GameStream from "../js/hooks/game_stream.js"

/**
 * A spectator's page sends NO input and NO probes (task 01a0dbd6 stage 4).
 *
 * Drives the real `GameStream` hook methods (initInput, the key forwarder,
 * dispatch, padStep, tick) on a stand-in `this` whose DOM-facing methods are
 * stubbed, with two fake open data channels that record every write. The
 * spectator case forces capture on, which the hook itself never allows a
 * spectator, so the only thing standing between a key and the channel is
 * the router. The positive control runs the same calls as P2 and shows each
 * path does write, so an empty spectator log is not an idle harness.
 */

function channel() {
  return {
    readyState: "open",
    sent: [],
    send(data) {
      this.sent.push(JSON.parse(data))
    },
  }
}

function fakeEvent(code) {
  return { code, key: code, repeat: false, preventDefault() {}, stopImmediatePropagation() {} }
}

function pad(buttons = []) {
  const b = []
  for (let i = 0; i < 17; i++) b.push({ value: buttons[i] || 0, pressed: (buttons[i] || 0) > 0.5 })
  return { id: "Pad (STANDARD GAMEPAD)", index: 0, mapping: "standard", connected: true, buttons: b, axes: [0.5, 0, 0, 0] }
}

function hook({ slots }) {
  const h = Object.create(GameStream)
  const pushes = []
  Object.assign(h, {
    dead: false,
    multi: true,
    rosterKnown: true,
    panel: "live",
    serverState: "live",
    capture: { captured: false, fullscreen: false },
    pending: new Map(),
    frames: 0,
    framesAtTick: 0,
    hasFrames: true,
    pc: null,
    lastInputAt: Date.now(),
    lastProbeAt: 0,
    lastStatsPushAt: 0,
    seq: 0,
    sessionId: "s1",
    canvasId: "c1",
    nodeId: "n1",
    events: channel(),
    stateCh: channel(),
    // DOM-facing: stubbed.
    active: () => true,
    renderFooter() {},
    renderCapture() {},
    renderRoster() {},
    renderAttach() {},
    maybeReclaim() {},
    updatePadLoop() {},
    readStats: async () => {},
    push(event, payload) {
      pushes.push([event, payload])
      return Promise.resolve({ ok: false })
    },
  })
  h.initInput({ body: { nodeType: 1, tagName: "BODY" }, activeElement: null })
  h.setMine(new Map(Object.entries(slots).map(([k, v]) => [Number(k), v])))
  return { h, pushes }
}

// Every input path the page has, in order: capture, keys, two pads, a probe
// tick, and a release (blur sends release_all).
function drive(h) {
  h.capture = { captured: true, fullscreen: false }
  h.keys.keydown(fakeEvent("KeyD"))
  h.keys.keyup(fakeEvent("KeyD"))
  h.padStep([pad([1]), { ...pad([0, 1]), index: 1 }])
  h.tick()
  h.dispatch({ type: "blur" })
}

describe("a spectator's hook writes nothing to the host's data channels", () => {
  it("no key, pad, probe or release_all, and no stats push", () => {
    const { h, pushes } = hook({ slots: {} })
    expect(h.router.player).toBe(false)
    drive(h)
    expect(h.events.sent).toEqual([])
    expect(h.stateCh.sent).toEqual([])
    expect(pushes.filter(([e]) => e === "game_stream_stats")).toEqual([])
    // A spectator's pad press does not claim a slot: Join is its explicit move.
    expect(pushes.filter(([e]) => e === "game_stream_join")).toEqual([])
  })

  it("cannot capture: a click on its live frame does nothing", () => {
    const { h } = hook({ slots: {} })
    h.isLive = () => true
    expect(h.canCapture()).toBe(false)
    h.dispatch({ type: "click", live: h.canCapture() })
    expect(h.capture.captured).toBe(false)
  })

  it("positive control: the same drive as P2 writes on both channels", () => {
    const { h, pushes } = hook({ slots: { 0: 1 } })
    expect(h.router.player).toBe(true)
    drive(h)
    const types = h.events.sent.map(m => m.t)
    expect(types).toContain("key")
    expect(types).toContain("probe")
    expect(types).toContain("release_all")
    expect(h.events.sent.find(m => m.t === "key")).toMatchObject({ src: 0, slot: 1 })
    expect(h.stateCh.sent.map(m => [m.src, m.slot])).toEqual([[0, 1]])
    // The second pad has no slot: its press asks for one instead of sending.
    expect(pushes.filter(([e]) => e === "game_stream_join").map(([, p]) => p.src)).toEqual([1])
  })

  it("the probe it sends is decoded against its own slot", () => {
    const { h } = hook({ slots: { 0: 2 } })
    h.capture = { captured: true, fullscreen: false }
    h.tick()
    expect(h.probeSlot).toBe(2)
    expect(h.events.sent).toEqual([{ t: "probe", seq: 1, src: 0 }])
    expect(Array.from(h.pending.keys())).toEqual([1])
  })

  it("losing the last slot (displaced) turns every path off again", () => {
    const { h } = hook({ slots: { 0: 0 } })
    h.onDisplaced({ slot: 0, by: "Alex" })
    expect(h.router.player).toBe(false)
    expect(h.displaced).toEqual({ slot: 0, by: "Alex" })
    h.events.sent.length = 0
    drive(h)
    expect(h.events.sent).toEqual([])
    expect(h.stateCh.sent).toEqual([])
  })
})

// Touch (task 01a0fe45 stage 2): a 1600x900 well showing a 16:9 frame, a
// touch-enabled host, and a pointer event shape the hook's onPointer takes.
function withTouch(h) {
  h.audio = { gesture() {} }
  h.video = {
    videoWidth: 1920,
    videoHeight: 1080,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1600, height: 900 }),
  }
  h.well = { setPointerCapture() {}, setAttribute() {}, removeAttribute() {} }
  h.setTouch({ enabled: true, slop_px: 0, move_hz: 1000 })
  return h
}

function pointer(type, pointerId, clientX, clientY) {
  const e = { type, pointerId, pointerType: "touch", clientX, clientY, target: null, prevented: false }
  e.preventDefault = () => (e.prevented = true)
  return e
}

// A tap, a two-finger drag, a cancel, a lost capture, and a release on blur.
function driveTouch(h) {
  const evs = [
    pointer("pointerdown", 1, 800, 450),
    pointer("pointerup", 1, 800, 450),
    pointer("pointerdown", 2, 400, 300),
    pointer("pointerdown", 3, 1200, 600),
    pointer("pointermove", 2, 500, 350),
    pointer("pointermove", 3, 1100, 500),
    pointer("pointercancel", 2, 500, 350),
    pointer("lostpointercapture", 3, 1100, 500),
    pointer("pointerdown", 4, 800, 450),
  ]
  for (const e of evs) h.onPointer(e)
  h.touches.releaseAll()
  return evs
}

describe("a spectator's touches write nothing (task 01a0fe45)", () => {
  it("ZERO channel writes, even with touch forced on so only the router stands in the way", () => {
    const { h } = hook({ slots: {} })
    withTouch(h)
    expect(h.touchWanted()).toBe(false)
    // Force it: the hook never enables touch for a spectator.
    h.touchOn = true
    driveTouch(h)
    expect(h.events.sent).toEqual([])
    expect(h.stateCh.sent).toEqual([])
  })

  it("positive control: the same drive as a player writes every phase on input-events", () => {
    const { h } = hook({ slots: { 0: 1 } })
    withTouch(h)
    expect(h.touchWanted()).toBe(true)
    h.renderTouch()
    expect(h.touchOn).toBe(true)
    const evs = driveTouch(h)
    const sent = h.events.sent
    expect(sent.every(m => m.t === "touch" && m.src === 0 && !("slot" in m))).toBe(true)
    expect(sent.map(m => `${m.ph}:${m.id}`)).toEqual([
      "down:0",
      "up:0",
      "down:0",
      "down:1",
      "move:0",
      "move:1",
      "cancel:0",
      "cancel:1",
      "down:0",
      "cancel:0",
    ])
    expect(h.stateCh.sent).toEqual([])
    // Handled pointer events, and only those, were preventDefaulted.
    expect(evs.every(e => e.prevented)).toBe(true)
  })

  it("a mouse on a player's well is neither forwarded nor prevented", () => {
    const { h } = hook({ slots: { 0: 0 } })
    withTouch(h)
    h.renderTouch()
    const e = { ...pointer("pointerdown", 1, 800, 450), pointerType: "mouse" }
    e.preventDefault = () => (e.prevented = true)
    h.onPointer(e)
    expect(e.prevented).toBe(false)
    expect(h.events.sent).toEqual([])
  })
})

describe("the hook writes the data channels in exactly one place", () => {
  it("both channel sends sit inside initInput's InputRouter", () => {
    const src = readFileSync(fileURLToPath(new URL("../js/hooks/game_stream.js", import.meta.url)), "utf8")
    const sends = src.match(/\.send\(/g) || []
    expect(sends).toHaveLength(2)
    const start = src.indexOf("this.router = new InputRouter({")
    const end = src.indexOf("this.keys = new KeyForwarder({", start)
    expect(start).toBeGreaterThan(0)
    const inside = src.slice(start, end).match(/\.send\(/g) || []
    expect(inside).toHaveLength(2)
  })
})
