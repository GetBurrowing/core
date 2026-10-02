import { describe, it, expect } from "vitest"
import {
  InputRouter,
  KeyForwarder,
  PadDiffer,
  PadSources,
  SLOT,
  controllerLabel,
  hintText,
  keyMessage,
  padName,
  padPressed,
  pickGamepad,
  pickGamepads,
} from "../js/hooks/lib/game_stream_input.js"

/**
 * game_stream keyboard and gamepad input (task 01a0db5f stage 4). Runs in
 * vitest's node env with fake events and a fake document.
 */

function fakeEvent(code, extra = {}) {
  return {
    code,
    key: code === "Escape" ? "Escape" : code,
    repeat: false,
    prevented: 0,
    stopped: 0,
    preventDefault() {
      this.prevented++
    },
    stopImmediatePropagation() {
      this.stopped++
    },
    ...extra,
  }
}

function forwarder({ captured = true } = {}) {
  const sent = []
  const state = { captured, escapes: 0, mutes: 0, inputs: 0 }
  const composer = {
    nodeType: 1,
    tagName: "TEXTAREA",
    blurred: 0,
    blur() {
      this.blurred++
      doc.activeElement = doc.body
    },
  }
  const doc = { body: { nodeType: 1, tagName: "BODY" }, activeElement: composer }
  const f = new KeyForwarder({
    isCaptured: () => state.captured,
    send: m => sent.push(m),
    onEscape: () => state.escapes++,
    onMute: () => state.mutes++,
    onInput: () => state.inputs++,
    doc,
  })
  return { f, sent, state, doc, composer }
}

describe("keyMessage", () => {
  it("builds the host's key shape: src 0, slot 0", () => {
    expect(keyMessage(fakeEvent("KeyW"), true)).toEqual({
      t: "key",
      code: "KeyW",
      down: true,
      repeat: false,
      src: 0,
      slot: 0,
    })
    expect(SLOT).toBe(0)
  })

  it("marks repeats only on keydown", () => {
    expect(keyMessage(fakeEvent("KeyW", { repeat: true }), true).repeat).toBe(true)
    expect(keyMessage(fakeEvent("KeyW", { repeat: true }), false).repeat).toBe(false)
  })

  it("never builds a message for Esc", () => {
    expect(keyMessage(fakeEvent("Escape"), true)).toBe(null)
  })
})

describe("KeyForwarder while captured", () => {
  it("delivers keydown AND keyup to the game, preventing both", () => {
    const { f, sent } = forwarder()
    const down = fakeEvent("KeyA")
    const up = fakeEvent("KeyA")
    expect(f.keydown(down)).toBe(true)
    expect(f.keyup(up)).toBe(true)
    expect(sent).toEqual([
      { t: "key", code: "KeyA", down: true, repeat: false, src: 0, slot: 0 },
      { t: "key", code: "KeyA", down: false, repeat: false, src: 0, slot: 0 },
    ])
    expect(down.prevented).toBe(1)
    expect(up.prevented).toBe(1)
    expect(down.stopped).toBe(1)
  })

  it("prevents Esc, routes it to the capture machine, and sends nothing", () => {
    const { f, sent, state } = forwarder()
    const e = fakeEvent("Escape")
    f.keydown(e)
    f.keyup(fakeEvent("Escape"))
    expect(sent).toEqual([])
    expect(state.escapes).toBe(1)
    expect(e.prevented).toBe(1)
  })

  it("consumes M at the browser layer and toggles exactly once per press", () => {
    const { f, sent, state } = forwarder()
    const down = fakeEvent("KeyM")
    const repeat = fakeEvent("KeyM", { repeat: true })
    const up = fakeEvent("KeyM")

    f.keydown(down)
    f.keydown(repeat)
    f.keyup(up)

    expect(state.mutes).toBe(1)
    expect(sent).toEqual([])
    expect(down.prevented).toBe(1)
    expect(repeat.prevented).toBe(1)
    expect(up.prevented).toBe(1)
  })

  it("blurs the focused chat composer at capture", () => {
    const { f, composer, doc } = forwarder()
    f.blurActive()
    expect(composer.blurred).toBe(1)
    expect(doc.activeElement).toBe(doc.body)
  })

  it("reports focus moving into an editable element", () => {
    const { f } = forwarder()
    expect(f.focusMovedToEditable({ nodeType: 1, tagName: "TEXTAREA" })).toBe(true)
    expect(f.focusMovedToEditable({ nodeType: 1, tagName: "DIV", isContentEditable: true })).toBe(
      true,
    )
    expect(f.focusMovedToEditable({ nodeType: 1, tagName: "BUTTON" })).toBe(false)
  })
})

