# ADR 0041 — Org Memory V2 — Wiki System

**Status:** Proposed
**Date:** 2026-05-14
**Author:** Sloane Scott / Clam
**Supersedes:** ADR-0033 (Org-Level Context Management)

---

## Context

ADR-0033 shipped an org-level context layer modeled after OpenClaw's per-agent file pattern, lifted to workspace scope: three named markdown files (`ORG_IDENTITY.md`, `ORG_MEMORY.md`, `ORG_AGENTS.md`) plus an append-only `org_memory_entries` log. The architecture works, but a fuller picture of the use cases has surfaced limitations:

1. **Flat namespace.** Everything is workspace-scoped. There is no channel-, project-, or DM-scoped memory, even though agents working on a specific project or channel need that scope.
2. **Push-only retrieval.** All three org files plus the last two days of journal entries are bundled at session start. This does not scale past three files; adding more makes the preamble unwieldy.
3. **No promotion lifecycle.** The dropped `memory_type` column hinted at a long-term store, but nothing currently graduates entries from `org_memory_entries` into curated long-term knowledge. `ORG_MEMORY.md` is the intended destination, but the path is manual.
4. **Document model only.** A growing org accumulates runbooks, playbooks, project decisions, and lessons learned. Three monolithic files cannot represent that without bloating.
5. **No retrieval over chat history.** Useful context lives in messages, including conversations between humans where no agent was present. Today that is invisible to agents unless a human re-types it as a memory entry.

This ADR replaces the flat-file model with a **namespaced wiki system** backed by Postgres, retaining the existing `org_context_files` table as the storage substrate.

---

## Decision

Adopt a wiki model for org memory. Pages live in a namespaced path tree (`org/`, `project/{id}/`, `space/{id}/`, `private/{owner_id}/`), cross-reference via `[[wikilinks]]`, and are stored in Postgres with an explicit links table. The Anthropic `memory_20250818` tool surface is exposed to agents for both reads and writes, with writes routed by path: agents write append-only to journal files; the **Historian** (dreaming agent) is the sole writer to wiki pages. A unified `memory_search` tool combines hybrid pgvector + tsvector search over pages, journal entries, and chat messages.

---

## Architecture

### Storage

The existing `org_context_files` table is the wiki backing store. Each page is one row.

**Extension to `org_context_files`:**

| Column         | Type              | Notes                                                    |
|----------------|-------------------|----------------------------------------------------------|
| id             | uuid v7           | PK                                                       |
| workspace_id   | uuid (nullable)   | Existing                                                 |
| file_key       | text              | Now a path-style key: `org/identity.md`, `project/{id}/decisions/migration-2026.md` |
| content        | text              | Markdown body, frontmatter included                      |
| version        | integer           | Existing — optimistic locking                            |
| updated_by     | uuid              | Existing                                                 |
| frontmatter    | jsonb             | **New.** Parsed frontmatter cached for query             |
| inserted_at    | utc_datetime_usec |                                                          |
| updated_at     | utc_datetime_usec |                                                          |

The `file_key` becomes the namespace path. No separate namespace column — the path is the namespace. This keeps the schema minimal and makes paths/aliases trivially comparable as strings.

**`org_memory_entries` retained** as the journal substrate. Same schema (id, workspace_id, date, content, authored_by, metadata, inserted_at). Stays append-only.

**New: `org_page_links`** — denormalized many-to-many for `[[wikilinks]]`.

| Column        | Type              | Notes                                              |
|---------------|-------------------|----------------------------------------------------|
| source_id     | uuid              | FK → `org_context_files(id)` ON DELETE CASCADE     |
| target_path   | text              | The literal `[[...]]` target                       |
| target_id     | uuid (nullable)   | Resolved page; null = dangling                     |
| display_text  | text (nullable)   | Optional `[[path\|alias]]` display                 |
| position      | integer           | Byte offset in source body                         |
| inserted_at   | utc_datetime_usec |                                                    |

Indexes on `(source_id)`, `(target_id)` for backlinks, `(target_path)` for rename resolution. No PK beyond `(source_id, position)`.

**New: `org_page_aliases`** — rename redirect table.

| Column      | Type              | Notes                                              |
|-------------|-------------------|----------------------------------------------------|
| old_path    | text              | PK                                                 |
| current_id  | uuid              | FK → `org_context_files(id)`                       |
| created_at  | utc_datetime_usec |                                                    |

When a page renames, its old path becomes an alias row. Link resolution checks `org_context_files` first, then `org_page_aliases`.

### Namespaces

Path prefixes are first-class scope identifiers:

