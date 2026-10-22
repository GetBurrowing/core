import { describe, it, expect, vi, afterEach } from "vitest"
import SearchFocus from "../../js/hooks/search_focus.js"

/**
 * The `SearchFocus` hook (task 01a1557a-8562 stage 3; renamed from
 * DrawerSearchFocus). Its scroller is named by the input's own
 * `data-blur-on-scroll`, not a hard-coded id, so each surface (drawer,
 * external switcher, Chat list search sheet) drops the keyboard on a swipe of
 * ITS OWN list.
 *
 * vitest runs in plain node here (no DOM), so the element, its scroller and
 * `document` are stubbed per test.
 */

function fakeInput(dataset) {
  return { dataset, focus: vi.fn(), blur: vi.fn() }
}

function fakeList() {
  const listeners = {}
  return {
    listeners,
    addEventListener: vi.fn((type, fn) => {
      listeners[type] = fn
    }),
    removeEventListener: vi.fn((type) => {
      delete listeners[type]
    }),
  }
}

function mount(el, lists = {}) {
  vi.stubGlobal("document", { getElementById: vi.fn((id) => lists[id] || null) })
  const hook = Object.assign(Object.create(SearchFocus), { el })
  hook.mounted()
  return hook
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("SearchFocus", () => {
  it("focuses without scrolling when data-search-intent is true", () => {
    const el = fakeInput({ searchIntent: "true" })
    mount(el)
    expect(el.focus).toHaveBeenCalledWith({ preventScroll: true })
  })

  it("does not focus otherwise", () => {
    const el = fakeInput({ searchIntent: "false" })
    mount(el)
    expect(el.focus).not.toHaveBeenCalled()

    const bare = fakeInput({})
    mount(bare)
    expect(bare.focus).not.toHaveBeenCalled()
  })

  it("blurs on a touchstart on the scroller the input names", () => {
    const list = fakeList()
    const other = fakeList()
    const el = fakeInput({ blurOnScroll: "chat-list-search-results" })
    mount(el, { "chat-list-search-results": list, "another-list": other })

    // Bound to the NAMED scroller, passively, and to nothing else.
    expect(list.addEventListener).toHaveBeenCalledWith("touchstart", expect.any(Function), {
      passive: true,
    })
    expect(other.addEventListener).not.toHaveBeenCalled()

    list.listeners.touchstart()
    expect(el.blur).toHaveBeenCalledTimes(1)
  })

  it("removes the listener on destroy", () => {
    const list = fakeList()
    const el = fakeInput({ blurOnScroll: "external-switcher-list" })
    const hook = mount(el, { "external-switcher-list": list })

    hook.destroyed()
    expect(list.removeEventListener).toHaveBeenCalledWith("touchstart", expect.any(Function))
  })

  it("does nothing, and does not throw, when the named scroller is absent", () => {
    const el = fakeInput({ searchIntent: "true", blurOnScroll: "not-in-the-document" })
    let hook
    expect(() => {
      hook = mount(el)
    }).not.toThrow()
    expect(el.focus).toHaveBeenCalled()
    expect(() => hook.destroyed()).not.toThrow()
  })
})
