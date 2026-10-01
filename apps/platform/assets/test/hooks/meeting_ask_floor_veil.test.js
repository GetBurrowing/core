import { describe, it, expect, beforeEach, vi } from "vitest"
import MeetingAskFloorVeil from "../../js/hooks/meeting_ask_floor_veil.js"

/**
 * Tests for `MeetingAskFloorVeil` (task 01a0cf5c stage 2, design canvas
 * 01a0cf5e-9cb0) — the singleton veil/card that opens while a viewer
 * holds an agent's push-to-talk floor.
 *
 * This hook is purely a CONSUMER of the `meeting:push-to-talk-*` window
 * events `meeting_push_to_talk.js` dispatches (see that file's own test
 * suite for the producer side), so these tests drive it entirely through
 * a fake `window` whose `addEventListener`/`dispatchEvent` actually
 * invoke registered listeners — unlike `meeting_push_to_talk.test.js`'s
 * fake window, which only RECORDS dispatches for a hook that is the
 * emitter, not the listener, here.
 */

function fakeBar() {
  return { style: {} }
}

// A fake `[data-role="meeting-ask-card"]` — real enough for
// `_playOutcome`'s `getBoundingClientRect` calls (both on this card and
// on whatever `document.querySelector` returns for the fly target) to
// run without throwing, without asserting on the actual numbers.
function fakeCard() {
  return {
    style: {},
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 100, height: 40 }
    },
  }
}

function mountHook({ barCount = 12 } = {}) {
  const label = { textContent: "" }
  const transcript = { textContent: "" }
  const card = fakeCard()
  const bars = Array.from({ length: barCount }, fakeBar)
  const error = { dataset: {} }
  const errorText = { textContent: "" }

  const el = {
    dataset: {},
    querySelector(sel) {
      if (sel === '[data-role="meeting-ask-label"]') return label
      if (sel === '[data-role="meeting-ask-transcript"]') return transcript
      if (sel === '[data-role="meeting-ask-card"]') return card
      if (sel === '[data-role="meeting-ask-error"]') return error
      if (sel === '[data-role="meeting-ask-error-text"]') return errorText
      return null
    },
    querySelectorAll(sel) {
      return sel === "[data-ptt-bar]" ? bars : []
    },
  }

  const listeners = {}
  globalThis.window = {
    addEventListener(type, fn) {
      ;(listeners[type] = listeners[type] || []).push(fn)
    },
    removeEventListener(type, fn) {
      if (!listeners[type]) return
      listeners[type] = listeners[type].filter((f) => f !== fn)
    },
  }

  globalThis.CustomEvent = class {
    constructor(type, init) {
      this.type = type
      this.detail = init && init.detail
    }
  }

  const fire = (type, detail) => {
    ;(listeners[type] || []).forEach((fn) => fn({ type, detail }))
  }

  // Recorded by name so a test can simulate the SERVER pushing
  // `meeting_ask_transcript_chunk` / `meeting_ask_outcome` (task
  // 01a0cf5c stage 3) without a real LiveView socket — `mounted()`
  // registers via `this.handleEvent(name, cb)`, exactly like a real
  // hook would.
  const serverHandlers = {}

  const hook = Object.assign(Object.create(MeetingAskFloorVeil), {
    el,
    handleEvent: (name, cb) => {
      serverHandlers[name] = cb
    },
  })
  hook.mounted()

  return { hook, el, label, transcript, card, bars, error, errorText, fire, serverHandlers }
}

beforeEach(() => {
  delete globalThis.window
  delete globalThis.CustomEvent
})

describe("before the hold threshold", () => {
  it("does not open on `armed` alone", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })

    expect(hook.isOpen()).toBe(false)
  })
})

describe("once `held` fires", () => {
  it("opens and labels itself with the agent's name", () => {
    const { hook, label, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })

    expect(hook.isOpen()).toBe(true)
    expect(label.textContent).toBe("Asking Atlas…")
  })

  it("ignores a `held` for a DIFFERENT agent than the one armed", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "some-other-agent", agentName: "Rey" })

    expect(hook.isOpen()).toBe(false)
  })
})

