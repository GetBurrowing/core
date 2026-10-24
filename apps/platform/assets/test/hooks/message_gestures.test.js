// MessageGestures (redesign rung 9, task 01a1557a-9406): a tap reveals the
// message pill synchronously, a second tap within 300ms/12px or a 450ms
// press (cancelled past 10px of movement) opens the actions sheet, and a
// tap on a FULLSCREEN prototype (promoted to the browser top layer, task
// 01a1389f) never counts, because the pill and the sheet would open under
// the top layer where they cannot be reached.
//
// Node environment (no jsdom): elements are small stubs, and a target's
// closest() answers from the list of simple selectors it is said to match.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import MessageGestures, { closePill, createLongPress } from "../../js/hooks/message_gestures.js"
import ReactorPopover from "../../js/hooks/reactor_popover.js"

const FULLSCREEN = '[data-role="prototype-canvas"][data-fullscreen="true"]'

let docListeners

function listenerHost() {
  const listeners = {}
  return {
    listeners,
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    fire(type, event) {
      for (const fn of listeners[type] || []) fn(event)
    },
  }
}

function makeScroller() {
  const s = listenerHost()
  s.scrollTop = 0
  return s
}

function mount(id = "m-1", scroller = null) {
  const host = listenerHost()
  const attrs = {}
  const el = Object.assign(host, {
    dataset: { messageId: id },
    setAttribute: (k, v) => (attrs[k] = String(v)),
    removeAttribute: (k) => delete attrs[k],
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    contains: (node) => node === el || (node && node._inside === el),
    closest: (sel) => (sel === "#chat-message-scroller" ? scroller : null),
  })
  const hook = Object.create(MessageGestures)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  return { el, hook }
}

// A target inside `el` that matches the given simple selectors.
const target = (el, matches = []) => ({
  _inside: el,
  closest: (sel) => (sel.split(", ").some((s) => matches.includes(s)) ? {} : null),
})

const pe = (el, opts = {}) => ({
  pointerId: 1,
  pointerType: "touch",
  isPrimary: true,
  clientX: 100,
  clientY: 100,
  target: target(el, opts.matches),
  ...opts,
})

function down(el, opts) {
  el.fire("pointerdown", pe(el, opts))
}
function up(el, opts) {
  el.fire("pointerup", pe(el, opts))
}
function move(el, opts) {
  el.fire("pointermove", pe(el, opts))
}
function tap(el, opts) {
  down(el, opts)
  up(el, opts)
}

const pillOpen = (el) => el.getAttribute("data-pill-open") === "true"

