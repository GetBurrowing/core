# Editable Messages — Coverage Matrix (Task 6 Stage 1 Recon)

**Date:** 2026-05-12
**Stage:** Task 6 / Stage 1 — Recon: inventory implemented surface against the Task-1 contract
**Branch:** `task/019df569-b82a-7319-8ac4-b9419ffe87b9`
**Worktree:** `~/projects/core-task-019df569-verify`

This matrix maps each section of the **Editable Messages Cross-Phase Contract** (Task 1, canvas `019e1827-e8e5-7c02-9534-22c1d6290bae`) to where it lives in the current codebase, what state it ships in, and any gaps / drift / runtime issues found during static recon.

---

## Section a — Data model

| Element | Status | Where | Notes |
|---|---|---|---|
| `chat_messages.frozen_at` column | ✅ Shipped | `lib/platform/chat/message.ex:29` | `utc_datetime_usec`; non-null ⇒ 409 on PATCH |
| `chat_messages.frozen_by_participant_id` column | ✅ Shipped | `lib/platform/chat/message.ex:80, 93–107` | Changeset cross-validates: both fields must be set together |
| `chat_messages.corrects_message_id` column | ✅ Shipped | `lib/platform/chat/message.ex:34, 82` | `binary_id`; used by Policy-3 agent corrections |
| `chat_messages.task_id` column | ⚠️ Need to verify | not seen in this grep pass | Section-e references task-scoped freeze; check Stage 2 |
| `chat_message_versions` table | ✅ Shipped | `priv/repo/migrations/20260511170000_add_message_edit_history.exs` | Migration name confirms; module `lib/platform/chat/message_version.ex` (80 lines) |
| Virtual `versions_count` | ✅ Shipped | `lib/platform/chat/message.ex:36` | For "(edited)" affix UI |

---

## Section b — API contract (HTTP PATCH + GET versions)

| Element | Status | Where | Notes |
|---|---|---|---|
| `PATCH /api/messages/:id` route | ✅ Shipped | `lib/platform_web/router.ex:114` | `MessageController, :update` |
| `GET /api/messages/:id/versions` route | ✅ Shipped | `lib/platform_web/router.ex:115` | `MessageController, :versions` |
| Author-only authz (403 on mismatch) | ✅ Shipped | `lib/platform_web/controllers/message_controller.ex:140–141` | "Policy 3 of the contract: agents can't edit their own messages, humans can't edit agent messages. Both reduce to the same author-id check" |
| Freeze handling (409 + freezing-action context) | ✅ Shipped | `lib/platform/chat/messages/edit.ex:21, 70` | `{:error, :frozen, freezing_action}` tuple returned when `message.frozen_at` is set |
| Transactional update + version insert | ✅ Shipped | `lib/platform/chat/messages/edit.ex:25` | "`chat_message_versions` insert run in one `Repo.transaction`" |

**Status:** Section b looks complete. Stage 2 will exercise the response-shape contract with integration tests.

---

## Section c — Realtime event

| Element | Status | Where | Notes |
|---|---|---|---|
| Broadcast event on edit | ✅ Shipped | `lib/platform/chat/messages/edit.ex:118` | `PubSub.broadcast(updated.space_id, {:message_edited, payload})` |
| Telemetry instrument | ✅ Shipped | `lib/platform/chat/messages/edit.ex:123` | `[:platform, :chat, :message_edited]` |

**⚠️ Drift finding — recorded for Stage 2 verification:**
ORG_MEMORY (2026-05-08) says realtime event should be **`{:message_updated, msg, diff}` 3-tuple** ("do NOT invent `:message_edited`"). Implementation broadcasts **`{:message_edited, payload}` 2-tuple** instead. Two possibilities:
1. The contract was updated after ORG_MEMORY was written and ORG_MEMORY is stale.
2. The implementation drifted from the contract Marlowe approved.

Stage 2 will reconcile by reading the live contract canvas (`019e1827-e8e5-7c02-9534-22c1d6290bae`) and updating ORG_MEMORY if needed. **Either way, the test suite must subscribe to whichever event name the contract authoritatively names** — this matters for in-context agent receivers, who need to listen on the right event.

Also worth verifying: ORG_MEMORY says "API ships as LV event `edit_message`, not REST PATCH." Implementation ships **both** — REST PATCH `/api/messages/:id` (router:114) AND LV event `save_edit` (`chat_live.ex:253`). Likely the implementation chose to support both, with the REST PATCH backing the contract's section-b API requirement and the LV `save_edit` driving the inline editor's form-submit path. Confirm via the canvas.

---

## Section d — Render contract (UI)

