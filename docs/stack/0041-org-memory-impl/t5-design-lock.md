# T5 Design Lock — `memory_*` Tool Surface + V1 Retirement

ADR-0041 Org Memory V2. Task `019e41d9-f6e9-775c-b782-75e4d3c1e596`, Plan `019e45e5-4d7d-79cd-a1ed-c0012bac8b64`, Stack `019e41d9-2a31-7d1f-86dc-755e6934c8af` (`stack/0041-org-memory-impl`).

Recon ran against the T4 stack tip (`origin/task/019e41d9-cd7f-7f0d-b986-5cb5c7509ebc`, HEAD `de3eabe`) which includes T2 (Wiki domain) + T3 (Wiki.Indexer) + T4 (Wiki.Context preamble). This member branch is cut from `origin/main` per stack convention; the rollup reconciles at PR time.

---

## 1. Module locations (locked)

- `Platform.Org.Wiki.Routing` at `apps/platform/lib/platform/org/wiki/routing.ex` — pure path → policy mapping + write/read gate. No `Repo`, no I/O, no telemetry.
- `Platform.Org.Wiki.Search` at `apps/platform/lib/platform/org/wiki/search.ex` — RRF fusion over pages + journal + messages; ACL-aware hydration.
- Tool definitions + dispatch land in existing `Platform.Federation.ToolSurface` (no new top-level module — keeps the federation surface single-file per convention).
- One new public function on `Platform.Org.Wiki`: `rename_page/3` (baton-pass, mirrors how T3 added `page_id` to `:wiki_page_deleted`).

## 2. Path namespace → routing policy table (canonical, no re-litigation downstream)

| File-key prefix                              | Write policy            | Read policy |
| -------------------------------------------- | ----------------------- | ----------- |
| `org/page/...`                               | `:historian`            | `:anyone`   |
| `org/journal/<YYYY-MM-DD>.md`                | `:anyone` (append-only) | `:anyone`   |
| `project/<uuid>/page/...`                    | `:historian`            | `:anyone`   |
| `project/<uuid>/journal/<YYYY-MM-DD>.md`     | `:anyone` (append-only) | `:anyone`   |
| `space/<uuid>/page/...`                      | `:historian`            | `:anyone`   |
| `space/<uuid>/journal/<YYYY-MM-DD>.md`       | `:anyone` (append-only) | `:anyone`   |
| `space/<uuid>/private/<agent_id>/...`        | `:owner` (== agent.id)  | `:owner`    |
| _anything else_                              | `:rejected`             | `:rejected` |

Journal-row keys are recognised via `Platform.Org.Wiki.Journal.parse_virtual_path/1` (T2-stable). `memory_create` is the only legal entry-point against a `*/journal/...` key; `memory_str_replace` / `memory_insert` / `memory_delete` / `memory_rename` against a journal path return `{:error, :journal_immutable}` — the Wiki.Journal contract is append-only.

UUID validation on the `<uuid>` slot uses `Ecto.UUID.cast/1`. A malformed UUID slot falls through to `:unknown_namespace`.

The terminal `*` catch-all is `:rejected`, not silent-org — keeps the prefix list honest.

## 3. Historian predicate (locked for T5, swappable in T6)

```elixir
def historian?(%Platform.Agents.Agent{system_events: events}) when is_list(events),
  do: "daily_summary" in events
def historian?(_), do: false
```

**Why this works pre-T6:** `Platform.Agents.Agent.@valid_system_events == ~w(daily_summary dreaming)`. `SystemEventScheduler` already filters Historian-role dispatch on `"daily_summary" in agent.system_events`. This is the only stable Historian signal currently on the schema; T6 may layer a richer role model, but the public call site (`Routing.historian?/1`) stays the same — T6 swaps the implementation in one place.

**Verbatim error string for non-Historian write to a page path** (load-bearing — clients parse it):

```
This path requires the Historian role. Propose the change via a journal entry instead — memory_create at <namespace>/journal/<YYYY-MM-DD>.md.
```

## 4. Owner-of-private check

