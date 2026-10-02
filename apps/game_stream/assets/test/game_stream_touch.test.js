import { describe, it, expect } from "vitest"
import {
  TouchForwarder,
  TouchIds,
  contentRect,
  normalize,
  normalizeTouch,
  tallAspect,
} from "../js/hooks/lib/game_stream_touch.js"

/**
 * Touch input (task 01a0fe45 stage 2): the content-rect mapping, the id pool
 * and the forwarder, driven with a manual clock and scheduler.
 */

const close = (a, b) => expect(a).toBeCloseTo(b, 9)

describe("contentRect: the object-fit: contain box", () => {
  it("pillarbox: a 4:3 frame in a 16:9 element is centred with side bars", () => {
    const r = contentRect({ left: 10, top: 20, width: 1600, height: 900 }, 640, 480)
    close(r.width, 1200)
    close(r.height, 900)
    close(r.left, 10 + 200)
    close(r.top, 20)
  })

  it("letterbox: a 21:9 frame in a 16:9 element has bars top and bottom", () => {
    const r = contentRect({ left: 0, top: 100, width: 1600, height: 900 }, 2100, 900)
    close(r.width, 1600)
    close(r.height, (1600 / 2100) * 900)
    close(r.top, 100 + (900 - r.height) / 2)
    close(r.left, 0)
  })

  it("exact fit: a 16:9 frame fills a 16:9 element", () => {
    const r = contentRect({ left: 5, top: 7, width: 800, height: 450 }, 1920, 1080)
    expect(r).toEqual({ left: 5, top: 7, width: 800, height: 450 })
  })

  it("null without a decoded size or an element size", () => {
    expect(contentRect({ left: 0, top: 0, width: 100, height: 100 }, 0, 0)).toBeNull()
    expect(contentRect({ left: 0, top: 0, width: 0, height: 100 }, 640, 480)).toBeNull()
    expect(contentRect(null, 640, 480)).toBeNull()
  })
})

describe("normalize", () => {
  const rect = { left: 100, top: 50, width: 400, height: 200 }

  it("maps the content box to [0, 1]", () => {
    expect(normalize(100, 50, rect)).toEqual({ x: 0, y: 0, inside: true })
    expect(normalize(500, 250, rect)).toEqual({ x: 1, y: 1, inside: true })
    expect(normalize(300, 100, rect)).toEqual({ x: 0.5, y: 0.25, inside: true })
  })

  it("a point off the frame is clamped and reported outside", () => {
    expect(normalize(50, 300, rect)).toEqual({ x: 0, y: 1, inside: false })
    expect(normalize(900, 10, rect)).toEqual({ x: 1, y: 0, inside: false })
  })
})

describe("normalizeTouch and tallAspect", () => {
  it("only enabled: true turns touch on, with the tuning or its defaults", () => {
    expect(normalizeTouch(null)).toEqual({ enabled: false, slopPx: 8, moveHz: 60 })
    expect(normalizeTouch({ enabled: "true" }).enabled).toBe(false)
    expect(normalizeTouch({ enabled: true, slop_px: 12, move_hz: 30 })).toEqual({
      enabled: true,
      slopPx: 12,
      moveHz: 30,
    })
    expect(normalizeTouch({ enabled: true, move_hz: 0 }).moveHz).toBe(60)
  })

  it("a frame taller than 16:9 takes its own aspect; 16:9 and wider keep aspect-video", () => {
    expect(tallAspect(1080, 1920)).toBe("1080 / 1920")
    expect(tallAspect(1440, 1080)).toBe("1440 / 1080")
    expect(tallAspect(1920, 1080)).toBeNull()
    expect(tallAspect(2560, 1080)).toBeNull()
    expect(tallAspect(0, 0)).toBeNull()
  })
})

