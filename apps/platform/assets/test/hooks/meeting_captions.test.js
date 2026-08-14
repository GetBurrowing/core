import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingCaptions from "../../js/hooks/meeting_captions.js"

/**
 * Stage-2 home for the quick-meet caption duplication regression
 * (task 019ff712 stage 1 = diagnosis only; this file carries the
 * measurement so stage 2 writes its assertions against observed facts,
 * not against the hypothesis in the ticket).
 *
 * ── MEASURED, not reasoned ───────────────────────────────────────────
 * Instrument: local dev server built from this branch, real LiveView
 * socket connected, quick-meet panel rendered in a channel
 * (`in_meeting == true`), driven over CDP. LiveKit itself was NOT
 * reachable, so the caption events were SYNTHESISED at the same entry
 * point `MeetingRoom._onTranscription` uses:
 *
 *   document.dispatchEvent(new CustomEvent("meeting:caption", {
 *     detail: { id, speaker, identity, text, final }
 *   }))
 *
 * ONE final caption event, against a freshly mounted panel:
 *
 *   document.querySelectorAll('[phx-hook="MeetingCaptions"]').length  -> 2
 *   document.querySelectorAll('[data-caption-slot]').length           -> 0
 *     (that selector matches nothing anywhere now — the per-tile overlay
 *      was removed in stage 3; the count is kept as the stage-1 record)
 *   document.querySelectorAll('.caption-line').length                 -> 2
 *
 * Nearest id'd ancestor of each node:
 *   hook hosts   : the desktop-rail host and the mobile-overlay host (self)
 *   caption slots: none exist
 *   caption lines: one inside each of those two hosts
 *
 * One dispatched event invokes each hook instance exactly once
 * (`viewHooks` carrying phx-hook="MeetingCaptions" == 2, and a spy
 * listener saw the event once). So the two nodes are two hook hosts,
 * not a doubled listener.
 *
 * ── What that rules in and out ───────────────────────────────────────
 * (a) per-tile `[data-caption-slot]` in the quick-meet grid — RULED OUT.
 *     Zero such nodes at any point; both `.meeting-participant-grid`
 *     containers (`#meeting-participants`, `#meeting-participants-mobile`)
 *     were empty, and no quick-meet markup authors the attribute.
 * (c) a third `MeetingCaptions` instance — RULED OUT. Exactly two hosts
 *     and two hook instances, across join / leave / re-join.
 * (b) interim + final rendering as two `.caption-line` nodes — CONFIRMED,
 *     and it is the only mechanism that puts more than one node inside a
 *     SINGLE bar. `_commitLine` clears `this._interimLine` only when the
 *     final segment carries the SAME id as the interim; when the ids
 *     differ, the stale interim survives and `_render` emits it next to
 *     the committed final. `_commitLine` also has no id dedupe, so a
 *     redelivered final pushes a second identical entry.
 *
 * Observed sequence for ONE utterance ("hello there"), per bar:
 *   interim id=u1-interim          -> 1 line
 *   final   id=u1-final            -> 2 lines (stale interim + final)
 *   final   id=u1-final (redeliver) -> 3 lines  <-- the reported triplicate
 *
 * ── The host duplication is NOT what the user sees ───────────────────
 * At the time of this measurement one host sat in the `hidden lg:flex`
 * desktop panel and a second in the `lg:hidden` fixed overlay. Measured
 * at 1200px: `offsetParent` non-null for the desktop host, null and zero
 * client rects for the mobile one. The two hosts are mutually exclusive
 * by CSS, so they double the DOM node count but cannot produce a second
 * VISIBLE line. Any fix aimed only at collapsing the two hosts would
 * leave the reported triplicate untouched.
 *
 * Stage 2 should therefore assert on `_updateInterim` / `_commitLine`
 * buffer identity, not on host count.
 *
 * (Superseded for the DOM, kept for the record: the quick-meet panel now
 * renders a single hoisted caption host shared by both breakpoints. That
 * unification is housekeeping — it did not and could not fix the
 * triplicate measured above.)
 */

// ── Fakes ──────────────────────────────────────────────────────────────
//
// No jsdom is installed for the assets workspace (see
// meeting_video_tile.test.js), so the two DOM surfaces the hook touches
// are stubbed: the host element's `innerHTML` / `classList`, and the
// throwaway `document.createElement("div")` that `_escapeHtml` uses.

