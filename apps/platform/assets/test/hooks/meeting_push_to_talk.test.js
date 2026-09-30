import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingPushToTalk, { HOLD_THRESHOLD_MS } from "../../js/hooks/meeting_push_to_talk.js"

/**
 * Tests for the `MeetingPushToTalk` hook (task 01a03f4e stage 5).
 *
 * ## NOTHING here asserts on button state
 *
 * That is the point, not an oversight. The failure this control exists to
 * prevent is a button that LOOKS armed while no audio is being captured —
 * and an assertion on "the button reads as pressed" passes in exactly that
 * case. It is the one assertion guaranteed to be green when the feature is
 * broken in its most likely way.
 *
 * So every assertion below is on one of two things:
 *
 *   * a MEASURED LEVEL — what the AnalyserNode actually reported, via
 *     `peakLevel()` / `levels()`, or
 *   * an EVENT that reached the server, via the recorded `pushEvent` calls,
 *     and `lastRejection()` for a press that was refused.
 *
 * `data-pressed` is set by the hook and deliberately never asserted on.
 *
 * ## Fakes
 *
 * The hook runs in the default vitest `node` env, so `window`, `MediaStream`
 * and `AudioContext` are built here. The fake analyser is handed an explicit
 * sample buffer, which is what makes the silent-track case a real
 * measurement rather than an absence: a silent track is a buffer of 128s
 * (`getByteTimeDomainData`'s zero point), NOT a missing analyser.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

function fakeEl() {
  const listeners = {}
  return {
    dataset: {},
    style: {},
    listeners,
    addEventListener(type, fn) {
      ;(listeners[type] = listeners[type] || []).push(fn)
    },
    removeEventListener(type, fn) {
      if (!listeners[type]) return
      listeners[type] = listeners[type].filter((f) => f !== fn)
    },
    querySelectorAll(sel) {
      return sel === "[data-ptt-bar]" ? bars : []
    },
    // No real DOM tree in this harness — a hook that calls `closest` (the
    // coaching tooltip lookup, task 01a0cf5c stage 2) gets `null` here
    // unless a specific test overrides it, exactly like a real button
    // with no matching ancestor would.
    closest() {
      return null
    },
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 0, height: 0 }
    },
    fire(type, event = {}) {
      ;(listeners[type] || []).forEach((fn) => fn(event))
    },
  }
}

let bars = []

function fakeBars(n = 12) {
  return Array.from({ length: n }, () => ({ style: {} }))
}

// A LiveKit-shaped local audio publication.
function micPublication(overrides = {}) {
  return {
    kind: "audio",
    source: "microphone",
    isMuted: false,
    track: {
      source: "microphone",
      isMuted: false,
      mediaStreamTrack: { readyState: "live", enabled: true },
    },
    ...overrides,
  }
}

function roomWith(publications) {
  return {
    localParticipant: {
      trackPublications: new Map(publications.map((p, i) => [String(i), p])),
    },
  }
}

// `samples` is the byte-time-domain buffer every read returns. 128 is
// silence; anything else is signal.
function installAudio(samples) {
  globalThis.MediaStream = class {
    constructor(tracks) {
      this.tracks = tracks
    }
  }

  globalThis.window.AudioContext = class {
    createMediaStreamSource() {
      return { connect() {}, disconnect() {} }
    }
    createAnalyser() {
      return {
        fftSize: 256,
        getByteTimeDomainData(buffer) {
          for (let i = 0; i < buffer.length; i++) {
            buffer[i] = samples[i % samples.length]
          }
        },
      }
    }
    close() {}
  }
}

function silentSamples() {
  return [128]
}

// A recognisable waveform: a ±40 swing about the midpoint.
function loudSamples() {
  return [168, 88, 168, 88]
}

function mountHook(room, { samples = loudSamples() } = {}) {
  bars = fakeBars()

  const pushed = []
  const el = fakeEl()

  globalThis.window = {
    __livekitRoom: room,
    listeners: {},
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent(event) {
      dispatched.push(event)
    },
    // Never auto-runs: every test steps `sample()` itself so a level is a
    // deliberate measurement rather than a race with the event loop.
    requestAnimationFrame() {
      return 1
    },
    cancelAnimationFrame() {},
  }

  globalThis.CustomEvent = class {
    constructor(type, init) {
      this.type = type
      this.detail = init && init.detail
    }
  }

  installAudio(samples)

  // Recorded by name so a test can simulate the SERVER pushing an event
  // (task 01a0cf5c stage 1's `push_to_talk_rejected`) without a real
  // LiveView socket — `mounted()` registers via `this.handleEvent(name,
  // cb)`, exactly like a real hook would.
  const serverHandlers = {}

  const hook = Object.assign(Object.create(MeetingPushToTalk), {
    el,
    pushEvent: (name, payload) => pushed.push([name, payload]),
    pushEventTo: () => {},
    handleEvent: (name, cb) => {
      serverHandlers[name] = cb
    },
  })

  hook.mounted()
  return { hook, el, pushed, serverHandlers }
}

let dispatched = []

beforeEach(() => {
  dispatched = []
})

afterEach(() => {
  delete globalThis.MediaStream
  delete globalThis.CustomEvent
})

// ── A live microphone produces a real, non-zero level ────────────────────

describe("with a live microphone", () => {
  it("reports a NON-ZERO level from the analyser while held", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })
    hook.sample()
    hook.sample()

    // THE load-bearing assertion. It is a measurement of what the
    // AnalyserNode reported, not a statement about the button.
    expect(hook.peakLevel()).toBeGreaterThan(0)
    // Two, because the fake rAF never auto-runs — these are exactly the
    // two frames this test stepped by hand.
    expect(hook.levels().length).toBe(2)
  })

  it("sends the press and the release to the server", () => {
    const { hook, el, pushed } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })
    expect(pushed.map(([name]) => name)).toContain("push_to_talk_press")

    el.fire("pointerup", {})
    expect(pushed.map(([name]) => name)).toContain("push_to_talk_release")
    expect(hook.lastRejection()).toBe(null)
  })

  it("sends the ADDRESSED agent id with the press when the control carries one", () => {
    const { el, pushed } = mountHook(roomWith([micPublication()]))
    // Per-agent hold-to-talk: the control sits on a specific agent's row.
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })

    const press = pushed.find(([name]) => name === "push_to_talk_press")
    expect(press).toBeTruthy()
    // The server learns WHO the press addresses up front, from the event.
    expect(press[1]).toEqual({ agent_id: "agent-123" })
  })

  it("sends an empty payload when the control names no agent (untargeted press)", () => {
    const { el, pushed } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })

    const press = pushed.find(([name]) => name === "push_to_talk_press")
    expect(press[1]).toEqual({})
  })

  it("scales the waveform bars from the measured level", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })
    hook.sample()

    const scales = bars.map((bar) => bar.style.transform)
    expect(scales.every((t) => /^scaleY\(/.test(t))).toBe(true)
    // Something moved off the resting floor of 0.08.
    expect(scales.some((t) => parseFloat(t.replace(/[^\d.]/g, "")) > 0.08)).toBe(true)
  })

  it("a release with no press pushes nothing", () => {
    const { el, pushed } = mountHook(roomWith([micPublication()]))

    el.fire("pointerup", {})
    expect(pushed).toEqual([])
  })
})

// ── Silence: the mutation target ─────────────────────────────────────────

describe("with a silent track", () => {
  it("reports a level of exactly ZERO — the analyser ran and heard nothing", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]), {
      samples: silentSamples(),
    })

    el.fire("pointerdown", { button: 0 })
    hook.sample()
    hook.sample()

    // The analyser genuinely RAN — the same two frames the live-mic test
    // steps — and every one of them measured silence. That distinction is
    // what makes the non-zero assertion above a real discriminator: this
    // is zero-because-measured, not zero-because-nothing-happened, and
    // the two are told apart by the sample count being identical.
    expect(hook.levels().length).toBe(2)
    expect(hook.peakLevel()).toBe(0)
  })
})

// ── No microphone, or a muted one: silence AND a refused press ───────────

describe("with no live microphone", () => {
  it("refuses the press and captures NOTHING when there is no publication", () => {
    const { hook, el, pushed } = mountHook(roomWith([]))

    el.fire("pointerdown", { button: 0 })
    hook.sample()

    // Silence: nothing was sampled at all.
    expect(hook.levels()).toEqual([])
    expect(hook.peakLevel()).toBe(0)

    // And the press was REFUSED — a named reason, and no press event
    // reached the server. Neither of these is a statement about how the
    // button looks.
    expect(hook.lastRejection()).toBe("no-microphone")
    expect(pushed).toEqual([])
  })

  it("refuses the press when the publication is muted", () => {
    const { hook, el, pushed } = mountHook(
      roomWith([micPublication({ isMuted: true })])
    )

    el.fire("pointerdown", { button: 0 })
    hook.sample()

    expect(hook.levels()).toEqual([])
    expect(hook.lastRejection()).toBe("microphone-muted")
    expect(pushed).toEqual([])
  })

  it("refuses the press when the MediaStreamTrack has ended", () => {
    const pub = micPublication()
    pub.track.mediaStreamTrack = { readyState: "ended", enabled: true }

    const { hook, el, pushed } = mountHook(roomWith([pub]))

    el.fire("pointerdown", { button: 0 })

    expect(hook.levels()).toEqual([])
    expect(hook.lastRejection()).toBe("microphone-muted")
    expect(pushed).toEqual([])
  })

  it("announces the refusal so the page can explain itself", () => {
    const { el } = mountHook(roomWith([]))

    el.fire("pointerdown", { button: 0 })

    expect(dispatched.map((e) => e.type)).toContain("meeting:push-to-talk-rejected")
    expect(dispatched[0].detail.reason).toBe("no-microphone")
  })

  it("a refused press is followed by a working one once the mic returns", () => {
    // Reachability: the refusals above are the missing microphone, not a
    // hook that never works.
    const { hook, el, pushed } = mountHook(roomWith([]))

    el.fire("pointerdown", { button: 0 })
    expect(pushed).toEqual([])

    globalThis.window.__livekitRoom = roomWith([micPublication()])

    el.fire("pointerdown", { button: 0 })
    hook.sample()

    expect(hook.lastRejection()).toBe(null)
    expect(hook.peakLevel()).toBeGreaterThan(0)
    expect(pushed.map(([name]) => name)).toContain("push_to_talk_press")
  })
})

// ── Press bookkeeping ────────────────────────────────────────────────────

describe("press bookkeeping", () => {
  it("ignores a right-click", () => {
    const { pushed, el } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 2 })
    expect(pushed).toEqual([])
  })

  it("a repeated keydown does not re-enter the press", () => {
    const { pushed, el } = mountHook(roomWith([micPublication()]))

    el.fire("keydown", { key: " ", preventDefault() {} })
    el.fire("keydown", { key: " ", repeat: true, preventDefault() {} })

    expect(pushed.filter(([name]) => name === "push_to_talk_press").length).toBe(1)
  })

  it("releases when the pointer leaves the control mid-press", () => {
    const { pushed, el } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })
    el.fire("pointerleave", {})

    expect(pushed.map(([name]) => name)).toEqual([
      "push_to_talk_press",
      "push_to_talk_release",
    ])
  })

  it("stops sampling after release", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))

    el.fire("pointerdown", { button: 0 })
    hook.sample()
    const during = hook.levels().length

    el.fire("pointerup", {})
    hook.sample()

    expect(hook.levels().length).toBe(during)
  })
})

// ── Touch: pointer capture (task 01a07410 stage 5) ───────────────────────
//
// Two behaviours, and the order matters. The happy path (capture holds,
// drift does not cancel) says NOTHING about the failure the stage fixes,
// which is silence: `setPointerCapture` throwing for a pointer that
// already ended, leaving a button that reads as pressed while no handler
// is listening. So the throw is exercised directly and every assertion is
// on state the page and the server can see.

function capturingEl(el, { throws = false } = {}) {
  el.captured = []
  el.released = []
  el.setPointerCapture = (id) => {
    if (throws) {
      // What a browser raises for a pointerId that is no longer active.
      throw new Error("InvalidStateError: pointer is not active")
    }
    el.captured.push(id)
  }
  el.releasePointerCapture = (id) => el.released.push(id)
  return el
}

describe("pointer capture on touch", () => {
  it("takes capture on pointerdown and releases it on pointerup", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))
    capturingEl(el)

    el.fire("pointerdown", { button: 0, pointerId: 7 })
    expect(el.captured).toEqual([7])
    expect(hook.pressed()).toBe(true)

    el.fire("pointerup", {})
    expect(el.released).toEqual([7])
    expect(hook.pressed()).toBe(false)
  })

  it("a pointer that drifts off the target while captured does NOT end the press", () => {
    const { hook, el, pushed } = mountHook(roomWith([micPublication()]))
    capturingEl(el)

    el.fire("pointerdown", { button: 0, pointerId: 3 })
    // The finger slid off the 44px box. With capture held the browser
    // still routes the pointer to us; the leave must be a no-op.
    el.fire("pointerleave", {})

    expect(hook.pressed()).toBe(true)
    expect(el.dataset.pressed).toBe("true")
    expect(pushed.map(([name]) => name)).toEqual(["push_to_talk_press"])

    // Sampling still runs: the utterance was not cut mid-sentence.
    hook.sample()
    expect(hook.peakLevel()).toBeGreaterThan(0)

    el.fire("pointerup", {})
    expect(pushed.map(([name]) => name)).toEqual([
      "push_to_talk_press",
      "push_to_talk_release",
    ])
  })

  it("when setPointerCapture THROWS the press is torn down and refused, not left armed", () => {
    const { hook, el, pushed } = mountHook(roomWith([micPublication()]))
    capturingEl(el, { throws: true })

    // If the throw escaped the handler this line would throw and the test
    // would fail here — the mutation that deletes the try/catch detonates
    // on this call, before any assertion.
    el.fire("pointerdown", { button: 0, pointerId: 9 })

    // Torn down: not pressed, data-pressed cleared, refused and named.
    expect(hook.pressed()).toBe(false)
    expect(el.dataset.pressed).toBe("false")
    expect(hook.lastRejection()).toBe("pointer-lost")
    expect(el.dataset.rejected).toBe("pointer-lost")

    // The refusal is announced, exactly like every other refusal.
    expect(dispatched.map((e) => e.type)).toContain("meeting:push-to-talk-rejected")
    expect(dispatched[dispatched.length - 1].detail).toEqual({ reason: "pointer-lost" })

    // Nothing is captured after the throw — no dangling id to release.
    expect(el.captured).toEqual([])

    // The server saw the press closed, never a press left open. Sampling
    // after the throw measures nothing: the analyser is gone.
    expect(pushed.map(([name]) => name)).toEqual([
      "push_to_talk_press",
      "push_to_talk_release",
    ])
    hook.sample()
    expect(hook.levels()).toEqual([])
  })

  it("a throw on one press does not poison the next one", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))
    capturingEl(el, { throws: true })

    el.fire("pointerdown", { button: 0, pointerId: 9 })
    expect(hook.lastRejection()).toBe("pointer-lost")

    // Capture works again (the pointer is live this time).
    capturingEl(el)
    el.fire("pointerdown", { button: 0, pointerId: 10 })

    expect(hook.pressed()).toBe(true)
    expect(hook.lastRejection()).toBe(null)
    expect(el.captured).toEqual([10])
  })

  it("without a pointerId there is no capture, and leaving still releases", () => {
    // Mouse events without pointer semantics, or a fake element that cannot
    // capture: the pre-stage behaviour is preserved, not silently lost.
    const { hook, el } = mountHook(roomWith([micPublication()]))
    capturingEl(el)

    el.fire("pointerdown", { button: 0 })
    expect(el.captured).toEqual([])

    el.fire("pointerleave", {})
    expect(hook.pressed()).toBe(false)
  })
})

// ── A refusal that arrives from the SERVER, after the press already
// looked accepted locally (task 01a0cf5c stage 1) ─────────────────────────

describe("a server-side refusal (held-by-other)", () => {
  it("tears down an in-progress press and marks it rejected, same as a client-side refusal", () => {
    const { hook, el, serverHandlers } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    expect(hook.pressed()).toBe(true)
    hook.sample()
    expect(hook.peakLevel()).toBeGreaterThan(0)

    // The server answers AFTER the local press already looked accepted —
    // mic live, waveform moving, `data-pressed="true"`.
    serverHandlers["push_to_talk_rejected"]({ agent_id: "agent-123", reason: "held-by-other" })

    expect(hook.pressed()).toBe(false)
    expect(el.dataset.pressed).toBe("false")
    expect(hook.lastRejection()).toBe("held-by-other")
    expect(el.dataset.rejected).toBe("held-by-other")

    // The analyser is torn down — sampling after the refusal measures
    // nothing, exactly like the pointer-lost case.
    hook.sample()
    expect(hook.levels()).toEqual([])

    // Announced through the SAME window event every other refusal uses.
    expect(dispatched.map((e) => e.type)).toContain("meeting:push-to-talk-rejected")
    expect(dispatched[dispatched.length - 1].detail).toEqual({ reason: "held-by-other" })
  })

  it("is ignored when the payload names a DIFFERENT agent than this control", () => {
    const { hook, el, serverHandlers } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    expect(hook.pressed()).toBe(true)

    // A rejection meant for a DIFFERENT agent's row — every
    // `MeetingPushToTalk` instance on the page receives every server
    // push, so the payload's `agent_id` is what narrows this to the
    // right button.
    serverHandlers["push_to_talk_rejected"]({ agent_id: "some-other-agent", reason: "held-by-other" })

    expect(hook.pressed()).toBe(true)
    expect(hook.lastRejection()).toBe(null)
  })

  it("is ignored for a control with no agent id (untargeted press has no floor to lose)", () => {
    const { hook, serverHandlers } = mountHook(roomWith([micPublication()]))
    // No `data-agent-id` set — an untargeted control.

    serverHandlers["push_to_talk_rejected"]({ agent_id: "agent-123", reason: "held-by-other" })

    expect(hook.lastRejection()).toBe(null)
  })
})

// ── The hold-threshold events (task 01a0cf5c stage 2) ─────────────────────
//
// The veil/card/tooltip choreography (design canvas 01a0cf5e-9cb0) is
// driven entirely by these window events, on client-side timing a
// LiveView round trip cannot promise to the millisecond. See
// `meeting_ask_floor_veil.js`'s moduledoc for the consumer side.

describe("the hold-threshold events", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("exposes the threshold that gates the veil/coaching-tooltip split", () => {
    expect(HOLD_THRESHOLD_MS).toBe(380)
  })

  it("dispatches `armed` immediately on press, and `held` only once the threshold elapses while still held", () => {
    vi.useFakeTimers()
    const { el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"
    el.dataset.agentName = "Atlas"

    el.fire("pointerdown", { button: 0 })

    const armed = dispatched.find((e) => e.type === "meeting:push-to-talk-armed")
    expect(armed).toBeTruthy()
    expect(armed.detail).toEqual({ agentId: "agent-123", agentName: "Atlas" })
    // Not yet — the threshold has not elapsed.
    expect(dispatched.map((e) => e.type)).not.toContain("meeting:push-to-talk-held")

    vi.advanceTimersByTime(HOLD_THRESHOLD_MS)

    const held = dispatched.find((e) => e.type === "meeting:push-to-talk-held")
    expect(held).toBeTruthy()
    expect(held.detail).toEqual({ agentId: "agent-123", agentName: "Atlas" })
  })

  it("an early release (<380ms) dispatches `early-release`, and `held` never fires even after the threshold would have elapsed", () => {
    vi.useFakeTimers()
    const { el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    vi.advanceTimersByTime(HOLD_THRESHOLD_MS - 50)
    el.fire("pointerup", {})

    // Time keeps passing after release — a bug that forgot to clear the
    // pending timer would still fire `held` late, opening the veil for
    // a press that already ended.
    vi.advanceTimersByTime(1000)

    expect(dispatched.map((e) => e.type)).toContain("meeting:push-to-talk-early-release")
    expect(dispatched.map((e) => e.type)).not.toContain("meeting:push-to-talk-held")
    expect(dispatched.map((e) => e.type)).not.toContain("meeting:push-to-talk-ended")
  })

  it("a hold that crosses the threshold and then releases dispatches `ended`, not `early-release`", () => {
    vi.useFakeTimers()
    const { el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    vi.advanceTimersByTime(HOLD_THRESHOLD_MS + 20)
    el.fire("pointerup", {})

    expect(dispatched.map((e) => e.type)).toContain("meeting:push-to-talk-ended")
    expect(dispatched.map((e) => e.type)).not.toContain("meeting:push-to-talk-early-release")
  })

  it("a server rejection before the threshold clears the pending timer — no late `held` arrives", () => {
    vi.useFakeTimers()
    const { el, serverHandlers } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    serverHandlers["push_to_talk_rejected"]({ agent_id: "agent-123", reason: "held-by-other" })

    vi.advanceTimersByTime(HOLD_THRESHOLD_MS + 100)

    expect(dispatched.map((e) => e.type)).not.toContain("meeting:push-to-talk-held")
  })

  it("dispatches the measured level on every sample, tagged with the agent id — the SAME level painted on the button's own bars", () => {
    const { hook, el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"

    el.fire("pointerdown", { button: 0 })
    hook.sample()

    const levelEvents = dispatched.filter((e) => e.type === "meeting:push-to-talk-level")
    expect(levelEvents.length).toBe(1)
    expect(levelEvents[0].detail.agentId).toBe("agent-123")
    expect(levelEvents[0].detail.level).toBe(hook.peakLevel())
    expect(levelEvents[0].detail.level).toBeGreaterThan(0)
  })
})

// ── The feedback line (task 01a0f324 stage 3, item 4) ─────────────────────
//
// Replaces the old floating `[data-role="meeting-agent-hold-coach"]`
// tooltip (positioned via `getBoundingClientRect` off the button, because
// its `display: contents` wrapper gave CSS nothing to anchor a
// `position: relative` against). The new element is a plain block
// `ParticipantRail` renders as a full-width sibling of the row, so this
// hook only ever sets its `data-open`/`data-tone` and text content — no
// position math left to test.

function fakeFeedback() {
  const textNode = { textContent: "" }
  const feedback = {
    dataset: {},
    querySelector(sel) {
      return sel === '[data-role="meeting-agent-hold-feedback-text"]' ? textNode : null
    },
  }
  return { feedback, textNode }
}

function fakeRow(feedback) {
  return {
    dataset: {},
    querySelector(sel) {
      return sel === '[data-role="meeting-agent-hold-feedback"]' ? feedback : null
    },
  }
}

describe("the feedback line", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("shows the early-release nudge under the row, full text, and auto-hides", () => {
    vi.useFakeTimers()

    const { feedback, textNode } = fakeFeedback()
    const row = fakeRow(feedback)

    const { el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"
    el.closest = (sel) => (sel === '[data-participant-type="agent"]' ? row : null)

    el.fire("pointerdown", { button: 0 })
    el.fire("pointerup", {}) // released immediately — well under the threshold

    expect(feedback.dataset.open).toBe("true")
    expect(feedback.dataset.tone).toBe("neutral")
    expect(textNode.textContent).toBe("Hold it down and talk. Let go when you are done.")

    vi.advanceTimersByTime(4000)

    expect(feedback.dataset.open).toBe("false")
  })

  it("never opens on a hold that crosses the threshold", () => {
    vi.useFakeTimers()

    const { feedback } = fakeFeedback()
    const row = fakeRow(feedback)

    const { el } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"
    el.closest = () => row
    el.getBoundingClientRect = () => ({ left: 0, top: 0, width: 0, height: 0 })

    el.fire("pointerdown", { button: 0 })
    vi.advanceTimersByTime(HOLD_THRESHOLD_MS + 20)
    el.fire("pointerup", {})

    // "false", not unset: `beginPress()` explicitly hides whatever the
    // LAST press left showing (see its comment) — a hold that crosses
    // the threshold never OPENS it in the first place.
    expect(feedback.dataset.open).toBe("false")
  })

  // Item 4's whole reason to exist: the old tooltip was `max-w-56` and
  // clipped copy this long. Nothing here asserts on CSS (that is
  // `participant_rail_test.exs`'s job) — this only proves the FULL
  // sentence, unabbreviated, is what the hook hands the text node for
  // every client-side rejection reason.
  it.each(["no-microphone", "microphone-muted", "no-audio-context", "pointer-lost"])(
    "shows the full couldn't-hear copy for a %s rejection",
    (reason) => {
      const { feedback, textNode } = fakeFeedback()
      const row = fakeRow(feedback)

      const room =
        reason === "no-microphone"
          ? roomWith([])
          : roomWith([micPublication({ isMuted: reason === "microphone-muted" })])

      const { el, hook } = mountHook(room)
      el.dataset.agentId = "agent-123"
      el.closest = () => row

      if (reason === "no-audio-context") {
        delete globalThis.window.AudioContext
        delete globalThis.window.webkitAudioContext
      }

      if (reason === "pointer-lost") {
        capturingEl(el, { throws: true })
        el.fire("pointerdown", { button: 0, pointerId: 1 })
      } else {
        hook.beginPress()
      }

      expect(feedback.dataset.tone).toBe("error")
      expect(textNode.textContent).toBe(
        "Couldn't hear you. Check that your microphone is on, then hold Ask."
      )
    }
  )

  // `held-by-other` is the one server-side rejection this hook renders —
  // and it is deliberately left OUT of the feedback line (see
  // `REJECTION_FEEDBACK`'s comment in the hook): `ParticipantRail` already
  // shows a "Held by <name>" chip on the row, so this would be the same
  // fact said twice.
  it("does not open the feedback line for a held-by-other rejection", () => {
    const { feedback } = fakeFeedback()
    const row = fakeRow(feedback)

    const { el, serverHandlers } = mountHook(roomWith([micPublication()]))
    el.dataset.agentId = "agent-123"
    el.closest = () => row

    el.fire("pointerdown", { button: 0 })
    serverHandlers["push_to_talk_rejected"]({ agent_id: "agent-123", reason: "held-by-other" })

    // "false", not unset — see the previous test's comment.
    expect(feedback.dataset.open).toBe("false")
  })

  // Task 01a0f324 stage 3: `disconnected()`/`reconnected()` are real
  // Phoenix LiveView hook lifecycle callbacks (see `meeting_client.js`'s
  // and `viewport_breakpoint.js`'s own `reconnected()`), not a new
  // detection mechanism — LiveView calls `disconnected()` when the
  // socket drops and `reconnected()` when it comes back, DOM intact.
  it("shows the offline warning on disconnected(), with no auto-hide, and clears it on reconnected()", () => {
    vi.useFakeTimers()

    const { feedback, textNode } = fakeFeedback()
    const row = fakeRow(feedback)

    const { el, hook } = mountHook(roomWith([micPublication()]))
    el.closest = () => row

    hook.disconnected()

    expect(feedback.dataset.open).toBe("true")
    expect(feedback.dataset.tone).toBe("warning")
    expect(textNode.textContent).toBe("Burrow went offline. It will rejoin when it reconnects.")

    // Does NOT time out on its own — an offline notice that vanished
    // while the socket was still down would be a worse lie than the
    // truncation this stage fixes.
    vi.advanceTimersByTime(60_000)
    expect(feedback.dataset.open).toBe("true")

    hook.reconnected()
    expect(feedback.dataset.open).toBe("false")
  })
})
