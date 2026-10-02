import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import GameStream from "../js/hooks/game_stream.js"

/**
 * Touch through the REAL hook (task 01a0fe45 stage 2): mounted, attach, the
 * peer's data channels, listen's pointer and click wiring, the footer, every
 * release trigger, and destroyed, on a small fake DOM.
 *
 * The well is 1600x900 and shows a 16:9 frame (no bars), so a pointer at
 * (800, 450) is (0.5, 0.5). The attach reply makes this peer P1 (src 0 to
 * slot 0) on a multi host; `touch` rides its roster, as core sends it.
 */

class FakeNode {
  constructor(dataset = {}) {
    this.dataset = dataset
    this.hidden = false
    this.textContent = ""
    this.listeners = new Map()
    const cls = new Set()
    this.classList = {
      toggle: (c, on) => (on ? cls.add(c) : cls.delete(c)),
      add: c => cls.add(c),
      remove: c => cls.delete(c),
      contains: c => cls.has(c),
    }
    this.attrs = new Map()
    this.captured = []
    this.style = {
      props: new Map(),
      setProperty: (k, v) => this.style.props.set(k, v),
      removeProperty: k => this.style.props.delete(k),
    }
  }
  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, [])
    this.listeners.get(type).push(fn)
  }
  removeEventListener(type, fn) {
    this.listeners.set(
      type,
      (this.listeners.get(type) || []).filter(f => f !== fn),
    )
  }
  fire(type, e = {}) {
    const ev = { type, target: this, stopPropagation() {}, prevented: false, ...e }
    ev.preventDefault = () => (ev.prevented = true)
    for (const fn of this.listeners.get(type) || []) fn(ev)
    return ev
  }
  click() {
    return this.fire("click")
  }
  setAttribute(k, v) {
    this.attrs.set(k, String(v))
  }
  getAttribute(k) {
    return this.attrs.has(k) ? this.attrs.get(k) : null
  }
  hasAttribute(k) {
    return this.attrs.has(k)
  }
  removeAttribute(k) {
    this.attrs.delete(k)
  }
  setPointerCapture(id) {
    this.captured.push(id)
  }
  querySelector() {
    return null
  }
}

const PANELS = ["unavailable", "building", "connecting", "live", "ended", "failed", "takeover", "elsewhere"]

function hub() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, [])
      listeners.get(type).push(fn)
    },
    removeEventListener(type, fn) {
      listeners.set(
        type,
        (listeners.get(type) || []).filter(f => f !== fn),
      )
    },
    fire(type, e = {}) {
      for (const fn of listeners.get(type) || []) fn({ type, ...e })
    },
  }
}

function wrapper(sessionId) {
  const el = new FakeNode({ sessionId, canvasId: `c-${sessionId}`, nodeId: "n1", state: "live" })
  el.rect = { left: 0, top: 0, right: 1600, bottom: 900 }
  el.onScreen = true
  el.getClientRects = () => (el.onScreen ? [el.rect] : [])
  el.getBoundingClientRect = () => el.rect
  el.contains = node => node === el || (node && node.owner === el)
  const video = Object.assign(new FakeNode(), {
    videoWidth: 1920,
    videoHeight: 1080,
    play: () => Promise.resolve(),
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1600, height: 900 }),
  })
  const parts = {
    "[data-gs-video]": video,
    "[data-gs-live-dot]": new FakeNode(),
    "[data-gs-end]": new FakeNode(),
    "[data-gs-well]": new FakeNode(),
    "[data-gs-controller]": new FakeNode(),
    "[data-gs-hint]": new FakeNode(),
    "[data-gs-stats]": new FakeNode(),
    "[data-gs-capture]": new FakeNode(),
  }
  for (const node of Object.values(parts)) node.owner = el
  const panels = PANELS.map(name => {
    const p = new FakeNode({ gsPanel: name })
    p.hidden = true
    p.owner = el
    return p
  })
  el.panels = panels
  el.parts = parts
  el.querySelector = sel => parts[sel] || null
  el.querySelectorAll = sel => (sel === "[data-gs-panel]" ? panels : parts[sel] ? [parts[sel]] : [])
  return el
}

class FakePC {
  constructor() {
    this.iceGatheringState = "complete"
    this.connectionState = "new"
    FakePC.all.push(this)
  }
  async setRemoteDescription() {}
  async createAnswer() {
    return { type: "answer", sdp: "answer" }
  }
  async setLocalDescription(d) {
    this.localDescription = d
  }
  addEventListener() {}
  close() {
    this.connectionState = "closed"
  }
}
FakePC.all = []

function channel(label) {
  const ch = new FakeNode()
  return Object.assign(ch, {
    label,
    readyState: "open",
    sent: [],
    send(data) {
      this.sent.push(JSON.parse(data))
    },
  })
}

const TOUCH_ON = { enabled: true, slop_px: 8, move_hz: 60, variant: null }
const TOUCH_OFF = { enabled: false, slop_px: 8, move_hz: 60, variant: null }

