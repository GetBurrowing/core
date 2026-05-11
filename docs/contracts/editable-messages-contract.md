# Editable Messages — Cross-Phase Contract

**Task:** `019df567-b7f9-7ec2` (1. Define editable-messages cross-phase contract)
**Epic:** `019d1359-d3dd-7977-9150-05c7076b0b58` (Chat)
**Status:** DRAFT — pending Marlowe review (especially Section f)
**Consumed by:** Tasks 2 (schema), 3 (PATCH endpoint), 4 (web UI / folded into Task 11 Stage 4-6), 5 (PWA UI / folded into Task 11), 6 (verification)
**Source-of-truth references:**
- Existing schema: `apps/platform/lib/platform/chat/message.ex`
- Existing PubSub conventions: `apps/platform/lib/platform/chat/pub_sub.ex`
- Author-identity snapshot rules: ADR 0038
- Task 11 plan stages 4-6: `019e0f29-161e-7dee-845e-5cbceb410ed0`

---

## (a) Data model

### A.1 Existing message table — three new columns

The `chat_messages` table already has `edited_at :utc_datetime_usec` (unused today; we adopt it). Three additional columns:

| Column | Type | Null | Purpose |
|---|---|---|---|
| `frozen_at` | `utc_datetime_usec` | nullable | Timestamp the message became immutable. When non-null, PATCH returns 409. |
| `frozen_by_participant_id` | `:binary_id` | nullable | Participant whose action triggered the freeze. **FK to `chat_participants.id`** (see decision D-1). |
| `corrects_message_id` | `:binary_id` | nullable | FK to `chat_messages.id`. Non-null only on agent correction messages (Policy 3). |

