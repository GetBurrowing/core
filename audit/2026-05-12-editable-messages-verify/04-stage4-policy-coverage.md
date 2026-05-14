# Stage 4 — Policy 1 / 3 / 4 coverage report

**Date:** 2026-05-12
**Stage:** Task 6 / Stage 4
**Branch:** `task/019df569-b82a-7319-8ac4-b9419ffe87b9`
**New test file:** `apps/platform/test/platform/chat/edit_policies_test.exs`

Stage 4 bundles the three trust-defining policies: who sees edits (Policy 1), how agent corrections render (Policy 3), and how users are warned about removing content (Policy 4).

## Policy 3 — Correction-message rendering (Section d.4) ✅

**Status:** Conformant and tested.

Implementation: `apps/platform/lib/platform_web/components/chat_message.ex:282–291`. When `@msg.corrects_message_id` is non-nil, the bubble prepends a button:
- Visible text: `Correction to earlier message`
- `phx-click="scroll_to_message"`
- `phx-value-id` set to the original message id

Tests added (`describe "Policy 3 — correction-message rendering"`):
- **Active:** agent-issued correction message renders the header + carries correct `phx-value-id` + correct `phx-click` event name.
- **Active:** regular message (no `corrects_message_id`) does NOT render the correction header.

## Policy 4 — Removal warning modal (Section f.4) ✅

**Status:** Conformant end-to-end and tested.

Implementation wiring:
- `assets/js/hooks/message_editor.js` (MessageEditor hook) — JS-side detection of shortening / substring removal; sets the hidden `removes_content` input.
- `apps/platform/lib/platform_web/components/chat_message_editor.ex:34` — hidden input declaration.
- `apps/platform/lib/platform_web/live/chat_live.ex:276–290` — `save_edit` handler branches on `removes_content` flag: `"true"` → stash `pending_save_edit` and surface the modal; `"false"` → apply the edit immediately.
- `apps/platform/lib/platform_web/live/chat_live.html.heex:1109–1130` — the modal markup with locked-in copy ("Edit removes text."), Esc-key dismissal, Cancel / Edit anyway buttons.
- `apps/platform/lib/platform_web/live/chat_live.ex:292–307` — `confirm_save_edit` / `cancel_save_edit` handlers.

Tests added (`describe "Policy 4 — removal warning modal"`):
- **Active:** `save_edit` with `removes_content="true"` stashes the pending edit, renders the modal markup (`#edit-removal-warning`, title copy), and confirms DB content is **unchanged** at this point.
- **Active:** `save_edit` with `removes_content="false"` fires the edit immediately — no modal, DB content updated.
- **Active:** `confirm_save_edit` on a stashed pending edit applies it and closes the modal.

## Policy 1 — Narrow notification scoping (Section f.1) ✅ CONFORMANT (closed 2026-05-13)

**Status:** Conformant. Producer-side scoping shipped on main; comprehensive adversarial coverage in a dedicated test file.

Task `019e1e83-fe24-77c4-8a7b-8f90fb5cfca5` shipped via PR #345 (squash `e185599` on main, 2026-05-13). The implementation chose the producer-side scoping path (option (a) from this audit's "non-trivial fix" framing): the space-wide broadcast is preserved for LiveView user clients, plus a per-participant fan-out on `chat:participant:<id>` topics for entitled agent recipients.

Implementation citations:
- Helper: `Platform.Chat.eligible_edit_recipients_for_message/1` at `apps/platform/lib/platform/chat.ex` — returns the deduplicated union of mention-matched and open-task-linked participant ids for a given message.
- Producer: per-participant fan-out added to `Platform.Chat.Messages.Edit.broadcast_edit/5` at `apps/platform/lib/platform/chat/messages/edit.ex` (the original space-wide broadcast at the same call site is intentionally retained for LiveView user UI compat).
- Mention predicate: `Platform.Chat.AttentionRouter.mentioned?/2` (promoted from `defp` to public during Stage 1 of the Policy 1 task; covers ADR 0037 bracketed `@[Display Name]`, legacy `@name`, participant id, and user-configured keywords).

**Privacy invariant** — the contract requirement that "agents merely subscribed to the channel without mention-or-task linkage MUST NOT receive `{:message_edited}`" holds **vacuously** at this commit: no agent currently subscribes to either the space topic or the participant topic for this event. The producer is correctly scoped, so when a future agent feature wires a consumer it just subscribes to `chat:participant:<id>` and the invariant continues to hold. Deferral documented at `audit/2026-05-13-policy-1-broadcaster/03-stage3-deferred.md` on the Policy 1 branch.

**Tests:** the canonical adversarial battery lives in `apps/platform/test/platform/chat/policy_1_edit_scoping_test.exs` on main (3-agent fan-out, cross-space scoping negatives, dedup, empty-recipient baseline; 6 tests, 0 failures). The Stage 4 placeholder test in `edit_policies_test.exs` was removed to avoid duplicate-shape tests; see the moduledoc note in that file.

## Follow-up status

**Suite Task `019e1e83-fe24-77c4-8a7b-8f90fb5cfca5`: "Implement Policy 1 narrow notification scoping for editable messages"** — **SHIPPED** via PR #345 (squash `e185599` on main, 2026-05-13).

## Stage 4 verdict — updated

- Policies 3 + 4: **✅ conformant** and have integration test coverage in this branch's `edit_policies_test.exs`.
- Policy 1: **✅ conformant.** Producer-side scoping shipped; canonical adversarial coverage in `policy_1_edit_scoping_test.exs` on main.

Test_pass: ✅ (5 tests, 0 failures) — `mix test test/platform/chat/edit_policies_test.exs` (Policy 1 placeholder deduplicated)
Lint_pass: ✅ — `mix format --check-formatted` exit 0

**Stage 4 complete (with 2026-05-13 close-out update).**

## Cumulative gaps surfaced by Task 6 — close-out status

1. **Stage 3** — Policy 2 freeze trigger not implemented. ✅ **CLOSED** by [`019e1e80-...`](https://suite.example.com/tasks/019e1e80-4230-7a79-ac73-c157975b3999) (PR #343 / `60f24be`).
2. **Stage 4** — Policy 1 narrow notification scoping not implemented. ✅ **CLOSED** by [`019e1e83-...`](https://suite.example.com/tasks/019e1e83-fe24-77c4-8a7b-8f90fb5cfca5) (PR #345 / `e185599`).
3. **Pre-Stage 1** — 3-dot menu Edit deadclick on the canonical UX path. ⏳ **OPEN**: [`019e1e78-...`](https://suite.example.com/tasks/019e1e78-16fd-7615-93fa-115ac4c8beaa). Not yet shipped on main as of 2026-05-13.

The editable-messages feature is announce-ready on the Policy 1 + Policy 2 axes. The 3-dot deadclick remains a UX-path gap that the announcement should account for (or wait on).
