import { describe, it, expect, vi } from "vitest"
import ViewportBreakpoint from "../../js/hooks/viewport_breakpoint.js"

/**
 * `ViewportBreakpoint` (task 01a07410 stage 3) tells the server which side
 * of one CSS breakpoint the viewport is on, so `/meetings` can render the
 * call rail in exactly one wrapper — the in-flow column or the bottom
 * sheet — instead of both gated by CSS (the sheet is a modal dialog, and a
 * modal dialog present at desktop makes the page behind it inert to a
 * screen reader).
 *
 * The hook runs in vitest's `node` env; `window.matchMedia` is faked with
 * a switchable `matches` and a captured `change` listener.
 */

function fakeMatchMedia(initialMatches) {
  const queries = []

  const matchMedia = vi.fn((query) => {
    const mql = {
      query,
      matches: initialMatches,
      listeners: [],
      addEventListener(name, fn) {
        if (name === "change") this.listeners.push(fn)
      },
      removeEventListener(name, fn) {
        this.listeners = this.listeners.filter((l) => l !== fn)
      },
      cross(matches) {
        this.matches = matches
        for (const fn of this.listeners) fn({ matches })
      },
    }
    queries.push(mql)
    return mql
  })

  return { matchMedia, queries }
}

function mount({ matches, breakpoint, event = "meeting_viewport" } = {}) {
  const { matchMedia, queries } = fakeMatchMedia(matches)
  vi.stubGlobal("window", { matchMedia })

  const hook = Object.create(ViewportBreakpoint)
  hook.el = { dataset: { event, ...(breakpoint ? { breakpoint } : {}) } }
  hook.pushEvent = vi.fn()
  hook.mounted()

  return { hook, mql: queries[0] }
}

describe("ViewportBreakpoint", () => {
  it("reports `below: true` at mount when the min-width query does not match", () => {
    const { hook, mql } = mount({ matches: false })

    expect(mql.query).toBe("(min-width: 1024px)")
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).toHaveBeenCalledWith("meeting_viewport", { below: true })

    hook.destroyed()
  })

  it("reports `below: false` at mount on a desktop viewport", () => {
    const { hook } = mount({ matches: true })

    expect(hook.pushEvent).toHaveBeenCalledWith("meeting_viewport", { below: false })

    hook.destroyed()
  })

  it("reports again on a CROSSING, with the new side, and not on same-side noise", () => {
    const { hook, mql } = mount({ matches: true })
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)

    mql.cross(false)
    expect(hook.pushEvent).toHaveBeenCalledTimes(2)
    expect(hook.pushEvent).toHaveBeenLastCalledWith("meeting_viewport", { below: true })

    mql.cross(true)
    expect(hook.pushEvent).toHaveBeenCalledTimes(3)
    expect(hook.pushEvent).toHaveBeenLastCalledWith("meeting_viewport", { below: false })

    hook.destroyed()
  })

  it("re-reports on reconnect — a remounted LiveView is back at its default", () => {
    const { hook } = mount({ matches: false })
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)

    hook.reconnected()

    expect(hook.pushEvent).toHaveBeenCalledTimes(2)
    expect(hook.pushEvent).toHaveBeenLastCalledWith("meeting_viewport", { below: true })

    hook.destroyed()
  })

  it("honours `data-breakpoint` and `data-event`, and unsubscribes on destroy", () => {
    const { hook, mql } = mount({ matches: false, breakpoint: "768", event: "viewport_md" })

    expect(mql.query).toBe("(min-width: 768px)")
    expect(hook.pushEvent).toHaveBeenCalledWith("viewport_md", { below: true })

    hook.destroyed()
    expect(mql.listeners).toEqual([])

    mql.cross(true)
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
  })
})