`space/<id>/private/<rest>`:

- If an existing `WikiPage` row exists: accepted iff `agent.id == page.updated_by`.
- If no row yet: accepted iff path matches `space/<space_id>/private/<agent_id>/...` AND `agent_id == agent.id` AND `agent` is a participant of `<space_id>` (`Platform.Chat.list_spaces_for_agent/2` — confirmed live at `apps/platform/lib/platform/chat.ex:148`).

Reads use the same gate. Error code `:not_owner`, `recoverable: true`.

## 5. Stage-3 public API surface (locked function signatures)

New on `Platform.Org.Wiki.Routing`:

```elixir
@type role :: :anyone | :historian | :owner | :rejected
@type classification :: %{
        kind: :page | :journal | :private | :unknown,
        write_role: role(),
        read_role: role(),
        namespace: String.t() | nil,   # "org" | "project/<id>" | "space/<id>" | nil
        journal_date: Date.t() | nil   # set only when kind == :journal
      }

@spec classify(String.t()) :: classification()
@spec historian?(Platform.Agents.Agent.t() | nil) :: boolean()

@spec gate_write(Platform.Agents.Agent.t() | nil, String.t(), keyword()) ::
        :ok | {:error, %{code: atom(), message: String.t(), suggestion: String.t(), recoverable: boolean()}}

@spec gate_read(Platform.Agents.Agent.t() | nil, String.t()) ::
        :ok | {:error, %{code: atom(), message: String.t(), suggestion: String.t(), recoverable: boolean()}}
```

`gate_write/3` opts:
- `:existing_page` — preloaded `%WikiPage{}` for owner check (avoids second DB hit).
- `:agent_id` — string fallback if `agent` is `nil` but caller has only the id; gate then loads agent via `Platform.Agents.get_agent/1`.

