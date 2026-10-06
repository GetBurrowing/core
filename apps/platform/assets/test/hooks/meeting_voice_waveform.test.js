import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingVoiceWaveform, {
  UPDATE_INTERVAL_MS,
  voiceBarBase,
} from "../../js/hooks/meeting_voice_waveform.js"
import { paintBars } from "../../js/hooks/lib/ptt_waveform.js"

/**
 * MeetingVoiceWaveform (task 01a1117f stage 4): the voice-only presence
 * glyph on an agent's gallery tile and rail row.
 *
 * No jsdom in the assets workspace, so `document`, `window`, the element,
 * its bars and `IntersectionObserver` are stubbed down to what the hook
 * touches. The Room is a fake with the two members the hook reads
 * (`on`/`off` for `activeSpeakersChanged`, `getParticipantByIdentity`), and
 * a participant whose `audioLevel` the test sets, as livekit-client's
 * speaker-update handler does.
 */

const IDENTITY = "agent:0000-burrow"

function fakeRoom() {
  const handlers = new Map()
  const participant = { identity: IDENTITY, isSpeaking: false, audioLevel: 0 }
  return {
    participant,
    handlers,
    on(event, fn) {
      if (!handlers.has(event)) handlers.set(event, new Set())
      handlers.get(event).add(fn)
    },
    off(event, fn) {
      handlers.get(event)?.delete(fn)
    },
    emit(event, ...args) {
      for (const fn of handlers.get(event) || []) fn(...args)
    },
    listenerCount(event) {
      return handlers.get(event)?.size || 0
    },
    getParticipantByIdentity(identity) {
      return identity === IDENTITY ? participant : undefined
    },
  }
}

