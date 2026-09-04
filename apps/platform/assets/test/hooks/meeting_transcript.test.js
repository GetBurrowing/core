import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingTranscript, { MAX_LINES, PIN_SLACK_PX } from "../../js/hooks/meeting_transcript.js"

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
 * Task 01a06524 stage 1 added, with the same shape of defect behind each:
 *   4. consecutive same-speaker lines share ONE header (a per-row name
 *      column wraps a 290px pane to three words a line)
 *   5. FOLLOW-LIVE: the reader's own scroll decides whether new lines pull
 *      the view down, a scrolled-up reader is never yanked, and a pill
 *      naming the speaker offers the way back
 *   6. the pane SAYS when the cap has dropped the top of the record
 *   7. interim text is muted, not italic, and finals are full strength
 *
 * No jsdom is installed for the assets workspace (see
 * `meeting_captions.test.js`), so the two DOM surfaces the hook touches
 * are stubbed the same way: the host element's `innerHTML` / scroll
 * geometry / listeners, and the throwaway `document.createElement("div")`
 * that `_escapeHtml` uses. `document.addEventListener` is stubbed to
 * capture the listener so the tests can drive it directly, and the host
 * stub captures its own `scroll` / `click` listeners the same way — the
 * follow-live flag is set ONLY by the scroll listener, so a test that
 * moves `scrollTop` must also fire `scroll`, exactly as a browser would.
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
// its content, i.e. trivially at the live edge — the tests that care
// about pinning override these three numbers explicitly and then fire
// `scroll` through `el.listeners`.
function fakeHostEl() {
  const el = {
    innerHTML: EMPTY_HTML,
    scrollTop: 0,
    clientHeight: 500,
    scrollHeight: 100,
    listeners: {},
    addEventListener(type, fn) {
      this.listeners[type] = fn
    },
    removeEventListener(type) {
      delete this.listeners[type]
    },
  }
  return el
}

// Simulate the reader dragging the scrollbar: set the geometry, then fire
// the event the browser would fire.
function scrollTo(hook, scrollTop) {
  hook.el.scrollTop = scrollTop
  hook.el.listeners.scroll()
}

// Simulate a click on the jump-to-live pill: the delegated handler on the
// host receives an event whose target resolves `closest()` to the pill.
function clickPill(hook) {
  hook.el.listeners.click({
    target: { closest: (sel) => (sel.includes("transcript-jump-live") ? {} : null) },
    preventDefault() {},
  })
}

function newHook() {
  const hook = Object.create(MeetingTranscript)
  hook.el = fakeHostEl()
  hook.mounted()
  return hook
}

// The rendered observable: the speaker+text of every `transcript-line`
// node `_render` wrote into the host, in document order. Every line
// carries its own `data-speaker` (grouping is a rendering choice, not a
// data one), so this reads per line even though the NAME is drawn once
// per group.
function renderedLines(hook) {
  const html = hook.el.innerHTML
  const out = []
  const re =
    /<p class="transcript-line[^"]*" data-role="transcript-line" data-speaker="([^"]*)" data-final="[^"]*">([\s\S]*?)<\/p>/g
  let m
  while ((m = re.exec(html)) !== null) out.push(`${m[1]} ${m[2]}`)
  return out
}

const headerCount = (hook) =>
  (hook.el.innerHTML.match(/data-role="transcript-speaker"/g) || []).length

const hairlineCount = (hook) =>
  (hook.el.innerHTML.match(/border-t border-base-300/g) || []).length

const pillHtml = (hook) => {
  const m = hook.el.innerHTML.match(/<button[^>]*data-role="transcript-jump-live"[^>]*>([\s\S]*?)<\/button>/)
  return m ? m[1] : null
}

