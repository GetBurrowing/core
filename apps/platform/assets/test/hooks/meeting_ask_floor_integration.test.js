import { describe, it, expect, beforeEach, vi } from "vitest"
import MeetingAskFloorVeil from "../../js/hooks/meeting_ask_floor_veil.js"
import MeetingAskHeardOverlay from "../../js/hooks/meeting_ask_heard_overlay.js"

/**
 * Cross-hook regression coverage, task 01a0fa7e-afd7 stage 2.
 *
 * `meeting_ask_floor_veil.test.js` and `meeting_ask_heard_overlay.test.js`
 * each prove their own hook is correct, but each one mounts against its
 * OWN private fake `window` — so neither suite ever exercises the thing
 * that is actually true in production: ONE real `window` dispatches
 * `meeting:push-to-talk-*` events to BOTH hook instances at once (the
 * veil and the heard overlay are two separate singletons listening to the
 * same global events — see both hooks' moduledocs, "opens/closes in
 * lockstep... without either hook holding a reference to the other").
 * That is exactly the seam a per-hook unit test cannot see, and exactly
 * where the user-visible "box drops after ~0.25s of holding" bug (task
 * 01a0f842 stage 2, re-reported live against task 01a0fa7e-afd7 item 2)
 * would have to show up if the fix were only partial.
 *
 * Mounting both hooks against one shared fake `window` and firing the
 * real event sequence directly pins the "both resolve together" claim
 * instead of leaving it as an unverified comment.
 */

function mountBoth() {
  const listeners = {}
  const sharedWindow = {
    addEventListener(type, fn) {
      ;(listeners[type] = listeners[type] || []).push(fn)
    },
    removeEventListener(type, fn) {
      if (!listeners[type]) return
      listeners[type] = listeners[type].filter((f) => f !== fn)
    },
    matchMedia() {
      return { matches: false }
    },
    innerWidth: 1280,
  }
  globalThis.window = sharedWindow

  globalThis.CustomEvent = class {
    constructor(type, init) {
      this.type = type
      this.detail = init && init.detail
    }
  }

  // No held row / rail — the overlay falls back to the phone placement,
  // which this test does not care about; only open/closed state matters
  // here.
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

  // ── Veil ──
  const veilLabel = { textContent: "" }
  const veilCard = {
    style: {},
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 100, height: 40 }
    },
  }
  const veilBars = Array.from({ length: 12 }, () => ({ style: {} }))
  const veilError = { dataset: {} }
  const veilErrorText = { textContent: "" }
  const veilEl = {
    dataset: {},
    querySelector(sel) {
      if (sel === '[data-role="meeting-ask-label"]') return veilLabel
      if (sel === '[data-role="meeting-ask-card"]') return veilCard
      if (sel === '[data-role="meeting-ask-error"]') return veilError
      if (sel === '[data-role="meeting-ask-error-text"]') return veilErrorText
      return null
    },
    querySelectorAll(sel) {
      return sel === "[data-ptt-bar]" ? veilBars : []
    },
  }
  const veilServerHandlers = {}
  const veil = Object.assign(Object.create(MeetingAskFloorVeil), {
    el: veilEl,
    handleEvent: (name, cb) => {
      veilServerHandlers[name] = cb
    },
  })
  veil.mounted()

  // ── Heard overlay ──
  const overlayStatus = { textContent: "" }
  const overlayText = { textContent: "" }
  const overlayEl = {
    dataset: { open: "false", placement: "desktop" },
    style: {},
    querySelector(sel) {
      if (sel === '[data-role="meeting-ask-heard-status"]') return overlayStatus
      if (sel === '[data-role="meeting-ask-heard-text"]') return overlayText
      return null
    },
  }
  const overlayServerHandlers = {}
  const overlay = Object.assign(Object.create(MeetingAskHeardOverlay), {
    el: overlayEl,
    handleEvent: (name, cb) => {
      overlayServerHandlers[name] = cb
    },
  })
  overlay.mounted()

  return { veil, overlay, fire, veilServerHandlers, overlayServerHandlers, overlayText }
}

beforeEach(() => {
  delete globalThis.window
  delete globalThis.CustomEvent
  delete globalThis.document
  delete globalThis.CSS
})

describe("veil + heard overlay sharing one real window (task 01a0fa7e-afd7 stage 2)", () => {
  it("both open together on `held` and both stay open through a mid-hold rejection, resolving together after the interrupted delay", () => {
    vi.useFakeTimers()
    try {
      const { veil, overlay, fire } = mountBoth()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Burrow" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Burrow" })

      expect(veil.isOpen()).toBe(true)
      expect(overlay.isOpen()).toBe(true)

      // The exact previously-buggy trigger: a rejection signal arriving
      // while the key is still physically held. Neither box may close
      // synchronously.
      fire("meeting:push-to-talk-rejected", { reason: "held-by-other" })

      expect(veil.isOpen()).toBe(true)
      expect(overlay.isOpen()).toBe(true)

      // Short of the interrupted-close window (quarter second and then
      // some) — this is the exact regression shape: closing here would
      // be the "drops after ~0.25s" bug reproduced live.
      vi.advanceTimersByTime(250)
      expect(veil.isOpen()).toBe(true)
      expect(overlay.isOpen()).toBe(true)

      // Both resolve on the SAME 2s window once it actually elapses.
      vi.advanceTimersByTime(1_750)
      expect(veil.isOpen()).toBe(false)
      expect(overlay.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("both stay open while held even after the server resolves the outcome early, and the overlay (which never waits on outcome) closes exactly at the physical release while the veil waits for its own fly/crumble animation", () => {
    vi.useFakeTimers()
    try {
      const { veil, overlay, fire, veilServerHandlers } = mountBoth()

      fire("meeting:push-to-talk-armed", { agentId: "agent-123", agentName: "Burrow" })
      fire("meeting:push-to-talk-held", { agentId: "agent-123", agentName: "Burrow" })

      // Server resolves before the physical release reaches the client.
      veilServerHandlers["meeting_ask_outcome"]({
        agent_id: "agent-123",
        candidate_id: "candidate-1",
        outcome: "fly",
      })

      // Still held — neither box may react to the outcome yet.
      expect(veil.isOpen()).toBe(true)
      expect(overlay.isOpen()).toBe(true)

      // Physical release.
      fire("meeting:push-to-talk-ended", { agentId: "agent-123" })

      // The overlay has nothing further to show once the key is up —
      // closes immediately, regardless of outcome.
      expect(overlay.isOpen()).toBe(false)
      // The veil plays the parked outcome, which resolves on its own
      // animation timer rather than synchronously.
      expect(veil.isOpen()).toBe(true)
      vi.advanceTimersByTime(400)
      expect(veil.isOpen()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })
})
