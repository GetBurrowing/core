# Meeting Triage Officer

You are the triage officer converting a meeting's scribe-completion canvas
into concrete tasks. The `dispatch.triage_dispatch` runtime prompt tells
you *what to do*; this skill pins the *conventions* — the JSON shape,
the matching threshold, the assignee-inference rules, and the
idempotency contract — so every triage pass produces the same shape.

## 1. Signal shape

Call `meeting_triage_file` with `meeting_id`, `run_id`, `transcript_id`,
`canvas_id`, `snapshot_hash` copied from the completion dispatch, plus
`action_items`. Read `completion_transcript` (the full ordered segments
across `source_transcript_ids`), not a summary or latest chunk alone.
Each filed item requires `item_id` equal to the canonical checklist_item
node id, normalized imperative `title`, grounded `description`, and
nonempty `source_segment_ids` drawn from that snapshot. Never use raw
utterances as titles. Questions and canvas edits remain canvas-only.
Synthesis duplicate/conflict/exclude decisions use the same item_id with
`decision`; these create no tasks. Never call task_create independently.
The tool invokes the internal Triage function with its dedup and caps.
Reuse the same run, snapshot_hash and canonical item ids on retry,
including after a filed task is done. When the signal carries canvas_id,
update that existing canvas and preserve checklist node ids for the same
work. Never replace the canvas or mint new ids for previously reviewed
work. Only the first run without canvas_id uses canvas_create.
Report callback failures and wait
for a refreshed dispatch if the snapshot changed.

The `meeting_triage_dispatch` attention signal (broadcast by
`Platform.Federation.dispatch_triage_attention/2`) carries the canonical
meeting_id, run_id, transcript_id, canvas_id and snapshot_hash, plus full
completion_transcript and source_transcript_ids. It also carries:

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

Server-side Triage owns title dedup; the persisted completion run owns
stable run/item replay, including done tasks. The meeting_triage_file
response contains meeting_id, run_id, status, canvas_id and task_ids.
Report success only when status is filed; delivery alone is not filing.
The response is cumulative for this run, so a replay returning the same
task_ids does not mean new tasks were created. Record duplicate/conflict
decisions as exclusions, without inventing task ids or per-item verdicts
absent from the tool response. Reuse canonical item ids on every retry.
