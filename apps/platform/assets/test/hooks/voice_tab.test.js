import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

/**
 * VoiceTab (task 01a1557a-eab7 stage 3): hold-to-talk on the Voice tab.
 *
 * Every assertion is on what reached the server (the recorded pushEvent
 * calls), never on how the button looks: a button that looks on while
 * nothing is captured is the failure this hook is written against.
 *
 * The hook runs in vitest's node env, so the DOM it touches is faked here:
 * `document` is a bare EventTarget (the `voice:caption` seam), the mic is a
 * plain object, and `livekit-client`'s Room is swapped for one whose local
 * mic publication the test controls. Time is a stubbed `performance.now`.
 */

const lk = vi.hoisted(() => ({ trackState: "live", rooms: [] }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor() {
      this.handlers = {}
      const pub = {
        isMuted: false,
        track: { mediaStreamTrack: { readyState: lk.trackState, enabled: true } },
        mute() {
          this.isMuted = true
          return Promise.resolve()
        },
        unmute() {
          this.isMuted = false
          return Promise.resolve()
        },
      }
      this.pub = pub
      this.localParticipant = {
        setMicrophoneEnabled: () => Promise.resolve(),
        getTrackPublication: () => pub,
      }
      lk.rooms.push(this)
    }
    on(event, fn) {
      this.handlers[event] = fn
      return this
    }
    connect() {
      return Promise.resolve()
    }
    disconnect() {
      this.disconnected = true
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

import VoiceTab, { HOLD_MS, CAPTION_EVENT } from "../../js/hooks/voice_tab.js"
import Sheet from "../../js/hooks/sheet.js"

// ── fakes ────────────────────────────────────────────────────────────────

let clock = 0

function fakeMic() {
  return {
    id: "mic",
    disabled: false,
    setPointerCapture() {},
    releasePointerCapture() {},
    focus() {
      this.focused = true
    },
    closest() {
      return this
    },
  }
}

const body = { id: "", closest: () => null }

function mount({ permission = "granted", userId = "u1", partnerId = "a1", reply } = {}) {
  const mic = fakeMic()
  const listeners = {}
  const pushed = []
  const payloads = []
  const handlers = {}
  const el = {
    dataset: { userId, partnerId },
    addEventListener(type, fn) {
      listeners[type] = fn
    },
    removeEventListener(type) {
      delete listeners[type]
    },
    querySelector(sel) {
      return sel === "#mic" ? mic : null
    },
    querySelectorAll() {
      return []
    },
  }

  const gum = vi.fn(() =>
    permission === "granted"
      ? Promise.resolve({ getTracks: () => [{ stop() {} }] })
      : Promise.reject(Object.assign(new Error("denied"), { name: "NotAllowedError" })),
  )
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: gum } })

  const hook = Object.create(VoiceTab)
  hook.el = el
  hook.pushEvent = (event, payload, cb) => {
    pushed.push(event)
    payloads.push([event, payload])
    if (event === "voice_start" && cb) {
      cb(reply || { ok: true, token: "tok", url: "ws://lk.test", room: "space-dm" })
    }
  }
  hook.handleEvent = (event, fn) => (handlers[event] = fn)
  hook.mounted()

  const fire = (type, event) => listeners[type] && listeners[type](event)

  return {
    hook,
    mic,
    pushed,
    payloads,
    handlers,
    gum,
    down: (at = clock) => {
      clock = at
      fire("pointerdown", { target: mic, button: 0, pointerId: 1, preventDefault() {} })
    },
    up: (at) => {
      clock = at
      fire("pointerup", { target: mic, pointerId: 1 })
    },
    cancel: () => fire("pointercancel", { target: mic, pointerId: 1 }),
    key: (type, key, opts = {}) =>
      fire(type, { target: opts.target || mic, key, repeat: !!opts.repeat, preventDefault() {} }),
  }
}

// Let the async press (permission -> voice_start -> connect -> unmute) settle.
const settle = () => new Promise((r) => setTimeout(r, 0))

const turnEvents = (pushed) => pushed.filter((e) => e !== "voice_start")

