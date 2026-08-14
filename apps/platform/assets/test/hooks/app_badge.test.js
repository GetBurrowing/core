import { describe, it, expect } from "vitest"
import { stripBadgePrefix, withBadgePrefix } from "../../js/hooks/app_badge.js"

/**
 * Tests for the `AppBadge` hook's title-prefix arithmetic (task 019ffb7b
 * stage 6).
 *
 * Only the two pure string functions are covered — the vitest suite runs in
 * plain node with no DOM, so `MutationObserver` / `navigator.setAppBadge`
 * are out of reach here (the LiveView side of the wiring is covered in
 * `shell_live_test.exs`). These two are where the real hazard lives:
 * `<.live_title>` rewrites `document.title` on every navigation, the hook
 * re-applies its prefix after each rewrite, and a re-application that did
 * not strip first would stack `(3) (3) Chat` forever.
 */
describe("stripBadgePrefix", () => {
  it("leaves an unprefixed title alone", () => {
    expect(stripBadgePrefix("Chat · Suite")).toBe("Chat · Suite")
  })

  it("removes a single prefix", () => {
    expect(stripBadgePrefix("(3) Chat · Suite")).toBe("Chat · Suite")
  })

  it("removes the capped prefix", () => {
    expect(stripBadgePrefix("(99+) Chat · Suite")).toBe("Chat · Suite")
  })

  it("removes stacked prefixes rather than shedding one per pass", () => {
    expect(stripBadgePrefix("(3) (2) Chat")).toBe("Chat")
  })

  it("does not eat parenthesised text that is not a badge", () => {
    expect(stripBadgePrefix("(draft) Chat")).toBe("(draft) Chat")
    expect(stripBadgePrefix("Chat (3)")).toBe("Chat (3)")
  })

  it("tolerates a non-string title", () => {
    expect(stripBadgePrefix(undefined)).toBe("")
  })
})

describe("withBadgePrefix", () => {
  it("prefixes a bare title", () => {
    expect(withBadgePrefix("Chat · Suite", "3")).toBe("(3) Chat · Suite")
  })

  it("is a fixed point on its own output — this is what stops the loop", () => {
    const once = withBadgePrefix("Chat · Suite", "3")
    expect(withBadgePrefix(once, "3")).toBe(once)
  })

  it("replaces a stale count instead of stacking", () => {
    expect(withBadgePrefix("(3) Chat · Suite", "4")).toBe("(4) Chat · Suite")
  })

  it("strips the prefix at zero, when the label is null", () => {
    expect(withBadgePrefix("(3) Chat · Suite", null)).toBe("Chat · Suite")
  })

  it("survives the live_title rewrite it exists for", () => {
    // LiveView writes the bare new page title on navigation; the hook's
    // observer then re-applies. Net effect must be one prefix.
    const afterLiveViewWrite = "Tasks · Suite"
    expect(withBadgePrefix(afterLiveViewWrite, "3")).toBe("(3) Tasks · Suite")
  })
})
