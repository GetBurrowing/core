---
name: meeting-triage-officer
description: How the triage-officer runtime consumes a scribe-completion canvas and files tasks — parse conventions for the `checklist_item.note` JSON, the `String.jaro_distance/2` project-resolution threshold, `principal_search`-based assignee inference, priority parsing, and the idempotency contract with `Platform.Meetings.Triage.file_tasks_from_canvas/2`.
---

# Meeting Triage Officer

You are the triage officer converting a meeting's scribe-completion canvas
into concrete tasks. The `dispatch.triage_dispatch` runtime prompt tells
you *what to do*; this skill pins the *conventions* — the JSON shape,
the matching threshold, the assignee-inference rules, and the
idempotency contract — so every triage pass produces the same shape.

## 1. Signal shape

The `meeting_triage_dispatch` attention signal (broadcast by
`Platform.Federation.dispatch_triage_attention/2`) carries four ids in
its payload:

- `space_id` — the chat space the meeting lives in.
- `room_id` — the meeting room the transcript belongs to.
- `transcript_id` — the source transcript feeding this triage pass.
- `canvas_id` — the scribe-completion canvas whose contents you consume.

The canvas the scribe posts has a `checklist` section titled `actions`.
Its children are `checklist_item` nodes — one per candidate task the
scribe surfaced from the transcript. Everything you file comes from
walking those `checklist_item` children.

## 2. Parse conventions

Each `checklist_item` carries two fields you read:

- `checklist_item.label` — the human-readable action string. This
  becomes the filed task's title verbatim (Triage may normalise
  trailing punctuation but does not rewrite the label).
- `checklist_item.note` — a JSON blob with keys:
  - `owner` — string, e.g. `"@dev"` or `"@nobody_matches"`. May be `nil`.
  - `project_hint` — string, e.g. `"Widgets Platform"`. May be `nil`.
  - `priority` — one of `"high" | "medium" | "low"`. May be missing.
  - `due_hint` — free-text like `"this week"` or `"next sprint"`. May
    be `nil`.
  - `source_transcript_id` — UUID of the transcript that surfaced
    this action.

Parse with `Jason.decode/1`. Fallback rules on malformed JSON — do
NOT crash, degrade gracefully:

- Whole `note` string is not JSON → treat the entire string as a
  free-text description; leave `owner`, `project_hint`, `due_hint`,
  `source_transcript_id` as `nil`; default `priority` to `"medium"`.
- Key is missing from a valid JSON object → treat that individual key
  as `nil` (or its default, for `priority`).
- `source_transcript_id` missing → fall back to the dispatch's
  `transcript_id` (the outer attention-signal value).

## 3. Project resolution

For each parsed item:

1. Call `project_list` to fetch every project the actor can see.
2. Score each project's `name` against the parsed `project_hint`
   using `String.jaro_distance/2`.
3. If the highest score is `>= 0.85`, accept that project as the
   target and mark the row's status `filed`.
4. Otherwise fall back to the project that owns the source canvas's
   space (resolve via `space_id → project_id`). Mark that row's
   status `fallback_project` so the summary card distinguishes it
   from a jaro-matched `filed` row.
5. If `project_hint` is `nil`, skip step 2–3 and go straight to the
   fallback branch.

The `0.85` threshold is deliberately tight enough to reject
`"Widgets Platform"` vs `"unknown_gibberish_xyz"` (score ≈ 0.4) and
accept `"Widgets Platform"` vs `"widgets-platform"` (score ≈ 0.9).
Do not soften it without a corresponding change to
`dispatch.triage_dispatch`.

## 4. Assignee inference

Resolve `owner` mentions through the `principal_search` MCP tool:

- A well-formed `@handle` string (leading `@`, then a handle) →
  call `principal_search` with the handle.
- Exactly one hit → take that principal's `agent_id` as the task's
  `assignee_id`.
- Zero hits, multiple ambiguous hits, or a malformed `owner` string
  → return `nil`. Let the runtime fall through to the task's
  `phase_assignee` (the project's or epic's default). Do NOT guess.

Do not invent assignees. Do not fuzzy-match handles. Explicit or
absent — nothing in between.

## 5. Priority parsing + idempotency

Priority map (`high|medium|low`, case-insensitive on the JSON string):

- `"high"` → `high`
- `"medium"` → `medium`
- `"low"` → `low`
- anything else (unrecognised string, missing key, `nil`) → `medium`

### Idempotency contract

Do NOT dedup yourself. `Platform.Meetings.Triage.file_tasks_from_canvas/2`
calls `Platform.Tasks.similar_open_titles/3` internally (from stack
member E) and returns a per-item verdict:

- `{:filed, task_id}` — new task inserted; put in the summary row as
  `status: filed`.
- `{:skipped_dupe, existing_task_id}` — an open task with a
  near-identical title already exists; put in the summary row as
  `status: skipped_dupe` and reflect the pre-existing `task_id`,
  NOT a new one.
- `{:fallback_project, task_id}` — filed against the fallback
  project (see section 3); put in the summary row as
  `status: fallback_project`.

Re-broadcasting the same `meeting_triage_dispatch` on the same
canvas must produce zero new tasks — every checklist_item's dedup
hit produces `skipped_dupe` on the second pass. Reflect that in the
summary card so an operator viewing the canvas after two passes can
see the second pass filed nothing.
