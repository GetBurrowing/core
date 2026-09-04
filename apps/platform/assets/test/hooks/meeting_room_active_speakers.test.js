import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingRoom from "../../js/hooks/meeting_room.js"

/**
 * Tests for `MeetingRoom._onActiveSpeaker` (task 01a059e4 stage 3).
 *
 * LiveKit fires `activeSpeakersChanged` many times a second. The hook must
 * NOT push one `active_speakers` event per fire — that is a render storm on
 * a LiveView that repaints the whole gallery grid. Two guards, tested here:
 *
 *   1. identity-set equality — an unchanged set is dropped outright
 *   2. a 250ms trailing timer — a burst collapses into ONE push carrying
 *      the LAST set seen
 *
 * Fake timers, so the assertions are about the debounce and not about wall
 * clock patience.
 */
function harness() {
  const pushed = []
  const hook = Object.create(MeetingRoom)
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  return { hook, pushed }
}

const speakers = (...ids) => ids.map((identity) => ({ identity }))

describe("MeetingRoom._onActiveSpeaker debounce", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it("collapses a burst of N changing calls into exactly one push carrying the last set", () => {
    const { hook, pushed } = harness()

    // Ten rapid, GENUINELY DIFFERENT sets, 10ms apart — well inside 250ms.
    for (let i = 0; i < 10; i++) {
      hook._onActiveSpeaker(speakers(`user:${i}`))
      vi.advanceTimersByTime(10)
    }

    // DIRECTION CONTROL: nothing has been pushed yet — the timer is still
    // pending, so this is a real trailing debounce and not a leading one
    // that happened to fire once.
    expect(pushed).toEqual([])

    vi.advanceTimersByTime(250)

    expect(pushed).toHaveLength(1)
    expect(pushed[0]).toEqual(["active_speakers", { identities: ["user:9"] }])
  })

  it("pushes again for a genuinely new set after the window", () => {
    const { hook, pushed } = harness()

    hook._onActiveSpeaker(speakers("user:a"))
    vi.advanceTimersByTime(250)
    expect(pushed).toHaveLength(1)

    hook._onActiveSpeaker(speakers("user:b"))
    vi.advanceTimersByTime(250)
    expect(pushed).toHaveLength(2)
    expect(pushed[1][1]).toEqual({ identities: ["user:b"] })
  })

  it("drops a repeat of the set already pushed (guard 1)", () => {
    const { hook, pushed } = harness()

    hook._onActiveSpeaker(speakers("user:a", "user:b"))
    vi.advanceTimersByTime(250)
    expect(pushed).toHaveLength(1)

    // Same members, different ORDER — still the same set.
    for (let i = 0; i < 20; i++) {
      hook._onActiveSpeaker(speakers("user:b", "user:a"))
      vi.advanceTimersByTime(5)
    }
    vi.advanceTimersByTime(250)

    expect(pushed).toHaveLength(1)
  })

  it("an empty speaker list is a real transition and is pushed", () => {
    const { hook, pushed } = harness()

    hook._onActiveSpeaker(speakers("user:a"))
    vi.advanceTimersByTime(250)
    hook._onActiveSpeaker([])
    vi.advanceTimersByTime(250)

    expect(pushed.map(([, p]) => p.identities)).toEqual([["user:a"], []])
  })

  it("drops malformed participants rather than pushing empty identities", () => {
    const { hook, pushed } = harness()

    hook._onActiveSpeaker([{ identity: "" }, {}, null, { identity: "user:a" }])
    vi.advanceTimersByTime(250)

    expect(pushed).toEqual([["active_speakers", { identities: ["user:a"] }]])
  })
})