const lineClass = (hook, id) => {
  // Lines are rendered in buffer order; find by text since ids are not in
  // the markup.
  const m = hook.el.innerHTML.match(
    new RegExp(`<p class="(transcript-line[^"]*)" data-role="transcript-line"[^>]*>${id}</p>`)
  )
  return m ? m[1] : null
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
    // (Task 01a06524 moved the decision from geometry-at-render to the
    // scroll listener, so the move is made the way a browser makes it:
    // geometry, then `scroll`.)
    hook.el.clientHeight = 200
    hook.el.scrollHeight = 1000
    scrollTo(hook, 100)

    caption(listeners, { id: "a", speaker: "Rowan", text: "hello" })

    // Untouched — re-reading is not yanked away by the next utterance.
    expect(hook.el.scrollTop).toBe(100)

    // Now pinned: bottom of the content is within the slack window.
    scrollTo(hook, 800)
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

  // ── Task 01a06524 stage 1 ──────────────────────────────────────────

  it("groups consecutive same-speaker lines under ONE header, hairline only on speaker change", () => {
    caption(listeners, { id: "a", speaker: "Rowan", identity: "user:1", text: "one" })
    caption(listeners, { id: "b", speaker: "Rowan", identity: "user:1", text: "two" })
    caption(listeners, { id: "c", speaker: "Rowan", identity: "user:1", text: "three" })

    // DIRECTION CONTROL: three lines, one name, no rule — there is no
    // speaker change above the first group to mark.
    expect(renderedLines(hook)).toEqual(["Rowan one", "Rowan two", "Rowan three"])
    expect(headerCount(hook)).toBe(1)
    expect(hairlineCount(hook)).toBe(0)

    caption(listeners, { id: "d", speaker: "Saru", identity: "agent:saru", text: "four" })
    caption(listeners, { id: "e", speaker: "Rowan", identity: "user:1", text: "five" })

    // Rowan / Saru / Rowan = three groups, two changes, two hairlines.
    expect(headerCount(hook)).toBe(3)
    expect(hairlineCount(hook)).toBe(2)
    // Each line still carries its own speaker, whatever the grouping.
    expect(renderedLines(hook)).toEqual([
      "Rowan one",
      "Rowan two",
      "Rowan three",
      "Saru four",
      "Rowan five",
    ])
    // Timestamp per group header, HH:MM from detail.timestamp / arrival.
    expect(hook.el.innerHTML.match(/data-role="transcript-time">\d{2}:\d{2}</g)).toHaveLength(3)
  })

  it("marks an agent speaker with an outline chip keyed on the agent: identity prefix, never a colour", () => {
    caption(listeners, { id: "a", speaker: "Rowan", identity: "user:1", text: "human" })
    expect(hook.el.innerHTML).not.toContain("transcript-agent-chip")

    caption(listeners, { id: "b", speaker: "Saru", identity: "agent:saru", text: "agent" })
    const chips = hook.el.innerHTML.match(/data-role="transcript-agent-chip"/g) || []
    expect(chips).toHaveLength(1)

    // The pane's palette: no state colours anywhere in it.
    for (const banned of ["text-info", "text-warning", "text-error", "badge-info", "badge-warning", "badge-error"]) {
      expect(hook.el.innerHTML).not.toContain(banned)
    }
  })

  it("never yanks a scrolled-up reader, and offers a pill naming who is speaking", () => {
    hook.el.clientHeight = 200
    hook.el.scrollHeight = 1000
    caption(listeners, { id: "a", speaker: "Rowan", text: "before" })
    expect(hook.el.scrollTop).toBe(1000)

    // Reader scrolls up into the scrollback. Quiet room: no pill yet —
    // there is nothing to jump to that they have not seen.
    scrollTo(hook, 100)
    expect(pillHtml(hook)).toBeNull()

    caption(listeners, { id: "b", speaker: "Marlowe", text: "new line" })

    expect(hook.el.scrollTop).toBe(100)
    expect(pillHtml(hook)).toBe("Marlowe is speaking ↓")
    // The pill is the ONLY primary in the pane.
    expect(hook.el.innerHTML.match(/btn-primary/g)).toHaveLength(1)

    // A later speaker replaces the name — it says who is speaking NOW.
    caption(listeners, { id: "c", speaker: "Harper", text: "newer" })
    expect(pillHtml(hook)).toBe("Harper is speaking ↓")
    expect(hook.el.scrollTop).toBe(100)

    clickPill(hook)

    expect(hook.el.scrollTop).toBe(hook.el.scrollHeight)
    expect(pillHtml(hook)).toBeNull()

    // And follow-live is restored: the next line pulls the view down.
    hook.el.scrollHeight = 1200
    caption(listeners, { id: "d", speaker: "Rowan", text: "after" })
    expect(hook.el.scrollTop).toBe(1200)
  })

  it("shows no pill and keeps auto-scrolling while the reader is at the live edge", () => {
    hook.el.clientHeight = 200
    hook.el.scrollHeight = 1000
    // Within PIN_SLACK_PX of the bottom counts as at the edge.
    scrollTo(hook, 1000 - 200 - (PIN_SLACK_PX - 1))

    caption(listeners, { id: "a", speaker: "Rowan", text: "hello" })

    expect(hook.el.scrollTop).toBe(1000)
    expect(pillHtml(hook)).toBeNull()

    // Returning to the bottom after a detour also retires the pill.
    scrollTo(hook, 100)
    caption(listeners, { id: "b", speaker: "Rowan", text: "away" })
    expect(pillHtml(hook)).not.toBeNull()
    scrollTo(hook, 1000)
    expect(pillHtml(hook)).toBeNull()
  })

  it("says the record is truncated once the cap first drops a line", () => {
    for (let i = 0; i < MAX_LINES; i++) {
      caption(listeners, { id: `seg-${i}`, speaker: "Rowan", text: `line ${i}` })
    }

    // DIRECTION CONTROL: exactly at the cap nothing has been dropped, so
    // no notice — a notice here would cry wolf on every long call.
    expect(renderedLines(hook)).toHaveLength(MAX_LINES)
    expect(hook.el.innerHTML).not.toContain("transcript-truncated")

    caption(listeners, { id: "seg-over", speaker: "Rowan", text: "one more" })

    expect(renderedLines(hook)).toHaveLength(MAX_LINES)
    expect(hook.el.innerHTML).toContain('data-role="transcript-truncated"')
    // The sentence carries the constant, so a reader can act on it.
    expect(hook.el.innerHTML).toContain(`Showing the last ${MAX_LINES} lines. Earlier speech is not kept.`)
  })

  it("renders interim text muted and NOT italic, and finals at full base-content", () => {
    caption(listeners, { id: "i1", speaker: "Rowan", text: "settling", final: false })

    const interim = lineClass(hook, "settling")
    expect(interim).toContain("text-base-content/60")
    expect(interim).not.toContain("italic")
    expect(interim).not.toContain("opacity")

    caption(listeners, { id: "f1", speaker: "Rowan", text: "settled" })

    const final = lineClass(hook, "settled")
    expect(final).toContain("text-base-content ")
    expect(final).not.toContain("text-base-content/60")
    expect(final).not.toContain("italic")
    expect(interimCount(hook)).toBe(0)
  })
})