describe("MessageGestures", () => {
  let savedDocument, savedWindow, win
  beforeEach(() => {
    vi.useFakeTimers()
    savedDocument = globalThis.document
    savedWindow = globalThis.window
    const doc = listenerHost()
    docListeners = doc
    globalThis.document = doc
    win = listenerHost()
    globalThis.window = win
  })
  afterEach(() => {
    closePill()
    vi.useRealTimers()
    vi.restoreAllMocks()
    globalThis.document = savedDocument
    globalThis.window = savedWindow
  })

  it("(a) a tap reveals the pill before any timer advances", () => {
    const { el, hook } = mount()
    down(el)
    up(el)
    // No vi.advanceTimersByTime here: the reveal must be synchronous.
    expect(pillOpen(el)).toBe(true)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("(b) a second tap at 299ms opens the actions once, at 301ms it does not", () => {
    const a = mount("m-a")
    tap(a.el)
    vi.advanceTimersByTime(299)
    tap(a.el)
    expect(a.hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(a.hook.pushEvent).toHaveBeenCalledWith("open_message_actions", { id: "m-a" })

    const b = mount("m-b")
    tap(b.el)
    vi.advanceTimersByTime(301)
    tap(b.el)
    expect(b.hook.pushEvent).not.toHaveBeenCalled()
    expect(pillOpen(b.el)).toBe(true)
  })

  it("(b2) a second tap more than 12px away is not a double-tap", () => {
    const { el, hook } = mount()
    tap(el)
    vi.advanceTimersByTime(100)
    tap(el, { clientX: 113 })
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("(c) a 449ms hold pushes nothing, a 450ms hold pushes once", () => {
    const short = mount("m-short")
    down(short.el)
    vi.advanceTimersByTime(449)
    expect(short.hook.pushEvent).not.toHaveBeenCalled()
    up(short.el)
    vi.advanceTimersByTime(1000)
    expect(short.hook.pushEvent).not.toHaveBeenCalled()

    const long = mount("m-long")
    down(long.el)
    vi.advanceTimersByTime(450)
    expect(long.hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(long.hook.pushEvent).toHaveBeenCalledWith("open_message_actions", { id: "m-long" })
    up(long.el)
    vi.advanceTimersByTime(1000)
    expect(long.hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("(d) a hold with an 11px move pushes nothing", () => {
    const { el, hook } = mount()
    down(el)
    move(el, { clientX: 111 })
    vi.advanceTimersByTime(1000)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("(d2) a hold with a 10px move still fires", () => {
    const { el, hook } = mount()
    down(el)
    move(el, { clientX: 110 })
    vi.advanceTimersByTime(450)
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("(d3) pointercancel before 450ms cancels the long-press", () => {
    const { el, hook } = mount()
    down(el)
    el.fire("pointercancel", pe(el))
    vi.advanceTimersByTime(1000)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("(e) a tap on a link, an image or a reaction pill opens no pill", () => {
    for (const matches of [["a"], ["img"], ['[data-role="reaction-pill"]'], [".reaction-pill"], ["[phx-click]"]]) {
      const { el, hook } = mount()
      tap(el, { matches })
      vi.advanceTimersByTime(299)
      tap(el, { matches })
      expect(pillOpen(el)).toBe(false)
      expect(hook.pushEvent).not.toHaveBeenCalled()
    }
  })

  it("(f) opening pill B closes pill A", () => {
    const a = mount("m-a")
    const b = mount("m-b")
    tap(a.el)
    expect(pillOpen(a.el)).toBe(true)
    vi.advanceTimersByTime(500)
    tap(b.el)
    expect(pillOpen(b.el)).toBe(true)
    expect(pillOpen(a.el)).toBe(false)
  })

  it("(g) Esc closes the pill", () => {
    const { el } = mount()
    tap(el)
    docListeners.fire("keydown", { key: "Enter" })
    expect(pillOpen(el)).toBe(true)
    docListeners.fire("keydown", { key: "Escape" })
    expect(pillOpen(el)).toBe(false)
  })

  it("(g) a scroll of the message scroller past 10px closes the pill, 10px does not", () => {
    const scroller = makeScroller()
    scroller.scrollTop = 500
    const { el } = mount("m-1", scroller)
    tap(el)
    scroller.scrollTop = 510
    scroller.fire("scroll", {})
    expect(pillOpen(el)).toBe(true)
    scroller.scrollTop = 489
    scroller.fire("scroll", {})
    expect(pillOpen(el)).toBe(false)
  })

  it("(g) a tap outside the message closes the pill, a tap inside does not", () => {
    const { el } = mount()
    tap(el)
    docListeners.fire("pointerdown", { target: target(el) })
    expect(pillOpen(el)).toBe(true)
    docListeners.fire("pointerdown", { target: { _inside: null } })
    expect(pillOpen(el)).toBe(false)
  })

  // The click is swallowed at the window: by the time the finger lifts the
  // sheet is under it, so the click lands OUTSIDE the message.
  const clickEvent = () => ({ target: {}, preventDefault: vi.fn(), stopPropagation: vi.fn() })

  it("(h) the click after a fired long-press is swallowed, wherever it lands", () => {
    const { el } = mount()
    down(el)
    vi.advanceTimersByTime(450)
    up(el)
    const click = clickEvent()
    win.fire("click", click)
    expect(click.preventDefault).toHaveBeenCalled()
    expect(click.stopPropagation).toHaveBeenCalled()

    // Only that one click.
    const next = clickEvent()
    win.fire("click", next)
    expect(next.stopPropagation).not.toHaveBeenCalled()
  })

  it("(h) with no click after the long-press, the next gesture's click is not swallowed", () => {
    const { el } = mount()
    down(el)
    vi.advanceTimersByTime(450)
    up(el)
    win.fire("pointerdown", {})
    const click = clickEvent()
    win.fire("click", click)
    expect(click.stopPropagation).not.toHaveBeenCalled()
  })

  it("(h2) the click after an ordinary tap is not swallowed", () => {
    const { el } = mount()
    tap(el)
    const click = clickEvent()
    win.fire("click", click)
    el.fire("click", { ...click, target: target(el) })
    expect(click.stopPropagation).not.toHaveBeenCalled()
  })

  it("(i) ignores a double-tap inside a fullscreen prototype", () => {
    const { el, hook } = mount()
    tap(el, { matches: [FULLSCREEN] })
    vi.advanceTimersByTime(120)
    tap(el, { matches: [FULLSCREEN] })
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(pillOpen(el)).toBe(false)
  })

  it("(i) a fullscreen tap does not pair with an ordinary tap either way", () => {
    const { el, hook } = mount()
    tap(el)
    vi.advanceTimersByTime(100)
    tap(el, { matches: [FULLSCREEN] })
    vi.advanceTimersByTime(100)
    tap(el)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  it("a mouse is not a gesture source: a double-click and a held press open nothing", () => {
    const { el, hook } = mount()
    tap(el, { pointerType: "mouse" })
    vi.advanceTimersByTime(100)
    tap(el, { pointerType: "mouse" })
    down(el, { pointerType: "mouse" })
    vi.advanceTimersByTime(1000)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(pillOpen(el)).toBe(false)
  })

  it("contextmenu is prevented after a touch, not after a mouse", () => {
    const { el } = mount()
    down(el)
    const touchMenu = { preventDefault: vi.fn() }
    el.fire("contextmenu", touchMenu)
    expect(touchMenu.preventDefault).toHaveBeenCalled()

    down(el, { pointerType: "mouse" })
    const mouseMenu = { preventDefault: vi.fn() }
    el.fire("contextmenu", mouseMenu)
    expect(mouseMenu.preventDefault).not.toHaveBeenCalled()
  })

  it("Copy copies data-clipboard-text and marks the message copied for 2s", async () => {
    const writeText = vi.fn(() => Promise.resolve())
    vi.stubGlobal("navigator", { clipboard: { writeText } })
    const body = { appendChild: vi.fn() }
    const toastEl = { dataset: {}, style: {}, setAttribute: vi.fn() }
    Object.assign(globalThis.document, {
      body,
      getElementById: () => null,
      createElement: () => toastEl,
    })
    vi.stubGlobal("window", { innerHeight: 800 })

    const { el } = mount()
    const attrs = {}
    const btn = {
      _inside: el,
      dataset: { clipboardText: "hello **world**" },
      setAttribute: (k, v) => (attrs[k] = v),
      removeAttribute: (k) => delete attrs[k],
    }
    btn.closest = (sel) => (sel === '[data-role="message-pill-copy"]' ? btn : null)
    el.fire("click", { target: btn, preventDefault: vi.fn(), stopPropagation: vi.fn() })
    await vi.waitFor(() => expect(el.getAttribute("data-copied")).toBe("true"))

    expect(writeText).toHaveBeenCalledWith("hello **world**")
    expect(el.getAttribute("data-copied")).toBe("true")
    expect(toastEl.textContent).toBe("Copied")
    expect(toastEl.dataset.role).toBe("copy-toast")
    expect(attrs["data-copy-check"]).toBe("true")
    vi.advanceTimersByTime(1500)
    expect(attrs["data-copy-check"]).toBeUndefined()
    expect(el.getAttribute("data-copied")).toBe("true")
    vi.advanceTimersByTime(500)
    expect(el.getAttribute("data-copied")).toBe(null)
    expect(toastEl.hidden).toBe(true)
    vi.unstubAllGlobals()
  })

  // Stage 3: a long-press on a reaction pill (ReactorPopover) lists who
  // reacted. It reuses createLongPress, so it has the message's timing, move
  // cancel and click swallow, and its pointerdown never reaches the
  // message's own gesture handler.
  describe("reaction pill long-press", () => {
    const PILL_MATCHES = ['[data-role="reaction-pill"]', ".reaction-pill", "button", "[phx-click]"]

    function mountPill(message, emoji = "👍") {
      const host = listenerHost()
      const el = Object.assign(host, {
        dataset: { emoji },
        getAttribute: (k) => (k === "phx-value-message-id" ? message.el.dataset.messageId : null),
      })
      const hook = Object.create(ReactorPopover)
      hook.el = el
      hook.pushEvent = vi.fn()
      hook.mounted()
      return { el, hook }
    }

    // Dispatch on the pill, then bubble to the message unless stopped.
    function onPill(pill, message, type, opts = {}) {
      let stopped = false
      const e = {
        ...pe(message.el, { matches: PILL_MATCHES, ...opts }),
        stopPropagation: () => (stopped = true),
      }
      pill.el.fire(type, e)
      if (!stopped) message.el.fire(type, e)
    }

    it("a 450ms press pushes open_reactors once and NOT open_message_actions", () => {
      const message = mount("m-r")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown")
      vi.advanceTimersByTime(449)
      expect(pill.hook.pushEvent).not.toHaveBeenCalled()
      vi.advanceTimersByTime(1)
      expect(pill.hook.pushEvent).toHaveBeenCalledTimes(1)
      expect(pill.hook.pushEvent).toHaveBeenCalledWith("open_reactors", {
        "message-id": "m-r",
        emoji: "👍",
      })
      onPill(pill, message, "pointerup")
      vi.advanceTimersByTime(1000)
      expect(pill.hook.pushEvent).toHaveBeenCalledTimes(1)
      expect(message.hook.pushEvent).not.toHaveBeenCalled()
      expect(pillOpen(message.el)).toBe(false)
    })

    it("the pill's pointerdown never reaches the message's gesture handler", () => {
      const message = mount("m-r")
      const spy = vi.spyOn(message.hook, "pointerDown")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown")
      expect(spy).not.toHaveBeenCalled()
      vi.advanceTimersByTime(450)
      expect(message.hook.pushEvent).not.toHaveBeenCalled()
    })

    it("an 11px move cancels the reactor press; 10px does not", () => {
      const message = mount("m-r")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown")
      onPill(pill, message, "pointermove", { clientX: 111 })
      vi.advanceTimersByTime(1000)
      expect(pill.hook.pushEvent).not.toHaveBeenCalled()

      onPill(pill, message, "pointerdown")
      onPill(pill, message, "pointermove", { clientX: 110 })
      vi.advanceTimersByTime(450)
      expect(pill.hook.pushEvent).toHaveBeenCalledTimes(1)
    })

    it("a tap on the pill opens no message pill and leaves its click alone (it toggles)", () => {
      const message = mount("m-r")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown")
      onPill(pill, message, "pointerup")
      expect(pillOpen(message.el)).toBe(false)
      const click = clickEvent()
      win.fire("click", click)
      expect(click.stopPropagation).not.toHaveBeenCalled()
      vi.advanceTimersByTime(1000)
      expect(pill.hook.pushEvent).not.toHaveBeenCalled()
      expect(message.hook.pushEvent).not.toHaveBeenCalled()
    })

    it("the click after a reactor long-press is swallowed, so it does not toggle", () => {
      const message = mount("m-r")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown")
      vi.advanceTimersByTime(450)
      onPill(pill, message, "pointerup")
      const click = clickEvent()
      win.fire("click", click)
      expect(click.preventDefault).toHaveBeenCalled()
      expect(click.stopPropagation).toHaveBeenCalled()
    })

    it("a mouse press on the pill is not a long-press (desktop keeps the hover popover)", () => {
      const message = mount("m-r")
      const pill = mountPill(message)
      onPill(pill, message, "pointerdown", { pointerType: "mouse" })
      vi.advanceTimersByTime(1000)
      expect(pill.hook.pushEvent).not.toHaveBeenCalled()
    })

    it("createLongPress reports a tap, a fired press and a moved release", () => {
      const fired = vi.fn()
      const lp = createLongPress(fired)
      lp.start({ pointerId: 1, clientX: 0, clientY: 0 })
      expect(lp.end({ pointerId: 1, clientX: 3, clientY: 0 })).toBe("tap")
      lp.start({ pointerId: 1, clientX: 0, clientY: 0 })
      vi.advanceTimersByTime(450)
      expect(fired).toHaveBeenCalledTimes(1)
      expect(lp.end({ pointerId: 1, clientX: 0, clientY: 0 })).toBe("fired")
      win.fire("pointerdown", {})
      lp.start({ pointerId: 1, clientX: 0, clientY: 0 })
      expect(lp.end({ pointerId: 1, clientX: 20, clientY: 0 })).toBe(null)
      expect(lp.end({ pointerId: 1, clientX: 0, clientY: 0 })).toBe(null)
    })
  })

  // Keyboard entry (stage 4; direction canvas 01a1666e node m3 rule 10).
  describe("keyboard on a focused message", () => {
    const key = (el, k, opts = {}) => {
      const e = { key: k, target: el, preventDefault: vi.fn(), ...opts }
      el.fire("keydown", e)
      return e
    }

    it("Shift+F10 pushes open_message_actions once", () => {
      const { el, hook } = mount("m-k")
      const e = key(el, "F10", { shiftKey: true })
      expect(e.preventDefault).toHaveBeenCalled()
      expect(hook.pushEvent).toHaveBeenCalledTimes(1)
      expect(hook.pushEvent).toHaveBeenCalledWith("open_message_actions", { id: "m-k" })
    })

    it("F10 without Shift does nothing", () => {
      const { el, hook } = mount("m-k")
      key(el, "F10")
      expect(hook.pushEvent).not.toHaveBeenCalled()
    })

    it("the ContextMenu key pushes open_message_actions and swallows the native menu once", () => {
      const { el, hook } = mount("m-k")
      key(el, "ContextMenu")
      expect(hook.pushEvent).toHaveBeenCalledWith("open_message_actions", { id: "m-k" })
      const menu = { preventDefault: vi.fn() }
      el.fire("contextmenu", menu)
      expect(menu.preventDefault).toHaveBeenCalledTimes(1)
      // Only the one that follows the key: a later mouse right-click is native.
      el.fire("pointerdown", pe(el, { pointerType: "mouse" }))
      const later = { preventDefault: vi.fn() }
      el.fire("contextmenu", later)
      expect(later.preventDefault).not.toHaveBeenCalled()
    })

    it("Enter reveals the pill and opens no actions", () => {
      const { el, hook } = mount("m-k")
      const e = key(el, "Enter")
      expect(e.preventDefault).toHaveBeenCalled()
      expect(pillOpen(el)).toBe(true)
      expect(hook.pushEvent).not.toHaveBeenCalled()
    })

    it("Esc closes the pill Enter opened", () => {
      const { el } = mount("m-k")
      key(el, "Enter")
      docListeners.fire("keydown", { key: "Escape" })
      expect(pillOpen(el)).toBe(false)
    })

    it("keys on a control inside the message are the control's own", () => {
      const { el, hook } = mount("m-k")
      const inner = target(el, ["button"])
      key(el, "F10", { shiftKey: true, target: inner })
      key(el, "ContextMenu", { target: inner })
      key(el, "Enter", { target: inner })
      expect(hook.pushEvent).not.toHaveBeenCalled()
      expect(pillOpen(el)).toBe(false)
    })
  })
})