| Prefix                  | Scope                                                         |
|-------------------------|---------------------------------------------------------------|
| `org/`                  | Workspace-wide. ORG_IDENTITY, ORG_AGENTS, org runbooks, etc.  |
| `project/{project_id}/` | A `Tasks.Project` scope                                       |
| `space/{space_id}/`     | A `Chat.Space` scope                                          |
| `private/{owner_id}/`   | Owner's private scratch. Only `owner_id` can write           |

`Tasks.Project` and `Chat.Space` namespaces are created lazily on first write (or eagerly at entity creation). Both coexist as separate prefixes — we do not collapse them. Some Spaces correspond to Projects and some do not; honoring both prefixes is simpler than forcing alignment.

**Access derives from existing membership:**
- An agent's accessible namespaces are: `org/*`, plus `project/{id}/*` for each Project it has access to, plus `space/{id}/*` for each Space it participates in, plus its own `private/{owner_id}/*`.
- Reads filter by accessible namespaces.
- Writes additionally check write permission per namespace (Historian writes pages everywhere; agents write journal everywhere they read, plus pages in their own `private/`).

### Tool Surface

Adopt Anthropic's `memory_20250818` tool protocol verbatim. The model already understands these six commands; we get free behavior without prompt engineering.

| Command       | Args                                            | Behavior                                       |
|---------------|-------------------------------------------------|------------------------------------------------|
| `view`        | `path`, optional `view_range`                   | List directory or read file (with line range)  |
| `create`      | `path`, `file_text`                             | Write file (overwrites)                        |
| `str_replace` | `path`, `old_str`, `new_str`                    | Edit by string match                           |
| `insert`      | `path`, `insert_line`, `insert_text`            | Insert at line                                 |
| `delete`      | `path`                                          | Remove file                                    |
| `rename`      | `old_path`, `new_path`                          | Move; creates alias row                        |

**Write routing** (the policy that gives us the single-writer property):

| Path pattern                | Agent permission                                              | Historian permission |
|-----------------------------|---------------------------------------------------------------|----------------------|
| Page (`*.md` outside journal) | Read-only. Write returns `read_only` error with guidance to journal | Full CRUD            |
| Journal (`*/journal/YYYY-MM-DD.md`) | Append-only via `insert`/`create`                       | Full CRUD            |
| `private/{owner_id}/*`     | Owner: full CRUD. Others: no access                            | Read-only            |

`str_replace` on pages by anyone other than the Historian is rejected. `create` of a brand-new page by an agent is also rejected outside `private/`. Agents proposing a new page write a journal entry tagged `proposed_page` and the Historian creates the page on its next pass.

**Concurrency:** because Historian is the sole writer of shared pages, `str_replace` races vanish in practice. Optimistic-locking via `version` (already on `org_context_files`) protects against the rare case of two Historian invocations overlapping (e.g., scheduled run colliding with a meeting-end trigger).

### Frontmatter

Pages carry optional YAML frontmatter. Common keys:

```yaml
---
preamble: true            # auto-injected at session start
type: person | project | runbook | decision | reference
status: active | superseded | draft
superseded_by: <path>     # if status=superseded
tags: [...]
---
```

Frontmatter is parsed on write and cached in the `frontmatter` jsonb column for fast filtering. The body remains canonical; the column is a denormalized index.

### Search

Hybrid retrieval over three corpora via the existing `Platform.Memory.Provider` behaviour:

1. **Pages** (`org_context_files`) — curated, weighted higher in default ranking.
2. **Journal entries** (`org_memory_entries`) — raw stream.
3. **Chat messages** (`messages`) — including agent-less conversations.

Each corpus indexed with both **pgvector** (semantic, HNSW) and **Postgres `tsvector`** (lexical). Result fusion via **Reciprocal Rank Fusion (RRF)** — standard, no special tuning needed at our scale.

**Tool surface:**

```
memory_search(
  query: string,
  source?: ["page", "journal", "message"],  # default: all
  namespace?: string,                        # e.g. "project/abc-123/"
  since?: timestamp,
  limit?: int (default 10)
) -> [
  {source, namespace, path_or_id, snippet, score, ...}
]
```

A single tool, fused results, source-tagged. Agents do not pick between surfaces; the system does.

### Preamble Policy

A page is auto-injected at session start if and only if `frontmatter.preamble == true` AND the page is in an accessible namespace for the session.

Constraints:

