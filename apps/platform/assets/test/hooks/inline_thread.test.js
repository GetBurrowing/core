// InlineThread (redesign rung 9, task 01a1557a-9406): a mousedown on the
// thread's collapse button while a composer field holds focus is prevented,
// so the field does not blur, the dock does not grow back under the finger,
// and the click lands on the button it was aimed at.
//
// Node environment (no jsdom): elements are small stubs whose closest() and
// matches() answer from the selectors they are said to match.

import { describe, it, expect, vi } from "vitest"
import { keepComposerFocus } from "../../js/hooks/inline_thread.js"

const COLLAPSE = '[data-role="thread-collapse"]'
const COMPOSE = '[phx-hook="ComposeInput"]'

function el(selectors = []) {
  const node = {
    matches: (sel) => selectors.includes(sel),
    closest: (sel) => (selectors.includes(sel) ? node : null),
  }
  return node
}

function mousedown(target) {
  return { target, preventDefault: vi.fn() }
}

describe("keepComposerFocus", () => {
  it("prevents the blur when the collapse button is pressed with a composer focused", () => {
    const event = mousedown(el([COLLAPSE]))
    keepComposerFocus(event, { activeElement: el([COMPOSE]) })
    expect(event.preventDefault).toHaveBeenCalledOnce()
  })

  it("leaves a press elsewhere in the thread alone", () => {
    const event = mousedown(el([]))
    keepComposerFocus(event, { activeElement: el([COMPOSE]) })
    expect(event.preventDefault).not.toHaveBeenCalled()
  })

  it("leaves the collapse button alone when no composer is focused", () => {
    const event = mousedown(el([COLLAPSE]))
    keepComposerFocus(event, { activeElement: el([]) })
    expect(event.preventDefault).not.toHaveBeenCalled()
    keepComposerFocus(event, { activeElement: null })
    expect(event.preventDefault).not.toHaveBeenCalled()
  })
})
