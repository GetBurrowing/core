import { describe, it, expect } from "vitest"
import { copyText, showCopyResult, resetCopyResult } from "../../js/hooks/copy_to_clipboard.js"

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

describe("showCopyResult", () => {
  const button = (dataset = {}) => ({ innerText: "Copy link", dataset: { ...dataset } })

  it("marks copied and uses the button's own label only on success", () => {
    const el = button({ copiedLabel: "Copied" })
    expect(showCopyResult(el, true)).toBe("Copy link")
    expect(el.innerText).toBe("Copied")
    expect(el.dataset.copyState).toBe("copied")
  })

  it("never says copied on failure", () => {
    const el = button({ copiedLabel: "Copied" })
    showCopyResult(el, false)
    expect(el.innerText).toBe("Couldn't copy")
    expect(el.dataset.copyState).toBe("failed")
  })

  it("keeps the old default label and restores the original", () => {
    const el = button()
    const original = showCopyResult(el, true)
    expect(el.innerText).toBe("Copied!")
    resetCopyResult(el, original)
    expect(el.innerText).toBe("Copy link")
    expect(el.dataset.copyState).toBeUndefined()
  })
})