- **Hard token budget: 4096 tokens** of preamble total per session. Pages over budget are dropped in deterministic order (path lex order); a single page exceeding budget is truncated with an explicit marker.
- **Strong prompting** in any UI or tool that lets a page toggle `preamble: true`: warning shown that the page will be loaded by every agent every session, and to prefer leaving it `false` unless universally needed.
- **Scope-aware:** preamble is selected from the union of `org/`, the agent's accessible `project/{id}/`, and the agent's active `space/{id}/`. An agent dispatched to a project gets that project's preamble pages in addition to org preamble.

The canonical preamble set is small and curated:

- `org/identity.md` (`preamble: true`)
- `org/agents.md` (`preamble: true`)
- `org/_index.md` (the page index / table of contents, `preamble: true`)

Other pages default to `preamble: false`.

---

## Write Model

### Journal-first

Agents observe and write to journals. Journal entries are short, append-only, dated. They are the raw stream — observations, decisions made, things learned, things tried that failed, corrections to existing pages.

Path convention:

```
org/journal/2026-05-14.md           # workspace-level journal
project/abc-123/journal/2026-05-14.md
space/def-456/journal/2026-05-14.md
private/user-789/journal/2026-05-14.md
```

Agents `insert` into the dated file (or `create` it if absent). One file per day per namespace.

### Historian as sole page writer

The Historian (the dreaming agent role from ADR-0033) is the **only** participant with write access to wiki pages in shared namespaces. It:

- **Creates** new pages by synthesizing journal entries, messages, and existing pages.
- **Edits** existing pages by integrating new information.
- **Invalidates** pages by marking `status: superseded` in frontmatter (or by writing a successor page and linking back).
- **Renames** pages, creating alias rows automatically.

Single-writer-per-page is the principal property here. It gives us:

- A consistent voice across the wiki.
- No `str_replace` race conditions.
- A natural quality gate — not every agent observation deserves a page edit.
- Latency tradeoff: fresh learnings are not in pages until the next Historian pass, but they are in the journal and reachable via `memory_search`.

### Agent correction loop

When an agent reads a wiki page and observes contradictory information, it writes a journal entry tagged as a correction:

```yaml
---
type: correction
target: org/decisions/migration-2026.md
---

The page says we standardized on Postgres 15. As of 2026-05-10 the
migration to Postgres 16 has completed across all environments.
```

The Historian processes correction entries on its next pass and updates the target page.

### Provider neutrality

Non-Claude agents in Suite (other model providers) can still use the same tool surface — tools are just JSON. They will not have the trained behavior of always-list-on-start that Claude has. The orchestration prompt template for non-Claude agents will include explicit guidance equivalent to Anthropic's system prompt nudge.

---

## Dreaming (Historian)

### Schedule

- **Every 6 hours**, staggered per workspace (workspace UUID mod 6h offset).
- Existing single-historian-per-workspace constraint preserved.
- No-op-if-nothing-new guard: Historian checks high-water marks first and exits early if no new content.

### Triggers

In addition to the scheduled cadence, the Historian fires on:

1. **`meeting_ended` system event** — emitted by `meeting-transcriber` when a meeting transcript is finalized. Dispatch is scoped to the meeting's transcript and relevant project/space pages. Practical: meeting decisions land in the wiki within minutes, not 6 hours.
2. **Unprocessed token threshold (~100k)** — when the sum of unprocessed journal entries + new messages + new transcripts in a workspace exceeds ~100k tokens, fire an immediate Historian pass. Acts as backpressure. Debounced: do not fire if a Historian pass ran in the last hour, even if threshold exceeded.

### Incremental processing

A new table tracks Historian high-water marks per (workspace, corpus):

**`org_historian_cursors`:**

| Column           | Type              | Notes                                              |
|------------------|-------------------|----------------------------------------------------|
| workspace_id     | uuid              | PK component                                       |
| corpus           | text              | PK component: `journal`, `message`, `transcript`   |
| last_processed_id| text              | UUID or bigserial as text; corpus-defined          |
| last_processed_at| utc_datetime_usec |                                                    |
| last_run_at      | utc_datetime_usec |                                                    |

Historian's first step every pass: fetch new content since `last_processed_id` per corpus. On success, advance cursors atomically.

### Reads from Chat

Historian reads from `messages` directly via the existing Chat domain — no mirroring. The wiki is the *synthesis*, not the *archive*. The source of truth for chat history remains in Chat; the wiki references messages by ID when citing them.

Privacy: Historian is workspace-scoped and follows the same membership rules as any agent. Private spaces and DMs are excluded unless explicitly granted.

---

## UI — `OrgMemoryLive`