describe("KeyForwarder while NOT captured", () => {
  it("touches nothing: no preventDefault, no message", () => {
    const { f, sent } = forwarder({ captured: false })
    const e = fakeEvent("KeyW")
    expect(f.keydown(e)).toBe(false)
    expect(f.keyup(fakeEvent("KeyW"))).toBe(false)
    expect(e.prevented).toBe(0)
    expect(sent).toEqual([])
    expect(f.focusMovedToEditable({ nodeType: 1, tagName: "TEXTAREA" })).toBe(false)
  })
})

function pad(buttons = [], axes = [0, 0, 0, 0], extra = {}) {
  const b = []
  for (let i = 0; i < 17; i++) b.push({ value: buttons[i] || 0, pressed: (buttons[i] || 0) > 0.5 })
  return { id: "Xbox Wireless Controller (STANDARD GAMEPAD)", mapping: "standard", connected: true, buttons: b, axes, ...extra }
}

describe("PadDiffer snapshot diffing", () => {
  it("sends the first snapshot, then only changes", () => {
    const d = new PadDiffer()
    const first = d.next(pad())
    expect(first).toMatchObject({ t: "pad", src: 0, slot: 0, seq: 1, connected: true })
    expect(first.buttons).toHaveLength(17)
    expect(first.axes).toHaveLength(4)

    expect(d.next(pad())).toBe(null)
    const pressed = d.next(pad([1]))
    expect(pressed.seq).toBe(2)
    expect(pressed.buttons[0]).toBe(1)
    expect(d.next(pad([1]))).toBe(null)
  })

  it("ignores axis noise below the host's epsilon, and sends a return to exactly 0", () => {
    const d = new PadDiffer()
    d.next(pad([], [0, 0, 0, 0]))
    expect(d.next(pad([], [0.001, 0, 0, 0]))).toBe(null)
    expect(d.next(pad([], [0.5, 0, 0, 0])).axes[0]).toBe(0.5)
    const back = d.next(pad([], [0, 0, 0, 0]))
    expect(back.axes[0]).toBe(0)
  })

  it("reports a pad that disappears once, as connected: false", () => {
    const d = new PadDiffer()
    d.next(pad([1]))
    expect(d.next(null)).toMatchObject({ t: "pad", slot: 0, connected: false })
    expect(d.next(null)).toBe(null)
  })

  it("seq always increases, so the host can drop reordered snapshots", () => {
    const d = new PadDiffer()
    const seqs = [d.next(pad()), d.next(pad([1])), d.next(null), d.next(pad())].map(m => m.seq)
    expect(seqs).toEqual([1, 2, 3, 4])
  })

  it("clamps out-of-range values", () => {
    const d = new PadDiffer()
    const m = d.next(pad([], [2, -3, 0, 0]))
    expect(m.axes.slice(0, 2)).toEqual([1, -1])
  })
})

describe("pickGamepad and labels", () => {
  it("prefers a standard-mapped connected pad and skips empty slots", () => {
    const odd = { id: "Odd", mapping: "", connected: true, buttons: [], axes: [] }
    const std = pad()
    expect(pickGamepad([null, odd, std])).toBe(std)
    expect(pickGamepad([null, odd])).toBe(odd)
    expect(pickGamepad([null, null])).toBe(null)
    expect(pickGamepad(undefined)).toBe(null)
  })

  it("names the pad without the browser's parenthetical", () => {
    expect(padName(pad())).toBe("Xbox Wireless Controller")
    expect(padName({ id: "" })).toBe("Controller")
  })

  it("says what to do with no controller, on desktop and on a phone", () => {
    expect(controllerLabel({ pad: null, coarse: false })).toBe("Press any button on your controller")
    expect(controllerLabel({ pad: null, coarse: true })).toBe(
      "Connect a controller to play on this device",
    )
    expect(controllerLabel({ pad: pad(), coarse: true })).toBe("Xbox Wireless Controller")
  })

  it("hint repeats the ring in words", () => {
    expect(hintText({ live: true, captured: true })).toBe("Esc to release")
    expect(hintText({ live: true, captured: false })).toBe("Click to play")
    expect(hintText({ live: false, captured: false })).toBe("")
  })
})

