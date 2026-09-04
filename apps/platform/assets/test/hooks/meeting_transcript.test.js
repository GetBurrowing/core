import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingTranscript, { MAX_LINES } from "../../js/hooks/meeting_transcript.js"

/**
 * Tests for the Transcript-tab hook (task 01a05b14 stage 5).
 *
 * The pane is JS-owned because `meeting:caption` is a client-side DOM
 * CustomEvent that never reaches the server, so these assertions are the
 * ONLY coverage of the rendered lines — a LiveView test can see the
 * container and the empty state and nothing past that.
 *
 * Properties under test, each with a matching real defect:
 *   1. lines render in ARRIVAL ORDER (a pane that reorders misattributes
 *      who spoke first)
 *   2. the buffer CAPS at MAX_LINES, keeping the tail (unbounded DOM
 *      growth over a long call)
 *   3. an interim is REPLACED by its final, not duplicated by it — the
 *      exact bug task 019ff712 fixed in the overlay bar, where the final
 *      carried a different id and the naive `id === interim.id` guard
 *      orphaned the interim
 *
 * No jsdom is installed for the assets workspace (see
 * `meeting_captions.test.js`), so the two DOM surfaces the hook touches
 * are stubbed the same way: the host element's `innerHTML` / scroll
 * geometry, and the throwaway `document.createElement("div")` that
 * `_escapeHtml` uses. `document.addEventListener` is stubbed to capture
 * the listener so the tests can drive it directly.
 */

const EMPTY_HTML = '<p data-role="transcript-empty">No captions have been received</p>'

function installDocumentStub() {
  const listeners = {}
  globalThis.document = {
    addEventListener(type, fn) {
      listeners[type] = fn
    },
    removeEventListener(type) {
      delete listeners[type]
    },
    createElement() {
      return {
        _text: "",
        set textContent(v) {
          this._text = String(v)
        },
        get innerHTML() {
          return this._text
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
        },
      }
    },
  }
  return listeners
}

// Host element stub. The scroll geometry defaults to a pane taller than
// its content, i.e. trivially pinned — the tests that care about
// pinning override these three numbers explicitly.
function fakeHostEl() {
  return {
    innerHTML: EMPTY_HTML,
    scrollTop: 0,
    clientHeight: 500,
    scrollHeight: 100,
  }
}

function newHook() {
  const hook = Object.create(MeetingTranscript)
  hook.el = fakeHostEl()
  hook.mounted()
  return hook
}

// The rendered observable: the speaker+text of every `transcript-line`
// node `_render` wrote into the host, in document order.
function renderedLines(hook) {
  const html = hook.el.innerHTML
  const out = []
  const re =
    /<div class="transcript-line[^"]*"[^>]*>\s*<span[^>]*>([\s\S]*?)<\/span>\s*<span[^>]*>([\s\S]*?)<\/span>/g
  let m
  while ((m = re.exec(html)) !== null) out.push(`${m[1]} ${m[2]}`)
  return out
}

const interimCount = (hook) =>
  (hook.el.innerHTML.match(/data-final="false"/g) || []).length

function caption(listeners, { id, speaker = "Ada", text, final = true, identity = null }) {
  listeners["meeting:caption"]({ detail: { id, speaker, text, final, identity } })
}

