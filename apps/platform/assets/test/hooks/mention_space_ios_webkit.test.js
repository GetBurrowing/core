import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ChatDock, { MENTION_MAX_H_VAR } from "../../js/hooks/chat_dock.js"
import ComposeInput from "../../js/hooks/compose_input.js"

/**
 * Task 01a1c863 stage 1: the @mention list is clamped to a sliver on a real
 * iPhone with the keyboard open (regression from #150).
 *
 * Every number below was MEASURED, not invented. Source: iOS Simulator
 * "iPhone 17" (402x874 pt, the same 1206x2622 screen as the reporter's
 * phone), iOS 26.3, Mobile Safari = real WebKit, software keyboard and its
 * accessory bar up (hardware keyboard disconnected), keys tapped through the
 * simulator's HID. The page was a dev server at origin/main 538b19071 with a
 * rig-only, uncommitted probe that sampled visualViewport, window and rects on every
 * visualViewport resize/scroll, window scroll, focus, input and list
 * mutation. Raw traces: execution space of task 01a1c863, stage 1 canvas.
 *
 * What WebKit reports once the keyboard is up and it has panned the page to
 * keep the composer visible (portrait, channel):
 *
 *   window.innerHeight 377   window.scrollY 337
 *   visualViewport { height: 377, offsetTop: 337, pageTop: 337, scale: 1 }
 *   #chat-drop-zone top -293 (channel header -293..-245, off screen)
 *   compose pill (mention anchor) top 325, dock bottom 377
 *
 * getBoundingClientRect() is relative to the SCROLLED viewport here: the dock
 * ends at 377 = visualViewport.height, and the screenshot shows it sitting on
 * the accessory bar, so client y 0..377 is exactly what the user sees. But
 * visualViewport.offsetTop (337) is measured from the LAYOUT viewport, which
 * WebKit leaves at the document top. Both hooks take
 * max(visualViewport.offsetTop, ...) as the visible top and subtract it from a
 * client rect:  325 - 337 - 2 < 0  ->  0px. The pan is counted twice.
 * Chromium (where #150's tests and CDP evidence came from) reports client
 * rects against the layout viewport, so there offsetTop IS in the same space
 * and the formula holds; that is why it passed there.
 *
 * The three candidate causes the stage asked to tell apart:
 *   1. coordinate-space mismatch  -> RED (it.fails below), the clamp.
 *   2. header bound               -> not it: header is off screen (-293).
 *   3. stale measurement          -> not it: the cap after the replayed
 *                                    event sequence equals a fresh measure.
 *
 * The coordinate-space cases are `it.fails` (the repo's diagnosis idiom, see
 * meeting_captions.test.js): they assert the CORRECT behaviour, fail on the
 * current code, and so pass the suite. Stage 2's fix must flip them to `it`.
 */

// A suggestion row is 52px on the phone (measured: rows at 316, 368, 420...).
const ROW_PX = 52
const THREE_ROWS = 3 * ROW_PX

// Portrait, channel composer, iPhone 17 / iOS 26.3 Safari.
const CHANNEL_KEYBOARD_CLOSED = {
  innerWidth: 402, innerHeight: 714, scrollY: 0,
  vv: { width: 402, height: 714, offsetTop: 0, offsetLeft: 0, pageTop: 0, scale: 1 },
  zoneTop: 44, anchorTop: 662,
}
const CHANNEL_KEYBOARD_OPEN = {
  innerWidth: 402, innerHeight: 377, scrollY: 337,
  vv: { width: 402, height: 377, offsetTop: 337, offsetLeft: 0, pageTop: 337, scale: 1 },
  zoneTop: -293, anchorTop: 325,
}
// The visible top in client coordinates while the keyboard is up: the dock's
// bottom (377) equals visualViewport.height, so the visible band is 0..377.
const CHANNEL_VISIBLE_TOP = 0

// Portrait, inline thread reply, same device: the reply field after "@" was
// typed with the keyboard up (input event, before the list opened).
const THREAD_KEYBOARD_OPEN = {
  innerWidth: 402, innerHeight: 377, scrollY: 337,
  vv: { width: 402, height: 377, offsetTop: 337, offsetLeft: 0, pageTop: 337, scale: 1 },
  field: { top: 272.5, bottom: 314.5, left: 105, width: 205.3, height: 42 },
}
// threadMentionPlacement's gutter (8) and panel chrome (10).
const THREAD_ROOM = THREAD_KEYBOARD_OPEN.field.top - 0 - 8 - 10