The existing `OrgContextLive` LiveView is renamed to `OrgMemoryLive` (route, module, label, sidebar entry). A redirect from the old route is kept until users migrate.

### Layout

A three-pane layout:

- **Left rail (namespace tree).** Expandable tree of namespaces. `org/`, `project/`, `space/`, `private/{me}/`. Each node expands to show pages and sub-namespaces. Page count badge per namespace. Pages flagged `preamble: true` get a small badge.
- **Main pane (page view).** Renders the markdown page. Frontmatter shown collapsed at top. `[[wikilinks]]` rendered as clickable links; dangling links shown in red with a tooltip ("page does not exist"). Code blocks, tables, etc. via the existing markdown renderer.
- **Right rail (metadata).** For the currently-open page:
  - **Backlinks** — pages that link to this one (single query against `org_page_links` by `target_id`).
  - **Version history** — last N versions with author and timestamp.
  - **Frontmatter editor** — structured form for `preamble`, `type`, `status`, etc.

### Tabs

Top-of-page tabs switch between modes within the same workspace:

1. **Pages** — the wiki view as described above.
2. **Journal** — append-only journal entries, grouped by date and namespace. Same UI as the existing Memory Feed tab, extended with namespace filter.
3. **Search** — single search input that queries the unified `memory_search` over pages + journal + messages. Results listed with source type, namespace, snippet, and score.
4. **Graph** *(future, optional)* — link graph visualization. Not in v2 initial scope.

### Edit affordances

- **Pages, agents:** read-only (the Historian is the sole writer).
- **Pages, humans:** editable. Humans are first-class above agents and can override the Historian. An edit by a human shows in version history as `updated_by: <user>`; the next Historian pass treats human edits as authoritative and synthesizes around them.
- **Journal:** append-only via UI for both humans and agents. A "New journal entry" form on the Journal tab.

### Rename notes

- LiveView module: `Platform.PlatformWeb.OrgContextLive` → `Platform.PlatformWeb.OrgMemoryLive`.
- Route: `/org_context` → `/org_memory`. Add a redirect from the old route.
- Sidebar label: "Org Context" → "Org Memory".
- Test files: rename to match.

---

## Use Cases Satisfied

Mapped to the five use cases that motivated this ADR:

1. **Agent on a channel's project needs other agents' learnings on that channel.**
   Search and read pages under `space/{space_id}/` and `project/{project_id}/`. Channel-scoped pages exist as a first-class concept rather than buried in a flat workspace bucket.

2. **DM with an agent → agent pulls past-project + org context.**
   `memory_search` across `org/` and any `project/` the participants share. Preamble loads `org/identity.md` and `org/agents.md` for baseline org awareness.

3. **Agent on a task needs context from outside the current project at org level.**
   `org/` namespace is always accessible. `memory_search` defaults to all accessible namespaces.

4. **All agents get a basic preamble of org identity / org agents directive.**
   `preamble: true` frontmatter on `org/identity.md` and `org/agents.md`. Auto-injected at session start. Hard 4k token budget prevents bloat.

5. **Agents can search over all transcripts and chats (public) via similarity search.**
   `memory_search(source: ["message"])` over the `messages` table. Membership rules enforce the public boundary; private spaces excluded unless explicit grant.

Additional use cases added during design:

- **Negative memory.** Agents flag failed approaches via journal entries; Historian synthesizes "Lessons Learned" pages.
- **Runbooks.** First-class as pages with `type: runbook`.
- **People routing.** Person pages (`org/people/<slug>.md`) with frontmatter for role, team, contact preferences.

---

## Alternatives Considered

### Atomic facts + graph (Mem0 / Zep)

