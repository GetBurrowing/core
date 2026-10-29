import { describe, it, expect, vi } from "vitest"
import ClipReview, { clipsUrl, keyAction, scrubPercent, secondsLeft, typingTarget } from "../js/hooks/clip_review.js"

/**
 * The Review bay hook's pure parts (Clip Studio 3/9, task 01a16662-8c00
 * stage 4): which keys navigate, where they are inert, the toast counter,
 * the scrubber and the URL sync. No key decides a clip.
 */

const body = { tagName: "BODY", isContentEditable: false }
const el = (tagName, isContentEditable = false) => ({ tagName, isContentEditable })

describe("keyAction", () => {
  it("J, K and Space map to next, prev and toggle", () => {
    expect(keyAction("j", body)).toBe("next")
    expect(keyAction("J", body)).toBe("next")
    expect(keyAction("k", body)).toBe("prev")
    expect(keyAction("K", body)).toBe("prev")
    expect(keyAction(" ", body)).toBe("toggle")
  })

  it("inactive in input, textarea, select and contenteditable", () => {
    for (const t of [el("INPUT"), el("TEXTAREA"), el("SELECT"), el("DIV", true)]) {
      expect(typingTarget(t)).toBe(true)
      for (const key of ["j", "J", "k", "K", " "]) expect(keyAction(key, t)).toBeNull()
    }
    expect(typingTarget(el("DIV"))).toBe(false)
    expect(typingTarget(el("BUTTON"))).toBe(false)
  })

  it("inactive with meta, ctrl or alt held", () => {
    for (const mods of [{ metaKey: true }, { ctrlKey: true }, { altKey: true }]) {
      for (const key of ["j", "k", " "]) expect(keyAction(key, body, mods)).toBeNull()
    }
    expect(keyAction("j", body, { shiftKey: true })).toBe("next")
  })

  it("no key decides", () => {
    const keys = ["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowLeft", "ArrowRight"]
    for (let c = 32; c <= 126; c++) keys.push(String.fromCharCode(c))
    const allowed = new Set([null, "next", "prev", "toggle"])

    for (const key of keys) {
      for (const mods of [{}, { shiftKey: true }, { metaKey: true }, { ctrlKey: true }, { altKey: true }]) {
        expect(allowed.has(keyAction(key, body, mods)), `key ${JSON.stringify(key)}`).toBe(true)
      }
    }
    expect(keyAction("Enter", body)).toBeNull()
    expect(keyAction("a", body)).toBeNull()
    expect(keyAction("r", body)).toBeNull()
  })
})

describe("secondsLeft", () => {
  it("rounds up to whole seconds", () => {
    expect(secondsLeft(8000, 0)).toBe(8)
    expect(secondsLeft(7001, 0)).toBe(8)
    expect(secondsLeft(7000, 0)).toBe(7)
    expect(secondsLeft(1, 0)).toBe(1)
  })

  it("never goes below 0", () => {
    expect(secondsLeft(1000, 1000)).toBe(0)
    expect(secondsLeft(1000, 5000)).toBe(0)
    expect(secondsLeft(NaN, 0)).toBe(0)
  })
})

describe("scrubPercent", () => {
  it("is the share of the duration played", () => {
    expect(scrubPercent(0, 42)).toBe(0)
    expect(scrubPercent(21, 42)).toBe(50)
    expect(scrubPercent(42, 42)).toBe(100)
  })

  it("is 0 without a positive finite duration and clamps to 0..100", () => {
    expect(scrubPercent(5, NaN)).toBe(0)
    expect(scrubPercent(5, Infinity)).toBe(0)
    expect(scrubPercent(5, 0)).toBe(0)
    expect(scrubPercent(5, -3)).toBe(0)
    expect(scrubPercent(5, undefined)).toBe(0)
    expect(scrubPercent(50, 42)).toBe(100)
    expect(scrubPercent(-1, 42)).toBe(0)
    expect(scrubPercent(NaN, 42)).toBe(0)
  })
})

describe("clipsUrl", () => {
  it("keeps other params and sets tab, view and clip", () => {
    const url = clipsUrl("?profile=p1&tab=posts&foo=bar", { view: "review", clip: "c1" })
    const p = new URLSearchParams(url)
    expect(url.startsWith("?")).toBe(true)
    expect(p.get("profile")).toBe("p1")
    expect(p.get("foo")).toBe("bar")
    expect(p.get("tab")).toBe("clips")
    expect(p.get("view")).toBe("review")
    expect(p.get("clip")).toBe("c1")
  })

  it("drops the clip when there is none", () => {
    const p = new URLSearchParams(clipsUrl("?tab=clips&view=review&clip=c1&x=1", { view: "library", clip: null }))
    expect(p.get("clip")).toBeNull()
    expect(p.get("view")).toBe("library")
    expect(p.get("x")).toBe("1")
  })

  it("works from an empty query", () => {
    expect(clipsUrl("", { view: "review", clip: "c2" })).toBe("?tab=clips&view=review&clip=c2")
  })
})


describe("removal dialog keyboard isolation", () => {
  it("does not navigate or toggle the clip behind a confirmation", () => {
    const push = vi.fn()
    const toggle = vi.fn()
    const preventDefault = vi.fn()
    const hook = { active: () => true, el: { querySelector: () => ({}) }, pushEventTo: push, toggle }
    for (const key of ["j", "k", " "]) ClipReview.key.call(hook, {key, target: body, preventDefault})
    expect(push).not.toHaveBeenCalled()
    expect(toggle).not.toHaveBeenCalled()
    expect(preventDefault).not.toHaveBeenCalled()
    hook.el.querySelector = () => null
    ClipReview.key.call(hook, {key: "j", target: body, preventDefault})
    expect(push).toHaveBeenCalledWith(hook.el, "next", {})
  })
})
