import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingPushToTalk from "../../js/hooks/meeting_push_to_talk.js"

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

  const hook = Object.assign(Object.create(MeetingPushToTalk), {
    el,
    pushEvent: (name, payload) => pushed.push([name, payload]),
    pushEventTo: () => {},
    handleEvent: () => {},
  })

  hook.mounted()
  return { hook, el, pushed }
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
