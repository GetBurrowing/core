import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingCaptions, {
  HIDE_AFTER_MS,
  STALL_AFTER_MS,
  STALL_CONFIRM_MS,
} from "../../js/hooks/meeting_captions.js"

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
  // Stall-detector state, same field set `mounted()` installs.
  hook._stallTimer = null
  hook._confirmTimer = null
  hook._speaking = false
  hook._meetingId = "meeting-under-test"
  // `pushEvent` is a real LiveView hook method this test double stands in
  // for, so the stall-signal cases (task 01a0cf5c stage 2) can assert on
  // what `_reportStall` sent without a live socket.
  hook.pushEvent = vi.fn()
  // The bar starts hidden, exactly as `mounted()` leaves it. Without this
  // the opacity assertions in the stall cases would pass vacuously against
  // a host that was never hidden in the first place.
  hook.el.classList.add("opacity-0", "pointer-events-none")
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
    hook._clearStallTimer()
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

describe("MeetingCaptions palette — theme-invariant by intent (task 01a0740e)", () => {
  let hook

  beforeEach(() => {
    installDocumentStub()
    hook = newHook()
  })

  afterEach(() => {
    hook._clearHideTimer()
    hook._clearStallTimer()
    delete globalThis.document
  })

  // The defect this pins: the host div carries `text-white`, but
  // `_render` wrote `text-base-content` / `text-base-content/90` on the
  // CHILD spans, and a colour on a child beats one inherited from a
  // parent — so the host's white was dead. `light` is `default: true` in
  // app.css and sets `--color-base-content: oklch(0% 0 0)`, so a
  // light-theme viewer got BLACK caption text on the `bg-black/75`
  // scrim. Not low contrast: invisible, and invisible to `mix test`.
  it("emits the white slots for the speaker and the text", () => {
    caption(hook, { id: "a", text: "hello there", final: true })

    const html = hook.el.innerHTML

    // Attribution: white, separated from the text by WEIGHT only.
    expect(html).toContain('<span class="font-semibold text-white">Ada</span>')
    // The spoken line: the same white, at full strength (the old
    // `/90` is gone — the canvas's slot is `oklch(100% 0 0)`).
    expect(html).toContain('<span class="text-white">hello there</span>')
  })

  // Asserting the ABSENCE is the load-bearing half. This is a
  // regression that reintroduces itself the moment someone "tidies"
  // the hook back toward the theme tokens, which is the tidy-looking
  // and wrong move here: the bar sits over arbitrary VIDEO, not over a
  // theme surface, so it is theme-invariant BY INTENT.
  it("emits no theme-following colour token anywhere in a caption line", () => {
    caption(hook, { id: "a", text: "first", final: true })
    caption(hook, { id: "i", text: "and then", final: false })

    // Reachability guard: the refutes below would pass just as happily
    // against an empty host, so pin that lines were actually drawn.
    expect(captionLineCount(hook)).toBe(2)

    expect(hook.el.innerHTML).not.toContain("text-base-content")
    expect(hook.el.innerHTML).not.toContain("base-content")
    // Semantic slots and Tailwind built-ins only — no raw hex.
    expect(hook.el.innerHTML).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
  })

  it("interim keeps its 70% + italic treatment on the line wrapper", () => {
    caption(hook, { id: "i", text: "half a sent", final: false })

    // White base colour composed with `opacity-70` IS the canvas's
    // "caption interim = white at 70%". It must not acquire a second
    // colour slot of its own.
    expect(hook.el.innerHTML).toContain("opacity-70")
    expect(hook.el.innerHTML).toContain("italic")
    expect(hook.el.innerHTML).toContain('<span class="text-white">half a sent</span>')

    // …and a final line does NOT get the interim treatment.
    caption(hook, { id: "f", text: "half a sentence", final: true })
    expect(hook.el.innerHTML).toContain("opacity-100")
    expect(hook.el.innerHTML).not.toContain("italic")
  })
})

