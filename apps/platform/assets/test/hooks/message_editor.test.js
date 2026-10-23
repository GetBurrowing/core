import { describe, it, expect, vi } from "vitest"
import MessageEditor, { shortenedOrRemoved } from "../../js/hooks/message_editor.js"

/**
 * Tests for `shortenedOrRemoved(original, next)` — the pure heuristic that
 * gates the removal-warning modal (editable-messages contract Policy 4,
 * task 019e1eaf).
 *
 * Each row: [name, original, next, expected].
 *
 * Three known-limitation rows are included intentionally:
 *   - "repeated word" — whitespace-tokenize-into-set treats `"go go go"`
 *     and `"go"` as having identical token sets, so the function reports
 *     no removal. Matches the server's behaviour (the server uses the
 *     same `~r/\s+/` split, so client and server agree). Acceptable
 *     limitation.
 *   - "URL edit" — `https://example.com/v1` is a single whitespace-bounded
 *     token; changing it to `/v2` makes the original token absent → the
 *     function reports removal. Acceptable conservative false-positive
 *     for URL edits.
 *   - "apostrophe contraction" — `"don't"` (one token) vs `"do not"`
 *     (two tokens) cannot be reconciled without an external contraction
 *     table. Token "don't" is not in {do, not, forget} → function reports
 *     removal. Acceptable conservative false-positive; explicitly out of
 *     scope for Stage 2 (task 019e1eaf plan v2).
 */
const CASES = [
  ["additive end",            "Hey can we talk about the API tomorrow?",  "Hey can we talk about the API tomorrow at 10am?",  false],
  ["additive comma-insert",   "Hey can we talk about the API tomorrow?",  "Hey, can we talk about the API tomorrow at 10am?", false],
  ["true substring removal",  "Hey can we talk about the API tomorrow?",  "Hey can we talk tomorrow?",                        true],
  ["middle replace longer",   "leaked secret token here",                 "leaked redacted-credential here",                   true],
  ["pure word reorder",       "alpha beta gamma",                         "gamma alpha beta",                                  false],
  ["strict shorter",          "abcdef",                                   "abc",                                                true],
  ["empty original",          "",                                         "hello world",                                       false],
  ["emoji preserved",         "Great work \u{1F389}",                     "Great work \u{1F389} indeed",                       false],
  ["CJK preserved",           "こんにちは world",     "こんにちは world today",        false],
  ["apostrophe contraction",  "don't forget",                             "do not forget",                                     true],
  ["repeated word",           "go go go",                                 "go",                                                false],
  ["URL edit",                "see https://example.com/v1",               "see https://example.com/v2",                        true],
  ["@mention removal",        "@alice please review",                     "please review",                                     true],
  ["remove and add",          "buy milk and eggs",                        "buy oat milk",                                      true],
  ["trailing whitespace",     "hello",                                    "hello ",                                            false]
]

describe("shortenedOrRemoved(original, next)", () => {
  for (const [name, original, next, expected] of CASES) {
    it(name, () => {
      expect(shortenedOrRemoved(original, next)).toBe(expected)
    })
  }
})

// The editor's keys (redesign rung 10, stage 4, coverage row 117): Enter
// saves, Shift+Enter is a newline, Cmd/Ctrl+Enter still saves, Esc cancels.
describe("MessageEditor keys", () => {
  function editor() {
    const listeners = {}
    const textarea = {
      value: "the original",
      focus: vi.fn(),
      setSelectionRange: vi.fn(),
      addEventListener: (type, fn) => (listeners[type] = fn),
      removeEventListener: vi.fn(),
    }
    const flag = { value: "false" }
    const form = {
      dataset: { originalContent: "the original" },
      requestSubmit: vi.fn(),
      querySelector: (sel) => (sel.startsWith("textarea") ? textarea : flag),
    }
    const hook = Object.create(MessageEditor)
    hook.el = form
    hook.pushEvent = vi.fn()
    hook.mounted()
    const press = (key, mods = {}) => {
      const e = { key, preventDefault: vi.fn(), ...mods }
      listeners.keydown(e)
      return e
    }
    return { form, hook, press }
  }

  it("Enter submits the edit", () => {
    const { form, press } = editor()
    const e = press("Enter")
    expect(e.preventDefault).toHaveBeenCalled()
    expect(form.requestSubmit).toHaveBeenCalledTimes(1)
  })

  it("Shift+Enter does not submit (the textarea breaks the line)", () => {
    const { form, press } = editor()
    const e = press("Enter", { shiftKey: true })
    expect(e.preventDefault).not.toHaveBeenCalled()
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("Enter while an IME is composing does not submit", () => {
    const { form, press } = editor()
    press("Enter", { isComposing: true })
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("Cmd+Enter and Ctrl+Enter still submit", () => {
    const { form, press } = editor()
    press("Enter", { metaKey: true })
    press("Enter", { ctrlKey: true })
    expect(form.requestSubmit).toHaveBeenCalledTimes(2)
  })

  it("Esc pushes cancel_edit and submits nothing", () => {
    const { form, hook, press } = editor()
    const e = press("Escape")
    expect(e.preventDefault).toHaveBeenCalled()
    expect(hook.pushEvent).toHaveBeenCalledWith("cancel_edit", {})
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })
})
