import { describe, it, expect } from "vitest"
import {
  BIG_STEP_S,
  STEP_S,
  clamp,
  frameTimes,
  framePayload,
  keyStep,
  stepFor,
  timeAt,
  timecode,
  toMs,
} from "../js/hooks/cover_picker.js"

/**
 * The cover picker's pure parts (task 01a165ec stage 4): what the hook
 * pushes, how a key moves the playhead, and the slider's timecode.
 */

describe("milliseconds", () => {
  it("rounds a currentTime to whole ms", () => {
    expect(toMs(7.4)).toBe(7400)
    expect(toMs(7.4004)).toBe(7400)
    expect(toMs(7.4006)).toBe(7401)
    expect(toMs(0)).toBe(0)
  })

  it("pushes integer ms and the browser's duration in ms, never seconds", () => {
    const payload = framePayload("p1", 7.4, 42.5)
    expect(payload).toEqual({ post_id: "p1", offset_ms: 7400, duration_ms: 42500 })
    expect(Number.isInteger(payload.offset_ms)).toBe(true)
  })

  it("omits an unknown duration", () => {
    expect(framePayload("p1", 1.25, NaN)).toEqual({ post_id: "p1", offset_ms: 1250 })
  })

  it("clamps the pushed time into the video", () => {
    expect(framePayload("p1", 99, 42.5).offset_ms).toBe(42500)
    expect(framePayload("p1", -3, 42.5).offset_ms).toBe(0)
  })
})

describe("keyboard steps", () => {
  it("is 0.1 s, and 1 s with Shift", () => {
    expect(STEP_S).toBe(0.1)
    expect(BIG_STEP_S).toBe(1)
    expect(stepFor(false)).toBe(0.1)
    expect(stepFor(true)).toBe(1)
  })

  it("moves right and left by the step without drift", () => {
    let t = 0
    for (let i = 0; i < 74; i++) t = keyStep(t, "ArrowRight", false, 42)
    expect(t).toBe(7.4)
    expect(keyStep(7.4, "ArrowLeft", false, 42)).toBe(7.3)
    expect(keyStep(7.4, "ArrowRight", true, 42)).toBe(8.4)
    expect(keyStep(7.4, "ArrowLeft", true, 42)).toBe(6.4)
  })

  it("ignores other keys", () => {
    expect(keyStep(1, "a", false, 42)).toBeNull()
    expect(keyStep(1, "Enter", false, 42)).toBeNull()
  })
})

describe("clamping to [0, duration]", () => {
  it("clamps at both ends", () => {
    expect(clamp(-1, 42)).toBe(0)
    expect(clamp(50, 42)).toBe(42)
    expect(clamp(7, 42)).toBe(7)
    expect(keyStep(0.05, "ArrowLeft", false, 42)).toBe(0)
    expect(keyStep(41.5, "ArrowRight", true, 42)).toBe(42)
  })

  it("only floors when the duration is unknown", () => {
    expect(clamp(50, NaN)).toBe(50)
    expect(clamp(-2, NaN)).toBe(0)
  })

  it("maps a pointer to a time inside the strip", () => {
    const rect = { left: 100, width: 200 }
    expect(timeAt(100, rect, 40)).toBe(0)
    expect(timeAt(200, rect, 40)).toBe(20)
    expect(timeAt(500, rect, 40)).toBe(40)
    expect(timeAt(0, rect, 40)).toBe(0)
  })
})

describe("aria-valuetext timecode", () => {
  it("reads m:ss.cc / m:ss", () => {
    expect(timecode(7.4, 42)).toBe("0:07.40 / 0:42")
    expect(timecode(0, 42.9)).toBe("0:00.00 / 0:42")
    expect(timecode(75.05, 125)).toBe("1:15.05 / 2:05")
  })

  it("omits the length when it is unknown", () => {
    expect(timecode(7.4, NaN)).toBe("0:07.40")
  })
})

describe("filmstrip frames", () => {
  it("are evenly spaced inside the video", () => {
    expect(frameTimes(40, 4)).toEqual([5, 15, 25, 35])
    expect(frameTimes(NaN, 4)).toEqual([])
  })
})