Constraints:
- `frozen_at IS NULL OR frozen_by_participant_id IS NOT NULL` (both-or-neither check constraint).
- `corrects_message_id` FK with `ON DELETE SET NULL` (don't cascade-delete corrections if the original is hard-deleted).

Indexes:
- `chat_messages_corrects_message_id_index` (partial: `WHERE corrects_message_id IS NOT NULL`) — for "fetch corrections to this message" queries.
- No index on `frozen_at` — freeze checks are per-message (single row lookup).

### A.2 New table — `chat_message_versions`

Append-only edit history. Separate table (not embedded in `metadata` jsonb) — chosen because:
1. ADR 0038 establishes precedent for explicit normalized columns over embedded jsonb for audit-relevant data (author identity snapshot uses dedicated columns).
2. Indexable queries like "edits in window X" become trivial.
3. Append-only constraint enforceable at the DB level.

```sql
CREATE TABLE chat_message_versions (
  id              uuid PRIMARY KEY,           -- UUIDv7
  message_id      uuid NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  version_number  integer NOT NULL,           -- 1-based; v1 is the original
  content         text NOT NULL,              -- snapshot of message.content at this version
  edited_at       timestamptz NOT NULL,       -- when this version was created (== predecessor's effective_until)
  edited_by_participant_id uuid NOT NULL REFERENCES chat_participants(id),
  inserted_at     timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX chat_message_versions_msg_ver_idx
  ON chat_message_versions(message_id, version_number);

CREATE INDEX chat_message_versions_msg_idx
  ON chat_message_versions(message_id);
```

Semantics:
- Version 1 is **the original** — inserted at the same time as the message itself (in a transaction with the initial `chat_messages` insert). This lets UI show full version history without a "first-edit" special case.
- Each successful PATCH inserts a new row with `version_number = previous + 1`.
- The current `chat_messages.content` always matches the highest-version row's `content`. Soft-redundant but cheaper than joining for every render.

### A.3 Rollback safety

Migration must be reversible:
- `CREATE TABLE chat_message_versions` ↔ `DROP TABLE`
- Three new columns on `chat_messages` ↔ `ALTER TABLE ... DROP COLUMN`
- The check constraint ↔ `ALTER TABLE ... DROP CONSTRAINT`

Backfill on up-migration: for every existing `chat_messages` row, insert one `chat_message_versions` row with `version_number=1`, `content=chat_messages.content`, `edited_by_participant_id=chat_messages.participant_id`, `edited_at=chat_messages.inserted_at`. Acceptable at current message volume (verify size at execution time; if >1M rows, switch to batched backfill).

---

## (b) API contract

### B.1 Route

`PATCH /api/messages/:id` — author-only, returns the updated message envelope.

Decision D-2 (default): mounted under `/api/` to match Suite's API conventions. If `apps/platform/lib/platform_web/router.ex` shows messages already under a different prefix (e.g., `/v1/`), follow the existing prefix; verify at execution time.

### B.2 Request body

```json
{
  "content": "edited body text"
}
```

- `content`: required string, 1–10000 chars (matches existing send-message validation; verify at execution time).
- No partial / structured edits in v1 — text-content only. Edits to `structured_content`, `canvas_id`, or attachments are out of scope.

### B.3 Success response

`200 OK`, envelope:

```json
{
  "data": {
    "id": "01957a...",
    "content": "edited body text",
    "edited_at": "2026-05-11T16:50:00.000000Z",
    "versions_count": 2,
    "space_id": "...",
    "thread_id": null,
    "participant_id": "...",
    "author_display_name": "...",
    "author_avatar_url": null,
    "content_type": "text",
    "frozen_at": null,
    "frozen_by_participant_id": null,
    "corrects_message_id": null
  }
}
```

`versions_count` is derived from `chat_message_versions` row count for the message — UI uses it to decide whether to render the "(edited)" affix (`versions_count > 1`).

### B.4 Error responses — all wrapped in:

```json
{ "error": { "code": "string_code", "message": "human readable" } }
```

| Status | `error.code` | When |
|---|---|---|
| **401** | `unauthorized` | No session / invalid session. |
| **403** | `forbidden_not_author` | Authenticated but not the message author (Policy 3 also catches agent-self-edits with this code). |
| **404** | `not_found` | Message ID doesn't exist OR is `deleted_at != null`. |
| **409** | `frozen` | Message has `frozen_at != null`. Body includes `freezing_action` context (see B.5). |
| **422** | `validation_failed` | Body fails validation (empty content, too long, etc.). Body includes `errors` map. |

### B.5 409 payload — frozen response

```json
{
  "error": {
    "code": "frozen",
    "message": "An agent has begun work on this message — send a follow-up to revise.",
    "freezing_action": {
      "participant_id": "...",
      "participant_display_name": "Saru",
      "frozen_at": "2026-05-11T16:48:00.000000Z",
      "task_id": "...",          // nullable — present if task-scoped freeze
      "task_title": "..."         // nullable — present if task-scoped freeze
    }
  }
}
```

UI renders the `message` field in a toast or tooltip; `participant_display_name` and `task_title` go into the explanatory tooltip on the disabled pencil/Edit affordance.

### B.6 Idempotency

If the PATCH body's `content` is byte-identical to the current `chat_messages.content`, the controller short-circuits: returns `200 OK` with the existing envelope, does NOT insert a new `chat_message_versions` row, and does NOT broadcast `message.edited`. Lets the client safely retry on uncertain network state.

### B.7 Rate limit

10 edits per minute, per user, per message. Implementer chooses the backing store (Hammer is the typical Elixir choice but isn't currently a dep — Decision D-3: add Hammer OR a process-dictionary windowed counter; flag if a different solution is preferred). Excess returns `429 Too Many Requests` with envelope code `rate_limited`.

---

## (c) Realtime event

### C.1 Reuse the existing transport

`Platform.Chat.PubSub.space_topic(space_id)` → `"chat:space:#{space_id}"`. **Do NOT introduce a new topic.**

### C.2 Event tuple

```elixir
{:message_edited, %{
  message: %Platform.Chat.Message{},          # the post-edit message struct
  previous_content: "...",                    # the content that was just replaced
  version_number: 2,                          # the new version_number
  edited_by_participant_id: "...",
  removed_substrings: ["…"]                   # see C.3
}}
```

The existing PubSub doc (`pub_sub.ex:30`) shows the pattern: `{:event_atom, payload}` where payload is either a struct or a map. We use a map here because the edit-specific fields (previous content, version number, removed substrings) aren't on the `Message` struct.

### C.3 `removed_substrings` — diff payload for agent reaction

When a user's edit shortens the content, the diff is computed server-side and included so in-context agents can detect "the human just retracted text I had read." Algorithm:
1. Tokenize previous and new content into words (whitespace-split).
2. Compute longest common subsequence.
3. `removed_substrings` = contiguous spans of words present in previous but not new.

For non-shortening edits (typo fixes, additions): `removed_substrings: []`.

The intent is detection, not legal-grade diff — false positives are acceptable; false negatives (claiming nothing was removed when it was) are not.

### C.4 Routing — who receives `{:message_edited, _}`?

The broadcast goes to **everyone subscribed to the space topic**. Filtering for "agents in active context" (Policy 1) happens at the agent's own consumption layer, NOT at broadcast — because:
- Humans in the space should see the edit live regardless.
- Agent-side filtering needs access to the agent's task context, which the broadcast doesn't have.

Agents implementing the filter use the payload + their session state to decide whether `message.edited` is *for them* (Policy 1).

---

## (d) Render contract

The four UI affordances the contract pins:

### D.1 "(edited)" affix

Render when `versions_count > 1`. Position: inline next to timestamp. Style: subdued (text-base-content/60). Element: `<button>` with `aria-label="Show edit history"` — clicking opens D.2.

Required field on the rendered message: `versions_count :: integer` (server provides; UI reads).

### D.2 Version history popover

Lists prior versions, newest-first. Per row: body preview (max 2 lines, truncate with ellipsis), relative timestamp ("2 minutes ago" via existing `format_relative_time/1`). Container: `<.dropdown>` on desktop, `<.sheet>` on mobile (consistent with the Task 11 Stage 3 pattern).

Required data: `GET /api/messages/:id/versions` returning `{ "data": [%{version_number, content, edited_at, edited_by_participant_id, edited_by_display_name}, ...] }`. **Decision D-4:** this endpoint is in scope for Task 3 (alongside PATCH). Flag if implementer prefers to defer it to Task 6.

### D.3 Disabled edit affordance + frozen tooltip

When `frozen_at != null`:
- Render the Edit affordance with `opacity-50 cursor-not-allowed`, keep it focusable but `pointer-events-none` on click.
- Tooltip on hover/focus: `"An agent has begun work on this message — send a follow-up to revise."`
- If `frozen_by_participant_id` resolves to a known participant, append: `" (started by {participant_display_name})"`.

### D.4 "Correction to earlier message" header

When `corrects_message_id != null`:
- Render a header above the message body: small, subdued (`text-base-content/60`), with a chevron-up icon, text `"Correction to earlier message"`.
- The header is a `<button>` with `phx-click="scroll_to_message" phx-value-id={corrects_message_id}`. The handler scrolls the stream to the original and applies a 1.5s pulse highlight on it.

---

## (e) Permission model

| Actor | Target message | Allowed? |
|---|---|---|
| Human, message author | Own message, not frozen | Yes — Section b PATCH |
| Human, message author | Own message, frozen | No — 409 |
| Human, NOT author | Anyone else's message | No — 403 |
| Agent, message author | Own message | No — 403 (Policy 3; emit a correction instead) |
| Agent, NOT author | Any message | No — 403 |
| Admin (any) | Any message | No — there is no admin override path in v1 |

Enforcement is server-side in the PATCH controller. UI affordance visibility (hide the pencil from non-authors) is a separate concern in Section d / Render contract; the API must enforce regardless.

---

## (f) Agent interaction model — load-bearing

This is the highest-stakes section. Editing messages AI agents have already consumed has retroactive implications human-to-human chat editing does not.

### F.1 Policy 1 — Notification scope (narrow active context)

An agent receives `{:message_edited, _}` events for a given message ONLY if **at least one** of:
- The agent's participant ID was `@`-mentioned in the message at any version (current OR prior).
- The agent's participant ID is the assignee on a task whose `message_id` field references this message.

Agents subscribed to the space topic that don't satisfy either condition MUST ignore the event at their consumption layer. (They still receive the broadcast — see C.4 — but filter it out.)

Rationale: a passive agent listener shouldn't pivot on an edit it had no investment in. Limits the surprise blast radius of an edit, and limits agent CPU/tokens consumed by no-op reactions.

### F.2 Policy 2 — Edit immutability after agent action

A message becomes immutable (`frozen_at` set, future PATCH → 409) the first time an agent in its active context performs an action that's hard to roll back. Two definitions depending on whether the message is task-scoped:

**Task-scoped messages** (a message has `metadata.task_id` set, OR a task references this message via its `triggering_message_id` / equivalent FK — verify naming at execution time):

Freeze when the associated task transitions `planning` → `in_progress` OR `in_review` → `in_progress`.

Pre-freeze (still editable):
- `planning` status (agent is drafting a plan; reads, searches, file lookups)
- `in_review` status (plan submitted, awaiting human review)

Post-freeze (immutable):
- `in_progress` (agent began executing the plan)
- `deploying`, `done`, etc. (downstream of in_progress)

**Ad-hoc directives** (no associated task — e.g., a direct `@Saru fix this typo` with no formal task):

Freeze on the agent's first state-changing operation **outside its own session**. Operations that trigger freeze:
- File write (write/edit on the filesystem)
- Git commit, branch creation, push
- PR creation, comment, merge
- Canvas creation / patch / restore (visible artifact)
- External API mutation (any non-GET HTTP from a tool the agent invoked)
- Suite-side state changes: task_update, validation_evaluate, review_request_create, etc.

Operations that do NOT freeze (read-only / agent-internal):
- File read, grep, list, glob, find
- Web search / fetch (read-only)
- LLM calls (the agent thinking)
- Reading Suite state: task_get, plan_get, space_get_messages

### F.3 Policy 3 — Agent self-edits not allowed

PATCH `/api/messages/:id` returns 403 (`forbidden_not_author`) if the actor IS the agent author of the message — even though structurally the agent IS the author.

Why: an agent retroactively rewriting its own statement is indistinguishable from gaslighting. Agents correct via a NEW message with `corrects_message_id` set to the original. UI renders these per Section D.4.

The 403 (vs a different code) is deliberate: it's the SAME "you're not the author" error humans get, conceptually — the agent IS the author by DB row, but the contract says "agents are never the editing author of their own messages."

### F.4 Policy 4 — Sensitive-info removal warning + diff emit

When a user's edit shortens the content (Section C.3 detection):

1. The web/PWA editor displays a **pre-submit confirmation dialog** BEFORE firing PATCH:

   > **Edit removes text.**
   > Agents that already read this still have the original in their memory.
   >
   > `[Cancel]   [Edit anyway]`

2. On **Edit anyway**: PATCH fires normally; the broadcast `{:message_edited, %{removed_substrings: [...]}}` is emitted normally so in-context agents (Policy 1) can react.

3. On **Cancel**: PATCH does NOT fire. Editor stays open with the edited (but unsaved) content; user can revise or cancel out entirely.

The dialog is intentionally factual, not preachy. It states what's true about agent memory; it doesn't ask the user to reconsider editing.

### F.5 Behavior summary

| Scenario | Editable? | Status | Agent notified? |
|---|---|---|---|
| Human msg, no agent in active context | Yes | 200 | No (no agents to notify) |
| Human msg, agent mentioned but no action yet | Yes | 200 | Yes — `{:message_edited, _}` |
| Human msg, task-scoped, task in `planning` | Yes | 200 | Yes |
| Human msg, task-scoped, task in `in_review` | Yes | 200 | Yes |
| Human msg, task-scoped, task in `in_progress` | **No** | 409 + freezing_action | N/A (already executing) |
| Human ad-hoc directive, agent did file reads only | Yes | 200 | Yes |
| Human ad-hoc directive, agent wrote a file / made a PR | **No** | 409 + freezing_action | N/A |
| Agent's own message | **No** | 403 | N/A |
| Edit removes text — pre-confirm cancelled | n/a (no PATCH fired) | n/a | n/a |
| Edit removes text — pre-confirm accepted | Yes | 200 | Yes — incl. `removed_substrings` |

---

## Open decisions (need Marlowe / planner sign-off)

| ID | Decision | Default proposed | Owner |
|---|---|---|---|
| ~~D-1~~ | ~~`frozen_by_*` FK target — `chat_participants.id` (proposed) vs. a new `agent_actions` table (task description's wording)~~ | **DECIDED 2026-05-11 (Marlowe):** use `chat_participants.id` — no `agent_actions` table exists today and the participant is sufficient for audit. | ✓ Done |
| D-2 | API route prefix — `/api/messages/:id` (proposed) vs whatever existing convention `router.ex` shows | Verify at Task 3 execution and adopt the existing prefix | Task 3 implementer |
| D-3 | Rate-limit backing store — add Hammer dep, or DIY windowed counter, or use existing infra | Verify at Task 3 execution; flag if existing infra found | Task 3 implementer |
| D-4 | `GET /api/messages/:id/versions` endpoint — in Task 3 (proposed) or deferred to Task 6 | In Task 3 — keeps the edit + history scope together | Task 3 implementer |
| D-5 | The "agent in active context" check (Policy 1) — where in the agent runtime does this filter live? | TBD by agent-runtime team; this contract only pins the rule, not the impl location | Agent platform team |
| D-6 | "Ad-hoc directive" freeze trigger detection (Policy 2) — where does the runtime hook into tool-use to record the freeze event? | Suite MCP wrapper layer can intercept tool calls and emit a freeze record; alt is per-tool annotations | Agent platform team |

---

## Out of scope for this contract

- **Bulk edit / batch operations.** v1 is single-message.
- **Edit history visualization for canvas content.** Canvases have their own versioning (ADR 0036) — edits to canvas-content messages route to canvas versioning, not message edit history.
- **Edit notifications outside the space.** No email / push notification on edit.
- **Edit conflict resolution** (two clients editing same message simultaneously). The 409-on-frozen covers the agent-vs-human case. Two humans simultaneously editing their own message (same author across two devices) → last writer wins via the optimistic update path; UI surfaces the version-history popover to make the loss visible.
- **Audit log retention policy.** `chat_message_versions` rows are kept indefinitely in v1. Retention / archival is a separate concern.
