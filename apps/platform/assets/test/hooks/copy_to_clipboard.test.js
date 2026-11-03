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
  const button = (dataset = {}) => {
    const classes = new Set()
    return {
      innerText: "Copy link",
      dataset: { ...dataset },
      classList: {
        add: (...c) => c.forEach((x) => classes.add(x)),
        remove: (...c) => c.forEach((x) => classes.delete(x)),
        contains: (c) => classes.has(c),
      },
    }
  }

  it("marks copied and uses the button's own label only on success", () => {
    const el = button({ copiedLabel: "Copied" })
    expect(showCopyResult(el, true)).toBe("Copy link")
    expect(el.innerText).toBe("Copied")
    expect(el.dataset.copyState).toBe("copied")
    expect(el.classList.contains("copy-copied")).toBe(true)
    expect(el.classList.contains("copy-failed")).toBe(false)
  })

  it("never says copied on failure", () => {
    const el = button({ copiedLabel: "Copied" })
    showCopyResult(el, false)
    expect(el.innerText).toBe("Couldn't copy")
    expect(el.dataset.copyState).toBe("failed")
    expect(el.classList.contains("copy-failed")).toBe(true)
    expect(el.classList.contains("copy-copied")).toBe(false)
  })

  it("keeps the old default label and restores the original", () => {
    const el = button()
    const original = showCopyResult(el, true)
    expect(el.innerText).toBe("Copied!")
    resetCopyResult(el, original)
    expect(el.innerText).toBe("Copy link")
    expect(el.dataset.copyState).toBeUndefined()
    expect(el.classList.contains("copy-copied")).toBe(false)
  })

  // Task 01a19ea6: the meeting invite rows name an aria-live region the
  // hook writes the outcome into, so a screen reader hears the swap.
  const docWith = (region) => ({ getElementById: (id) => (id === "status-1" ? region : null) })

  it("announces a copy in the named aria-live region, and clears it on reset", () => {
    const region = { textContent: "" }
    const el = button({ copiedLabel: "Copied", copyStatusTarget: "status-1" })
    const original = showCopyResult(el, true, docWith(region))
    expect(region.textContent).toBe("Link copied")
    resetCopyResult(el, original, docWith(region))
    expect(region.textContent).toBe("")
  })

  it("announces a failure as a failure, never as copied", () => {
    const region = { textContent: "" }
    const el = button({ copiedLabel: "Copied", copyStatusTarget: "status-1" })
    showCopyResult(el, false, docWith(region))
    expect(region.textContent).toBe("Couldn't copy")
  })

  it("writes nowhere when the button names no region", () => {
    const region = { textContent: "untouched" }
    const el = button({ copiedLabel: "Copied" })
    showCopyResult(el, true, docWith(region))
    expect(region.textContent).toBe("untouched")
  })
})