// mulberry32: a small seeded generator, so jitter tests are deterministic.
function seeded(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function harness({ reducedMotion = false, room = fakeRoom(), random = null, barCount = 4 } = {}) {
  const docListeners = new Map()
  globalThis.document = {
    hidden: false,
    addEventListener(event, fn) {
      if (!docListeners.has(event)) docListeners.set(event, new Set())
      docListeners.get(event).add(fn)
    },
    removeEventListener(event, fn) {
      docListeners.get(event)?.delete(fn)
    },
  }

  const observers = []
  globalThis.IntersectionObserver = class {
    constructor(cb) {
      this.cb = cb
      this.disconnected = false
      observers.push(this)
    }
    observe() {}
    disconnect() {
      this.disconnected = true
    }
  }

  globalThis.window = {
    __livekit_room: room,
    matchMedia: (query) => ({
      matches: reducedMotion && query.includes("prefers-reduced-motion"),
    }),
  }

  const bars = Array.from({ length: barCount }, () => ({ style: { transform: "" } }))
  // The component's two elements: the outer, phx-update="ignore" hook
  // element, and the inner [data-voice-waveform] glyph that carries every
  // JS-owned attribute. `el` below is the GLYPH, because that is where the
  // state must land.
  const el = {
    dataset: { identity: IDENTITY },
    querySelectorAll: (sel) => (sel === "[data-wave-bar]" ? bars : []),
  }
  const root = {
    dataset: { identity: IDENTITY },
    querySelector: (sel) => (sel === "[data-voice-waveform]" ? el : null),
  }

  const hook = Object.create(MeetingVoiceWaveform)
  hook.el = root
  if (random) hook.random = random

  const fireDoc = (event) => {
    for (const fn of docListeners.get(event) || []) fn({})
  }

  return { hook, el, root, bars, room, observers, docListeners, fireDoc }
}

const transforms = (bars) => bars.map((b) => b.style.transform)
const scales = (bars) => bars.map((b) => Number(b.style.transform.match(/scaleY\(([\d.]+)\)/)[1]))
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length
const speak = (room) => room.emit("activeSpeakersChanged", [room.participant])
const silence = (room) => room.emit("activeSpeakersChanged", [])

describe("MeetingVoiceWaveform", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => {
    vi.useRealTimers()
    delete globalThis.document
    delete globalThis.window
    delete globalThis.IntersectionObserver
  })

  it("mounts idle, with no interval and no inline transforms", () => {
    const { hook, el, bars } = harness()
    hook.mounted()

    expect(el.dataset.waveState).toBe("idle")
    expect(hook._timer).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
    expect(transforms(bars)).toEqual(["", "", "", ""])
  })

  it("speaking switches to active, and the transforms follow audioLevel", () => {
    // A constant jitter factor isolates the level: bar by bar, louder is taller.
    const { hook, el, bars, room } = harness({ random: () => 0.5 })
    hook.mounted()

    room.participant.audioLevel = 0.1
    speak(room)
    expect(el.dataset.waveState).toBe("active")
    expect(vi.getTimerCount()).toBe(1)
    const quiet = transforms(bars)
    expect(quiet.every((t) => t.startsWith("scaleY("))).toBe(true)

    room.participant.audioLevel = 0.4
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS)
    const loud = transforms(bars)

    // DIRECTION: louder is taller, bar by bar, not merely different.
    const scale = (t) => Number(t.match(/scaleY\(([\d.]+)\)/)[1])
    loud.forEach((t, i) => expect(scale(t)).toBeGreaterThan(scale(quiet[i])))
  })

  it("reads the level at most every 80ms (no faster repaint)", () => {
    const { hook, bars, room } = harness()
    hook.mounted()
    room.participant.audioLevel = 0.1
    speak(room)
    const first = transforms(bars)

    room.participant.audioLevel = 0.4
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS - 1)
    expect(transforms(bars)).toEqual(first)
    vi.advanceTimersByTime(1)
    expect(transforms(bars)).not.toEqual(first)
  })

  it("silence returns to idle, drops the inline transforms and leaves no live interval", () => {
    const { hook, el, bars, room } = harness()
    hook.mounted()
    room.participant.audioLevel = 0.5
    speak(room)
    expect(vi.getTimerCount()).toBe(1)

    silence(room)
    expect(el.dataset.waveState).toBe("idle")
    expect(hook._timer).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
    expect(transforms(bars)).toEqual(["", "", "", ""])

    // Nothing polls while silent: a level change paints nothing.
    room.participant.audioLevel = 0.9
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS * 10)
    expect(transforms(bars)).toEqual(["", "", "", ""])
  })

  it("another participant speaking does not activate this glyph", () => {
    const { hook, el, room } = harness()
    hook.mounted()
    room.emit("activeSpeakersChanged", [{ identity: "user:someone-else" }])
    expect(el.dataset.waveState).toBe("idle")
    expect(vi.getTimerCount()).toBe(0)
  })

  it("mounting while the participant is already speaking starts active", () => {
    const room = fakeRoom()
    room.participant.isSpeaking = true
    room.participant.audioLevel = 0.3
    const { hook, el, bars } = harness({ room })
    hook.mounted()
    expect(el.dataset.waveState).toBe("active")
    expect(transforms(bars).every((t) => t.startsWith("scaleY("))).toBe(true)
  })

  it("a hidden tab stops updates, and showing it again resumes them", () => {
    const { hook, bars, room, fireDoc } = harness()
    hook.mounted()
    room.participant.audioLevel = 0.2
    speak(room)
    expect(vi.getTimerCount()).toBe(1)

    document.hidden = true
    fireDoc("visibilitychange")
    expect(vi.getTimerCount()).toBe(0)
    const frozen = transforms(bars)
    room.participant.audioLevel = 0.9
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS * 5)
    expect(transforms(bars)).toEqual(frozen)

    document.hidden = false
    fireDoc("visibilitychange")
    expect(vi.getTimerCount()).toBe(1)
    expect(transforms(bars)).not.toEqual(frozen)
  })

  it("an off-screen glyph stops updates (IntersectionObserver)", () => {
    const { hook, room, observers } = harness()
    hook.mounted()
    room.participant.audioLevel = 0.2
    speak(room)
    expect(vi.getTimerCount()).toBe(1)

    observers[0].cb([{ isIntersecting: false }])
    expect(vi.getTimerCount()).toBe(0)
    observers[0].cb([{ isIntersecting: true }])
    expect(vi.getTimerCount()).toBe(1)
  })

  it("prefers-reduced-motion: the state flips but nothing is painted and no interval runs", () => {
    const { hook, el, bars, room } = harness({ reducedMotion: true })
    hook.mounted()
    room.participant.audioLevel = 0.6
    speak(room)
    expect(el.dataset.waveState).toBe("active")
    expect(vi.getTimerCount()).toBe(0)
    expect(transforms(bars)).toEqual(["", "", "", ""])
  })

  it("destroy releases the room listener, the document listeners, the observer and the interval", () => {
    const { hook, room, observers, docListeners } = harness()
    hook.mounted()
    expect(room.listenerCount("activeSpeakersChanged")).toBe(1)
    speak(room)
    expect(vi.getTimerCount()).toBe(1)

    hook.destroyed()
    expect(room.listenerCount("activeSpeakersChanged")).toBe(0)
    expect(docListeners.get("visibilitychange").size).toBe(0)
    expect(docListeners.get("livekit:room-connected").size).toBe(0)
    expect(observers[0].disconnected).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
  })

  it("binds once a room connects after mount, and follows a replacement room", () => {
    const { hook, el, fireDoc } = harness({ room: null })
    window.__livekit_room = null
    hook.mounted()
    expect(hook._room).toBeNull()

    const first = fakeRoom()
    window.__livekit_room = first
    fireDoc("livekit:room-connected")
    expect(first.listenerCount("activeSpeakersChanged")).toBe(1)

    const second = fakeRoom()
    window.__livekit_room = second
    fireDoc("livekit:room-connected")
    expect(first.listenerCount("activeSpeakersChanged")).toBe(0)
    expect(second.listenerCount("activeSpeakersChanged")).toBe(1)

    second.participant.audioLevel = 0.3
    speak(second)
    expect(el.dataset.waveState).toBe("active")
  })

  it("writes the state on the inner glyph, never on the ignored hook element", () => {
    const { hook, el, root, room } = harness()
    hook.mounted()
    speak(room)
    expect(el.dataset.waveState).toBe("active")
    // LiveView strips unrendered data-* off a phx-update="ignore" element on
    // every patch, so a state written there would not survive the next one.
    expect(root.dataset.waveState).toBeUndefined()
  })

  it("follows an identity change delivered by updated()", () => {
    const { hook, el, root, room } = harness()
    hook.mounted()
    room.participant.identity = "agent:new-identity"
    room.getParticipantByIdentity = (id) => (id === "agent:new-identity" ? room.participant : undefined)
    room.participant.isSpeaking = true
    root.dataset.identity = "agent:new-identity"
    hook.updated()
    expect(el.dataset.waveState).toBe("active")
    room.emit("activeSpeakersChanged", [])
    expect(el.dataset.waveState).toBe("idle")
  })
  // ── Stage 5: level-scaled jitter ─────────────────────────────────────

  it("a constant audioLevel still moves: 3 consecutive ticks give at least 2 different transform sets", () => {
    for (const barCount of [4, 8]) {
      const { hook, bars, room } = harness({ random: seeded(42), barCount })
      hook.mounted()
      room.participant.audioLevel = 0.5
      speak(room)
      const ticks = [transforms(bars).join("|")]
      vi.advanceTimersByTime(UPDATE_INTERVAL_MS)
      ticks.push(transforms(bars).join("|"))
      vi.advanceTimersByTime(UPDATE_INTERVAL_MS)
      ticks.push(transforms(bars).join("|"))
      expect(new Set(ticks).size).toBeGreaterThanOrEqual(2)
      hook.destroyed()
    }
  })

  it("a higher level gives a higher mean scale (same random sequence)", () => {
    const meanAt = (level) => {
      const { hook, bars, room } = harness({ random: seeded(7), barCount: 8 })
      hook.mounted()
      room.participant.audioLevel = level
      speak(room)
      const samples = []
      for (let i = 0; i < 20; i++) {
        samples.push(mean(scales(bars)))
        vi.advanceTimersByTime(UPDATE_INTERVAL_MS)
      }
      hook.destroyed()
      return mean(samples)
    }
    expect(meanAt(0.75)).toBeGreaterThan(meanAt(0.5))
    expect(meanAt(0.5)).toBeGreaterThan(meanAt(0.375))
  })

  it("ordinary speech levels do not saturate the centre bars", () => {
    for (const level of [0.375, 0.5, 0.625, 0.75]) {
      expect(voiceBarBase(level, 3, 8)).toBeLessThan(1)
      expect(voiceBarBase(level, 1, 4)).toBeLessThan(1)
    }
  })

  it("silence after jittering clears the interval and every transform", () => {
    const { hook, bars, room } = harness({ random: seeded(3) })
    hook.mounted()
    room.participant.audioLevel = 0.5
    speak(room)
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS * 3)
    silence(room)
    expect(vi.getTimerCount()).toBe(0)
    expect(transforms(bars)).toEqual(["", "", "", ""])
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS * 5)
    expect(transforms(bars)).toEqual(["", "", "", ""])
  })

  it("reduced motion: no jitter, no painting, across ticks", () => {
    const random = vi.fn(seeded(9))
    const { hook, bars, room } = harness({ reducedMotion: true, random })
    hook.mounted()
    room.participant.audioLevel = 0.5
    speak(room)
    vi.advanceTimersByTime(UPDATE_INTERVAL_MS * 5)
    expect(random).not.toHaveBeenCalled()
    expect(transforms(bars)).toEqual(["", "", "", ""])
  })

  it("the Ask meter's paintBars is unchanged (pinned stage-4 values)", () => {
    const bars = Array.from({ length: 8 }, () => ({ style: { transform: "" } }))
    paintBars(bars, 0.5)
    expect(transforms(bars)).toEqual([
      "scaleY(0.495)",
      "scaleY(0.668)",
      "scaleY(0.841)",
      "scaleY(1.000)",
      "scaleY(1.000)",
      "scaleY(0.841)",
      "scaleY(0.668)",
      "scaleY(0.495)",
    ])
  })
})