// ── Several pads, sources and the router (task 01a0dbd6 stage 4) ─────────

function idx(p, index) {
  return { ...p, index }
}

describe("pickGamepads: a list", () => {
  it("every connected pad, standard-mapped first, each group in index order", () => {
    const odd = { id: "Odd", index: 0, mapping: "", connected: true, buttons: [], axes: [] }
    const a = idx(pad(), 1)
    const b = idx(pad(), 3)
    const gone = idx(pad([], [0, 0, 0, 0], { connected: false }), 2)
    expect(pickGamepads([odd, a, gone, b])).toEqual([a, b, odd])
    expect(pickGamepads(undefined)).toEqual([])
    expect(pickGamepad([odd, a, gone, b])).toBe(a)
  })
})

describe("PadSources: one src per pad, kept while it stays connected", () => {
  it("the first pad is src 0 (shared with the keyboard), the second src 1", () => {
    const s = new PadSources()
    const a = idx(pad(), 0)
    const b = idx(pad(), 1)
    const { assigned, gone } = s.assign([a, b])
    expect(assigned.map(x => [x.src, x.pad])).toEqual([
      [0, a],
      [1, b],
    ])
    expect(gone).toEqual([])
  })

  it("a second pad unplugging does not move the first; the first unplugging does not move the second", () => {
    const s = new PadSources()
    const a = idx(pad(), 0)
    const b = idx(pad(), 1)
    s.assign([a, b])
    expect(s.assign([a])).toEqual({ assigned: [{ src: 0, pad: a }], gone: [1] })
    s.assign([a, b])
    const r = s.assign([b])
    expect(r.assigned).toEqual([{ src: 1, pad: b }])
    expect(r.gone).toEqual([0])
    // A pad that comes back takes the lowest free src.
    const c = idx(pad(), 2)
    expect(s.assign([b, c]).assigned).toEqual([
      { src: 0, pad: c },
      { src: 1, pad: b },
    ])
  })
})

describe("padPressed", () => {
  it("true while any button is down", () => {
    expect(padPressed(pad())).toBe(false)
    expect(padPressed(pad([0, 0, 1]))).toBe(true)
    expect(padPressed(null)).toBe(false)
  })
})

describe("PadDiffer per src", () => {
  it("carries its src and the slot it currently maps to", () => {
    const d = new PadDiffer(2, 1)
    expect(d.next(pad([1]))).toMatchObject({ t: "pad", src: 1, slot: 2, seq: 1 })
    d.slot = 3
    expect(d.next(null)).toMatchObject({ t: "pad", src: 1, slot: 3, connected: false })
  })

  it("two pads in one browser diff independently", () => {
    const d0 = new PadDiffer(0, 0)
    const d1 = new PadDiffer(1, 1)
    expect(d0.next(pad([1]))).not.toBe(null)
    expect(d1.next(pad())).not.toBe(null)
    // Pad 0 unchanged, pad 1 pressed: only pad 1 sends.
    expect(d0.next(pad([1]))).toBe(null)
    expect(d1.next(pad([0, 1]))).toMatchObject({ src: 1, slot: 1, seq: 2 })
  })
})

function router(slots) {
  const events = []
  const states = []
  const r = new InputRouter({ sendEvent: m => events.push(m), sendState: m => states.push(m) })
  r.setSlots(slots)
  return { r, events, states }
}

