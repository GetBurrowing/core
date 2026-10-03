import { describe, it, expect, beforeEach, vi } from "vitest"
import MeetingAskHeardOverlay from "../../js/hooks/meeting_ask_heard_overlay.js"

/**
 * Tests for `MeetingAskHeardOverlay` (task 01a0fa7e-afd7, design canvas
 * 01a0fa80-da74, "Burrow round 3: floating heard text and hittable
 * rail") — the floating, out-of-flow box that shows what Burrow heard
 * while a viewer holds an agent's push-to-talk floor.
 *
 * Like `meeting_ask_floor_veil.test.js`, this drives the hook entirely
 * through a fake `window` whose `addEventListener`/`dispatchEvent`
 * actually invoke registered listeners, since this hook is purely a
 * CONSUMER of the `meeting:push-to-talk-*` window events
 * `meeting_push_to_talk.js` dispatches.
 */

function mountHook({ matches = false } = {}) {
  const status = { textContent: "" }
  const text = { textContent: "" }

  const el = {
    dataset: { open: "false", placement: "desktop" },
    style: {},
    querySelector(sel) {
      if (sel === '[data-role="meeting-ask-heard-status"]') return status
      if (sel === '[data-role="meeting-ask-heard-text"]') return text
      return null
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
    matchMedia(_query) {
      return { matches }
    },
    innerWidth: 1280,
  }

  globalThis.CustomEvent = class {
    constructor(type, init) {
      this.type = type
      this.detail = init && init.detail
    }
  }

  // No held row / rail found by default — every positioning test that
  // needs them stubs `document.querySelector` itself. Most behavioural
  // tests below (open/close/append) do not care where the box lands, so
  // this keeps them from having to stub a DOM they never read.
  globalThis.document = {
    querySelector() {
      return null
    },
    querySelectorAll() {
      return []
    },
  }
  globalThis.CSS = { escape: (s) => s }

  const fire = (type, detail) => {
    ;(listeners[type] || []).forEach((fn) => fn({ type, detail }))
  }

  const serverHandlers = {}

  const hook = Object.assign(Object.create(MeetingAskHeardOverlay), {
    el,
    handleEvent: (name, cb) => {
      serverHandlers[name] = cb
    },
  })
  hook.mounted()

  return { hook, el, status, text, fire, serverHandlers }
}

beforeEach(() => {
  delete globalThis.window
  delete globalThis.CustomEvent
  delete globalThis.document
  delete globalThis.CSS
})

describe("before the hold threshold", () => {
  it("does not open on `armed` alone", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(false)
  })
})

describe("once `held` fires", () => {
  it("opens with the fixed status line", () => {
    const { hook, status, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(true)
    // "Must keep" in the canvas: the status line reads exactly this,
    // never "Asking <name>…" — that wording stays on the veil's own
    // card.
    expect(status.textContent).toBe("Listening while you hold")
  })

  it("ignores a `held` for a DIFFERENT agent than the one armed", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "some-other-agent" })

    expect(hook.isOpen()).toBe(false)
  })
})

describe("the heard text window", () => {
  it("appends a chunk addressed to the held agent, and ignores one for a different agent", () => {
    const { text, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "some-other-agent", text: "nope" })
    expect(text.textContent).toBe("")

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "hello" })
    expect(text.textContent).toBe("hello")

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "there" })
    expect(text.textContent).toBe("hello there")
  })

  it("clears on the NEXT press, so a new ask never shows the previous one's words", () => {
    const { text, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })
    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "hello" })
    expect(text.textContent).toBe("hello")

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })
    expect(text.textContent).toBe("")
  })

  it("never appends while closed (armed but not yet held)", () => {
    const { text, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "too early" })

    expect(text.textContent).toBe("")
  })
})

