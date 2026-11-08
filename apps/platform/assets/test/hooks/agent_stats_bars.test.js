import { describe, it, expect } from "vitest"
import { tipFor } from "../../js/hooks/agent_stats_bars.js"

// A stand-in for the DOM: `closest` walks a given ancestor chain.
function node(title, parentIsBar) {
  return {
    closest(sel) {
      if (sel !== ".ba-bars i") return null
      return parentIsBar ? { getAttribute: (n) => (n === "title" ? title : null) } : null
    },
  }
}

describe("tipFor", () => {
  it("returns the bar's title when the pointer is over a bar", () => {
    expect(tipFor(node("3 shipped · today", true))).toBe("3 shipped · today")
  })

  it("returns null off a bar so the tip is left alone", () => {
    expect(tipFor(node("x", false))).toBeNull()
  })

  it("returns null for a bar with no title", () => {
    expect(tipFor(node(null, true))).toBeNull()
  })

  it("tolerates a non-element target", () => {
    expect(tipFor(null)).toBeNull()
    expect(tipFor({})).toBeNull()
  })
})