describe("TouchIds", () => {
  it("gives the smallest free id and keeps it for the pointer's lifetime", () => {
    const ids = new TouchIds()
    expect(ids.acquire(101)).toBe(0)
    expect(ids.acquire(102)).toBe(1)
    expect(ids.acquire(103)).toBe(2)
    expect(ids.acquire(102)).toBe(1)
    expect(ids.release(101)).toBe(0)
    expect(ids.acquire(104)).toBe(0)
    expect(ids.get(103)).toBe(2)
  })

  it("an 11th concurrent pointer gets none", () => {
    const ids = new TouchIds()
    for (let p = 0; p < 10; p++) expect(ids.acquire(p)).toBe(p)
    expect(ids.acquire(10)).toBeNull()
    ids.release(4)
    expect(ids.acquire(10)).toBe(4)
  })
})

// A forwarder on a manual clock and scheduler, against a mutable element rect
// and decoded size.
function rig({ slopPx = 8, moveHz = 60, enabled = true } = {}) {
  const env = {
    t: 0,
    timers: [],
    sent: [],
    enabled,
    el: { left: 0, top: 0, width: 1600, height: 900 },
    vw: 1920,
    vh: 1080,
  }
  env.fwd = new TouchForwarder({
    isEnabled: () => env.enabled,
    send: m => env.sent.push(m),
    rect: () => contentRect(env.el, env.vw, env.vh),
    now: () => env.t,
    slopPx,
    moveHz,
    schedule: (fn, ms) => {
      const h = { fn, at: env.t + ms, done: false }
      env.timers.push(h)
      return h
    },
    unschedule: h => (h.done = true),
  })
  env.advance = ms => {
    env.t += ms
    for (const h of env.timers) {
      if (!h.done && h.at <= env.t) {
        h.done = true
        h.fn()
      }
    }
  }
  return env
}

const ev = (pointerId, clientX, clientY, pointerType = "touch") => ({ pointerId, clientX, clientY, pointerType })

describe("TouchForwarder: down", () => {
  it("a press on the frame sends down at its normalised point", () => {
    const r = rig()
    expect(r.fwd.pointerdown(ev(1, 800, 450))).toBe(true)
    expect(r.sent).toEqual([{ t: "touch", src: 0, id: 0, ph: "down", x: 0.5, y: 0.5 }])
  })

  it("a press in a letterbox bar sends nothing (4:3 frame, pillarbox at x < 200)", () => {
    const r = rig()
    r.vw = 640
    r.vh = 480
    expect(r.fwd.pointerdown(ev(1, 100, 450))).toBe(false)
    expect(r.sent).toEqual([])
    // Inside the content, the bar's width is subtracted: (500 - 200) / 1200.
    expect(r.fwd.pointerdown(ev(2, 500, 450))).toBe(true)
    expect(r.sent[0].x).toBeCloseTo(0.25, 9)
    expect(r.sent[0].y).toBeCloseTo(0.5, 9)
  })

  it("a letterboxed frame's y is measured from the content's top, not the element's", () => {
    const r = rig()
    // 2100x900 in 1600x900: content height 685.714..., top bar 107.142...
    r.vw = 2100
    r.vh = 900
    const top = (900 - (1600 / 2100) * 900) / 2
    expect(r.fwd.pointerdown(ev(1, 800, 50))).toBe(false)
    r.fwd.pointerdown(ev(2, 400, top + 10))
    expect(r.sent[0].x).toBeCloseTo(0.25, 9)
    expect(r.sent[0].y).toBeCloseTo(10 / ((1600 / 2100) * 900), 9)
  })

  it("mouse is never forwarded; pen is", () => {
    const r = rig()
    expect(r.fwd.pointerdown(ev(1, 800, 450, "mouse"))).toBe(false)
    expect(r.fwd.pointerup(ev(1, 800, 450, "mouse"))).toBe(false)
    expect(r.sent).toEqual([])
    expect(r.fwd.pointerdown(ev(2, 800, 450, "pen"))).toBe(true)
    expect(r.sent.map(m => m.ph)).toEqual(["down"])
  })

  it("nothing while disabled, and nothing before the video has a size", () => {
    const r = rig({ enabled: false })
    expect(r.fwd.pointerdown(ev(1, 800, 450))).toBe(false)
    r.enabled = true
    r.vw = 0
    expect(r.fwd.pointerdown(ev(1, 800, 450))).toBe(false)
    expect(r.sent).toEqual([])
  })
})