function fakeClassList() {
  const set = new Set()
  return {
    add: (...c) => c.forEach((x) => set.add(x)),
    remove: (...c) => c.forEach((x) => set.delete(x)),
    has: (c) => set.has(c),
  }
}

function fakeHostEl() {
  return { innerHTML: "", classList: fakeClassList() }
}

function installDocumentStub() {
  globalThis.document = {
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
}

// A hook receiver with the same field set `mounted()` installs, minus
// the document listener + persistence (neither is under test here).
function newHook() {
  const hook = Object.create(MeetingCaptions)
  hook.el = fakeHostEl()
  hook._lines = []
  hook._interimLine = null
  hook._hideTimer = null
  return hook
}

// The rendered observable: how many `.caption-line` nodes `_render`
// wrote into the host. Counting the emitted markup is exactly what the
// stage-1 CDP measurement counted in the live DOM.
function captionLineCount(hook) {
  return (hook.el.innerHTML.match(/class="caption-line/g) || []).length
}

// `identity` is deliberately omitted from every event: it only drives
// the `(guest)` display suffix, which is not part of this regression.
// The per-tile caption fan-out it used to feed no longer exists (task
// 019ff712 stage 3) — the consolidated bar is the only caption surface.
function caption(hook, { id, text, final }) {
  hook._onCaption({ detail: { id, speaker: "Ada", text, final } })
}

describe("MeetingCaptions rolling buffer — one utterance, one line", () => {
  let hook

  beforeEach(() => {
    installDocumentStub()
    hook = newHook()
  })

  afterEach(() => {
    hook._clearHideTimer()
    delete globalThis.document
  })

  it("renders exactly one line for interim → final(new id) → final redelivered", () => {
    // Step 1 — interim segment under its own id.
    caption(hook, { id: "u1-interim", text: "hello the", final: false })
    expect(captionLineCount(hook)).toBe(1)

    // Step 2 — the final segment carries a DIFFERENT id than the interim.
    // Broken behaviour observed at stage 1: 2 (the stale interim survived).
    caption(hook, { id: "u1-final", text: "hello there", final: true })
    expect(captionLineCount(hook)).toBe(1)

    // Step 3 — the same final redelivered. Broken behaviour: 3.
    caption(hook, { id: "u1-final", text: "hello there", final: true })
    expect(captionLineCount(hook)).toBe(1)

    expect(hook._interimLine).toBe(null)
    expect(hook._lines.map((l) => l.id)).toEqual(["u1-final"])
  })

  it("keeps scrollback: distinct finals accumulate up to the cap", () => {
    // Guards the dedupe fix from collapsing every utterance into one —
    // duplicates must go without history going with them. Updated for
    // MAX_LINES = 2 (task 019ff712 stage 4, gallery occlusion); the
    // discriminating step is still that two DISTINCT ids give two lines,
    // which the collapse bug would have shown as one.
    caption(hook, { id: "a", text: "first", final: true })
    expect(captionLineCount(hook)).toBe(1)

    caption(hook, { id: "b", text: "second", final: true })
    expect(captionLineCount(hook)).toBe(2)

    caption(hook, { id: "c", text: "third", final: true })
    expect(captionLineCount(hook)).toBe(2)

    expect(hook._lines.map((l) => l.id)).toEqual(["b", "c"])
    expect(hook.el.innerHTML).toContain("third")
  })

  it("a redelivered final updates the existing entry in place, not a new one", () => {
    caption(hook, { id: "a", text: "first", final: true })
    caption(hook, { id: "b", text: "secnd", final: true })
    caption(hook, { id: "b", text: "second", final: true })

    expect(captionLineCount(hook)).toBe(2)
    expect(hook._lines.map((l) => l.id)).toEqual(["a", "b"])
    expect(hook.el.innerHTML).toContain("second")
    expect(hook.el.innerHTML).not.toContain("secnd")
  })

  it("caps the rolling buffer at two finalised lines", () => {
    // MAX_LINES is intended behaviour, not part of the bug. Lowered from 3
    // to 2 in stage 4 so the bar occludes less of the gallery grid; the cap
    // itself is what this case pins, and the oldest line is what drops.
    for (const id of ["a", "b", "c", "d"]) {
      caption(hook, { id, text: `line ${id}`, final: true })
    }

    expect(captionLineCount(hook)).toBe(2)
    expect(hook._lines.map((l) => l.id)).toEqual(["c", "d"])
  })
})