describe("InputRouter: the only writer to the data channels", () => {
  it("a SPECTATOR (no slots) sends nothing: no key, pad, release_all or probe", () => {
    const { r, events, states } = router({})
    expect(r.player).toBe(false)
    expect(r.key(keyMessage(fakeEvent("KeyD"), true))).toBe(false)
    expect(r.pad(new PadDiffer(0, 0).next(pad([1])))).toBe(false)
    expect(r.pad({ t: "pad", src: 0, slot: 0, seq: 1, connected: false })).toBe(false)
    expect(r.releaseAll()).toBe(false)
    expect(r.probe(5, 3)).toBe(null)
    expect(events).toEqual([])
    expect(states).toEqual([])
  })

  it("positive control: the same calls as P2 all send, with src and the core slot", () => {
    const { r, events, states } = router({ 0: 1 })
    expect(r.player).toBe(true)
    expect(r.key(keyMessage(fakeEvent("KeyD"), true))).toBe(true)
    expect(r.pad(new PadDiffer(0, 0).next(pad([1])))).toBe(true)
    expect(r.releaseAll()).toBe(true)
    expect(r.probe(5, 3)).toBe(1)
    expect(events).toEqual([
      { t: "key", code: "KeyD", down: true, repeat: false, src: 0, slot: 1 },
      { t: "release_all" },
      { t: "probe", seq: 5, src: 0 },
    ])
    expect(states).toHaveLength(1)
    expect(states[0]).toMatchObject({ t: "pad", src: 0, slot: 1 })
  })

  it("a pad whose src holds no slot sends nothing, while another src of the same peer does", () => {
    const { r, states } = router(new Map([[0, 0]]))
    expect(r.pad(new PadDiffer(0, 1).next(pad([1])))).toBe(false)
    expect(r.pad(new PadDiffer(0, 0).next(pad([1])))).toBe(true)
    expect(states.map(m => m.src)).toEqual([0])
  })

  it("a player holding only a second pad's slot: keys go nowhere, probes ride that pad's src", () => {
    const { r, events } = router({ 1: 2 })
    expect(r.key(keyMessage(fakeEvent("KeyW"), true))).toBe(false)
    expect(r.probe(9, 3)).toBe(2)
    expect(events).toEqual([{ t: "probe", seq: 9, src: 1 }])
  })

  it("no probe from a slot the 2-bit code cannot name", () => {
    const { r, events } = router({ 0: 4 })
    expect(r.probe(1, 3)).toBe(null)
    expect(events).toEqual([])
  })

  it("the message's own slot is replaced by core's", () => {
    const { r, events } = router({ 0: 3 })
    r.key({ t: "key", code: "KeyA", down: true, repeat: false, src: 0, slot: 0 })
    expect(events[0].slot).toBe(3)
  })
})

describe("InputRouter.touch: slot-gated exactly like key (task 01a0fe45)", () => {
  const touch = { t: "touch", src: 0, id: 0, ph: "down", x: 0.5, y: 0.25 }

  it("a spectator (no slots) sends no touch", () => {
    const { r, events, states } = router({})
    expect(r.touch(touch)).toBe(false)
    expect(events).toEqual([])
    expect(states).toEqual([])
  })

  it("a player whose src 0 holds a slot sends it on input-events, with no slot field", () => {
    const { r, events, states } = router({ 0: 2 })
    expect(r.touch(touch)).toBe(true)
    expect(events).toEqual([{ t: "touch", src: 0, id: 0, ph: "down", x: 0.5, y: 0.25 }])
    expect(events[0]).not.toHaveProperty("slot")
    expect(states).toEqual([])
  })

  it("a player holding only a second pad's slot sends no touch (touch is src 0's, like keys)", () => {
    const { r, events } = router({ 1: 1 })
    expect(r.key(keyMessage(fakeEvent("KeyW"), true))).toBe(false)
    expect(r.touch(touch)).toBe(false)
    expect(events).toEqual([])
  })

  it("src is forced to 0 and a null message is refused", () => {
    const { r, events } = router({ 0: 0 })
    expect(r.touch(null)).toBe(false)
    r.touch({ ...touch, src: 3 })
    expect(events).toEqual([{ ...touch, src: 0 }])
  })
})

describe("footer copy with touch (task 01a0fe45)", () => {
  it("a phone whose taps go to the game says so, and has no Click to play hint", () => {
    expect(controllerLabel({ pad: null, coarse: true, touch: true })).toBe("Touch the game to play")
    expect(hintText({ live: true, captured: false, touch: true })).toBe("")
    expect(hintText({ live: true, captured: true, touch: true })).toBe("Esc to release")
  })

  it("without touch the lines are unchanged", () => {
    expect(controllerLabel({ pad: null, coarse: true, touch: false })).toBe(
      "Connect a controller to play on this device",
    )
    expect(controllerLabel({ pad: null, coarse: false, touch: true })).toBe("Press any button on your controller")
    expect(hintText({ live: true, captured: false, touch: false })).toBe("Click to play")
  })
})
