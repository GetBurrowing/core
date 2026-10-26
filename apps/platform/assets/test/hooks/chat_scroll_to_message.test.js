import { describe, it, expect, beforeEach, afterEach } from "vitest"
import ChatScrollToMessage from "../../js/hooks/chat_scroll_to_message.js"

/**
 * Tests for the `ChatScrollToMessage` hook's one-frame retry
 * (task 019fabe8 stage 3).
 *
 * The hook used to `return` silently when
 * `[data-message-id="<id>"]` was absent. That is fine for the original
 * caller (a search jump inside an already-rendered window) but wrong
 * for the `?message=` deep link, where the LV pushes the event in the
 * SAME reply that streams the anchored window — the event can be
 * handled a frame before morphdom has patched the row in, and the pulse
 * is lost to the race. One retry on the next animation frame closes it;
 * bounding it at one keeps a genuinely absent target (deleted, evicted)
 * from looping forever.
 *
 * Node env (no jsdom), matching the other hook suites here.
 */

function fakeTarget() {
  return {
    classList: {
      added: [],
      removed: [],
      add(c) {
        this.added.push(c)
      },
      remove(c) {
        this.removed.push(c)
      },
    },
    scrollIntoViewCalls: [],
    scrollIntoView(opts) {
      this.scrollIntoViewCalls.push(opts)
    },
  }
}

describe("ChatScrollToMessage — survives the stream-patch race", () => {
  let priorDocument
  let priorRaf
  let rafQueue
  let registry

  function buildHook() {
    const hook = Object.create(ChatScrollToMessage)
    hook.el = {}
    hook._handlers = {}
    hook.handleEvent = (name, cb) => {
      hook._handlers[name] = cb
    }
    hook.mounted()
    return hook
  }

  function push(hook, id) {
    hook._handlers["chat:scroll-to-message"]({ id })
  }

  function drainFrames() {
    let frames = 0
    while (rafQueue.length > 0) {
      // Guard against a retry loop turning this helper into a hang.
      if (++frames > 10) throw new Error("requestAnimationFrame loop")
      const cb = rafQueue.shift()
      cb()
    }
    return frames
  }

  beforeEach(() => {
    registry = new Map()
    rafQueue = []
    priorDocument = globalThis.document
    globalThis.document = {
      querySelector(sel) {
        const match = /^\[data-message-id="(.+)"\]$/.exec(sel)
        if (!match) return null
        return registry.get(match[1]) || null
      },
    }
    priorRaf = globalThis.requestAnimationFrame
    globalThis.requestAnimationFrame = (cb) => {
      rafQueue.push(cb)
      return rafQueue.length
    }
  })

  afterEach(() => {
    globalThis.document = priorDocument
    globalThis.requestAnimationFrame = priorRaf
  })

  it("BASELINE: scrolls and pulses when the row is already in the DOM", () => {
    const target = fakeTarget()
    registry.set("m-1", target)

    push(buildHook(), "m-1")

    expect(target.scrollIntoViewCalls).toEqual([
      { behavior: "smooth", block: "center" },
    ])
    expect(target.classList.added).toEqual(["chat-message-pulse"])
    // No frame was burned when the row was there the first time.
    expect(rafQueue).toHaveLength(0)
  })

  it("retries on the next frame when the row lands after the event", () => {
    const hook = buildHook()

    // The deep-link case: event handled before the stream patch applied.
    push(hook, "m-2")
    expect(rafQueue).toHaveLength(1)

    const target = fakeTarget()
    registry.set("m-2", target)
    drainFrames()

    expect(target.scrollIntoViewCalls).toEqual([
      { behavior: "smooth", block: "center" },
    ])
    expect(target.classList.added).toEqual(["chat-message-pulse"])
  })

  it("gives up after exactly one retry when the row never arrives", () => {
    const hook = buildHook()

    push(hook, "m-missing")
    const frames = drainFrames()

    // Positive control that the retry ran at all is the frame count;
    // the point of this case is that it did not schedule a second one.
    expect(frames).toBe(1)
    expect(rafQueue).toHaveLength(0)
  })
})

// Task 01a174f5 stage 3: a main-log reply quote's tap pushes
// `chat:message-jump` with `variant: "quote"`, which marks the row with the
// neutral `.chat-message-jump-quote` flash; the Answering panel's jump (no
// variant) keeps `.chat-message-jump`.
describe("ChatScrollToMessage — the quote jump variant", () => {
  let priorDocument
  let registry

  function jumpTarget() {
    return {
      classList: {
        added: [],
        add(c) {
          this.added.push(c)
        },
        remove() {},
      },
      offsetWidth: 0,
      hasAttribute() {
        return true
      },
      focus() {},
    }
  }

  function buildHook() {
    const hook = Object.create(ChatScrollToMessage)
    hook.el = {}
    hook._handlers = {}
    hook.handleEvent = (name, cb) => {
      hook._handlers[name] = cb
    }
    hook.mounted()
    return hook
  }

  beforeEach(() => {
    registry = new Map()
    priorDocument = globalThis.document
    globalThis.document = {
      querySelector(sel) {
        const match = /^\[data-message-id="(.+)"\]$/.exec(sel)
        return match ? registry.get(match[1]) || null : null
      },
    }
  })

  afterEach(() => {
    globalThis.document = priorDocument
  })

  it("variant quote adds the neutral flash class, not the primary jump", () => {
    const target = jumpTarget()
    registry.set("q-1", target)
    const hook = buildHook()
    hook._handlers["chat:message-jump"]({ id: "q-1", variant: "quote" })
    clearTimeout(hook._jumpTimer)
    expect(target.classList.added).toEqual(["chat-message-jump-quote"])
  })

  it("CONTROL: no variant keeps the panel's primary jump class", () => {
    const target = jumpTarget()
    registry.set("q-2", target)
    const hook = buildHook()
    hook._handlers["chat:message-jump"]({ id: "q-2" })
    clearTimeout(hook._jumpTimer)
    expect(target.classList.added).toEqual(["chat-message-jump"])
  })
})
