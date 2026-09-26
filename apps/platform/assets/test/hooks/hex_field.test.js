import { describe, it, expect } from "vitest"
import { hexEquivalent, settledValue } from "../../js/hooks/hex_field.js"

/**
 * The `HexField` hook's decision (task 01a0dbee-f598-7001-b450-7890103f44c4
 * stage 5). The DOM half (blur listener, focus check) is exercised in a real
 * browser; the vitest suite runs in plain node, so what is pinned here is the
 * rule that decides whether the server's normalised value may replace the
 * text in the field.
 */
describe("hexEquivalent", () => {
  it("expands shorthand and lowercases", () => {
    expect(hexEquivalent("#F55")).toBe("#ff5555")
  })

  it("adds the missing #", () => {
    expect(hexEquivalent("ff5555")).toBe("#ff5555")
  })

  it("has no equivalent for an invalid entry", () => {
    expect(hexEquivalent("#12")).toBe(null)
    expect(hexEquivalent("")).toBe(null)
    expect(hexEquivalent(undefined)).toBe(null)
  })
})

describe("settledValue", () => {
  it("applies the server's normalisation of the text in the field", () => {
    expect(settledValue("#f55", "#ff5555")).toBe("#ff5555")
    expect(settledValue("FF5555", "#ff5555")).toBe("#ff5555")
  })

  it("leaves an already-normalised field alone", () => {
    expect(settledValue("#ff5555", "#ff5555")).toBe(null)
  })

  it("never pastes a stale server value over newer typing", () => {
    // Server still holds the previous entry; the admin has typed '#0a0'.
    expect(settledValue("#0a0", "#ff5555")).toBe(null)
  })

  it("keeps an invalid entry as typed", () => {
    expect(settledValue("#12", "#12")).toBe(null)
    expect(settledValue("#12", "#ff5555")).toBe(null)
  })

  it("does nothing without a server value", () => {
    expect(settledValue("#f55", "")).toBe(null)
    expect(settledValue("#f55", undefined)).toBe(null)
  })
})