Mem0 (open source, May 2025 paper, ~26% LOCOMO accuracy gain over OpenAI's hosted memory) and Zep / Graphiti (Jan 2025 paper, bi-temporal validity) lead the public benchmark conversation on agent memory. Their model: shred conversations into atomic facts, store as graph edges with temporal validity, supersede on conflict.

Rejected because:
- LOCOMO is point-recall-biased by construction; our use cases are 90% narrative (runbooks, decisions, lessons, identity).
- Suite's value proposition is humans and agents in the same conversation. Humans read prose, not triples.
- The shops building agent products for humans (Anthropic, Cursor, Devin) all bet prose; the shops building agent infra for other agents bet facts. We are the former.
- Implementation cost is materially higher (fact extraction pipeline, graph storage, conflict resolution policy).

A **light hybrid** (prose primary + optional frontmatter for structured attributes) is retained — it gives us machine-readable structure where it helps without building an extraction pipeline.

### Wiki per project

A separate wiki per project (each project gets its own namespace, search index, ACL surface).

Rejected because:
- Cross-project links are lost or forced to duplicate.
- Org-level content (identity, agents directive) has to be duplicated into every project wiki or projects inherit nothing.
- Infrastructure cost (per-wiki provisioning, indexes, ACLs) is substantially higher.

Single wiki with namespace prefixes achieves project isolation through filtering, not separate storage.

### Full hybrid with fact extraction sidecar

Pages canonical, plus an automatic LLM-driven extraction pipeline producing atomic facts in a sidecar table for fast mechanical queries.

Rejected because:
- Doubles implementation surface for marginal benefit at our scale.
- Two write paths and two read paths create truth-divergence risk (page says X, extracted fact says Y).
- Schema for facts is an open-ended modeling problem we do not have to take on.

Light frontmatter approach captures the win without the cost.

---

## Migration V1 → V2

Incremental. V1 data is preserved.

### Data migration

- Existing `org_context_files` rows migrate by **path-prefixing the `file_key`**: `ORG_IDENTITY.md` → `org/identity.md`, `ORG_MEMORY.md` → `org/memory.md`, `ORG_AGENTS.md` → `org/agents.md`. A migration script renames keys and adds `org_page_aliases` entries so any external references keep resolving.
- Existing `org_memory_entries` rows migrate unchanged. They become journal entries under `org/journal/{date}.md` virtually (the file_key for journal pages is derived from date; entries are aggregated by `Platform.Org.Context.build_context/1` extended to render `org/journal/...` paths from the entries table).
- New tables: `org_page_links`, `org_page_aliases`, `org_historian_cursors`. Empty on migrate; populated lazily.
- New column: `org_context_files.frontmatter jsonb`. Backfilled by parsing existing content; new writes populate on save.

### Tool migration

- Existing tools (`org_context_read`, `org_context_write`, `org_context_list`, `org_memory_append`, `org_memory_search`) remain available with adapters.
- New tool surface (`memory_20250818` protocol + `memory_search`) added alongside. New agents preferentially get the new tools.
- Phase-out window: V1 tools deprecated 30 days after V2 ships, removed 60 days after.

### Build-context migration

`Platform.Org.Context.build_context/1` is refactored:
- Old behavior: returns map of `file_key => content` for all `org_context_files` plus `ORG_NOTES-YYYY-MM-DD` for last 2 days of memory entries.
- New behavior: returns map of `path => content` for all `preamble: true` pages in accessible namespaces, subject to the 4k token budget. Journal is NOT in the preamble — agents reach it via tools.
- This is a behavior change agents will notice. The orchestration prompt template is updated to instruct agents to call `view org/_index.md` early in any session to discover pages.

### UI migration

- `OrgContextLive` → `OrgMemoryLive` happens in one commit.
- Old `/org_context` route returns a 301 to `/org_memory` for one release cycle, then is removed.

---

## Open Questions

1. **User-scoping** — agents accumulate facts about specific people ("Sloane prefers worktrees"). Currently parked: agents record people facts in `org/people/{slug}.md` or `project/{id}/people/{slug}.md`. Revisit if cross-project person memory becomes a recurring pain.
2. **Stale page detection** — if a page's underlying facts change and no one writes a correction, the page silently goes stale. Possible mitigation: Historian periodically re-reads pages and flags low-confidence candidates for refresh. Not in v2 initial scope.
3. **Preamble token-budget overflow policy** — currently truncates by lex order. May want a priority field on preamble pages instead. Defer until we have overflow in practice.
4. **Non-Claude agent behavior** — same tool surface, but without trained `list-then-read` instinct. Orchestration prompt template carries explicit guidance for non-Claude providers. Effectiveness to be measured.
5. **Bi-temporal validity** — Zep's `valid_from`/`valid_to` model is appealing for queries like "what did we believe about X 30 days ago." Not in v2 — page versions plus `status: superseded` frontmatter give us a coarser version of the same property. Revisit if temporal queries become a recurring need.
6. **Federated wikis** — multi-workspace orgs may want shared wiki content across workspaces. Out of scope for v2; in scope for any future multi-tenant work.

---

## Related

- ADR-0033 — Org-Level Context Management (V1, superseded by this ADR)
- ADR-0030 — Meetings / LiveKit Voice + Video (provides the `meeting_ended` trigger)
- ADR-0036 — Meeting Summary Agent Entity (interacts with the meeting-end Historian trigger)
- ADR-0040 — Federated Agent Owner Identity (informs the agent identity that authors journal entries)