describe("MeetingCaptions state 3 — the stalled bar (task 01a0740e stage 2)", () => {
  let hook

  // `meeting:speaking` is driven SYNTHETICALLY here, at the same entry point
  // `MeetingRoom._onActiveSpeaker` dispatches into. BE CLEAR ABOUT WHAT THAT
  // PROVES: this file exercises the caption hook's RULE, not LiveKit's real
  // `activeSpeakersChanged` wiring. The dispatch side belongs to
  // `meeting_room.js` and is asserted in
  // `meeting_room_active_speakers.test.js`. Neither file is end-to-end
  // coverage of the SFU, and no case here should be read as such.
  function speaking(h, identities) {
    h._onSpeaking({ detail: { identities } })
  }

  const stalled = (h) => h.el.innerHTML.includes('data-role="caption-stall"')

  beforeEach(() => {
    vi.useFakeTimers()
    installDocumentStub()
    hook = newHook()
  })

  afterEach(() => {
    hook._clearHideTimer()
    hook._clearStallTimer()
    vi.useRealTimers()
    delete globalThis.document
  })

  // The FLOOR, pinned directly rather than implied by the cases below.
  // If STALL_AFTER_MS ever slips under HIDE_AFTER_MS, an ordinary
  // conversational pause — the bar's own fade window — trips the notice and
  // every user in a normal pause is told their captions are broken. That is
  // the single worst outcome available to this feature.
  it("keeps the stall window strictly longer than the hide window", () => {
    expect(STALL_AFTER_MS).toBeGreaterThan(HIDE_AFTER_MS)
  })

  // ── CASE 1 — flowing -> stalled ─────────────────────────────────────
  it("says so when speech continues and captions stop arriving", () => {
    caption(hook, { id: "a", text: "the rail collapses to forty four", final: true })
    expect(captionLineCount(hook)).toBe(1) // reachability: a line was drawn

    speaking(hook, ["user:sam"])

    // Crossing STALL_AFTER_MS alone is only the CANDIDATE (task 01a0cf5c
    // stage 2) — the bar must not have said anything yet.
    vi.advanceTimersByTime(STALL_AFTER_MS + 1)
    expect(stalled(hook)).toBe(false)

    // The confirmation re-check fires STALL_CONFIRM_MS later, with speech
    // still sustained the whole time. THAT is what renders the notice.
    vi.advanceTimersByTime(STALL_CONFIRM_MS)

    // THE ASSERTION THAT MATTERS: the last caption is not still on screen
    // looking current next to a notice saying nothing is being transcribed.
    expect(hook.el.innerHTML).not.toContain("the rail collapses to forty four")
    expect(hook._lines).toEqual([])

    expect(stalled(hook)).toBe(true)
    expect(hook.el.innerHTML).toContain(
      "Captions stopped. Nothing is being transcribed."
    )

    // It HOLDS POSITION. A notice nobody is looking at when it appears is
    // the same as no notice.
    expect(hook.el.classList.has("opacity-0")).toBe(false)
    expect(hook.el.classList.has("pointer-events-none")).toBe(false)

    // Warning, not error, and no raw hex.
    expect(hook.el.innerHTML).toContain("text-warning")
    expect(hook.el.innerHTML).not.toContain("text-error")
    expect(hook.el.innerHTML).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)

    // The stall signal (task 01a0cf5c stage 2): fired exactly once, at
    // the point the bar entered state 3, carrying a meeting id and an
    // elapsed duration — not a per-tick payload.
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).toHaveBeenCalledWith("meeting_captions_stalled", {
      meeting_id: "meeting-under-test",
      elapsed_ms: STALL_AFTER_MS + STALL_CONFIRM_MS,
    })
  })

  // ── CASE 2 — a silent room NEVER stalls ─────────────────────────────
  //
  // The asymmetry is the whole feature: the claim is made only on positive
  // evidence of speech, never on caption silence alone.
  it("never stalls when nobody is speaking, however long the silence runs", () => {
    caption(hook, { id: "a", text: "hello there", final: true })
    speaking(hook, []) // explicit empty set — everyone stopped

    vi.advanceTimersByTime(STALL_AFTER_MS * 10)

    expect(stalled(hook)).toBe(false)
    expect(hook.el.innerHTML).not.toContain("Captions stopped")
  })

  it("never stalls when no speaking signal has arrived at all", () => {
    caption(hook, { id: "a", text: "hello there", final: true })

    vi.advanceTimersByTime(STALL_AFTER_MS * 10)

    expect(stalled(hook)).toBe(false)
  })

  // The hot-mic mitigation, and the only one applied: the speaking window
  // must be SUSTAINED for the full stall window. Bursts do not accumulate.
  it("does not let short speech bursts accumulate into a stall", () => {
    for (let i = 0; i < 5; i++) {
      speaking(hook, ["user:sam"])
      vi.advanceTimersByTime(STALL_AFTER_MS - 2000)
      speaking(hook, [])
      vi.advanceTimersByTime(1000)
    }

    expect(stalled(hook)).toBe(false)
  })

  // Direction control for case 1: with captions still flowing under the
  // same continuous speech, the notice must never appear.
  it("stays quiet while captions keep arriving under continuous speech", () => {
    speaking(hook, ["user:sam"])

    for (let i = 0; i < 6; i++) {
      vi.advanceTimersByTime(STALL_AFTER_MS - 2000)
      caption(hook, { id: `c${i}`, text: `line ${i}`, final: true })
      expect(stalled(hook)).toBe(false)
    }

    vi.advanceTimersByTime(STALL_AFTER_MS - 2000)
    expect(stalled(hook)).toBe(false)
  })

  // ── CASE 3 — recovery ───────────────────────────────────────────────
  it("clears the stall the moment a caption arrives, without the pre-stall line", () => {
    caption(hook, { id: "a", text: "pre-stall utterance", final: true })
    speaking(hook, ["user:sam"])
    vi.advanceTimersByTime(STALL_AFTER_MS + STALL_CONFIRM_MS + 1)
    expect(stalled(hook)).toBe(true) // reachability

    caption(hook, { id: "b", text: "fresh utterance", final: true })

    expect(stalled(hook)).toBe(false)
    expect(hook.el.innerHTML).toContain("fresh utterance")
    expect(hook.el.innerHTML).not.toContain("pre-stall utterance")
    expect(captionLineCount(hook)).toBe(1)
    expect(hook.el.classList.has("opacity-0")).toBe(false)

    // Recovering does not re-fire the stall signal — it only ever fires
    // on ENTERING state 3, once for this one episode.
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  // ── CASE 4 — idle-gap staleness ─────────────────────────────────────
  //
  // Second defect, found during planning and not in the ticket. The gap
  // here has NO speaking signal, so no stall fires and the stall fix
  // cannot be what saves this: the buffer clear on the hide path is.
  it("does not bring a pre-gap line back beside the first caption after a gap", () => {
    caption(hook, { id: "a", text: "twenty minutes ago", final: true })
    expect(captionLineCount(hook)).toBe(1)

    vi.advanceTimersByTime(HIDE_AFTER_MS + 1)
    expect(hook.el.classList.has("opacity-0")).toBe(true)
    expect(stalled(hook)).toBe(false) // no speech, so no stall, by design

    caption(hook, { id: "b", text: "just said", final: true })

    expect(captionLineCount(hook)).toBe(1)
    expect(hook.el.innerHTML).not.toContain("twenty minutes ago")
    expect(hook.el.innerHTML).toContain("just said")
  })

  it("empties the host on fade, leaving aria-live nothing stale to announce", () => {
    caption(hook, { id: "i", text: "half a sent", final: false })
    expect(captionLineCount(hook)).toBe(1)

    vi.advanceTimersByTime(HIDE_AFTER_MS + 1)

    // `opacity-0` is a VISUAL hide only. The host carries
    // `aria-live="polite"`, so anything left in the DOM is still in the
    // accessibility tree: a faded bar that still holds the line has hidden
    // it from sighted users and from nobody else.
    //
    // (An earlier draft of this case asserted `hook._interimLine === null`
    // after a fresh caption. That was VACUOUS: `_commitLine` nulls the
    // interim unconditionally, so it passed just as happily with the whole
    // hide-path clear deleted. The host content is the observable.)
    expect(hook.el.innerHTML).toBe("")
  })

  // State 2 is silence ON PURPOSE. This refutes the reflex fix the canvas
  // warns about — a placeholder that appears whether or not a transcriber
  // is attached asserts something nobody checked.
  it("renders no idle placeholder: no spinner, and never the word Listening", () => {
    caption(hook, { id: "a", text: "hello there", final: true })
    expect(captionLineCount(hook)).toBe(1) // reachability: it CAN draw

    // Fall idle: the fade window passes with nobody speaking.
    vi.advanceTimersByTime(HIDE_AFTER_MS + 1)
    expect(hook.el.innerHTML).toBe("")

    // …and it stays nothing, well past the stall window, because no speech
    // is occurring and the bar has nothing honest to say.
    vi.advanceTimersByTime(STALL_AFTER_MS * 5)
    expect(hook.el.innerHTML).toBe("")
    expect(hook.el.innerHTML).not.toMatch(/listening/i)
  })
})