describe("MeetingTranscript", () => {
  let hook
  let listeners

  beforeEach(() => {
    listeners = installDocumentStub()
    hook = newHook()
  })

  afterEach(() => {
    hook.destroyed()
    delete globalThis.document
  })

  it("shows the server-rendered empty state until a caption arrives", () => {
    // DIRECTION CONTROL: the empty state is present BEFORE any caption, so
    // the assertion after the dispatch is about the caption and not about
    // markup that was never there.
    expect(hook.el.innerHTML).toContain("transcript-empty")

    caption(listeners, { id: "a", speaker: "Rowan", text: "hello" })

    expect(hook.el.innerHTML).not.toContain("transcript-empty")
    expect(renderedLines(hook)).toEqual(["Rowan hello"])
  })

  it("renders finalized lines in arrival order", () => {
    caption(listeners, { id: "a", speaker: "Rowan", text: "first" })
    caption(listeners, { id: "b", speaker: "Saru", text: "second" })
    caption(listeners, { id: "c", speaker: "Rowan", text: "third" })

    expect(renderedLines(hook)).toEqual(["Rowan first", "Saru second", "Rowan third"])
  })

  it("caps the buffer at MAX_LINES, dropping the OLDEST", () => {
    for (let i = 0; i < MAX_LINES + 25; i++) {
      caption(listeners, { id: `seg-${i}`, speaker: "Rowan", text: `line ${i}` })
    }

    const lines = renderedLines(hook)
    expect(lines).toHaveLength(MAX_LINES)
    // The window is the TAIL, not the head.
    expect(lines[0]).toBe("Rowan line 25")
    expect(lines[lines.length - 1]).toBe(`Rowan line ${MAX_LINES + 24}`)
  })

  it("updates an interim line in place rather than appending each revision", () => {
    caption(listeners, { id: "i1", speaker: "Rowan", text: "he", final: false })
    caption(listeners, { id: "i1", speaker: "Rowan", text: "hell", final: false })
    caption(listeners, { id: "i1", speaker: "Rowan", text: "hello th", final: false })

    expect(renderedLines(hook)).toEqual(["Rowan hello th"])
    expect(interimCount(hook)).toBe(1)
  })

  it("replaces an interim with its final even when the final carries a DIFFERENT id", () => {
    caption(listeners, { id: "interim-1", speaker: "Rowan", text: "hello th", final: false })

    // DIRECTION CONTROL: exactly one line, and it IS the interim.
    expect(renderedLines(hook)).toEqual(["Rowan hello th"])
    expect(interimCount(hook)).toBe(1)

    // Transcribers do not reliably reuse the interim id for the final
    // (task 019ff712). A different id must still END the interim.
    caption(listeners, { id: "final-9", speaker: "Rowan", text: "hello there" })

    expect(renderedLines(hook)).toEqual(["Rowan hello there"])
    expect(interimCount(hook)).toBe(0)
  })

  it("does not duplicate a redelivered final", () => {
    caption(listeners, { id: "a", speaker: "Rowan", text: "hello" })
    caption(listeners, { id: "a", speaker: "Rowan", text: "hello there" })

    expect(renderedLines(hook)).toEqual(["Rowan hello there"])
  })

  it("suffixes guest speakers and escapes markup in speaker and text", () => {
    caption(listeners, {
      id: "a",
      speaker: "<b>Mal</b>",
      identity: "guest:abc",
      text: "<img src=x onerror=1>",
    })

    expect(hook.el.innerHTML).toContain("&lt;b&gt;Mal&lt;/b&gt; (guest)")
    expect(hook.el.innerHTML).toContain("&lt;img src=x onerror=1&gt;")
    expect(hook.el.innerHTML).not.toContain("<img src=x")
  })

  it("ignores blank captions", () => {
    caption(listeners, { id: "a", speaker: "Rowan", text: "   " })

    expect(renderedLines(hook)).toEqual([])
    expect(hook.el.innerHTML).toContain("transcript-empty")
  })

  it("auto-scrolls only when the reader is already pinned to the bottom", () => {
    // Pane with real overflow, reader scrolled UP into the scrollback.
    hook.el.clientHeight = 200
    hook.el.scrollHeight = 1000
    hook.el.scrollTop = 100

    caption(listeners, { id: "a", speaker: "Rowan", text: "hello" })

    // Untouched — re-reading is not yanked away by the next utterance.
    expect(hook.el.scrollTop).toBe(100)

    // Now pinned: bottom of the content is within the slack window.
    hook.el.scrollTop = 800
    caption(listeners, { id: "b", speaker: "Rowan", text: "again" })

    expect(hook.el.scrollTop).toBe(1000)
  })

  it("stops listening once destroyed", () => {
    // DIRECTION CONTROL: the registration exists before teardown, so its
    // absence after is teardown's doing and not a listener that was never
    // installed.
    expect(listeners["meeting:caption"]).toBeTypeOf("function")

    hook.destroyed()

    expect(listeners["meeting:caption"]).toBeUndefined()
  })
})