describe("TouchForwarder: devicePixelRatio does not enter", () => {
  // The same CSS layout at DPR 1, 2 and 3: CSS-px pointer positions and CSS-px
  // rects are identical, and the decoded frame is the same. The forwarder has
  // no DPR input, and globalThis.devicePixelRatio is set to prove it is not
  // read either.
  function run(dpr) {
    const prior = globalThis.devicePixelRatio
    globalThis.devicePixelRatio = dpr
    try {
      const r = rig()
      r.el = { left: 0, top: 40, width: 390, height: 219.375 }
      r.vw = 1280
      r.vh = 720
      r.fwd.pointerdown(ev(1, 97.5, 40 + 54.84375))
      r.advance(20)
      r.fwd.pointermove(ev(1, 300, 200))
      r.fwd.pointerup(ev(1, 300, 200))
      return r.sent
    } finally {
      globalThis.devicePixelRatio = prior
    }
  }

  it("DPR 1, 2 and 3 give identical output", () => {
    const one = run(1)
    expect(one[0]).toMatchObject({ ph: "down", x: 0.25, y: 0.25 })
    expect(run(2)).toEqual(one)
    expect(run(3)).toEqual(one)
  })
})

describe("TouchForwarder: rotation (the rect is read per event)", () => {
  it("a touch that spans a rotation maps each event against the rect of its moment", () => {
    const r = rig({ slopPx: 0 })
    // Portrait phone, landscape stream: 390x219 well, letterboxed none.
    r.el = { left: 0, top: 0, width: 390, height: 219.375 }
    r.vw = 1280
    r.vh = 720
    r.fwd.pointerdown(ev(1, 195, 109.6875))
    expect(r.sent[0]).toMatchObject({ x: 0.5, y: 0.5 })
    // Rotated to landscape: the well is now 844x390, the 16:9 frame is
    // pillarboxed to 693.33 wide, centred.
    r.el = { left: 0, top: 0, width: 844, height: 390 }
    const cw = (390 * 1280) / 720
    const left = (844 - cw) / 2
    r.advance(20)
    r.fwd.pointermove(ev(1, left + cw * 0.75, 390 * 0.25))
    expect(r.sent[1].ph).toBe("move")
    expect(r.sent[1].x).toBeCloseTo(0.75, 9)
    expect(r.sent[1].y).toBeCloseTo(0.25, 9)
    // A new press in the new pillar bar is not a touch.
    expect(r.fwd.pointerdown(ev(2, left / 2, 100))).toBe(false)
  })

  it("a resolution change mid-stream is picked up on the next event", () => {
    const r = rig({ slopPx: 0 })
    r.fwd.pointerdown(ev(1, 800, 450))
    r.vw = 1080
    r.vh = 1920 // portrait now: content 506.25 wide, centred
    r.advance(20)
    r.fwd.pointermove(ev(1, 800 - 506.25 / 4, 450))
    expect(r.sent[1].ph).toBe("move")
    expect(r.sent[1].x).toBeCloseTo(0.25, 9)
    expect(r.sent[1].y).toBeCloseTo(0.5, 9)
    // The old 16:9 mapping would have put that point at 0.4609.
    expect(r.sent[1].x).not.toBeCloseTo((800 - 506.25 / 4) / 1600, 3)
  })
})

