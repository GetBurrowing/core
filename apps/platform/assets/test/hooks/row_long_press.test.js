import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import RowLongPress, {
  HOLD_MS,
  MOVE_CANCEL_PX,
  SWALLOW_MS,
  RELEASE_GRACE_MS,
  longPressPayload,
} from "../../js/hooks/row_long_press.js"

/**
 * The generic `RowLongPress` hook (task 01a1557a-8562 stage 4), first used by
 * the Chat list and next by the Inbox list. vitest runs in plain node here
 * (no DOM), so the element is a minimal event target built per test. Fake
 * timers drive the 450ms hold and the 1200ms swallow window.
 */

function fakeRow(dataset) {
  const listeners = {}
  const key = (type, capture) => `${type}${capture ? ":capture" : ""}`
  return {
    dataset,
    listeners,
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

function clickEvent() {
  return { preventDefault: vi.fn(), stopPropagation: vi.fn() }
}

// The swallow listens on the document (the click after a hold often lands on
// whatever the hold opened), so the document is a fake event target too.
let doc

function mount(dataset) {
  const el = fakeRow(dataset)
  const pushes = []
  const hook = Object.assign(Object.create(RowLongPress), {
    el,
    pushEvent: (name, payload) => pushes.push([name, payload]),
  })
  hook.mounted()
  return { hook, el, pushes }
}

const rowData = () => ({
  longPressEvent: "open_list_sheet",
  longPressSheet: "row",
  longPressSpaceId: "space-1",
  editing: "false",
})

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal("navigator", { vibrate: vi.fn() })
  doc = fakeRow({})
  vi.stubGlobal("document", doc)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("RowLongPress", () => {
  it("uses the shared gesture constants", () => {
    expect(HOLD_MS).toBe(450)
    expect(MOVE_CANCEL_PX).toBe(10)
    expect(SWALLOW_MS).toBe(1200)
    expect(RELEASE_GRACE_MS).toBe(250)
  })

  it("builds the payload from data-long-press-* attributes, without the event", () => {
    expect(longPressPayload(rowData())).toEqual({ sheet: "row", space_id: "space-1" })
  })

  it("a 450ms hold pushes once, buzzes, and the following click is prevented", () => {
    const { el, pushes } = mount(rowData())

    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)

    expect(pushes).toEqual([["open_list_sheet", { sheet: "row", space_id: "space-1" }]])
    expect(navigator.vibrate).toHaveBeenCalledWith(20)

    el.fire("touchend")
    const click = clickEvent()
    doc.fire("click", click, true)
    expect(click.preventDefault).toHaveBeenCalled()
    expect(click.stopPropagation).toHaveBeenCalled()

    // One click only: the next one goes through.
    const next = clickEvent()
    doc.fire("click", next, true)
    expect(next.preventDefault).not.toHaveBeenCalled()
  })

  it("a 449ms hold pushes nothing", () => {
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(449)
    el.fire("touchend")
    vi.advanceTimersByTime(1000)
    expect(pushes).toEqual([])
  })

  it("a 12px move then a hold pushes nothing (it is a scroll)", () => {
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    el.fire("touchmove", touch(10, 22))
    vi.advanceTimersByTime(600)
    expect(pushes).toEqual([])
  })

  it("a move inside 10px does not cancel", () => {
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    el.fire("touchmove", touch(16, 16))
    vi.advanceTimersByTime(450)
    expect(pushes.length).toBe(1)
  })

  it("a short tap's click is NOT prevented", () => {
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(120)
    el.fire("touchend")
    const click = clickEvent()
    doc.fire("click", click, true)
    expect(pushes).toEqual([])
    expect(click.preventDefault).not.toHaveBeenCalled()
  })

  it("a click 1300ms after the hold is not prevented", () => {
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)
    el.fire("touchend")
    expect(pushes.length).toBe(1)

    vi.advanceTimersByTime(1300)
    const click = clickEvent()
    doc.fire("click", click, true)
    expect(click.preventDefault).not.toHaveBeenCalled()
  })

  it("is inert while data-editing is true", () => {
    const { el, pushes } = mount({ ...rowData(), editing: "true" })
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(600)
    expect(pushes).toEqual([])
  })

  it("a mouse press drives the same gesture; touch pointers are left to the touch listeners", () => {
    const { el, pushes } = mount(rowData())
    el.fire("pointerdown", { pointerType: "touch", button: 0, clientX: 1, clientY: 1 })
    vi.advanceTimersByTime(600)
    expect(pushes).toEqual([])

    el.fire("pointerdown", { pointerType: "mouse", button: 0, clientX: 1, clientY: 1 })
    vi.advanceTimersByTime(450)
    expect(pushes.length).toBe(1)
  })

  it("prevents the context menu", () => {
    const { el } = mount(rowData())
    const e = { preventDefault: vi.fn() }
    el.fire("contextmenu", e)
    expect(e.preventDefault).toHaveBeenCalled()
  })

  it("destroyed() removes every listener and cancels a pending hold", () => {
    const { hook, el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    hook.destroyed()
    vi.advanceTimersByTime(600)
    expect(pushes).toEqual([])
    expect(Object.keys(el.listeners)).toEqual([])
    expect(Object.keys(doc.listeners)).toEqual([])
  })

  it("destroyed() during the swallow window drops the document listener", () => {
    const { hook, el } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)
    expect(Object.keys(doc.listeners)).toEqual(["click:capture"])
    hook.destroyed()
    expect(Object.keys(doc.listeners)).toEqual([])
  })

  it("the swallow catches the release click wherever it lands, not only on the row", () => {
    // The hold opens a sheet under the finger; the click goes to the sheet's
    // backdrop, which is outside the row. It must still be swallowed.
    const { el } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)
    el.fire("touchend")
    const onBackdrop = clickEvent()
    doc.fire("click", onBackdrop, true)
    expect(onBackdrop.stopPropagation).toHaveBeenCalled()
  })

  it("a release with NO click does not leave the next real tap swallowed", () => {
    // The finger slid off, or the browser suppressed the release click: the
    // swallow must not stay armed and eat the user's next tap.
    const { el } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)
    el.fire("touchend")
    // The reviewer's measurement: the next real tap 300ms after the release.
    vi.advanceTimersByTime(300)
    const nextTap = clickEvent()
    doc.fire("click", nextTap, true)
    expect(nextTap.preventDefault).not.toHaveBeenCalled()
    expect(Object.keys(doc.listeners)).toEqual([])
  })

  it("a release click inside the grace after touchend is still swallowed", () => {
    const { el } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    vi.advanceTimersByTime(450)
    el.fire("touchend")
    vi.advanceTimersByTime(RELEASE_GRACE_MS - 1)
    const release = clickEvent()
    doc.fire("click", release, true)
    expect(release.preventDefault).toHaveBeenCalled()
  })

  it("a mouse release (pointerup) with no click clears the swallow after the grace too", () => {
    const { el } = mount(rowData())
    el.fire("pointerdown", { pointerType: "mouse", button: 0, clientX: 5, clientY: 5 })
    vi.advanceTimersByTime(450)
    el.fire("pointerup", { pointerType: "mouse" })
    vi.advanceTimersByTime(RELEASE_GRACE_MS)
    const nextTap = clickEvent()
    doc.fire("click", nextTap, true)
    expect(nextTap.preventDefault).not.toHaveBeenCalled()
  })

  it("leaving the row while still holding does not start the grace", () => {
    // pointerleave is not a release: the click that follows the eventual
    // release must still be swallowed.
    const { el } = mount(rowData())
    el.fire("pointerdown", { pointerType: "mouse", button: 0, clientX: 5, clientY: 5 })
    vi.advanceTimersByTime(450)
    el.fire("pointerleave", { pointerType: "mouse" })
    vi.advanceTimersByTime(RELEASE_GRACE_MS + 100)
    const release = clickEvent()
    doc.fire("click", release, true)
    expect(release.preventDefault).toHaveBeenCalled()
  })

  it("works without a vibrate function", () => {
    vi.stubGlobal("navigator", {})
    const { el, pushes } = mount(rowData())
    el.fire("touchstart", touch(10, 10))
    expect(() => vi.advanceTimersByTime(450)).not.toThrow()
    expect(pushes.length).toBe(1)
  })
})