describe("MeetingCaptions — slow-but-alive vs. genuinely-dead transcriber (task 01a0cf5c)", () => {
  // Diagnosis (stage 1) for the production incident where Sam saw the
  // literal STALL_COPY live. Working hypothesis (backend confirmation was
  // unreachable from that environment — see task 01a0cf5c stage 1 notes):
  // the `meeting-transcriber` worker was alive but slower than the old
  // 6000ms STALL_AFTER_MS under load, not dead, with the specific round
  // trip observed at ~8s.
  //
  // Fix (stage 2), two layers, matching the two "and/or" options in the
  // ticket: STALL_AFTER_MS raised 6000ms -> 12000ms (clears the observed
  // ~8s with margin on its own), AND a confirmation re-check
  // (STALL_CONFIRM_MS) so a single timeout crossing is never sufficient —
  // the sustained-speech-with-no-caption condition has to hold at a
  // SECOND checkpoint too. These cases pin both layers separately so a
  // future change to one can't silently lean on the other to stay green.
  let hook

  function speaking(h, identities) {
    h._onSpeaking({ detail: { identities } })
  }

  const stalled = (h) => h.el.innerHTML.includes('data-role="caption-stall"')

  beforeEach(() => {
    vi.useFakeTimers()
    installDocumentStub()
    hook = newHook()
  })

  afterEach(() => {
    hook._clearHideTimer()
    hook._clearStallTimer()
    vi.useRealTimers()
    delete globalThis.document
  })

  // CASE (i) — was RED via `it.fails` at diagnosis; now the fixed,
  // green behaviour. The exact incident shape: a caption merely late,
  // landing at ~8s, must not trip the false STALLED state a genuinely
  // dead pipeline would.
  it("does not falsely stall when a caption is merely delayed to ~8s, not dead", () => {
    speaking(hook, ["user:sam"])

    // ~8s, sustained speech, nothing yet. Below the new STALL_AFTER_MS
    // (12000ms) on its own, so the candidate timer has not even fired —
    // this is the production incident's own number, held fixed rather
    // than expressed relative to STALL_AFTER_MS, so a future retune that
    // creeps the threshold back down is still caught here.
    vi.advanceTimersByTime(8000)
    expect(stalled(hook)).toBe(false)

    // The delayed-but-alive transcriber's caption lands.
    caption(hook, { id: "delayed", text: "finally arrived", final: true })
    expect(stalled(hook)).toBe(false)
    expect(hook.el.innerHTML).toContain("finally arrived")
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  // CASE (i-b) — the confirmation re-check itself, isolated from the ~8s
  // incident number so it stays meaningful under a future STALL_AFTER_MS
  // retune. A caption landing AFTER the STALL_AFTER_MS candidate
  // crossing but BEFORE the STALL_CONFIRM_MS re-check must still cancel
  // the notice — "sustained across a confirmation re-check", not "a
  // single timeout crossing", is the rule now.
  it("a caption landing during the confirmation window cancels the candidate stall", () => {
    speaking(hook, ["user:sam"])

    vi.advanceTimersByTime(STALL_AFTER_MS + 1)
    expect(stalled(hook)).toBe(false) // candidate only, not yet confirmed

    // One tick shy of the confirm deadline (armed at STALL_AFTER_MS,
    // confirm fires STALL_CONFIRM_MS after that; +1 already elapsed).
    vi.advanceTimersByTime(STALL_CONFIRM_MS - 2)
    caption(hook, { id: "delayed", text: "just in time", final: true })

    expect(stalled(hook)).toBe(false)
    expect(hook.el.innerHTML).toContain("just in time")
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })

  // CASE (ii) — GREEN before and after the stage-2 fix. Speech never lets
  // up and no caption is EVER delivered — the genuinely-dead-pipeline
  // reading (hypothesis (a) in task 01a0cf5c). Whatever stage 2 does to
  // tolerate a slow-but-alive transcriber (cases (i)/(i-b) above), it
  // must not do so by disarming the detector outright: a real outage
  // still has to surface, eventually, as the stalled notice — and the
  // stall signal must still fire so the incident is recorded.
  it("still raises the stall when speech continues indefinitely and no caption ever arrives", () => {
    speaking(hook, ["user:sam"])

    // Far past any reasonable "still working" grace period, sustained
    // the whole time, with nothing ever arriving.
    vi.advanceTimersByTime(STALL_AFTER_MS * 20)

    expect(stalled(hook)).toBe(true)
    expect(hook.el.innerHTML).toContain(
      "Captions stopped. Nothing is being transcribed."
    )
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).toHaveBeenCalledWith("meeting_captions_stalled", {
      meeting_id: "meeting-under-test",
      elapsed_ms: STALL_AFTER_MS + STALL_CONFIRM_MS,
    })
  })

  // CASE (iii) — the telemetry contract itself: ONE call per episode, not
  // one per tick. `still raises the stall...` above only ever advances
  // the fake clock in a SINGLE jump, which would pass just as happily
  // against a `setInterval`-based re-firing implementation, since one big
  // `advanceTimersByTime` call drains a repeating timer's queue without
  // distinguishing "fired once" from "fired many times and only the last
  // call was asserted". This case walks the clock forward in many small
  // increments, well past the point the notice renders, and pins the
  // call count at every step — a future rewrite that reschedules
  // `_reportStall` on a recurring timer (e.g. to "refresh" the notice)
  // would be caught here even though the single-jump case above could not
  // see it.
  it("does not re-fire the stall signal on every tick while the outage continues", () => {
    speaking(hook, ["user:sam"])

    const episodeMs = STALL_AFTER_MS + STALL_CONFIRM_MS
    let elapsed = 0
    while (elapsed < episodeMs) {
      vi.advanceTimersByTime(500)
      elapsed += 500
      expect(hook.pushEvent).toHaveBeenCalledTimes(elapsed >= episodeMs ? 1 : 0)
    }
    expect(stalled(hook)).toBe(true)
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)

    // Keep ticking well past the point the notice rendered. Nothing
    // arrives, speech never stops — a periodic re-fire would show up as
    // additional calls here.
    for (let i = 0; i < 30; i++) {
      vi.advanceTimersByTime(1000)
    }
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
  })
})