function roster(touch) {
  const r = { multi: true, max_players: 2, slots: { 0: { peer_id: "peer-1", name: "Rowan" } }, spectators: 0, names: [] }
  // null: an older core that sends no touch map at all.
  if (touch !== null) r.touch = touch
  return r
}

let seq = 0
let pushes

async function settle() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

// Mounts, attaches as P1, answers the offer, opens both channels and shows a
// decoded frame, so the copy is live.
async function live({ touch = TOUCH_ON, slots = { 0: 0 } } = {}) {
  const sessionId = `s-${++seq}`
  const el = wrapper(sessionId)
  const h = Object.create(GameStream)
  h.el = el
  h.handleEvent = () => {}
  h.pushEvent = (event, payload, cb) => {
    pushes.push({ event, payload })
    let reply = { ok: true }
    if (event === "game_stream_attach") {
      reply = {
        ok: true,
        viewer: true,
        viewer_token: "tok",
        peer_id: "peer-1",
        slots,
        roster: roster(touch),
        status: { state: "live" },
        pending_offer: { type: "offer", sdp: "v=0" },
      }
    }
    if (event === "game_stream_leave") reply = { ok: true, slots: {}, roster: roster(touch) }
    queueMicrotask(() => cb(reply))
  }
  h.mounted()
  await settle()
  const pc = FakePC.all[FakePC.all.length - 1]
  const events = channel("input-events")
  const state = channel("input-state")
  pc.ondatachannel({ channel: events })
  pc.ondatachannel({ channel: state })
  h.frameSeen(h.pcId)
  const well = el.parts["[data-gs-well]"]
  const touches = () => events.sent.filter(m => m.t === "touch")
  return { h, el, well, pc, events, state, touches }
}

function down(well, id = 1, x = 800, y = 450, pointerType = "touch") {
  return well.fire("pointerdown", { pointerId: id, pointerType, clientX: x, clientY: y })
}

