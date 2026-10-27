import { describe, it, expect } from "vitest"
import { copyText } from "../../js/hooks/copy_to_clipboard.js"

describe("copyText", () => {
  it("is true when the clipboard accepts the text", async () => {
    const seen = []
    expect(await copyText("burrow", { clipboard: { writeText: async (t) => seen.push(t) } })).toBe(true)
    expect(seen).toEqual(["burrow"])
  })

  it("falls back when the clipboard rejects, and reports the fallback's result", async () => {
    const clipboard = { writeText: async () => { throw new Error("NotAllowedError") } }
    expect(await copyText("x", { clipboard, fallback: () => true })).toBe(true)
    expect(await copyText("x", { clipboard, fallback: () => false })).toBe(false)
  })

  it("does not throw with no clipboard at all", async () => {
    expect(await copyText("x", { clipboard: undefined, fallback: () => false })).toBe(false)
  })
})
