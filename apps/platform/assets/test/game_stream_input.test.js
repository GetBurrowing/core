import { describe, it, expect } from "vitest"
import {
  KeyForwarder,
  PadDiffer,
  SLOT,
  controllerLabel,
  hintText,
  keyMessage,
  padName,
  pickGamepad,
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
  const state = { captured, escapes: 0, inputs: 0 }
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
    onInput: () => state.inputs++,
    doc,
  })
  return { f, sent, state, doc, composer }
}

describe("keyMessage", () => {
  it("builds the host's key shape with slot 0", () => {
    expect(keyMessage(fakeEvent("KeyW"), true)).toEqual({
      t: "key",
      code: "KeyW",
      down: true,
      repeat: false,
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
      { t: "key", code: "KeyA", down: true, repeat: false, slot: 0 },
      { t: "key", code: "KeyA", down: false, repeat: false, slot: 0 },
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
    expect(first).toMatchObject({ t: "pad", slot: 0, seq: 1, connected: true })
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