beforeEach(() => {
  clock = 0
  lk.trackState = "live"
  lk.rooms = []
  vi.stubGlobal("performance", { now: () => clock })
  vi.stubGlobal("document", Object.assign(new EventTarget(), { getElementById: () => null }))
})

afterEach(() => {
  vi.unstubAllGlobals()
})

// ── hold vs tap ──────────────────────────────────────────────────────────

describe("the 280ms hold/tap split, measured at pointerup", () => {
  it("is 280ms", () => {
    expect(HOLD_MS).toBe(280)
  })

  it("a hold of 280ms or more ends the turn on release", async () => {
    const t = mount()
    t.down(0)
    await settle()
    // Literal times, not HOLD_MS-relative: a test that moves with the
    // constant cannot catch the constant changing.
    t.up(280)
    expect(t.pushed).toEqual(["voice_start", "voice_press", "voice_release"])
    expect(t.hook.inTurn()).toBe(false)
  })

  it("a shorter tap leaves the turn toggled on; the next tap ends it", async () => {
    const t = mount()
    t.down(0)
    await settle()
    t.up(279)
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled"])
    expect(t.hook.inTurn()).toBe(true)

    t.down(2_000)
    t.up(2_050)
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled", "voice_release"])
    expect(t.hook.inTurn()).toBe(false)
  })

  it("a tap before the mic is live still toggles once it is", async () => {
    const t = mount()
    t.down(0)
    t.up(100)
    await settle()
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled"])
  })

  it("a 100ms tap then a second tap within 400ms releases with a duration under 400ms", async () => {
    // Direction state 5 (too short): the server ends a release under
    // VoiceLive.too_short_ms (400) with no final caption at idle, with no
    // bubble and no thinking. The hook's part is the toggle plus an honest
    // duration on the release.
    const t = mount()
    t.down(0)
    await settle()
    t.up(100)
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled"])
    t.down(300)
    t.up(350)
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled", "voice_release"])
    const [, release] = t.payloads.find(([e]) => e === "voice_release")
    expect(release.duration_ms).toBe(350)
    expect(release.duration_ms).toBeLessThan(400)
    expect(t.hook.inTurn()).toBe(false)
  })

  it("pointercancel ends the turn", async () => {
    const t = mount()
    t.down(0)
    await settle()
    t.cancel()
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_release"])
  })

  it("the second press reuses the room: one voice_start", async () => {
    const t = mount()
    t.down(0)
    await settle()
    t.up(1_000)
    t.down(2_000)
    await settle()
    t.up(3_000)
    expect(t.pushed.filter((e) => e === "voice_start")).toHaveLength(1)
    expect(lk.rooms).toHaveLength(1)
  })
})

// ── keyboard ─────────────────────────────────────────────────────────────

describe("keyboard on #mic only", () => {
  it("Space down/up holds while #mic has focus; repeats are ignored", async () => {
    const t = mount()
    t.key("keydown", " ")
    await settle()
    t.key("keydown", " ", { repeat: true })
    t.key("keydown", " ", { repeat: true })
    await settle()
    clock = 1_000
    t.key("keyup", " ")
    expect(t.pushed).toEqual(["voice_start", "voice_press", "voice_release"])
  })

  it("Space anywhere else does nothing", async () => {
    const t = mount()
    t.key("keydown", " ", { target: body })
    await settle()
    t.key("keyup", " ", { target: body })
    expect(t.pushed).toEqual([])
    expect(t.gum).not.toHaveBeenCalled()
  })

  it("Enter toggles: on, then off", async () => {
    const t = mount()
    t.key("keydown", "Enter")
    await settle()
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled"])
    t.key("keydown", "Enter")
    expect(turnEvents(t.pushed)).toEqual(["voice_press", "voice_toggled", "voice_release"])
  })
})

// ── captions ─────────────────────────────────────────────────────────────