describe("closing", () => {
  // Round 5 (Dalton's PR #1178 re-check, item 2): `ended` used to close
  // the box immediately — which is why nothing showed on release where
  // the mockup shows "✓ Sent to Burrow". It now shows that confirmation
  // and stays open for `SENT_DISPLAY_MS` before actually closing.
  it("shows the sent confirmation on `ended`, and closes only after the display window", () => {
    vi.useFakeTimers()
    try {
      const { hook, status, fire } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Burrow" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123" })
      expect(hook.isOpen()).toBe(true)

      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })

      // Still open, now showing the confirmation rather than "Listening…".
      expect(hook.isOpen()).toBe(true)
      expect(status.textContent).toBe("✓ Sent to Burrow")

      vi.advanceTimersByTime(2_199)
      expect(hook.isOpen()).toBe(true)

      vi.advanceTimersByTime(1)
      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("an early release never opened the overlay, so there is nothing for it to close", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-early-release", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(false)
  })

  it("stays open through a failure for the interrupted-close window, matching the veil's own timing", () => {
    vi.useFakeTimers()
    try {
      const { hook, fire } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123" })
      fire("meeting:push-to-talk-rejected", { reason: "held-by-other" })

      // "Until done or 2s after a failure" (canvas) — not instantly.
      expect(hook.isOpen()).toBe(true)

      vi.advanceTimersByTime(2_000)
      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("a rejection while the overlay was never open is a no-op", () => {
    const { hook, fire } = mountHook()

    fire("meeting:push-to-talk-rejected", { reason: "no-microphone" })

    expect(hook.isOpen()).toBe(false)
  })
})

// Round 2 of this task's review (task 01a0fa7e-afd7 stage 5/6) confirmed
// live, via a real `MutationObserver`, that `data-open` gets stomped back
// to the template's literal `"false"` by a LiveView patch landing on this
// `phx-update="ignore"` element — the SAME `DOM.mergeAttrs(isIgnored:
// true)` mechanism `meeting_push_to_talk.test.js`'s own "surviving a
// LiveView patch mid-hold" block already covers for `MeetingPushToTalk`.
// There is no real morphdom in this vitest harness, so a stomp is
// simulated directly: set the dataset back to the template default, same
// as `simulateLiveViewPatchStomp` does over there.
describe("surviving a LiveView patch mid-hold", () => {
  it("restores data-open after a patch stomps it moments into a hold — not just once", () => {
    const { hook, el, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })
    expect(hook.isOpen()).toBe(true)

    // The exact regression shape the review captured: a server round
    // trip (the row re-rendering on an unrelated activity tick) lands
    // moments into the hold and reverts the attribute.
    el.dataset.open = "false"
    expect(hook.isOpen()).toBe(false) // the bug, reproduced directly
    hook.updated()
    expect(hook.isOpen()).toBe(true) // the fix: restored immediately

    // Sampled across several separate patches, not just the first — every
    // patch that lands mid-hold must be corrected, not just one.
    for (let i = 0; i < 5; i++) {
      el.dataset.open = "false"
      hook.updated()
      expect(hook.isOpen()).toBe(true)
    }

    // Round 5: `ended` now opens the "sent" confirmation rather than
    // closing outright — see the "closing" describe block above.
    fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
    expect(hook.isOpen()).toBe(true)
  })

  it("restores data-placement the same way", () => {
    const { hook, el, fire } = mountHook({ matches: true })

    // No row/rail stubbed -> falls back to phone placement (see the
    // "positioning" describe block below for the same fixture shape).
    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })
    expect(el.dataset.placement).toBe("phone")

    el.dataset.placement = "desktop" // the template's literal default
    hook.updated()
    expect(el.dataset.placement).toBe("phone")
    // The stomp on `data-open` must be corrected independently of
    // `data-placement` — `updated()` always reasserts both.
    expect(hook.isOpen()).toBe(true)
  })

  it("does NOT resurrect data-open for a press that never opened the overlay", () => {
    const { hook, el, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    // Early release — never crossed the hold threshold, so the overlay
    // never opened at all.
    fire("meeting:push-to-talk-early-release", { agentId: "agent-123" })
    expect(hook.isOpen()).toBe(false)

    // A hypothetical unrelated patch artifact must not open a box that
    // was never meant to be open — `updated()` always reads CURRENT
    // `_isHeld`, never assumes a stomp implies "should be open".
    el.dataset.open = "true"
    hook.updated()
    expect(hook.isOpen()).toBe(false)
  })

  it("after a real close, a late patch does not resurrect a stale open state", () => {
    vi.useFakeTimers()
    try {
      const { hook, el, fire } = mountHook()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123" })
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })
      // Round 5: `ended` opens the sent confirmation first; let that
      // window elapse to reach an actual close.
      vi.advanceTimersByTime(2_200)
      expect(hook.isOpen()).toBe(false)

      el.dataset.open = "true" // a hypothetical unrelated patch artifact
      hook.updated()
      expect(hook.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("still appends a transcript chunk arriving in the same tick as a stomp, before updated() runs", () => {
    const { el, text, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    // The review's exact failure shape: a real transcript chunk and a
    // LiveView patch can land in the same tick, and the patch's stomp of
    // `data-open` must not race the chunk's gate. Deliberately NOT
    // calling `hook.updated()` here — the DOM attribute is left stomped
    // ("false") to prove `_appendText` no longer reads it at all.
    el.dataset.open = "false"

    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "hello" })

    expect(text.textContent).toBe("hello")
  })

  it("a chunk for a press the overlay never opened is still dropped, stomp or no stomp", () => {
    const { text, fire, serverHandlers } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    // Not yet held — `_isHeld` is false, so the gate must still hold even
    // though nothing has stomped anything.
    serverHandlers["meeting_ask_transcript_chunk"]({ agent_id: "agent-123", text: "too early" })

    expect(text.textContent).toBe("")
  })
})