let saved, rootStyle, windowListeners

function stubGlobals() {
  saved = {
    window: globalThis.window,
    document: globalThis.document,
    getComputedStyle: globalThis.getComputedStyle,
    CustomEvent: globalThis.CustomEvent,
    ResizeObserver: globalThis.ResizeObserver,
  }
  rootStyle = {
    props: {},
    setProperty(k, v) { this.props[k] = v },
    removeProperty(k) { delete this.props[k] },
  }
  windowListeners = {}
  globalThis.window = {
    addEventListener(type, fn) { (windowListeners[type] ||= []).push(fn) },
    removeEventListener(type, fn) {
      windowListeners[type] = (windowListeners[type] || []).filter((f) => f !== fn)
    },
    dispatchEvent() { return true },
  }
  globalThis.document = {
    documentElement: { style: rootStyle, setAttribute() {}, removeAttribute() {} },
  }
  globalThis.getComputedStyle = () => ({ display: "block" })
  globalThis.CustomEvent = class { constructor(type, init = {}) { this.type = type; this.detail = init.detail } }
  globalThis.ResizeObserver = class {
    constructor(cb) { this.cb = cb }
    observe() {}
    disconnect() {}
  }
}

function restoreGlobals() {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete globalThis[k]
    else globalThis[k] = v
  }
}

// Mount ChatDock against one measured geometry. `apply` swaps in another
// measured geometry and fires the visualViewport events WebKit fired
// (resize, then scroll), in that order.
function mountChannel(sample, { withZone = true } = {}) {
  const listeners = {}
  const geom = { ...sample }
  const viewport = {
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn) },
    removeEventListener(type, fn) { listeners[type] = (listeners[type] || []).filter((f) => f !== fn) },
  }
  const sync = () => {
    Object.assign(viewport, geom.vv)
    window.innerWidth = geom.innerWidth
    window.innerHeight = geom.innerHeight
    window.scrollY = geom.scrollY
  }
  sync()
  window.visualViewport = viewport
  const el = {
    getBoundingClientRect: () => ({ height: 52 }),
    querySelector: (s) => s === '[data-role="compose-mention-anchor"]'
      ? { getBoundingClientRect: () => ({ top: geom.anchorTop }) }
      : null,
    closest: (s) => (withZone && s === "#chat-drop-zone"
      ? { getBoundingClientRect: () => ({ top: geom.zoneTop }) }
      : null),
  }
  const hook = Object.create(ChatDock)
  hook.el = el
  hook.mounted()
  const apply = (next) => {
    Object.assign(geom, next)
    sync()
    for (const type of ["resize", "scroll"]) (listeners[type] || []).forEach((fn) => fn())
  }
  return { hook, apply, cap: () => parseInt(rootStyle.props[MENTION_MAX_H_VAR], 10) }
}

