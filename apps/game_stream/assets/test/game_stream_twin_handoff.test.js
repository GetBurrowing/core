import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import GameStream from "../js/hooks/game_stream.js"

/**
 * Two copies of one game_stream node in ONE page (task 01a0ee4f stage 2):
 * the inline chat copy, and the canvas panel copy the person opened through
 * the canvas selector. Opening the panel mounts its copy, which attaches and
 * suspends the inline copy. On origin/main the suspended copy called
 * `show("connecting")` after closing its pc, so the inline copy sat on
 * "Connecting..." beside a panel that was live on its own pc: a Connecting
 * with no pc behind it.
 *
 * Drives the REAL hook (mounted, attach, suspend, tick, listen's click
 * wiring, destroyed) on a small fake DOM. `onScreen` is the hook's own
 * check: each copy has its own rectangle, and `document.elementFromPoint`
 * answers with the on-screen copy under the point. Every `show()` call and
 * every write of the wrapper's `data-state` is recorded, so "never
 * Connecting" is checked at every step of the handoff, not only at the end.
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
  click() {
    const e = { target: this, stopPropagation() {}, preventDefault() {} }
    for (const fn of this.listeners.get("click") || []) fn(e)
  }
  setAttribute(k, v) {
    this.attrs.set(k, v)
  }
  getAttribute(k) {
    return this.attrs.has(k) ? this.attrs.get(k) : null
  }
  removeAttribute(k) {
    this.attrs.delete(k)
  }
  querySelector() {
    return null
  }
}

const PANELS = ["unavailable", "building", "connecting", "live", "ended", "failed", "takeover", "elsewhere"]

// Every copy in the page; elementFromPoint answers from these.
let page = []

function wrapper({ sessionId, left, stateLog, state: initial = "live" }) {
  const data = { sessionId, canvasId: `c-${sessionId}`, nodeId: "n1", state: initial }
  // Record every data-state write the hook makes.
  let state = data.state
  Object.defineProperty(data, "state", {
    get: () => state,
    set: v => {
      state = v
      stateLog.push(v)
    },
    enumerable: true,
  })
  const el = new FakeNode(data)
  el.onScreen = true
  el.rect = { left, top: 0, right: left + 400, bottom: 300 }
  el.getClientRects = () => (el.onScreen ? [el.rect] : [])
  el.getBoundingClientRect = () => el.rect
  el.contains = node => node === el || (node && node.owner === el)

  const parts = {
    "[data-gs-video]": Object.assign(new FakeNode(), { play: () => Promise.resolve() }),
    "[data-gs-live-dot]": new FakeNode(),
    "[data-gs-end]": new FakeNode(),
    "[data-gs-well]": new FakeNode(),
    "[data-gs-play-here]": new FakeNode(),
    "[data-gs-play-here-twin]": new FakeNode(),
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
    this.closed = false
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
    this.closed = true
    this.connectionState = "closed"
  }
}
FakePC.all = []

function listenerHub() {
  return { addEventListener() {}, removeEventListener() {} }
}

let pushes
let seq = 0

function mount(name, { sessionId, left, onScreen = true, state }) {
  const stateLog = []
  const shows = []
  const el = wrapper({ sessionId, left, stateLog, state })
  el.onScreen = onScreen
  page.push(el)
  const h = Object.create(GameStream)
  h.name = name
  h.el = el
  h.stateLog = stateLog
  h.shows = shows
  // Record every show() with the pc the copy held at that moment.
  h.show = function (panel) {
    shows.push({ panel, pc: this.pc, rendered: this.el.getClientRects().length > 0 })
    return GameStream.show.call(this, panel)
  }
  h.handleEvent = () => {}
  h.pushEvent = (event, payload, cb) => {
    pushes.push({ copy: name, event, payload })
    let reply = { ok: true }
    if (event === "game_stream_attach") {
      reply = {
        ok: true,
        viewer: true,
        viewer_token: "tok",
        peer_id: "peer-1",
        status: { state: "live" },
        pending_offer: { type: "offer", sdp: "v=0" },
      }
    }
    queueMicrotask(() => cb(reply))
  }
  h.mounted()
  return h
}

// Lets every pending attach / answer promise chain run.
async function settle() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

// A decoded frame on the copy's current pc, as requestVideoFrameCallback
// would report it.
function frame(h) {
  h.frameSeen(h.pcId)
}

function since(log, mark) {
  return log.slice(mark)
}

describe("a sidebar the person opened holds the stream: the inline copy shows elsewhere", () => {
  let priorDocument, priorWindow, priorPC, sessionId

  beforeEach(() => {
    vi.useFakeTimers()
    pushes = []
    page = []
    FakePC.all = []
    sessionId = `s-${++seq}`
    priorDocument = globalThis.document
    priorWindow = globalThis.window
    priorPC = globalThis.RTCPeerConnection
    globalThis.document = {
      ...listenerHub(),
      body: { nodeType: 1, tagName: "BODY" },
      activeElement: null,
      fullscreenElement: null,
      visibilityState: "visible",
      createElement: () => ({ getContext: () => ({}) }),
      elementFromPoint: (x, y) =>
        page.find(el => el.onScreen && x >= el.rect.left && x < el.rect.right && y >= el.rect.top && y < el.rect.bottom) ||
        null,
    }
    globalThis.window = { ...listenerHub(), innerWidth: 1440, innerHeight: 900 }
    globalThis.RTCPeerConnection = FakePC
  })

  afterEach(() => {
    vi.useRealTimers()
    globalThis.document = priorDocument
    globalThis.window = priorWindow
    globalThis.RTCPeerConnection = priorPC
  })

  // The inline copy plays; the person opens the canvas panel, whose copy
  // mounts on screen beside it and attaches.
  async function handoff() {
    const a = mount("inline", { sessionId, left: 0 })
    await settle()
    frame(a)
    expect(a.active()).toBe(true)
    expect(a.panel).toBe("live")
    expect(a.pc).not.toBeNull()
    const aPc = a.pc
    const mark = { shows: a.shows.length, states: a.stateLog.length }
    const b = mount("panel", { sessionId, left: 800 })
    await settle()
    frame(b)
    return { a, b, aPc, mark }
  }

  it("(a) the holder ends on elsewhere with no pc, and never shows Connecting during the handoff", async () => {
    const { a, b, aPc, mark } = await handoff()

    expect(b.active()).toBe(true)
    expect(b.panel).toBe("live")
    expect(b.pc).not.toBeNull()

    expect(a.active()).toBe(false)
    expect(a.suspended).toBe(true)
    expect(a.pc).toBeNull()
    expect(aPc.closed).toBe(true)
    expect(a.panel).toBe("elsewhere")
    expect(a.el.dataset.state).toBe("elsewhere")

    // Every step of the handoff, not just the end.
    const shows = since(a.shows, mark.shows)
    expect(shows.map(s => s.panel)).toEqual(["elsewhere"])
    expect(shows.every(s => s.pc === null)).toBe(true)
    expect(since(a.stateLog, mark.states)).not.toContain("connecting")

    // Only the elsewhere panel shows, with the twin Play here; End is hidden.
    const visible = a.el.panels.filter(p => !p.hidden).map(p => p.dataset.gsPanel)
    expect(visible).toEqual(["elsewhere"])
    expect(a.el.parts["[data-gs-end]"].hidden).toBe(true)

    // Sticky while the panel copy is on screen: ticks and status messages
    // (which the server sends to every copy) leave it alone.
    for (let i = 0; i < 3; i++) a.tick()
    a.onServer({ type: "status", session_id: sessionId, status: { state: "connecting" } })
    a.onServer({ type: "status", session_id: sessionId, status: { state: "live" } })
    expect(a.panel).toBe("elsewhere")
    expect(a.pc).toBeNull()
    expect(b.active()).toBe(true)
    expect(since(a.stateLog, mark.states)).not.toContain("connecting")
    expect(since(a.shows, mark.shows).some(s => s.panel === "connecting")).toBe(false)

    a.destroyed()
    b.destroyed()
  })

  it("(a) an ended session still shows ended when the twin takes over, not elsewhere", async () => {
    const a = mount("inline", { sessionId, left: 0 })
    await settle()
    a.applyStatus({ state: "ended" })
    expect(a.panel).toBe("ended")
    const b = mount("panel", { sessionId, left: 800 })
    await settle()
    expect(b.active()).toBe(true)
    expect(a.panel).toBe("ended")
    a.destroyed()
    b.destroyed()
  })

  it("(b) closing the panel (its copy destroyed) lets the inline copy's tick attach it again", async () => {
    const { a, b } = await handoff()
    const attachesBefore = pushes.filter(p => p.copy === "inline" && p.event === "game_stream_attach").length

    b.destroyed()
    page = page.filter(el => el !== b.el)
    a.tick()
    await settle()

    expect(a.active()).toBe(true)
    expect(a.suspended).toBe(false)
    const attaches = pushes.filter(p => p.copy === "inline" && p.event === "game_stream_attach")
    expect(attaches.length).toBe(attachesBefore + 1)
    expect(attaches[attaches.length - 1].payload.mode).toBe("take")
    expect(a.pc).not.toBeNull()
    frame(a)
    expect(a.panel).toBe("live")
    a.destroyed()
  })

  it("(b) positive control: with the panel copy still on screen, the tick does NOT take the stream back", async () => {
    const { a, b } = await handoff()
    a.tick()
    await settle()
    expect(a.active()).toBe(false)
    expect(b.active()).toBe(true)
    expect(a.panel).toBe("elsewhere")
    a.destroyed()
    b.destroyed()
  })

  it("(c) the inline twin Play here attaches the inline copy and suspends the panel into elsewhere, with no take-over", async () => {
    const { a, b } = await handoff()
    const bPc = b.pc
    const bMark = { shows: b.shows.length, states: b.stateLog.length }
    const mark = pushes.length

    a.el.parts["[data-gs-play-here-twin]"].click()
    await settle()

    expect(a.active()).toBe(true)
    expect(a.pc).not.toBeNull()
    expect(b.active()).toBe(false)
    expect(b.pc).toBeNull()
    expect(bPc.closed).toBe(true)
    expect(b.panel).toBe("elsewhere")
    expect(since(b.stateLog, bMark.states)).not.toContain("connecting")

    const after = pushes.slice(mark)
    expect(after.filter(p => p.event === "game_stream_take_over")).toEqual([])
    expect(after.filter(p => p.event === "game_stream_attach").map(p => [p.copy, p.payload.mode])).toEqual([
      ["inline", "take"],
    ])

    // B, still on screen, does not grab it back on its own tick.
    b.tick()
    await settle()
    expect(a.active()).toBe(true)
    expect(b.panel).toBe("elsewhere")
    a.destroyed()
    b.destroyed()
  })
  // Task 01a0ee4f stage 3 (behavioural gate finding 1). At a phone width the
  // person opens the canvas, so the full-screen overlay copy holds the
  // stream, the inline chat copy is covered and suspended, and the desktop
  // #canvas-sidebar copy mounts HIDDEN (`hidden lg:flex`). Crossing lg to
  // 1440 renders the sidebar copy while the inline copy takes the stream
  // back. On origin/main and at stage 2 the sidebar copy kept its mount-time
  // Connecting forever, with no pc, no attach and no stuck clock. It must show
  // elsewhere with Play here, and NOT take the stream itself (a resize is not
  // a deliberate open).
  describe("a copy that mounted hidden and becomes rendered while a twin holds the stream", () => {
    let observers, priorRO

    beforeEach(() => {
      observers = new Map()
      priorRO = globalThis.ResizeObserver
      // The hook's own ResizeObserver path: each copy's callback is kept so
      // the test fires it the way a breakpoint crossing would.
      globalThis.ResizeObserver = class {
        constructor(cb) {
          this.cb = cb
        }
        observe(el) {
          observers.set(el, this.cb)
        }
        disconnect() {}
      }
    })

    afterEach(() => {
      globalThis.ResizeObserver = priorRO
    })

    function resize(...copies) {
      for (const c of copies) observers.get(c.el)()
    }

    function renderedShows(h, mark = 0) {
      return h.shows.slice(mark).filter(s => s.rendered)
    }

    it.each(["connecting", "live"])(
      "two copies: B (mount data-state %s) shows elsewhere with no pc, never Connecting while rendered, and does not attach",
      async mountState => {
        const a = mount("inline", { sessionId, left: 0 })
        await settle()
        frame(a)
        expect(a.active()).toBe(true)

        const b = mount("sidebar", { sessionId, left: 800, onScreen: false, state: mountState })
        await settle()
        expect(b.suspended).toBe(true)

        // The crossing renders B beside the live A.
        b.el.onScreen = true
        resize(b, a)
        for (let i = 0; i < 3; i++) {
          vi.advanceTimersByTime(1000)
          frame(a) // A keeps decoding
          b.tick()
          a.tick()
        }
        await settle()

        expect(b.active()).toBe(false)
        expect(b.pc).toBeNull()
        expect(b.panel).toBe("elsewhere")
        expect(b.el.dataset.state).toBe("elsewhere")
        const visible = b.el.panels.filter(p => !p.hidden).map(p => p.dataset.gsPanel)
        expect(visible).toEqual(["elsewhere"])
        // Every show() B ever made: after the hidden mount-time one, none is
        // Connecting, and none made while rendered is Connecting.
        expect(b.shows.slice(1).map(s => s.panel)).not.toContain("connecting")
        expect(renderedShows(b).map(s => s.panel)).not.toContain("connecting")
        expect(b.shows.every(s => s.pc === null)).toBe(true)
        // B sent no attach: it did not take the stream on the resize.
        expect(pushes.filter(p => p.copy === "sidebar" && p.event === "game_stream_attach")).toEqual([])
        expect(a.active()).toBe(true)
        expect(a.panel).toBe("live")

        // B's Play here attaches B and suspends A into elsewhere, no take-over.
        const mark = pushes.length
        const aMark = a.stateLog.length
        b.el.parts["[data-gs-play-here-twin]"].click()
        await settle()
        frame(b)
        expect(b.active()).toBe(true)
        expect(b.pc).not.toBeNull()
        expect(b.panel).toBe("live")
        expect(a.active()).toBe(false)
        expect(a.pc).toBeNull()
        expect(a.panel).toBe("elsewhere")
        expect(a.stateLog.slice(aMark)).not.toContain("connecting")
        const after = pushes.slice(mark)
        expect(after.filter(p => p.event === "game_stream_take_over")).toEqual([])
        expect(after.filter(p => p.event === "game_stream_attach").map(p => [p.copy, p.payload.mode])).toEqual([
          ["sidebar", "take"],
        ])
        a.destroyed()
        b.destroyed()
      },
    )

    // The reviewer's exact sequence, with the resize callbacks fired in both
    // orders: the sidebar's first (the overlay still holds and is off screen)
    // and the inline copy's first (the inline copy already holds).
    it.each([
      ["sidebar first", ["sidebar", "inline"]],
      ["inline first", ["inline", "sidebar"]],
    ])("390 overlay open, then 1440: inline reclaims, sidebar shows elsewhere, overlay elsewhere (%s)", async (_l, order) => {
      // 390: the inline copy played, then the overlay opened over it.
      const inline = mount("inline", { sessionId, left: 0 })
      await settle()
      frame(inline)
      const sidebar = mount("sidebar", { sessionId, left: 800, onScreen: false, state: "connecting" })
      const overlay = mount("overlay", { sessionId, left: 0 })
      inline.el.onScreen = false // covered by the fixed inset-0 overlay
      page = [overlay.el, inline.el, sidebar.el]
      await settle()
      frame(overlay)
      expect(overlay.active()).toBe(true)
      expect(inline.panel).toBe("elsewhere")
      expect(sidebar.panel).toBe("elsewhere")

      // 1440 with the overlay still OPEN: it goes lg:hidden, and the inline
      // and sidebar copies render.
      overlay.el.onScreen = false
      inline.el.onScreen = true
      sidebar.el.onScreen = true
      const copies = { inline, sidebar }
      const sMark = sidebar.shows.length
      resize(...order.map(n => copies[n]))
      await settle()
      frame(inline)
      for (let i = 0; i < 15; i++) {
        vi.advanceTimersByTime(1000)
        frame(inline) // the inline copy keeps decoding
        for (const c of [inline, sidebar, overlay]) c.tick()
      }
      await settle()

      expect(inline.active()).toBe(true)
      expect(inline.panel).toBe("live")
      expect(sidebar.active()).toBe(false)
      expect(sidebar.pc).toBeNull()
      expect(sidebar.panel).toBe("elsewhere")
      expect(sidebar.shows.slice(sMark).map(s => s.panel)).not.toContain("connecting")
      expect(renderedShows(sidebar).map(s => s.panel)).not.toContain("connecting")
      expect(overlay.panel).toBe("elsewhere")
      expect(overlay.pc).toBeNull()
      expect(pushes.filter(p => p.copy === "sidebar" && p.event === "game_stream_attach")).toEqual([])
      for (const c of [inline, sidebar, overlay]) c.destroyed()
    })

    it("mounted hidden while a twin holds: on elsewhere before it is ever rendered", async () => {
      const a = mount("inline", { sessionId, left: 0 })
      await settle()
      const b = mount("sidebar", { sessionId, left: 800, onScreen: false, state: "connecting" })
      expect(b.panel).toBe("elsewhere")
      expect(b.el.dataset.state).toBe("elsewhere")
      a.destroyed()
      b.destroyed()
    })

    it("mounted hidden BEFORE any copy held the stream: a twin's attach moves it to elsewhere", async () => {
      const b = mount("sidebar", { sessionId, left: 800, onScreen: false, state: "connecting" })
      await settle()
      expect(b.panel).toBe("connecting") // nobody holds yet; it is hidden
      const a = mount("inline", { sessionId, left: 0 })
      await settle()
      frame(a)
      expect(a.active()).toBe(true)
      expect(b.panel).toBe("elsewhere")
      b.el.onScreen = true
      resize(b)
      await settle()
      expect(b.panel).toBe("elsewhere")
      expect(renderedShows(b).map(s => s.panel)).not.toContain("connecting")
      expect(pushes.filter(p => p.copy === "sidebar" && p.event === "game_stream_attach")).toEqual([])
      a.destroyed()
      b.destroyed()
    })

    it("positive control: rendered with NO twin holding the claim, the copy still attaches", async () => {
      const b = mount("sidebar", { sessionId, left: 800, onScreen: false, state: "connecting" })
      await settle()
      expect(b.active()).toBe(false)
      expect(b.panel).toBe("connecting")
      b.el.onScreen = true
      resize(b)
      await settle()
      expect(b.active()).toBe(true)
      expect(b.pc).not.toBeNull()
      expect(pushes.filter(p => p.copy === "sidebar" && p.event === "game_stream_attach").length).toBe(1)
      b.destroyed()
    })

    it("positive control: a twin holding the claim OFF screen is still reclaimed from, not shown as elsewhere", async () => {
      const a = mount("overlay", { sessionId, left: 0 })
      await settle()
      const b = mount("sidebar", { sessionId, left: 800, onScreen: false, state: "connecting" })
      await settle()
      expect(b.panel).toBe("elsewhere")
      a.el.onScreen = false
      b.el.onScreen = true
      resize(b)
      await settle()
      expect(b.active()).toBe(true)
      expect(b.pc).not.toBeNull()
      expect(a.panel).toBe("elsewhere")
      a.destroyed()
      b.destroyed()
    })
  })
})