// Round 5 (Dalton's PR #1178 re-check, item 5): the old implementation
// anchored BESIDE `[data-role="meeting-left-rail"]` — a SEPARATE desktop
// card-board rail absent from the surface that actually renders the Ask
// control, so this always fell through to the phone placement, ~500px
// above the row it belonged to. The mockup's own placement has no
// desktop/phone branch at all: `position:absolute;left:12px;right:12px;
// top:calc(100% + 6px)` relative to the ROW, the same rule everywhere.
// These tests cover that directly — no rail lookup, no `matchMedia`.
describe("positioning", () => {
  it("falls back to the phone/top-of-viewport placement when the held row cannot be found", () => {
    const { hook, el, fire } = mountHook()

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(true)
    expect(el.dataset.placement).toBe("phone")
    expect(el.style.left).toBe("16px")
  })

  it("anchors directly under the held row, at every viewport, when nothing overlaps", () => {
    const { hook, el, fire } = mountHook()

    // Stubbed AFTER `mountHook` — `mounted()` does not touch `document`
    // until the first `_reposition` call below, so this survives.
    const row = {
      getBoundingClientRect: () => ({ top: 100, left: 20, right: 320, bottom: 140, width: 300 }),
    }
    const button = {
      dataset: { agentId: "agent-123" },
      closest: () => row,
    }

    globalThis.document.querySelector = (sel) => {
      if (sel.includes("meeting-agent-hold-to-talk")) return button
      return null
    }
    globalThis.document.querySelectorAll = () => []

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(true)
    expect(el.dataset.placement).toBe("row")
    expect(el.style.left).toBe("32px") // row.left (20) + 12px inset
    expect(el.style.top).toBe("146px") // row.bottom (140) + 6px gap
    expect(el.style.width).toBe("276px") // row.width (300) - 2*12px inset
  })

  it("falls back to phone placement when the under-row anchor would overlap a rail control", () => {
    const { hook, el, fire } = mountHook()

    const row = {
      getBoundingClientRect: () => ({ top: 100, left: 20, right: 320, bottom: 140, width: 300 }),
    }
    const button = {
      dataset: { agentId: "agent-123" },
      closest: () => row,
    }
    // A control whose rect intersects the computed under-row overlay rect
    // (left 32, top 146, width 276, height budget 160) forces the
    // fallback — e.g. the NEXT agent row's own Ask key or kick button.
    const overlappingControl = {
      getBoundingClientRect: () => ({ left: 40, right: 100, top: 150, bottom: 200 }),
    }

    globalThis.document.querySelector = (sel) => {
      if (sel.includes("meeting-agent-hold-to-talk")) return button
      return null
    }
    globalThis.document.querySelectorAll = () => [overlappingControl]

    fire("meeting:push-to-talk-armed", { agentId: "agent-123" })
    fire("meeting:push-to-talk-held", { agentId: "agent-123" })

    expect(hook.isOpen()).toBe(true)
    expect(el.dataset.placement).toBe("phone")
  })
})
