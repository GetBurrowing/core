// MessageActionsCopy (redesign rung 9 stage 2, task 01a1557a-9406): the
// actions sheet's 'Copy text' and 'Copy link' rows copy their
// `data-clipboard-text`, show their own toast ('Copied' / 'Link copied'),
// and mark the message the sheet was opened for `data-copied="true"` for 2s.
//
// Node environment (no jsdom): elements are small stubs.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import MessageActionsCopy from "../../js/hooks/message_actions_copy.js"
import { place } from "../../js/hooks/message_actions_popover.js"

function element(attrs = {}) {
  const listeners = {}
  return {
    attrs,
    listeners,
    addEventListener: (t, fn) => ((listeners[t] ||= []).push(fn)),
    removeEventListener: (t, fn) => (listeners[t] = (listeners[t] || []).filter((f) => f !== fn)),
    setAttribute: (k, v) => (attrs[k] = String(v)),
    removeAttribute: (k) => delete attrs[k],
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
  }
}

describe("MessageActionsCopy", () => {
  let toastEl, message, writeText, selectors
  beforeEach(() => {
    vi.useFakeTimers()
    writeText = vi.fn(() => Promise.resolve())
    toastEl = { dataset: {}, style: {}, setAttribute: vi.fn() }
    message = element()
    selectors = []
    vi.stubGlobal("navigator", { clipboard: { writeText } })
    vi.stubGlobal("window", { innerHeight: 800 })
    vi.stubGlobal("document", {
      body: { appendChild: vi.fn() },
      getElementById: () => null,
      createElement: () => toastEl,
      querySelector: (sel) => (selectors.push(sel), message),
    })
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  function mount() {
    const el = element()
    el.dataset = { actionsMessageId: "m-1" }
    el.contains = (node) => node && node._inside === el
    const hook = Object.create(MessageActionsCopy)
    hook.el = el
    hook.mounted()
    return el
  }

  const row = (el, dataset) => {
    const r = { _inside: el, dataset }
    r.closest = (sel) => (sel === "[data-copy-toast]" ? r : null)
    return r
  }

  for (const [label, text, toast] of [
    ["Copy text", "The build is green.", "Copied"],
    ["Copy link", "http://localhost:4000/chat/general?message=m-1", "Link copied"],
  ]) {
    it(`${label} copies its text, toasts '${toast}' and marks the message for 2s`, async () => {
      const el = mount()
      const target = row(el, { clipboardText: text, copyToast: toast })
      for (const fn of el.listeners.click) fn({ target })

      await vi.waitFor(() => expect(message.getAttribute("data-copied")).toBe("true"))
      expect(writeText).toHaveBeenCalledWith(text)
      expect(toastEl.textContent).toBe(toast)
      expect(toastEl.dataset.role).toBe("copy-toast")
      expect(selectors).toEqual(['[data-message-id="m-1"][phx-hook="MessageGestures"]'])
      vi.advanceTimersByTime(2000)
      expect(message.getAttribute("data-copied")).toBe(null)
    })
  }

  it("a click on a row without data-copy-toast copies nothing", async () => {
    const el = mount()
    const target = { _inside: el, dataset: {}, closest: () => null }
    for (const fn of el.listeners.click) fn({ target })
    await Promise.resolve()
    expect(writeText).not.toHaveBeenCalled()
  })
})

describe("MessageActionsPopover place()", () => {
  const viewport = { width: 1280, height: 800 }
  const size = { width: 320, height: 400 }

  it("sits under the anchor, right-aligned to it", () => {
    const { left, top } = place({ top: 100, bottom: 130, right: 900 }, size, viewport)
    expect(left).toBe(580)
    expect(top).toBe(136)
  })

  it("flips above the anchor when it would run off the bottom", () => {
    const { top } = place({ top: 700, bottom: 730, right: 900 }, size, viewport)
    expect(top).toBe(294)
  })

  it("never leaves the viewport on the left", () => {
    const { left } = place({ top: 100, bottom: 130, right: 100 }, size, viewport)
    expect(left).toBe(8)
  })
})
