import { describe, it, expect } from "vitest"
import { formatDuration, frameStyle } from "../../js/hooks/chat_clip.js"

// Task 01a1655c stage 4: the pure parts of the ChatClip hook. The suite runs
// in node with no DOM, so the event wiring is covered by the LiveView markup
// tests (chat_message_video_test.exs) and the stage screenshots.
describe("formatDuration", () => {
  it("formats m:ss", () => {
    expect(formatDuration(42)).toBe("0:42")
    expect(formatDuration(61.4)).toBe("1:01")
    expect(formatDuration(600)).toBe("10:00")
  })

  it("returns null for unknown durations", () => {
    expect(formatDuration(NaN)).toBe(null)
    expect(formatDuration(Infinity)).toBe(null)
    expect(formatDuration(undefined)).toBe(null)
  })
})

describe("frameStyle", () => {
  it("keeps a vertical clip's own ratio and caps its width under 60vh", () => {
    expect(frameStyle(1080, 1920)).toEqual({
      aspectRatio: "1080 / 1920",
      maxWidth: "min(100%, calc(60vh * 1080 / 1920))",
    })
  })

  it("returns null before the browser knows the size", () => {
    expect(frameStyle(0, 0)).toBe(null)
  })
})
