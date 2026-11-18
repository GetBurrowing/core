import { describe, it, expect } from "vitest"
import { formatElapsed } from "../../js/hooks/meeting_bar.js"

// Task 01a1e82a stage 1: the top bar's clock reads m:ss, then h:mm:ss past
// an hour ("12:04", "1:02:09"), as the approved prototype shows it.
describe("formatElapsed", () => {
  it("reads m:ss under an hour", () => {
    expect(formatElapsed(0)).toBe("0:00")
    expect(formatElapsed(7)).toBe("0:07")
    expect(formatElapsed(12 * 60 + 4)).toBe("12:04")
    expect(formatElapsed(59 * 60 + 59)).toBe("59:59")
  })

  it("reads h:mm:ss from an hour on", () => {
    expect(formatElapsed(3600)).toBe("1:00:00")
    expect(formatElapsed(3600 + 2 * 60 + 9)).toBe("1:02:09")
  })

  it("never goes negative and drops fractions", () => {
    expect(formatElapsed(-5)).toBe("0:00")
    expect(formatElapsed(64.9)).toBe("1:04")
  })
})
