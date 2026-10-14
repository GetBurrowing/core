// LongpressMenu: the double-tap that opens the message-actions sheet, and
// the rule that a tap on a FULLSCREEN prototype (promoted to the browser top
// layer, task 01a1389f) never counts, because the sheet would open under the
// top layer where it cannot be reached. Node environment (no jsdom): the
// target is a stub whose closest() answers the one selector the hook asks.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import LongpressMenu from "../../js/hooks/longpress_menu.js"

const FULLSCREEN = '[data-role="prototype-canvas"][data-fullscreen="true"]'

function mount() {
  const el = {
    dataset: { messageId: "m-1" },
    addEventListener: (type, fn) => (el._touchend = fn),
    removeEventListener: () => {},
  }
  const hook = Object.create(LongpressMenu)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  return { el, hook }
}

const target = (insideFullscreen) => ({
  closest: (sel) => (sel === FULLSCREEN && insideFullscreen ? {} : null),
})

const tap = (el, insideFullscreen, x = 100, y = 100) =>
  el._touchend({ target: target(insideFullscreen), changedTouches: [{ clientX: x, clientY: y }] })

describe("LongpressMenu", () => {
  let now
  beforeEach(() => {
    now = 1_000_000
    vi.spyOn(Date, "now").mockImplementation(() => now)
  })
  afterEach(() => vi.restoreAllMocks())

  it("control: an ordinary double-tap opens the message actions", () => {
    const { el, hook } = mount()
    tap(el, false)
    now += 120
    tap(el, false)
    expect(hook.pushEvent).toHaveBeenCalledWith("open_message_actions", { id: "m-1" })
  })

  it("ignores a double-tap inside a fullscreen prototype", () => {
    const { el, hook } = mount()
    tap(el, true)
    now += 120
    tap(el, true)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("a fullscreen tap does not pair with an ordinary tap either way", () => {
    const { el, hook } = mount()
    tap(el, false)
    now += 100
    tap(el, true)
    now += 100
    tap(el, false)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })
})