describe("TouchForwarder: slop and coalescing", () => {
  it("no move until the pointer travels more than slop_px from its down", () => {
    const r = rig({ slopPx: 8 })
    r.fwd.pointerdown(ev(1, 800, 450))
    r.advance(100)
    expect(r.fwd.pointermove(ev(1, 805, 455))).toBe(true) // 7.07 px
    expect(r.fwd.pointermove(ev(1, 808, 450))).toBe(true) // exactly 8
    expect(r.sent.map(m => m.ph)).toEqual(["down"])
    r.fwd.pointermove(ev(1, 809, 450))
    expect(r.sent.map(m => m.ph)).toEqual(["down", "move"])
  })

  it("a tap that never left the slop lifts where it went down", () => {
    const r = rig({ slopPx: 8 })
    r.fwd.pointerdown(ev(1, 800, 450))
    r.fwd.pointermove(ev(1, 803, 452))
    r.fwd.pointerup(ev(1, 803, 452))
    expect(r.sent).toEqual([
      { t: "touch", src: 0, id: 0, ph: "down", x: 0.5, y: 0.5 },
      { t: "touch", src: 0, id: 0, ph: "up", x: 0.5, y: 0.5 },
    ])
  })

  it("at most one move per 1/move_hz per id, coalesced to the latest position", () => {
    const r = rig({ slopPx: 0, moveHz: 50 }) // 20 ms
    r.fwd.pointerdown(ev(1, 0, 0))
    r.fwd.pointermove(ev(1, 160, 0)) // sends at t=0 (first move)
    r.advance(5)
    r.fwd.pointermove(ev(1, 320, 0))
    r.advance(5)
    r.fwd.pointermove(ev(1, 480, 0))
    r.advance(5)
    r.fwd.pointermove(ev(1, 640, 0))
    expect(r.sent.filter(m => m.ph === "move").map(m => m.x)).toEqual([0.1])
    // The trailing move fires at t=20 with the LATEST point, not the first.
    r.advance(5)
    const moves = r.sent.filter(m => m.ph === "move")
    expect(moves.map(m => m.x)).toEqual([0.1, 0.4])
    // A drag that stops sends nothing more.
    r.advance(100)
    expect(r.sent.filter(m => m.ph === "move")).toHaveLength(2)
  })

  it("coalescing is per id: two fingers each get their own budget", () => {
    const r = rig({ slopPx: 0, moveHz: 50 })
    r.fwd.pointerdown(ev(1, 0, 0))
    r.fwd.pointerdown(ev(2, 1600, 900))
    r.fwd.pointermove(ev(1, 160, 0))
    r.fwd.pointermove(ev(2, 1440, 900))
    const moves = r.sent.filter(m => m.ph === "move")
    expect(moves.map(m => m.id)).toEqual([0, 1])
  })

  it("an up drops the pending trailing move and lifts at the up's point", () => {
    const r = rig({ slopPx: 0, moveHz: 50 })
    r.fwd.pointerdown(ev(1, 0, 0))
    r.fwd.pointermove(ev(1, 160, 0))
    r.advance(5)
    r.fwd.pointermove(ev(1, 320, 0))
    r.fwd.pointerup(ev(1, 480, 0))
    r.advance(50)
    expect(r.sent.map(m => [m.ph, m.x])).toEqual([
      ["down", 0],
      ["move", 0.1],
      ["up", 0.3],
    ])
  })

  it("a touch dragged off the frame is clamped to its edge", () => {
    const r = rig({ slopPx: 0 })
    r.vw = 640
    r.vh = 480 // pillarbox: content x in [200, 1400]
    r.fwd.pointerdown(ev(1, 800, 450))
    r.advance(20)
    r.fwd.pointermove(ev(1, 50, -40))
    expect(r.sent[1]).toMatchObject({ ph: "move", x: 0, y: 0 })
    r.fwd.pointerup(ev(1, 1590, 2000))
    expect(r.sent[2]).toMatchObject({ ph: "up", x: 1, y: 1 })
  })
})

