import { describe, it, expect } from "vitest"
import { shortenedOrRemoved } from "../../js/hooks/message_editor.js"

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
