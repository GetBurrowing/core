# ADR 0037: @-Mention Wire Format

**Status:** Accepted
**Date:** 2026-04-17
**Deciders:** Rowan
**Related:** ADR 0020 (Chat Rich Content Rendering), ADR 0027 (Active Agent Mutex), ADR 0035 (ChatLive Modularization)

---

## Context

@-mentions are stored as free-form substrings inside `Message.content`. The composer writes `@Display Name ` on accept (`compose_input.js:145`), the renderer highlights them with `~r/@(\w+)/` (`content_renderer.ex:111`), and the attention router resolves recipients with `String.contains?/2` against each participant's `display_name` (`attention_router.ex:479`).

Three bugs follow from this:

1. **Highlight drops after the first word.** `@Rowan Ellis` renders with only `@Rowan` highlighted because `\w+` stops at whitespace. Participants with multi-word display names (most humans) get visually truncated mentions.
2. **Autocomplete drops after the first word.** The composer's detection regex `/@(\w*)$/` stops at whitespace, so typing `@Rowan Mil` only ever queries `"Rowan"` — the user cannot narrow by continuing to type a surname.
3. **Prefix-match ambiguity in routing.** `String.contains?(content, "@rowan")` matches both `@Rowan` and `@Rowan Ellis`. In a space with both a "Rowan" and a "Rowan Ellis", a message mentioning one routes to both.

These are fixable individually, but the underlying cause is shared: the wire format has no delimiter to tell a mention from its surrounding text. Any point fix (greedy regex, capitalized-token heuristic, roster-threaded renderer) papers over the same gap.

## Decision

**Change the mention wire format to `@[Display Name]`** — bracketed, human-readable, no embedded ID.

Example raw text: `hey @[Rowan Ellis] and @[higgins], can you look at this?`

The composer emits the bracketed form on mention accept. The renderer matches `@[…]` as its primary pattern and keeps `@\w+` as a legacy fallback so pre-migration messages stay highlighted until the backfill runs. The attention router resolves recipients with an exact bracketed-match check first, legacy substring-match second.

## Alternatives considered

### 1. Greedy "capitalized tokens" regex

`~r/@([A-Z]\w*(?:\s+[A-Z]\w*)*)/`. One-line change. Handles `@Rowan Ellis` and `@Sloane Scott`.

**Rejected** because it breaks for lowercase handles (every agent: `higgins`, `mycroft`, `geordi`) and over-matches on capitalized follow-on words: `@Rowan Have you seen this` would highlight "Rowan Have". No improvement to the routing ambiguity.

### 2. Thread the roster into the renderer

Pass `participants_map` into `ContentRenderer.render_message/2` and build an alternation regex of known display names at render time. Correct. Zero false positives.

**Rejected** because (a) it does not fix the composer autocomplete or the router ambiguity — those would need parallel fixes, (b) every render site has to find and thread the roster, and (c) it doesn't solve the underlying "mentions have no wire-format boundary" problem. A wire-format change cleans up all three surfaces in one cut.

### 3. Opaque ID format (`<@participant_id>`)

Slack/Discord-style. Stable across renames, unambiguous.

**Rejected** because Suite's codebase leans on `Message.content` being readable. Attention routing, search indexing, exports, audit review, and developer inspection all benefit from raw text legibility. `<@usr_01H…>` scattered through every message is a large tax for a benefit (rename stability) that Suite's users rarely trigger in practice.

### 4. Hybrid `@[Name:id]`

Readable *and* rename-stable. Best of both.

**Deferred, not rejected.** The bracket-delimited format chosen here is a strict subset — if rename stability becomes important later, we extend `@[Name]` to `@[Name:id]` without another wire-format break. Renderer and router can pattern-match both.

## Consequences

### Changes

| File | Change |
|---|---|
| `assets/js/hooks/compose_input.js` | Detection regex `/(?:^\|\s)@([^\[\]@\n]*)$/` (allows spaces in query, stops at bracket); insert pattern `@[Name] ` |
| `lib/platform/chat/content_renderer.ex` | Primary pattern `~r/@\[([^\[\]]+)\]/`, legacy fallback `~r/@(\w+)/` |
| `lib/platform/chat/attention_router.ex` | `mentioned?/2` checks bracketed form first, substring fallback second |
| `lib/platform/chat/mention_backfill.ex` | Release-callable `Platform.Chat.MentionBackfill.run/1` — core rewrite logic |
| `lib/mix/tasks/platform/backfill_mentions.ex` | Thin CLI shim delegating to the module (dev convenience) |
| `test/platform/chat/content_renderer_test.exs` | Extend with new-format and legacy-fallback cases |
| `test/platform/chat/attention_router_test.exs` | Add bracketed-mention cases if not covered |

### Migration

`Platform.Chat.MentionBackfill.run/1` scans `messages.content` and rewrites substrings of the form `@<Display Name>` to `@[<Display Name>]` where `<Display Name>` matches an active participant's `display_name` in that message's space. Longest-match-wins for overlapping names. Idempotent — skips content already containing `@[`. Dry-run by default.

Invocation:

```bash
# Local / dev
mix platform.backfill_mentions [--apply] [--space-id <uuid>] [--limit N]

# Release / prod (no Mix in the release)
bin/platform eval 'Platform.Chat.MentionBackfill.run(apply: true)'
```

The legacy `@Word` fallback in renderer and router stays indefinitely. It has no meaningful cost (regex) and covers any message the backfill missed (e.g., mentions that never resolved to a real participant — those still render as highlighted text, as they did before).

### Non-goals

- No change to the `keywords` free-form strings in `attention_config["keywords"]` — those are arbitrary user phrases, not participant references.
- No change to any LLM-facing prompt template that might emit `@Name` strings (`meetings/summary_prompt.ex`, etc.). Those flow through `ContentRenderer` and are covered by the legacy fallback.
- No UI change for how mentions are displayed — the `span class="..."` wrapper stays the same. Only the source pattern changes.
- No rename-stability. See alternative 4 — extend to `@[Name:id]` if and when that matters.

## Rollback

If the new format causes problems, revert the code changes. The backfill rewrite is not reversible in place, but the legacy `@Word` fallback means reverted code still renders and routes pre-migration and post-migration messages identically. No data is destroyed.