describe("the level meter", () => {
  it("paints the bars from the measured level once open, and ignores a level for a different agent", () => {
    const { hook, bars, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
    // Opening resets every bar to the resting scale (0.08) — capture that
    // baseline so the next assertion can tell "untouched" apart from
    // "painted", rather than comparing against `undefined`.
    const resting = bars.map((b) => b.style.transform)

    fire("meeting:push-to-talk-level", { agentId: "some-other-agent", level: 1 })

    // A level for a different agent must not move these bars off rest.
    expect(bars.map((b) => b.style.transform)).toEqual(resting)

    fire("meeting:push-to-talk-level", { agentId: "agent-123", level: 1 })

    expect(hook.isOpen()).toBe(true)
    expect(bars.some((b) => /^scaleY\(/.test(b.style.transform))).toBe(true)
  })

  it("does not paint before the veil has opened (armed but not yet held)", () => {
    const { bars, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-level", { agentId: "agent-123", level: 1 })

    expect(bars.every((b) => b.style.transform === undefined)).toBe(true)
  })
})

describe("closing", () => {
  it("stays open on `ended` — the release OUTCOME is server-decided (task 01a0cf5c stage 3), not client-driven", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-ended", { agentId: "agent-123" })

    // Unlike stage 2, `ended` alone does not close the veil — it parks
    // it awaiting `meeting_ask_outcome` from the server.
    expect(hook.isOpen()).toBe(true)
  })

  // Task 01a0f842 stage 2, canvas 01a0f846-cfb1, item 2: the heard card
  // used to close INSTANTLY on any rejection, even one arriving while
  // the key was still physically held (`held-by-other` via
  // `_serverReject` in `meeting_push_to_talk.js`, which never fires
  // `meeting:push-to-talk-ended`) — that unconditional, synchronous
  // close was the flash-then-vanish bug. It now always shows the
  // failure inline and resolves on its own timer, never synchronously,
  // whether or not the key is still down.
  describe("a rejection mid-hold", () => {
    it("does not close synchronously — it shows inline and resolves after the interrupted delay", () => {
      vi.useFakeTimers()
      try {
        const { hook, error, errorText, fire } = mountHook()

        fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
        fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
        fire("meeting:push-to-talk-rejected", { reason: "held-by-other" })

        // Still open and still held immediately after the rejection —
        // this is the exact "flashes and disappears" bug this stage
        // fixes: no synchronous close.
        expect(hook.isOpen()).toBe(true)
        expect(error.dataset.open).toBe("true")
        expect(errorText.textContent).not.toBe("")

        // It does resolve eventually — "never vanishes without saying
        // why", not "never vanishes at all".
        vi.advanceTimersByTime(2_000)
        expect(hook.isOpen()).toBe(false)
      } finally {
        vi.useRealTimers()
      }
    })

    it("resolves the same way once the key is no longer held (e.g. pointer-lost, which ends the press first)", () => {
      vi.useFakeTimers()
      try {
        const { hook, error, fire } = mountHook()

        fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
        fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
        // `pointer-lost` calls `endPress()` before `_reject`, so by the
        // time the rejection reaches this hook the hold has already
        // ended — simulate that ordering.
        fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
        fire("meeting:push-to-talk-rejected", { reason: "pointer-lost" })

        expect(hook.isOpen()).toBe(true)
        expect(error.dataset.open).toBe("true")

        vi.advanceTimersByTime(2_000)
        expect(hook.isOpen()).toBe(false)
      } finally {
        vi.useRealTimers()
      }
    })

    it("is a no-op if the veil was never open (an early-release-adjacent rejection with nothing to show)", () => {
      const { hook, error, fire } = mountHook()

      fire("meeting:push-to-talk-rejected", { reason: "no-microphone" })

      expect(hook.isOpen()).toBe(false)
      expect(error.dataset.open).not.toBe("true")
    })
  })

  describe("an outcome arriving while still held", () => {
    it("does not close the card until the key is actually released", () => {
      vi.useFakeTimers()
      try {
        const { hook, fire, serverHandlers } = mountHook()

        fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
        fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })

        // The server resolves before this client's own `ended` arrives.
        serverHandlers["meeting_ask_outcome"]({
          agent_id: "agent-123",
          candidate_id: "candidate-1",
          outcome: "fly",
        })

        expect(hook.isOpen()).toBe(true)

        // Now the physical release reaches the client — the parked
        // outcome plays for real.
        fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
        vi.advanceTimersByTime(400)

        expect(hook.isOpen()).toBe(false)
      } finally {
        vi.useRealTimers()
      }
    })
  })

  it("an early release never opened the veil, so there is nothing for it to close", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-early-release", { agentId: "agent-123", agentName: "Atlas" })

    expect(hook.isOpen()).toBe(false)

    // And a stale `held` that somehow arrived late for the same press
    // must not reopen it after the fact.
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
    expect(hook.isOpen()).toBe(false)
  })
})

