import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import RowLongPress, { HOLD_MS } from "../../js/hooks/row_long_press.js"

/**
 * The shared `RowLongPress` hook (rung 6's file, consumed byte-identical) on
 * an Inbox row (task 01a1557a-ad2d stage 3). rung 6's own vitest covers the
 * gesture; this file covers only what the Inbox row adds: its attribute set
 * (`data-long-press-event="open_row_sheet"`, `data-long-press-id`, and the
 * row's other data attributes that must NOT reach the payload), and no edit
 * mode at all (no `data-editing` attribute).
 */

function fakeEl(dataset) {
  const listeners = {}
  const key = (type, capture) => `${type}${capture ? ":capture" : ""}`
  return {
    dataset,
    addEventListener: vi.fn((type, fn, opts) => {
      const capture = opts === true || (opts && opts.capture === true)
      listeners[key(type, capture)] = fn
    }),
    removeEventListener: vi.fn((type, fn, opts) => {
      const capture = opts === true || (opts && opts.capture === true)
      if (listeners[key(type, capture)] === fn) delete listeners[key(type, capture)]
    }),
    fire(type, event = {}, capture = false) {
      const fn = listeners[key(type, capture)]
      if (fn) fn(event)
    },
  }
}

const touch = (x, y) => ({ touches: [{ clientX: x, clientY: y }] })
const click = () => ({ preventDefault: vi.fn(), stopPropagation: vi.fn() })

// The attributes `PlatformWeb.Inbox.InboxList` renders on a row link, as the
// browser's dataset spells them. No `editing`: the Inbox has no edit mode.
const inboxRow = () => ({
  role: "inbox-row",
  itemId: "item-1",
  itemKind: "chat_mention",
  longPressEvent: "open_row_sheet",
  longPressId: "item-1",
})

let doc

function mount(dataset) {
  const el = fakeEl(dataset)
  const pushes = []
  const hook = Object.assign(Object.create(RowLongPress), {
    el,
    pushEvent: (name, payload) => pushes.push([name, payload]),
  })
  hook.mounted()
  return { hook, el, pushes }
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal("navigator", { vibrate: vi.fn() })
  doc = fakeEl({})
  vi.stubGlobal("document", doc)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("RowLongPress on an Inbox row", () => {
  it("a 450ms hold pushes open_row_sheet with only the row id, once", () => {
    const { el, pushes } = mount(inboxRow())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(HOLD_MS)
    vi.advanceTimersByTime(2000)

    expect(pushes).toEqual([["open_row_sheet", { id: "item-1" }]])
  })

  it("the release click is swallowed at the document, so the patch link does not fire", () => {
    const { el } = mount(inboxRow())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(HOLD_MS)
    el.fire("touchend")

    const ev = click()
    doc.fire("click", ev, true)
    expect(ev.preventDefault).toHaveBeenCalledTimes(1)
    expect(ev.stopPropagation).toHaveBeenCalledTimes(1)
  })

  it("a row with no data-editing attribute is never inert", () => {
    const data = inboxRow()
    expect("editing" in data).toBe(false)
    const { el, pushes } = mount(data)
    el.fire("touchstart", touch(0, 0))
    vi.advanceTimersByTime(HOLD_MS)
    expect(pushes.length).toBe(1)
  })

  it("a 449ms hold pushes nothing and its tap still navigates", () => {
    const { el, pushes } = mount(inboxRow())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(HOLD_MS - 1)
    el.fire("touchend")
    vi.advanceTimersByTime(1000)

    const ev = click()
    doc.fire("click", ev, true)
    expect(pushes).toEqual([])
    expect(ev.preventDefault).not.toHaveBeenCalled()
  })

  it("a second hold after the first sheet opens pushes again, for that row", () => {
    const { el, pushes } = mount(inboxRow())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(HOLD_MS)
    el.fire("touchend")
    doc.fire("click", click(), true)

    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(HOLD_MS)
    expect(pushes).toEqual([
      ["open_row_sheet", { id: "item-1" }],
      ["open_row_sheet", { id: "item-1" }],
    ])
  })
})