New on `Platform.Org.Wiki` (baton-pass extension to T2's surface):

```elixir
@spec rename_page(String.t(), String.t(), keyword()) ::
        {:ok, WikiPage.t()} | {:error, :not_found | :stale | :ambiguous_kind | Ecto.Changeset.t()}
# Implementation: Repo.transaction { upsert_page(new_path, content+updated_by), delete_page(old_path) }.
# Caller (memory_rename in ToolSurface) is responsible for the cross-path gate_write check before invoking.
```

`Wiki.rename_page/3` is the ONLY net-new public function added to a T2 module. T2's stage-5 scope-creep guard pins `wiki.ex` via sha256 — T3 set the precedent by extending the `:wiki_page_deleted` payload with `page_id` and adjusting the guard; T5 follows that pattern. Recompute the guard digest in T5 stage 5.

New on `Platform.Org.Wiki.Search`:

```elixir
@type corpus :: :page | :journal | :message
@type hit :: %{
        source: String.t(),         # "page" | "journal" | "message"
        id: String.t(),
        path: String.t() | nil,     # file_key for page/journal, nil for message
        space_id: String.t() | nil, # message only
        content: String.t(),
        score: float(),             # RRF score
        semantic_rank: pos_integer() | nil,
        lexical_rank: pos_integer() | nil,
        authored_by: String.t() | nil,
        date_or_inserted_at: String.t()
      }

@spec search(query :: String.t(), agent :: Platform.Agents.Agent.t() | nil, opts :: keyword()) ::
        {:ok, %{results: [hit()], fusion_constant_k: 60, truncated: boolean()}} | {:error, term()}
```

`search/3` opts: `:source` (filter to one corpus), `:namespace` (prefix filter for page/journal), `:since` (`Date.t()` lower bound for date-keyed corpora), `:limit` (default 20, max 100), `:workspace_id`.

## 6. memory_search fusion (locked: RRF, k=60)

Reciprocal Rank Fusion, the BM25-paper standard:

```
score(d) = Σ over channels c where d appears of  1 / (k + rank_c(d))
k = 60
```

Channels:

1. **Semantic (single channel across all corpora)** — `Platform.Memory.search(query, opts)` returns `[%{entry_id, score}]`. Provider scores ordered desc; take top `2*limit`. Each hit is tagged by corpus after hydration (since memory-service stores `memory_type` per the T3 indexer payload: `"page"` | `"journal"`; messages are not in memory-service — semantic doesn't cover them in T5).
2. **Lexical pages** — Postgres `ilike '%query%'` on `org_wiki_pages.content` (no tsvector; see §8). Take top `2*limit` ordered by `inserted_at desc`.
3. **Lexical journal** — Postgres `ilike` on `org_wiki_journal_entries.content`. Take top `2*limit` ordered by `inserted_at desc`.
4. **Lexical messages** — `Platform.Chat.search_messages/3` per accessible space (see ACL §7). Take top `2*limit` per-channel, union, then re-truncate to `2*limit`.

Tie-break: lexical rank (lower rank wins) → `inserted_at desc`.

`truncated: true` if ANY channel hit its `2*limit` cap.

**Equal-weight RRF — no per-channel weight knobs in v1.** Both semantic and lexical produce partial signals; the BM25-paper k=60 is the documented sweet spot. Future telemetry can inform weighting in a follow-up; not in scope for T5.

## 7. Hydration policy

Memory-service returns ids; hydrate via `WikiPage`/`WikiJournalEntry`/`Message` lookups.

- **Orphan ids** (deleted between embed and query) — dropped silently.
- **Message ACL** — filter `message` hits to the spaces the caller agent participates in (`Chat.list_spaces_for_agent(agent.id)`). Drop silently if outside the allow-set. NOT reflected in result envelope (would leak existence of restricted content).
- **Page/journal ACL** — pages/journal entries are gated by the `Routing.gate_read/2` policy after hydration. Public namespaces pass; private hits filtered to the owner-agent only.

## 8. tsvector migration verdict: **NOT NEEDED FOR T5**

Recon checked T4 HEAD migrations (`apps/platform/priv/repo/migrations/`) and the schemas at `apps/platform/lib/platform/org/wiki_page.ex` + `wiki_journal_entry.ex`. Neither has a `search_vector` column. Only `chat_messages` has one (generated column via migration `20260314080000_create_chat_tables.exs:106`).

**Decision: skip the tsvector migration for T5.** Lexical pages/journal use `ilike '%query%'` against `content`. Reasons:

1. Page corpus is small (low hundreds of curated pages — preamble lives here).
2. Journal entries are date-keyed; the `since:` filter prunes the row set hard before `ilike`.
3. The dominant search axis is semantic (memory-service), which the T3 indexer already feeds for both corpora.
4. A tsvector migration is a separate, mechanical follow-up (a `force_update`-style migration + schema column + generated expression) — easy to ship as a tightening pass in a later task once we have telemetry on lexical recall.

If telemetry from stage 4 e2e tests shows `ilike` is too leaky on multi-word queries, the migration adds one column + one index + a `to_tsquery` swap in `Search.lexical_pages/2`. Low-risk follow-up. **T5 does not write that migration.**

## 9. Capability broadcast — no engine change

`PlatformWeb.Channels.RuntimeChannel.handle_info(:send_capabilities, ...)` already calls `ToolSurface.tool_definitions()` and pushes to runtimes on connect (verified at the T4 tip). Re-registering the `memory_*` tools under the renamed `memory` bundle in `@bundles` means every federated reconnect picks up the new surface for free. e2e Case D in stage 6 confirms.

## 10. V1 retirement — caller-site checklist (stage 5)

Delete from `apps/platform/lib/platform/federation/tool_surface.ex` (line numbers from T4 HEAD):

- Private fn `org_context_tools/0` (lines ~235–410).
- `execute("org_context_read", …)` (line 4032).
- `execute("org_context_write", …)` (line 4060).
- `execute("org_context_list", …)` (line 4116).
- `execute("org_memory_append", …)` (line 4126).
- `execute("org_memory_search", …)` (line 4180).
- Private helpers: `search_with_memory_service/2`, `db_fallback_search/1`, `hydrate_scored_results/1`, `serialize_context_file/1`, `serialize_memory_entry/1` (line 4556).
- **Keep:** `inspect_errors_safe/1` — used by `react`, `review_request_create`, `project_update`, `plan_create`, `template_update` (5 other call sites verified at T4 HEAD lines 1744, 1790, 2229, 3619, 4000).
- **Keep:** `parse_date/1` and `parse_optional_date/1` — reused by `memory_search`'s `since` opt.

Rename in `@bundles`: `"org_context"` → `"memory"`. Update `tools_for_bundle("org_context")` → `tools_for_bundle("memory")`. Tag accordingly.

`allowed_bundles` migration (stage 5): per-runtime backfill — `UPDATE agent_runtimes SET allowed_bundles = array_append(array_remove(allowed_bundles, 'org_context'), 'memory') WHERE 'org_context' = ANY(allowed_bundles) AND NOT 'memory' = ANY(allowed_bundles)`. Mirrors `20260506203637_agent_runtime_skill_bundle.exs` pattern (not a global whitelist — direct array mutation per runtime row).

### Non-tool-surface caller sites to update

- `apps/platform/lib/platform/orchestration/prompt_templates.ex` — `## Writing to Org Memory` blocks reference `suite_org_memory_append` + `suite_org_context_write`. Rewrite to `suite_memory_create` (journal append) and `suite_memory_str_replace` (page edits), with the path-policy framing.
- `apps/platform/lib/platform/agents/system_event_scheduler.ex` lines 51–63 — Historian-role prompt cites `org_memory_append` / `org_memory_search` / `org_context_read` / `org_context_write`. Rewrite to `memory_create` / `memory_search` / `memory_view` / `memory_str_replace` with path-policy framing.
- `apps/platform/test/platform/federation/tool_surface_org_context_test.exs` — delete entirely (replaced by new `memory_tools_test.exs` in stage 3).
- `apps/platform/test/platform/agents/system_event_scheduler_test.exs` line 240 — flip the substring assertion to `memory_create`.
- `apps/platform/lib/platform/org/context.ex` line 299 doc comment references `org_memory_search` — update to `memory_search`.

**Out of T5 scope:** `Platform.Org.Context` module itself stays. T7 OrgMemoryLive will replace `OrgContextLive` callers; until then `Context.ex` remains for the UI. Deeper removal is a post-stack cleanup task.

## 11. Prompt-template refresh migration (stage 5)

Pattern T4 established: `priv/repo/migrations/<YYYYMMDDHHMMSS>_force_update_prompt_templates_memory_v2.exs` — idempotent re-seed of the two `dispatch.assigned` + `dispatch.in_progress` templates so deployments seeded pre-T5 pick up the new copy. Next-available timestamp at stage 5 dispatch time. One migration, no down (force-update pattern).

---

## Stage-by-stage map

| Stage | Module(s) touched | Validations |
| ----- | ----------------- | ----------- |
| 1     | this doc, empty `Routing` + `Search` stubs, failing-red routing_test.exs (no test_pass validation) | lint, type |
| 2     | `Routing` real impl + tests | lint, type, test |
| 3     | `ToolSurface` memory_* clauses + `Wiki.rename_page/3` + tests | lint, type, test |
| 4     | `Search` impl + `ToolSurface.execute("memory_search", …)` + tests | lint, type, test |
| 5     | V1 retirement: tool_surface deletes, bundle rename, prompt_template + system_event_scheduler updates, allowed_bundles migration, prompt-template refresh migration | lint, type, test |
| 6     | Task-level e2e_behavior — federation capability broadcast, search ACL, routing rejection messages | e2e |
| 7     | Scope-creep guards + task-level review evidence | manual_approval |

## Open contingencies

None outstanding. tsvector is resolved (skip). Historian predicate is resolved (`"daily_summary" in agent.system_events`). Capability broadcast is no-engine-work. The only forward-looking risk is the T2 scope-creep guard sha256 — stage 5 must recompute it when `Wiki.rename_page/3` lands.