describe("iOS WebKit keyboard pan: channel @mention cap (measured, task 01a1c863)", () => {
  beforeEach(stubGlobals)
  afterEach(restoreGlobals)

  it("control: keyboard closed, the cap is the room under the header (passes on #150)", () => {
    const { hook, cap } = mountChannel(CHANNEL_KEYBOARD_CLOSED)
    // 662 - 44 - 2: the header bound works when it is the binding edge.
    expect(cap()).toBe(616)
    hook.destroyed()
  })

  // CAUSE 1, coordinate space. RED on #150 / origin/main 538b19071: the cap
  // comes out 0px, so the panel is its 10px of border and padding, the
  // sliver in the screenshots. The user can see 325px above the pill.
  it.fails("keyboard open and panned: room for at least 3 full rows above the pill, inside the visible band", () => {
    const { hook, apply, cap } = mountChannel(CHANNEL_KEYBOARD_CLOSED)
    apply(CHANNEL_KEYBOARD_OPEN)
    expect(cap()).toBeGreaterThanOrEqual(THREE_ROWS)
    expect(cap()).toBeLessThanOrEqual(CHANNEL_KEYBOARD_OPEN.anchorTop - CHANNEL_VISIBLE_TOP - 2)
    hook.destroyed()
  })

  it("pins today's value: 325 - max(offsetTop 337, zone -293) - 2 clamps to 0", () => {
    // Documents the mechanism; stage 2 deletes or inverts this case.
    const { hook, apply, cap } = mountChannel(CHANNEL_KEYBOARD_CLOSED)
    apply(CHANNEL_KEYBOARD_OPEN)
    expect(cap()).toBe(0)
    hook.destroyed()
  })

  // CAUSE 2, header bound: ruled out. With the header off screen the zone
  // edge never binds; removing it entirely gives the same cap.
  it("header bound is not the clamp: the measured cap is the same with and without the zone", () => {
    const a = mountChannel(CHANNEL_KEYBOARD_CLOSED)
    a.apply(CHANNEL_KEYBOARD_OPEN)
    const withZone = a.cap()
    a.hook.destroyed()
    const b = mountChannel(CHANNEL_KEYBOARD_CLOSED, { withZone: false })
    b.apply(CHANNEL_KEYBOARD_OPEN)
    expect(b.cap()).toBe(withZone)
    b.hook.destroyed()
  })

  // CAUSE 3, stale measurement: ruled out. Replaying WebKit's event order
  // from the pre-keyboard mount ends on the same cap as measuring the final
  // geometry from scratch; nothing is left over from before the keyboard.
  it("stale measurement is not the clamp: replayed events end on a fresh measurement", () => {
    const replay = mountChannel(CHANNEL_KEYBOARD_CLOSED)
    expect(replay.cap()).toBe(616)
    replay.apply(CHANNEL_KEYBOARD_OPEN)
    const replayed = replay.cap()
    replay.hook.destroyed()
    const fresh = mountChannel(CHANNEL_KEYBOARD_OPEN)
    expect(replayed).toBe(fresh.cap())
    fresh.hook.destroyed()
  })
})

describe("iOS WebKit keyboard pan: thread reply @mention cap (measured, task 01a1c863)", () => {
  afterEach(() => vi.unstubAllGlobals())

  function mountThread(sample) {
    const fns = new Map()
    const target = () => ({
      addEventListener: vi.fn((n, f) => fns.set(f, n)),
      removeEventListener: vi.fn((n, f) => fns.delete(f)),
    })
    const viewport = { ...target(), ...sample.vv }
    const win = { ...target(), visualViewport: viewport, innerWidth: sample.innerWidth, innerHeight: sample.innerHeight, scrollY: sample.scrollY }
    vi.stubGlobal("window", win)
    vi.stubGlobal("document", {})
    vi.stubGlobal("requestAnimationFrame", vi.fn((f) => { win.frame = f; return 1 }))
    vi.stubGlobal("cancelAnimationFrame", vi.fn())
    const values = new Map()
    const box = { style: { setProperty: (k, v) => values.set(k, v), removeProperty: (k) => values.delete(k) } }
    const field = {
      getBoundingClientRect: () => sample.field,
      closest: (s) => ({ ".thread-field-box": box, "#chat-message-scroller": target() })[s],
    }
    const hook = Object.assign(Object.create(ComposeInput), { el: field })
    hook._mountThreadMentionViewport()
    return { hook, cap: () => parseInt(values.get("--thread-mention-max-h"), 10) }
  }

  // CAUSE 1 again, in threadMentionPlacement/viewportBounds: 272.5 - 337 -
  // 8 - 10 < 0 -> 0px. The user can see 272.5px above the reply field.
  it.fails("keyboard open and panned: room for at least 3 full rows above the reply field", () => {
    const { hook, cap } = mountThread(THREAD_KEYBOARD_OPEN)
    expect(cap()).toBeGreaterThanOrEqual(THREE_ROWS)
    expect(cap()).toBeLessThanOrEqual(Math.floor(THREAD_ROOM))
    hook._threadMentionCleanup()
  })

  it("pins today's value: 272.5 - offsetTop 337 - 18 clamps to 0", () => {
    const { hook, cap } = mountThread(THREAD_KEYBOARD_OPEN)
    expect(cap()).toBe(0)
    hook._threadMentionCleanup()
  })
})