describe("TouchForwarder: ids across interleaved pointers", () => {
  it("each pointer keeps its id; a freed id is reused by the next down", () => {
    const r = rig({ slopPx: 0 })
    r.fwd.pointerdown(ev(11, 100, 100))
    r.fwd.pointerdown(ev(22, 200, 100))
    r.fwd.pointerdown(ev(33, 300, 100))
    r.advance(20)
    r.fwd.pointermove(ev(22, 210, 120))
    r.fwd.pointerup(ev(11, 100, 100))
    r.fwd.pointermove(ev(33, 320, 120))
    r.fwd.pointerdown(ev(44, 400, 100))
    r.advance(20)
    r.fwd.pointermove(ev(22, 230, 140))
    r.fwd.pointerup(ev(33, 320, 120))
    r.fwd.pointerup(ev(22, 230, 140))
    r.fwd.pointerup(ev(44, 400, 100))
    expect(r.sent.map(m => `${m.ph}:${m.id}`)).toEqual([
      "down:0",
      "down:1",
      "down:2",
      "move:1",
      "up:0",
      "move:2",
      "down:0",
      "move:1",
      "up:2",
      "up:1",
      "up:0",
    ])
  })

  it("the 11th concurrent pointer is ignored, end to end", () => {
    const r = rig()
    for (let p = 0; p < 10; p++) expect(r.fwd.pointerdown(ev(p, 100 + p, 100))).toBe(true)
    expect(r.fwd.pointerdown(ev(10, 500, 500))).toBe(false)
    expect(r.fwd.pointermove(ev(10, 600, 600))).toBe(false)
    expect(r.fwd.pointerup(ev(10, 600, 600))).toBe(false)
    expect(r.sent.map(m => m.id)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    expect(r.sent.every(m => m.ph === "down")).toBe(true)
  })
})

describe("TouchForwarder: cancel and release", () => {
  it("pointercancel sends cancel at the last sent point and frees the id", () => {
    const r = rig({ slopPx: 0 })
    r.fwd.pointerdown(ev(1, 800, 450))
    r.advance(20)
    r.fwd.pointermove(ev(1, 400, 450))
    expect(r.fwd.pointercancel(ev(1, 0, 0))).toBe(true)
    expect(r.sent[2]).toEqual({ t: "touch", src: 0, id: 0, ph: "cancel", x: 0.25, y: 0.5 })
    expect(r.fwd.count).toBe(0)
    // A later up for the same pointer sends nothing more.
    expect(r.fwd.pointerup(ev(1, 0, 0))).toBe(false)
    expect(r.sent).toHaveLength(3)
  })

  it("lostpointercapture sends cancel", () => {
    const r = rig()
    r.fwd.pointerdown(ev(7, 800, 450))
    expect(r.fwd.lostpointercapture(ev(7, 800, 450))).toBe(true)
    expect(r.sent.map(m => m.ph)).toEqual(["down", "cancel"])
  })

  it("the lostpointercapture that follows a normal up sends nothing", () => {
    const r = rig()
    r.fwd.pointerdown(ev(7, 800, 450))
    r.fwd.pointerup(ev(7, 800, 450))
    expect(r.fwd.lostpointercapture(ev(7, 800, 450))).toBe(false)
    expect(r.sent.map(m => m.ph)).toEqual(["down", "up"])
  })

  it("releaseAll cancels every active id, clears them, and drops pending moves", () => {
    const r = rig({ slopPx: 0, moveHz: 50 })
    r.fwd.pointerdown(ev(1, 100, 100))
    r.fwd.pointerdown(ev(2, 200, 100))
    r.fwd.pointerdown(ev(3, 300, 100))
    r.fwd.pointerup(ev(2, 200, 100))
    r.fwd.pointermove(ev(1, 150, 150))
    r.advance(5)
    r.fwd.pointermove(ev(1, 170, 170)) // pending
    expect(r.fwd.releaseAll()).toBe(2)
    r.advance(100)
    const tail = r.sent.slice(-2)
    expect(tail.map(m => `${m.ph}:${m.id}`).sort()).toEqual(["cancel:0", "cancel:2"])
    expect(r.sent.filter(m => m.ph === "move")).toHaveLength(1)
    expect(r.fwd.count).toBe(0)
    expect(r.fwd.releaseAll()).toBe(0)
    // Ids are free again.
    r.fwd.pointerdown(ev(9, 100, 100))
    expect(r.sent[r.sent.length - 1]).toMatchObject({ ph: "down", id: 0 })
  })
})
