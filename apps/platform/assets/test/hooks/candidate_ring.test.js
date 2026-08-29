import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import CandidateRing from "../../js/hooks/candidate_ring.js"

/**
 * Tests for the `CandidateRing` hook (task 01a03f4e-78b1).
 *
 * The defect this hook exists to fix is precise and was measured on the
 * shipped rail: the countdown number was computed on the server at render
 * time and then *did not move*. A card said "30" until the next LiveView
 * patch, whenever that happened to be.
 *
 * So "the element exists" and "a number is rendered" are both worthless
 * assertions here — the old rail passed both. Every test below asserts that
 * the number CHANGES, and by how much, against a deadline the test chose.
 *
 * The hook runs in vitest's default `node` env (no jsdom), so this builds a
 * minimal fake element. The fake resolves the two `[data-role=...]`
 * selectors the hook actually uses rather than returning a fixed node for
 * any input — a fake that answered everything would let a hook querying the
 * wrong selector pass.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

function fakeNode(role, { withDataset = false } = {}) {
  return {
    role,
    textContent: "",
    attrs: {},
    dataset: withDataset ? { remaining: "" } : {},
    setAttribute(name, value) {
      this.attrs[name] = value
    },
  }
}

// Resolves `[data-role='x'], [data-role='y']` against the node list by the
// role each node was built with. Deliberately literal: an unknown selector
// matches nothing, so a typo in the hook shows up as a dead assertion
// rather than as a passing test.
function rolesIn(selector) {
  return [...selector.matchAll(/data-role='([^']+)'/g)].map((m) => m[1])
}

function fakeHookEl({ actsAt, totalSeconds = 30, circumference = 94.25 }) {
  const nodes = [
    fakeNode("meeting-candidate-remaining", { withDataset: true }),
    fakeNode("meeting-candidate-remaining-word"),
    fakeNode("meeting-candidate-ring-progress"),
  ]

  return {
    dataset: {
      actsAt,
      totalSeconds: String(totalSeconds),
      circumference: String(circumference),
    },
    nodes,
    querySelectorAll(selector) {
      const roles = rolesIn(selector)
      return nodes.filter((n) => roles.includes(n.role))
    },
    querySelector(selector) {
      const roles = rolesIn(selector)
      return nodes.find((n) => roles.includes(n.role)) || null
    },
    node(role) {
      return nodes.find((n) => n.role === role)
    },
  }
}

// A hook instance bound to a fake element, with a `pushEvent` spy so the
// "never polls the server" claim is checkable rather than asserted in a
// comment.
function mountHook(el) {
  const hook = Object.create(CandidateRing)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.pushEventTo = vi.fn()
  hook.mounted()
  return hook
}

function shownNumber(el) {
  return el.node("meeting-candidate-remaining").textContent
}

// ── Suite ────────────────────────────────────────────────────────────────

describe("CandidateRing", () => {
  const T0 = new Date("2026-08-29T12:00:00.000Z").getTime()

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("ticks the number down once a second — the defect this hook fixes", () => {
    const el = fakeHookEl({ actsAt: new Date(T0 + 30_000).toISOString() })
    const hook = mountHook(el)

    // The value at mount, before any time passes.
    expect(shownNumber(el)).toBe("30")

    vi.advanceTimersByTime(3000)
    expect(shownNumber(el)).toBe("27")

    vi.advanceTimersByTime(7000)
    expect(shownNumber(el)).toBe("20")

    hook.destroyed()
  })

  it("reads ITS OWN deadline — two cards at one instant show different numbers", () => {
    const near = fakeHookEl({ actsAt: new Date(T0 + 5_000).toISOString() })
    const far = fakeHookEl({ actsAt: new Date(T0 + 25_000).toISOString() })

    const a = mountHook(near)
    const b = mountHook(far)

    // The anti-vacuity pair. A hook that started a 30-second timer at mount,
    // or that rendered `total` and decremented, would show the SAME number
    // on both cards and pass every single-card assertion above.
    expect(shownNumber(near)).toBe("5")
    expect(shownNumber(far)).toBe("25")

    vi.advanceTimersByTime(2000)
    expect(shownNumber(near)).toBe("3")
    expect(shownNumber(far)).toBe("23")

    a.destroyed()
    b.destroyed()
  })

  it("drains the ring in step with the number, and agrees with the server at both ends", () => {
    const circumference = 94.25
    const el = fakeHookEl({
      actsAt: new Date(T0 + 30_000).toISOString(),
      circumference,
    })
    const hook = mountHook(el)
    const ring = el.node("meeting-candidate-ring-progress")

    // Full ring at t=total: nothing drained.
    expect(Number(ring.attrs["stroke-dashoffset"])).toBeCloseTo(0, 2)

    // Half drained at half time — this is the assertion that catches a ring
    // wired to the wrong end of the fraction, which would look plausible
    // and count backwards.
    vi.advanceTimersByTime(15_000)
    expect(Number(ring.attrs["stroke-dashoffset"])).toBeCloseTo(circumference / 2, 1)

    // Empty at zero.
    vi.advanceTimersByTime(15_000)
    expect(Number(ring.attrs["stroke-dashoffset"])).toBeCloseTo(circumference, 2)

    hook.destroyed()
  })

  it("floors at zero and stops, rather than counting into negative seconds", () => {
    const el = fakeHookEl({ actsAt: new Date(T0 + 2_000).toISOString() })
    const hook = mountHook(el)

    vi.advanceTimersByTime(10_000)
    expect(shownNumber(el)).toBe("0")

    // Still zero a further minute on. A hook that kept subtracting would
    // render "-58" at a participant.
    vi.advanceTimersByTime(60_000)
    expect(shownNumber(el)).toBe("0")

    hook.destroyed()
  })

  it("renders 0, not a negative, for a card already overdue at mount", () => {
    // The reachable case, and the one that made the zero-floor survive a
    // first mutation run: the interval stops the instant it reaches zero, so
    // it can never tick INTO a negative. But the very first tick happens in
    // `mounted()`, and a card whose `acts_at` has already passed — rendered
    // by the server in the window before the sweeper claims it — arrives
    // overdue. Without the floor that participant is shown "-5".
    const el = fakeHookEl({ actsAt: new Date(T0 - 5_000).toISOString() })
    const hook = mountHook(el)

    expect(shownNumber(el)).toBe("0")

    hook.destroyed()
  })

  it("never asks the server for anything — not even at zero", () => {
    const el = fakeHookEl({ actsAt: new Date(T0 + 2_000).toISOString() })
    const hook = mountHook(el)

    vi.advanceTimersByTime(30_000)

    // The countdown is a rendering of the server's `acts_at`; the sweeper
    // fires on its own and broadcasts. A push here — per card, per second,
    // per participant — is exactly what a client-side countdown exists to
    // avoid, and at zero it would give every browser its own opinion about
    // when a card fired.
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(hook.pushEventTo).not.toHaveBeenCalled()

    hook.destroyed()
  })

  it("picks up a moved deadline on update instead of counting from the old one", () => {
    const el = fakeHookEl({ actsAt: new Date(T0 + 10_000).toISOString() })
    const hook = mountHook(el)

    vi.advanceTimersByTime(5000)
    expect(shownNumber(el)).toBe("5")

    // The server extended the countdown and re-rendered.
    el.dataset.actsAt = new Date(T0 + 5000 + 30_000).toISOString()
    hook.updated()

    expect(shownNumber(el)).toBe("30")

    hook.destroyed()
  })

  it("stops ticking once destroyed", () => {
    const el = fakeHookEl({ actsAt: new Date(T0 + 30_000).toISOString() })
    const hook = mountHook(el)

    vi.advanceTimersByTime(2000)
    expect(shownNumber(el)).toBe("28")

    hook.destroyed()
    vi.advanceTimersByTime(10_000)

    // Frozen at the last value. A leaked interval on a card that has left
    // the rail keeps a detached node alive for the life of the meeting.
    expect(shownNumber(el)).toBe("28")
  })

  it("does nothing at all without a deadline, rather than counting from now", () => {
    const el = fakeHookEl({ actsAt: undefined })
    const hook = mountHook(el)

    vi.advanceTimersByTime(5000)

    // A disarmed card has no `acts_at`. Defaulting to "now + total" is how
    // a stopped card would appear to still be counting down.
    expect(shownNumber(el)).toBe("")

    hook.destroyed()
  })
})