describe("touch through the real hook", () => {
  let prior

  function setup({ coarse }) {
    prior = {
      document: globalThis.document,
      window: globalThis.window,
      RTCPeerConnection: globalThis.RTCPeerConnection,
      requestAnimationFrame: globalThis.requestAnimationFrame,
      cancelAnimationFrame: globalThis.cancelAnimationFrame,
    }
    const doc = hub()
    globalThis.document = Object.assign(doc, {
      body: { nodeType: 1, tagName: "BODY" },
      activeElement: null,
      fullscreenElement: null,
      visibilityState: "visible",
      createElement: () => ({ getContext: () => ({}) }),
      elementFromPoint: () => null,
    })
    globalThis.window = Object.assign(hub(), {
      innerWidth: 1600,
      innerHeight: 900,
      matchMedia: q => ({ matches: coarse && q === "(pointer: coarse)" }),
    })
    globalThis.RTCPeerConnection = FakePC
    globalThis.requestAnimationFrame = () => 1
    globalThis.cancelAnimationFrame = () => {}
  }

  beforeEach(() => {
    vi.useFakeTimers()
    pushes = []
    FakePC.all = []
  })

  afterEach(() => {
    vi.useRealTimers()
    for (const [k, v] of Object.entries(prior)) globalThis[k] = v
  })

  describe("a host WITHOUT touch.enabled is exactly as before", () => {
    it.each([
      ["no touch map (older core)", null],
      ["touch.enabled false", TOUCH_OFF],
    ])("%s: no data-gs-touch, no sends, and a tap still clicks to capture", async (_label, touch) => {
      setup({ coarse: true })
      const { h, well, events, el } = await live({ touch })
      expect(h.panel).toBe("live")
      expect(h.router.player).toBe(true)
      expect(well.hasAttribute("data-gs-touch")).toBe(false)
      const e = down(well)
      well.fire("pointerup", { pointerId: 1, pointerType: "touch", clientX: 800, clientY: 450 })
      expect(e.prevented).toBe(false)
      expect(events.sent).toEqual([])
      // The Click to play panel shows and the footer is main's.
      expect(el.panels.find(p => p.dataset.gsPanel === "live").hidden).toBe(false)
      expect(el.parts["[data-gs-controller]"].textContent).toBe("Connect a controller to play on this device")
      expect(el.parts["[data-gs-hint]"].textContent).toBe("Click to play")
      // The compat click is not swallowed: click-to-capture still works.
      well.click()
      expect(h.capture.captured).toBe(true)
      h.destroyed()
    })
  })

  describe("a host WITH touch.enabled", () => {
    it("turns the well on, sends a tap, and swallows its compat click", async () => {
      setup({ coarse: true })
      const { h, well, el, touches } = await live()
      expect(well.getAttribute("data-gs-touch")).toBe("on")
      // A phone: no Click to play panel, and the footer says what to do.
      expect(el.panels.every(p => p.hidden)).toBe(true)
      expect(el.parts["[data-gs-controller]"].textContent).toBe("Touch the game to play")
      expect(el.parts["[data-gs-hint]"].textContent).toBe("")

      expect(h.audio.activated).toBeFalsy()
      const e = down(well)
      expect(e.prevented).toBe(true)
      expect(well.captured).toEqual([1])
      expect(h.audio.activated).toBe(true)
      well.fire("pointerup", { pointerId: 1, pointerType: "touch", clientX: 800, clientY: 450 })
      expect(touches()).toEqual([
        { t: "touch", src: 0, id: 0, ph: "down", x: 0.5, y: 0.5 },
        { t: "touch", src: 0, id: 0, ph: "up", x: 0.5, y: 0.5 },
      ])
      well.click()
      expect(h.capture.captured).toBe(false)
      h.destroyed()
    })

    it("a mouse on the same well is not forwarded and still clicks to capture", async () => {
      setup({ coarse: false })
      const { h, well, events, el } = await live()
      expect(well.getAttribute("data-gs-touch")).toBe("on")
      // A fine pointer keeps the Click to play panel.
      expect(el.panels.find(p => p.dataset.gsPanel === "live").hidden).toBe(false)
      const e = down(well, 1, 800, 450, "mouse")
      expect(e.prevented).toBe(false)
      expect(events.sent).toEqual([])
      well.click()
      expect(h.capture.captured).toBe(true)
      h.destroyed()
    })

    it("the rect is read per event: a resized well maps against its new box", async () => {
      setup({ coarse: true })
      const { h, well, el, touches } = await live()
      const video = el.parts["[data-gs-video]"]
      // Rotated to landscape: an 844x390 well pillarboxes the 16:9 frame.
      video.getBoundingClientRect = () => ({ left: 0, top: 0, width: 844, height: 390 })
      const cw = (390 * 16) / 9
      const left = (844 - cw) / 2
      expect(down(well, 1, left / 2, 200).prevented).toBe(false)
      down(well, 2, left + cw / 4, 195)
      expect(touches()[0].x).toBeCloseTo(0.25, 9)
      expect(touches()[0].y).toBeCloseTo(0.5, 9)
      h.destroyed()
    })

    it("a portrait frame gives the well its own aspect; landscape keeps aspect-video", async () => {
      setup({ coarse: true })
      const { h, el, well } = await live()
      const video = el.parts["[data-gs-video]"]
      video.videoWidth = 1080
      video.videoHeight = 1920
      video.fire("resize")
      expect(well.hasAttribute("data-gs-tall")).toBe(true)
      expect(well.style.props.get("--gs-aspect")).toBe("1080 / 1920")
      video.videoWidth = 1920
      video.videoHeight = 1080
      video.fire("resize")
      expect(well.hasAttribute("data-gs-tall")).toBe(false)
      expect(well.style.props.has("--gs-aspect")).toBe(false)
      h.destroyed()
    })
  })

  describe("every active touch is cancelled on a lost pointer", () => {
    const triggers = [
      ["window blur", ({}) => globalThis.window.fire("blur")],
      [
        "visibilitychange to hidden",
        () => {
          globalThis.document.visibilityState = "hidden"
          globalThis.document.fire("visibilitychange")
        },
      ],
      ["pagehide", () => globalThis.window.fire("pagehide")],
      ["the input-events channel closing", ({ events }) => events.fire("close")],
      [
        "the peer connection closing",
        ({ pc }) => {
          pc.connectionState = "closed"
          pc.onconnectionstatechange()
        },
      ],
      ["leaving (src 0 loses its slot)", async ({ h }) => {
        await h.leave()
      }],
      ["being displaced (viewer transfer)", ({ h }) => h.onDisplaced({ slot: 0, by: "Harper" })],
      ["touch turning off", ({ h }) => h.setRoster(roster(TOUCH_OFF))],
      ["destroyed", ({ h }) => h.destroyed()],
    ]

    it.each(triggers)("%s", async (_label, trigger) => {
      setup({ coarse: true })
      const ctx = await live()
      const { well, touches } = ctx
      down(well, 1, 400, 450)
      down(well, 2, 1200, 450)
      expect(touches().map(m => m.ph)).toEqual(["down", "down"])
      await trigger(ctx)
      await settle()
      const cancels = touches().filter(m => m.ph === "cancel")
      expect(cancels.map(m => m.id).sort()).toEqual([0, 1])
      expect(ctx.h.touches.count).toBe(0)
      if (!ctx.h.dead) ctx.h.destroyed()
    })

    it("pointercancel on the well cancels that touch only", async () => {
      setup({ coarse: true })
      const { h, well, touches } = await live()
      down(well, 1, 400, 450)
      down(well, 2, 1200, 450)
      const e = well.fire("pointercancel", { pointerId: 2, pointerType: "touch", clientX: 0, clientY: 0 })
      expect(e.prevented).toBe(true)
      expect(touches().map(m => `${m.ph}:${m.id}`)).toEqual(["down:0", "down:1", "cancel:1"])
      h.destroyed()
    })

    it("after a lost slot, a new touch sends nothing and the well turns off", async () => {
      setup({ coarse: true })
      const { h, well, touches } = await live()
      h.onDisplaced({ slot: 0, by: "Harper" })
      expect(well.hasAttribute("data-gs-touch")).toBe(false)
      const n = touches().length
      expect(down(well).prevented).toBe(false)
      expect(touches()).toHaveLength(n)
      h.destroyed()
    })
  })
})