| Element | Status | Where | Notes |
|---|---|---|---|
| Pencil-icon hover toolbar (web) | ✅ Shipped | `lib/platform_web/components/chat_message.ex:159–180` | Placed after Copy per spec; visibility filtered to own non-agent text messages |
| Pencil disabled-with-tooltip on frozen | ✅ Shipped | `lib/platform_web/components/chat_message.ex:166–177` | `phx-click` suppressed via `:if-nil`; `aria-disabled` + tooltip from `edit_affordance_title/2` (line 600) |
| 3-dot menu sheet | ✅ Shipped | `lib/platform_web/live/chat_live.html.heex:1134–1204` | Single `:open_message_actions_id`-driven Sheet at page bottom |
| 3-dot menu "Edit message" item | ⚠️ **Shipped with known runtime bug** | `lib/platform_web/live/chat_live.html.heex:1190–1202` | **See `01-deadclick-finding.md`** — Marlowe user report 2026-05-12, click feels like deadclick |
| Inline editor component | ✅ Shipped | `lib/platform_web/components/chat_message_editor.ex` (70 lines) | Form-submit `save_edit`; Cmd/Ctrl+Enter via `MessageEditor` JS hook |
| `(edited)` indicator + version popover | ⚠️ Need to verify | not located in this pass | Stage 4 component test will cover |
| Correction message rendering (Policy 3) | ⚠️ Need to verify | not located in this pass | Stage 4 component test will cover |
| Removal warning modal (Policy 4) | ⚠️ Need to verify | hook detection logic in `assets/js/hooks/message_editor.js:onInput` | Modal trigger via `removes_content` flag + LV `save_edit` branch; surface in chat_live needs verification |

---

## Section e — Permissions

| Element | Status | Where | Notes |
|---|---|---|---|
| Author-only edit (403 on other-user message) | ✅ Shipped | `message_controller.ex` (author-id check at line 140–141) | Stage 3 will write the 403 test |
| Human can't edit agent message (403) | ✅ Shipped | Same author-id check covers this case (cross-participant-type denial) | Stage 3 test |
| Agent can't edit own message (403, Policy 3) | ⚠️ Need to verify | Not seen in grep — may rely on author-id check + participant_type=user requirement | Stage 3 test will explicitly cover |

---

## Section f — Agent interaction model (Policies 1–4)

| Policy | Status | Where | Notes |
|---|---|---|---|
| **Policy 1 — narrow notification scoping** (mentioned + task-assigned only) | ⚠️ Need to verify | Not yet located in `messages_hooks.ex` grep — Stage 4 will trace | Test: subscribe 3 agents, confirm delivery set |
| **Policy 2 — freeze on task `in_progress` or first state-changing op** | ✅ Logic shipped | `lib/platform/chat/messages/edit.ex:70`; `lib/platform/chat/message.ex:25, 93–107` | The DB-level freeze fields are present; what TRIGGERS the freeze (task transition hook, action-log hook) needs Stage 3 tracing |
| **Policy 3 — agents correct via `corrects_message_id`, not edit** | ✅ Shipped | `lib/platform/chat/message.ex:33–34`; render in `chat_message.ex` needs Stage 4 check | Test: agent-issued correction renders with header + link to original |
| **Policy 4 — pre-submit removal warning** | ✅ Shipped (JS side) | `assets/js/hooks/message_editor.js:onInput`; LV branch at `chat_live.ex:253–266` | Test: warning fires only on shortening / substring-removal; not on additive/length-preserving |

---

## Cross-client + search index

| Element | Status | Notes |
|---|---|---|
| Cross-client sync via realtime | ✅ Server-side broadcast ships | Stage 5 Playwright test: two browser contexts, edit in one, observe in the other |
| Reactions + thread survive edit | ⚠️ Need to verify | Stage 5 |
| Search index re-ingest on edit | ❌ **Unknown** | Stage 5 — if not implemented, file follow-up task, do NOT extend Task 6 |

---

## Surface size for context

| File | Lines | Role |
|---|---|---|
| `lib/platform/chat/message.ex` | 110 | Schema + changeset cross-validations |
| `lib/platform/chat/message_version.ex` | 80 | Version row schema |
| `lib/platform/chat/messages/edit.ex` | 170 | `apply_edit/3` + freeze check + broadcast + telemetry |
| `lib/platform_web/controllers/message_controller.ex` | 250 | REST PATCH + GET versions + authz |
| `lib/platform_web/components/chat_message.ex` | 647 | Render contract — bubble + hover toolbar + 3-dot button + editor mount point |
| `lib/platform_web/components/chat_message_editor.ex` | 70 | Inline editor form + MessageEditor JS hook binding |
| `lib/platform_web/live/chat_live.ex` | 842 | LV handlers — `edit_message_clicked`, `save_edit`, `cancel_edit`, `confirm_save_edit`, `apply_save_edit` |

---

## Stage 1 recon verdict

**The feature has shipped substantively** — every contract section has an implementation pointer. **Three areas need Stage 2–5 verification:**

1. **Section c drift** — confirm whether the realtime event is `:message_edited` (implementation) or `:message_updated` 3-tuple (ORG_MEMORY claim). Resolve before Stage 2's broadcast tests.
2. **Render-contract runtime gap** — the 3-dot menu's "Edit message" item has a Marlowe-reported deadclick. See `01-deadclick-finding.md` for the code-path walkthrough + ranked hypotheses + recommended next experiment.
3. **Policy 1 enforcement** — narrow notification scoping isn't visible in this grep pass. Stage 4 must locate the scoping logic before writing the 3-agent-fixture test.

Search index re-ingest (Stage 5) is the most likely candidate for the "file follow-up task" escape hatch the plan baked in — flag for Marlowe if Stage 5 confirms.

**Stage 1 complete.**