describe("the voice:caption seam", () => {
  const caption = (detail) => document.dispatchEvent(new CustomEvent(CAPTION_EVENT, { detail }))

  it("pushes FINAL captions only, as me / agent, with no room connected", () => {
    const t = mount({ userId: "u1", partnerId: "a1" })
    const turns = []
    t.hook.pushEvent = (event, payload) => turns.push([event, payload.who, payload.text])

    caption({ identity: "user:u1", text: "what is block", final: false })
    caption({ identity: "user:u1", text: "what is blocking rung 13", final: true })
    caption({ identity: "agent:a1", text: "Two", final: false })
    caption({ identity: "agent:a1", text: "Two things.", final: true })
    caption({ identity: "agent:someone-else", text: "not my partner", final: true })
    caption({ identity: "user:u1", text: "   ", final: true })

    expect(turns).toEqual([
      ["voice_turn", "me", "what is blocking rung 13"],
      ["voice_turn", "agent", "Two things."],
    ])
  })

  it("LiveKit TranscriptionReceived becomes voice:caption with the segment's final flag", async () => {
    const t = mount({ userId: "u1", partnerId: "a1" })
    const seen = []
    document.addEventListener(CAPTION_EVENT, (e) => seen.push(e.detail))
    t.down(0)
    await settle()

    const room = lk.rooms[0]
    const onTranscription = Object.entries(room.handlers).find(([k]) =>
      /transcription/i.test(k),
    )[1]
    onTranscription(
      [
        { text: "half", final: false },
        { text: "whole thought", final: true },
      ],
      { identity: "agent:a1" },
    )

    expect(seen).toEqual([
      { identity: "agent:a1", text: "half", final: false },
      { identity: "agent:a1", text: "whole thought", final: true },
    ])
  })
})

// ── the mic must be live ─────────────────────────────────────────────────

describe("the microphone", () => {
  it("a refused permission pushes voice_mic_blocked and never voice_start or voice_press", async () => {
    const t = mount({ permission: "denied" })
    t.down(0)
    await settle()
    t.up(1_000)
    expect(t.pushed).toEqual(["voice_mic_blocked"])
    expect(t.hook.inTurn()).toBe(false)
  })

  it("no voice_press while the local track is not live", async () => {
    lk.trackState = "ended"
    const t = mount()
    t.down(0)
    await settle()
    t.up(1_000)
    expect(t.pushed).toEqual(["voice_start"])
  })

  it("a failed voice_start reply connects nothing and presses nothing", async () => {
    const t = mount({ reply: { ok: false } })
    t.down(0)
    await settle()
    t.up(1_000)
    expect(t.pushed).toEqual(["voice_start"])
    expect(lk.rooms).toHaveLength(0)
  })

  it("is muted outside a turn", async () => {
    const t = mount()
    t.down(0)
    await settle()
    const pub = lk.rooms[0].pub
    expect(pub.isMuted).toBe(false)
    t.up(1_000)
    await settle()
    expect(pub.isMuted).toBe(true)
  })

  it("voice_disconnect leaves the room without pushing a release", async () => {
    const t = mount()
    t.down(0)
    await settle()
    t.handlers.voice_disconnect()
    expect(lk.rooms[0].disconnected).toBe(true)
    expect(turnEvents(t.pushed)).toEqual(["voice_press"])
    expect(t.hook.inTurn()).toBe(false)
  })
})

// ── the pickers: Escape, focus trap, focus return (stage 4) ─────────────
//
// #partner-sheet and #ctx-sheet are `<.sheet>`s, so the `Sheet` hook owns
// Escape, Tab and focus. These drive that hook on the Voice popover's shape:
// `data-return-focus` naming the pill, and a sheet handle the lg popover
// hides (checkVisibility false).

