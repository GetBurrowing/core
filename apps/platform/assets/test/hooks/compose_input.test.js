import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ComposeInput, { shouldResetViewportAfterBlur } from "../../js/hooks/compose_input.js"

/**
 * Tests for the `ComposeInput` hook's post-blur viewport reset (task
 * 01a1557a stage 2).
 *
 * The hook resets the page scroll 100ms after the textarea blurs, so the
 * viewport recovers when the iOS keyboard closes. Picking an @mention
 * suggestion also blurs the textarea, and `chat:insert-mention` refocuses it
 * synchronously; before this fix the queued reset still fired and jumped the
 * conversation to the top mid-compose. The reset must now run only when
 * focus has really left the composer.
 *
 * vitest runs in plain node here (no jsdom), so the second block stubs
 * `window`, `document` and `CSS` and drives the real listeners registered by
 * `mounted()` through a fake element.
 */
describe("shouldResetViewportAfterBlur", () => {
  const el = { id: "composer" }

  it("skips the reset when focus is back on the composer", () => {
    expect(shouldResetViewportAfterBlur(el, el)).toBe(false)
  })

  it("resets when focus moved to another element", () => {
    expect(shouldResetViewportAfterBlur({ id: "other" }, el)).toBe(true)
  })

  it("resets when nothing is focused (null or body)", () => {
    expect(shouldResetViewportAfterBlur(null, el)).toBe(true)
    expect(shouldResetViewportAfterBlur({ tagName: "BODY" }, el)).toBe(true)
  })
})

function fakeTextarea(doc) {
  const listeners = {}
  const el = {
    value: "hi @al",
    defaultValue: "",
    selectionStart: 6,
    dataset: {},
    style: {},
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    fire(type, event = {}) {
      for (const fn of listeners[type] || []) fn(event)
    },
    focus() {
      doc.activeElement = el
    },
    blur() {
      doc.activeElement = { tagName: "BODY" }
      el.fire("blur")
    },
    setSelectionRange(a) {
      el.selectionStart = a
    },
    closest() {
      return null
    },
  }
  return el
}

describe("ComposeInput blur listener", () => {
  let doc
  let scrollTo
  let hook

  beforeEach(() => {
    vi.useFakeTimers()
    doc = { activeElement: null }
    scrollTo = vi.fn()
    vi.stubGlobal("document", doc)
    vi.stubGlobal("window", {
      scrollTo,
      matchMedia: () => ({ matches: true }),
    })
    vi.stubGlobal("CSS", { supports: () => true })

    const el = fakeTextarea(doc)
    hook = Object.create(ComposeInput)
    hook.el = el
    hook.pushEvent = vi.fn()
    hook.mounted()
    el.focus()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it("does not scroll to the top when an @mention pick refocuses the composer", () => {
    hook.el.blur()
    hook.el.fire("chat:insert-mention", { detail: { name: "Alice" } })
    vi.advanceTimersByTime(200)

    expect(hook.el.value).toBe("hi @[Alice] ")
    expect(doc.activeElement).toBe(hook.el)
    expect(scrollTo).not.toHaveBeenCalled()
  })

  it("still resets the viewport when focus really leaves (keyboard dismissed)", () => {
    hook.el.blur()
    vi.advanceTimersByTime(200)

    expect(scrollTo).toHaveBeenCalledTimes(1)
    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "instant" })
  })
})
