# T6 Design Lock — Historian + every-6h staggered cadence

_Stack `stack/0041-org-memory-impl` — Org Memory V2 — task `019e41da-1a48-7da4-adb4-9a63f8251c54`._

Stage 1 was auto-skipped by the engine (markdown-only, no enforced validation rows). This memo is committed as part of stage 2 so the rollup audit trail captures the design intent before code lands.

## Current shape (pre-T6, on `main`)

- `Platform.Agents.SystemEventScheduler` (`apps/platform/lib/platform/agents/system_event_scheduler.ex`) fires two fixed-hour events: `daily_summary` @ 23 UTC and `dreaming` @ 03 UTC, via `@default_events %{"daily_summary" => 23, "dreaming" => 3}`.
- `Platform.Agents.Agent.@valid_system_events` whitelist is `~w(daily_summary dreaming)`.
- Instruction copy lives in an in-module `@instruction_templates` literal map; `post_instruction/3` writes that text into the dispatched agent's system message.
- Wiki-write gating lives in `Platform.Org.Wiki.Routing.@historian_event` (T2/T3 work — not yet on `main` as of this stage's branch cut from `origin/main@1eb12c8`, but rollup-merged via the stack PR). The gate is keyed on the event name string.

## New `historian` event (replaces both legacy events)

T6 replaces `daily_summary` + `dreaming` with a single `historian` system event. Per Sloane's approval there is **no deprecation window** — legacy strings become invalid in one step. Lockstep changes (executed in later stages 3–6 of this stack):

- `SystemEventScheduler.@anchors = [0, 6, 12, 18]` (UTC hours). Stagger per workspace via `offset_minutes = :erlang.phash2(workspace_id, 360)` (0–359, uniform across the 6h window).
- `Agent.@valid_system_events = ~w(historian)`.
- `Wiki.Routing.@historian_event = "historian"`.
- `post_instruction/3` swaps from in-module literals to `PromptTemplates.render_template("historian.scheduled" | "historian.meeting_ended" | "historian.threshold", ...)`, with the literal default kept as fallback for empty DB.

## V1 fan-out: org-scope only

`Platform.Tasks.Projects.list_active_workspaces/0` returns `[nil]` for V1 (org-scope only). The stagger algorithm is real — it's structured so a one-line change ships true multi-tenancy when that's prioritised.

## 100k-token auto-trigger contract

Auto-trigger reads pending bytes from `org_historian_cursors` (T1 migration `20260519203825_create_org_historian_cursors.exs` — composite PK `(workspace_id, corpus)`, fields `last_processed_id :text`, `last_processed_at :utc_datetime_usec`, `last_run_at :utc_datetime_usec`).

- Cursor table is bound to `Platform.Agents.HistorianCursor` (this stage).
- Context module `Platform.Agents.Historian` (this stage) owns all writes; the scheduler stays a pure dispatcher.
- Threshold = **100_000 tokens** × 4 bytes/token = **400_000 bytes** pending across all four corpora (`"pages"`, `"journal"`, `"messages"`, `"transcripts"`).
- Token estimator = `byte_size(content) |> div(4)` — same char/4 heuristic as `Platform.Org.PreambleBuilder` (Anthropic/OpenAI publish ~4 chars/tok for English; cheap and good enough until a real tokenizer is wired).
- Debounce = no `last_run_at` within the last 60 minutes for ANY corpus in the workspace.

## `meeting_ended` handler

Stage 4: new GenServer `Platform.Agents.MeetingHistorianHandler` subscribes to each project's meetings PubSub topic at boot (and to a new `"meetings:projects"` topic for projects created after boot). On `{:meeting_ended, meeting}` it dispatches the Historian via `Platform.Agents.HistorianDispatcher` with metadata `%{trigger: "meeting_ended", meeting_id, project_id, chat_space_id}`.

## Prompt-template change set (stage 6)

- New entries in `do_default_templates/0`: `historian.scheduled`, `historian.meeting_ended`, `historian.threshold`.
- `dispatch.planning` / `dispatch.in_progress` get the journal-by-default rule explicitly: non-Historian agents edit pages by appending `<correction target="..." line="N">…</correction>` to today's journal; calling `memory_str_replace` / `memory_insert` against a page path returns `:historian_only`.
- Force-update migration mirroring `20260520010000_force_update_prompt_templates_memory_v2.exs`.

## Explicit non-scope

- No new MCP tools — T5 shipped the `memory_*` surface.
- No `_web/live/` touches.
- No `chat_messages.search_vector` changes.
- No embedding-pipeline edits.
- No journal/page schema additions (T6 is wiring + cursor schema only; page/journal schema work belongs to T2/T3).
- No LiveView.

## Char/4 heuristic — load-bearing convention

The `byte_size(content) |> div(4)` heuristic is the same one `Platform.Org.PreambleBuilder` uses for its 4096-token budget enforcement (see ORG_MEMORY.md → "Org Memory V2 — Preamble Policy"). Keeping the same estimator across the preamble and the historian threshold means both gates see the same workspace size in tokens. If/when a real tokenizer ships, both sites update together.

## Corpus source-of-truth (as of this stage)

Stage 2 binds the cursor table; corpus sources are read by `Platform.Agents.Historian.pending_bytes/1`. Stage-2 contract:

| Corpus key      | Table                       | Timestamp column     | Byte source                          |
|-----------------|-----------------------------|----------------------|--------------------------------------|
| `"pages"`       | `org_context_files`         | `updated_at`         | `byte_size(content)`                 |
| `"journal"`     | `org_memory_entries`        | `inserted_at`        | `byte_size(content)`                 |
| `"messages"`    | `chat_messages`             | `inserted_at`        | `byte_size(content)` (nil → 0)       |
| `"transcripts"` | `meeting_transcripts`       | `updated_at`         | `byte_size(summary) + segments size` |

Note the table names — the `org_wiki_*` rename from T2 hasn't shipped on `main` yet as of this stage's branch cut. The Historian binds to the names that exist on `origin/main@1eb12c8`. Later stages (or a follow-up) update the queries when the rename lands.

For `meeting_transcripts.segments` (jsonb array of `%{"speaker", "text", "ts", ...}` maps), byte size is approximated by serialising the array to JSON and taking its `byte_size` — close enough for the 4-bytes-per-token heuristic without round-tripping every segment row.

## Stage-2 deliverables (this stage)

1. `apps/platform/lib/platform/agents/historian_cursor.ex` — Ecto schema with composite PK `[:workspace_id, :corpus]`.
2. `apps/platform/lib/platform/agents/historian.ex` — context module with `pending_bytes/1`, `pending_tokens/1`, `last_run_at/1`, `mark_run_started/1`, `advance_cursor/4`.
3. `test/platform/agents/historian_test.exs` — five tests (empty workspace, sum-across-corpora, walk past cursor, mark_run_started idempotency, advance_cursor upsert).
4. This memo.
5. T1 migration `20260519203825_create_org_historian_cursors.exs` brought over from T5 tip `c0a3f9d` so the schema has a table to bind to.