function voicePicker({ returnFocus = "#partner", activeElement, handleVisible = false } = {}) {
  const focused = []
  const node = (id, extra = {}) => {
    const n = {
      id,
      focus: vi.fn(() => {
        focused.push(id)
        doc.activeElement = n
      }),
      addEventListener() {},
      removeEventListener() {},
      ...extra,
    }
    return n
  }

  const nodes = {}
  nodes.pill = node("partner")
  nodes.mic = node("mic")
  nodes.handle = node("handle", { checkVisibility: () => handleVisible })
  nodes.first = node("first-row", { checkVisibility: () => true })
  nodes.last = node("last-row", { checkVisibility: () => true })
  nodes.panel = node("panel")
  nodes.body = { id: "body" }

  const doc = Object.assign(new EventTarget(), {
    body: nodes.body,
    activeElement: activeElement ? nodes[activeElement] : nodes.body,
    getElementById: () => null,
    querySelector: (sel) => (sel === "#partner" ? nodes.pill : null),
  })
  vi.stubGlobal("document", doc)
  vi.stubGlobal("requestAnimationFrame", (fn) => fn())
  vi.stubGlobal("window", { matchMedia: () => ({ matches: false }) })

  const elListeners = {}
  const el = {
    dataset: {
      open: "false",
      onClose: "close_sheet",
      swipeDismiss: "true",
      variant: "popover",
      ...(returnFocus ? { returnFocus } : {}),
    },
    addEventListener: (t, fn) => (elListeners[t] = fn),
    removeEventListener: (t) => delete elListeners[t],
    querySelector(sel) {
      if (sel === ".sheet-panel") return nodes.panel
      if (sel === ".sheet-handle-button") return nodes.handle
      if (sel === ".sheet-body") return { scrollTop: 0 }
      if (sel.startsWith("button:not")) return nodes.first
      return null
    },
    querySelectorAll: () => [nodes.handle, nodes.first, nodes.last],
  }

  const hook = Object.create(Sheet)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.pushEventTo = vi.fn()
  hook.mounted()

  const escape = () => doc.dispatchEvent(Object.assign(new Event("keydown"), { key: "Escape" }))
  const tab = (shiftKey = false) => {
    const e = { key: "Tab", shiftKey, preventDefault: vi.fn() }
    elListeners.keydown(e)
    return e
  }
  const open = () => {
    el.dataset.open = "true"
    hook.updated()
  }
  // The server's close_sheet answer: the sheet re-renders shut.
  const shut = () => {
    el.dataset.open = "false"
    hook.updated()
  }

  return { hook, el, nodes, doc, focused, escape, tab, open, shut }
}

describe("the Voice pickers: Escape and focus (stage 4)", () => {
  it("Escape on an open picker pushes close_sheet, and focus returns to its pill", () => {
    // A click that did not focus the pill (Safari): activeElement is the body.
    const p = voicePicker()
    p.open()
    expect(p.focused).toEqual(["first-row"])

    p.escape()
    expect(p.hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(p.hook.pushEvent).toHaveBeenCalledWith("close_sheet")

    p.shut()
    expect(p.focused).toEqual(["first-row", "partner"])
    expect(p.doc.activeElement).toBe(p.nodes.pill)
  })

  it("if #mic had focus when the picker opened, #mic gets it back", () => {
    const p = voicePicker({ activeElement: "mic" })
    p.open()
    p.escape()
    p.shut()
    expect(p.focused).toEqual(["first-row", "mic"])
    expect(p.nodes.pill.focus).not.toHaveBeenCalled()
  })

  it("a pill that took focus on click gets it back", () => {
    const p = voicePicker({ activeElement: "pill" })
    p.open()
    p.shut()
    expect(p.focused).toEqual(["first-row", "partner"])
  })

  it("Escape on a closed picker pushes nothing", () => {
    const p = voicePicker()
    p.escape()
    expect(p.hook.pushEvent).not.toHaveBeenCalled()
  })

  it("Tab stays inside, and the popover's hidden handle is not a stop", () => {
    const p = voicePicker()
    p.open()

    p.doc.activeElement = p.nodes.last
    const forward = p.tab()
    expect(forward.preventDefault).toHaveBeenCalled()
    expect(p.doc.activeElement).toBe(p.nodes.first)

    const back = p.tab(true)
    expect(back.preventDefault).toHaveBeenCalled()
    expect(p.doc.activeElement).toBe(p.nodes.last)
    expect(p.nodes.handle.focus).not.toHaveBeenCalled()
  })

  it("on a phone the visible handle is the trap's first stop", () => {
    const p = voicePicker({ handleVisible: true })
    p.open()
    p.doc.activeElement = p.nodes.last
    p.tab()
    expect(p.doc.activeElement).toBe(p.nodes.handle)
  })
})