// ── Task 01a0cf5c stage 3: the live transcript feed and the server-
// decided release outcome (fly / crumble / the safety-net fade) ──────────

describe("the live transcript feed", () => {
  it("appends a chunk addressed to the held agent, and ignores one for a different agent", () => {
    const { transcript, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "some-other-agent", text: "nope" })
    expect(transcript.textContent).toBe("")

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "hello" })
    expect(transcript.textContent).toBe("hello")

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "there" })
    expect(transcript.textContent).toBe("hello there")
  })

  it("clears on the NEXT press, so a new ask never shows the previous one's words", () => {
    const { transcript, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "hello" })
    expect(transcript.textContent).toBe("hello")

    fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
    expect(transcript.textContent).toBe("")
  })
})

describe("the release outcome", () => {
  it("resolves (closes) once `meeting_ask_outcome` names the held agent, fly outcome", () => {
    // Fake timers from BEFORE mount: `_playOutcome`'s `_finishOutcome`
    // is scheduled via `setTimeout` the instant the outcome event
    // fires below, so the clock has to already be fake at that point —
    // installing it afterward would leave a REAL timer running that
    // `vi.runAllTimers()` can never see.
    vi.useFakeTimers()
    try {
      const { hook, fire, serverHandlers } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
      expect(hook.isOpen()).toBe(true)

      serverHandlers["meeting_ask_outcome"]({
        agent_id: "agent-123",
        candidate_id: "candidate-1",
        outcome: "fly",
      })

      // The transition is animated (`_finishOutcome` runs on a timer),
      // so the veil is not closed SYNCHRONOUSLY — but it must resolve.
      // Advance past the 340ms transition only, NOT `runAllTimers`,
      // which would also fire the (now superseded) 4500ms safety net.
      vi.advanceTimersByTime(400)

      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("resolves (closes) on a crumble outcome too", () => {
    vi.useFakeTimers()
    try {
      const { hook, fire, serverHandlers } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })

      serverHandlers["meeting_ask_outcome"]({
        agent_id: "agent-123",
        candidate_id: "candidate-1",
        outcome: "crumble",
      })

      vi.advanceTimersByTime(400)

      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("ignores an outcome addressed to a different agent", () => {
    vi.useFakeTimers()
    try {
      const { hook, fire, serverHandlers } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })

      serverHandlers["meeting_ask_outcome"]({
        agent_id: "some-other-agent",
        candidate_id: "candidate-1",
        outcome: "fly",
      })

      // Advance past the transition window, but NOT `runAllTimers` —
      // this must stay open on its own merits, not because nothing
      // else had a chance to fire.
      vi.advanceTimersByTime(400)

      expect(hook.isOpen()).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it("has a safety-net fade if `meeting_ask_outcome` never arrives, so the veil cannot be stuck open forever", () => {
    vi.useFakeTimers()
    try {
      const { hook, fire } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Atlas" })
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
      expect(hook.isOpen()).toBe(true)

      vi.runAllTimers()

      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })
})
