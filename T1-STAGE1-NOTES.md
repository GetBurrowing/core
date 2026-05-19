# T1 Stage 1 — Cherry-pick decision + recon notes

**Task:** `019e41d9-69bc-7245-94c0-ebd3fa6e0646` — Setup + Schema migration
**Stack:** `019e41d9-2a31-7d1f-86dc-755e6934c8af` (`0041-org-memory-impl`)
**Plan:** `019e41e0-0ccf-7f3f-9d49-f3abdd456804` (approved)
**ADR:** `docs/decisions/0041-org-memory-v2-wiki-system.md`

## Cherry-pick decision

Source branch: `origin/task/019e2d6e-f3e7-701b-8ab6-51e2fecb1b58` (old P1 of the abandoned ADR-0041 stack).

| SHA | Commit | Decision | Rationale |
|-----|--------|----------|-----------|
| `8774497` | P1 stages 2+4: rename org_context tables and schemas to org_wiki | **TAKE** (stage 2 of this task) | Clean rename: migration `20260515224500_rename_org_context_to_org_wiki.exs` renames tables (`org_context_files` → `org_wiki_pages`, `org_memory_entries` → `org_wiki_journal_entries`) with index renames; module renames (`Platform.Org.ContextFile` → `Platform.Org.WikiPage`, `Platform.Org.MemoryEntry` → `Platform.Org.WikiJournalEntry`); alias updates in `Platform.Org.Context`, `Platform.Memory`, `Platform.Memory.TelemetryHandler`, `Platform.Org.Seeds`; test fixture renames. Reusable as-is. |
| `6a637aa` | P1 stage 3: create org_wiki_links and org_wiki_aliases tables | **TAKE** (stage 3 of this task) | Clean isolated migration `20260516013500_create_org_wiki_links_and_aliases.exs`. Single-file diff, no schema modules created (the migration's moduledoc defers them to "Phase 2 / T2"). Reusable as-is. |
| `94d60b7` | P1 stage 4: add missing @impl true annotations in canvas kinds | **DROP** | Unrelated canvas drift (`@impl true` on `Platform.Chat.Canvas.Kinds.{Embed,Image}`). Confirmed both file paths exist on current `origin/main` at `cb6b9f2`. Whether they still need the annotation is a separate question; not part of org-memory work. |

### SHA verification

Confirmed via `git show --stat`:

- `8774497` diff stat matches dispatch description exactly (12 files: `memory.ex`, `telemetry_handler.ex`, `org/context.ex`, `org/seeds.ex`, two schema renames via `git mv`, the rename migration, four test files).
- `6a637aa` is a single 65-line migration file.
- `94d60b7` is a 6-line change to two canvas kind files — no hidden drift.

No surprises on inspection.

## Adapter changes on top of cherry-picks

These are the T1-only deltas the new task layers on top of the two cherry-picks. Per the plan:

1. **`frontmatter` jsonb column** on the renamed `org_wiki_pages` table — new migration `20260519XXXXXX_add_frontmatter_to_org_wiki_pages.exs` (`add :frontmatter, :map, null: false, default: %{}`) and a corresponding `field :frontmatter, :map, default: %{}` on `Platform.Org.WikiPage` with the field allowed in `cast`/`changeset`.
2. **`org_historian_cursors` table** — new migration creating composite-PK table `(workspace_id, corpus)` with `last_processed_id` (text, nullable), `last_processed_at` (utc_datetime_usec, nullable), `last_run_at` (utc_datetime_usec, nullable), `inserted_at`/`updated_at` via `timestamps(type: :utc_datetime_usec)`, index on `(workspace_id)`. No schema module yet — T6 owns that.
3. **Path-style `file_key` data migration + alias backfill** — Ecto data migration that maps existing `ORG_*.md` keys to `org/*.md` paths and writes one `org_wiki_aliases` row per (workspace_id, old_key) pair. Down reverses by alias-driven UPDATE + DELETE.
4. **Seeds rewrite** — `apps/platform/lib/platform/org/seeds.ex` `@default_files` keys rewritten to `org/identity.md` / `org/memory.md` / `org/agents.md`; `Platform.Org.Context` `@default_templates` map keyed the same way.
5. **Whitelist relaxation** — delete `@valid_file_keys` and the `validate_inclusion(:file_key, @valid_file_keys)` from `Platform.Org.WikiPage`. Uniqueness still enforced by the `(workspace_id, file_key)` index. Path-style keys become free-form.
6. **Deprecated stubs** — keep `allowed_file_keys/0` and `valid_file_keys/0` exported as deprecated stubs returning the old three uppercase keys so V1 callers (`Platform.Org.Seeds`, test fixtures referencing those names) don't break in this commit. Removal deferred to a later stack task.
7. **Alias-compat resolver in `Platform.Org.Context.get_context_file/2`** — if direct lookup misses and the requested `file_key` matches a legacy uppercase `ORG_*.md` pattern, fall back through `org_wiki_aliases`. This is what keeps V1 federation tools functional until T5 retires them.

## Files anticipated per subsequent stage (rough)

Confirmed at the start of each stage by its implementer.

### Stage 2 — Cherry-pick rename + add frontmatter + relax whitelist
- `apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs` (NEW from cherry-pick)
- `apps/platform/priv/repo/migrations/20260519XXXXXX_add_frontmatter_to_org_wiki_pages.exs` (NEW, T1-only)
- `apps/platform/lib/platform/org/wiki_page.ex` (renamed from `context_file.ex`, plus frontmatter field, plus whitelist removal, plus deprecated stubs)
- `apps/platform/lib/platform/org/wiki_journal_entry.ex` (renamed from `memory_entry.ex`)
- `apps/platform/lib/platform/org/context.ex` (alias updates)
- `apps/platform/lib/platform/org/seeds.ex` (alias updates only at this stage; key rewrite happens at stage 4)
- `apps/platform/lib/platform/memory.ex`
- `apps/platform/lib/platform/memory/telemetry_handler.ex`
- Test fixture renames under `test/platform/org/`, `test/platform/memory/`, `test/platform/federation/`

### Stage 3 — Cherry-pick links + aliases + add historian_cursors
- `apps/platform/priv/repo/migrations/20260516013500_create_org_wiki_links_and_aliases.exs` (NEW from cherry-pick)
- `apps/platform/priv/repo/migrations/20260519XXXXXX_create_org_historian_cursors.exs` (NEW, T1-only)

### Stage 4 — Data migration: path-style keys + alias backfill + seeds rewrite
- `apps/platform/priv/repo/migrations/20260519XXXXXX_path_style_file_keys_and_alias_backfill.exs` (NEW data migration)
- `apps/platform/lib/platform/org/seeds.ex` (key rewrite to path-style)
- `apps/platform/lib/platform/org/context.ex` (`@default_templates` key rewrite + alias-compat resolver in `get_context_file/2`)
- Tests under `test/platform/org/` that hardcode legacy keys (split: V1-behavior tests stay green via alias resolution; direct-insert tests switch to path-style)

### Stage 5 — Test-fixture sweep + `mix precommit` green
- Grep targets: `org_context_files`, `org_memory_entries`, `ContextFile`, `MemoryEntry`, `ORG_IDENTITY.md`, `ORG_MEMORY.md`, `ORG_AGENTS.md` under `apps/platform/test` and `apps/platform/lib`
- `apps/platform/test/platform_web/live/control_center_live_test.exs` — known to reference `ContextFile`, may need updates
- Catch-all formatting/compile-warning cleanup

### Stage 6 — Task-level e2e_behavior review
- No file changes; review agent dispositions four planner-authored behavioral scenarios.

## Surprises from recon

None of substance:

- The three commit SHAs match the dispatch description byte-for-byte. `8774497` does NOT have unrelated drift.
- `apps/platform/lib/platform/chat/canvas/kinds/embed.ex` and `image.ex` still exist on `origin/main` — `94d60b7` drift would still apply cleanly if anyone wanted it. Out of scope here.
- Note `main` at the time of the dispatch's "pre-T1 head 86e4b41" has moved on. `origin/main` is now at `cb6b9f2` ("raise space_get_messages content cap to 64KB"). The plan's e2e_behavior `setup` field still references `86e4b41` as the baseline — that's fine for the review-stage setup (reviewers can manually check out 86e4b41 to seed legacy rows), but flag it so we don't get confused if the data-migration test setup hits a schema drift from intervening migrations. No new migrations touching `org_context_files` exist between `86e4b41` and `cb6b9f2` (verified by `git log 86e4b41..cb6b9f2 -- apps/platform/priv/repo/migrations/`), so the baseline assumption holds.
- pgvector "drop" scope item: confirmed there's no `pgvector` / `CREATE EXTENSION vector` / `:vector` column anywhere in `apps/` or `priv/`. Embedding storage already routes through `memory-service` via `Platform.Memory.Provider`. The "Drop pgvector" line resolves to a documentation note — no actual schema work.

## Branch reconciliation tension — TO SURFACE TO JACOB

The plan stage-1 description explicitly says:

> Create worktree at ~/Code/worktrees/0041-org-memory-impl-T1 off origin/main on the stack rollup branch stack/0041-org-memory-impl (NOT a per-task branch — single rollup PR for the whole stack).

The engine dispatch instead instructed:

> Branch name MUST be `task/019e41d9-69bc-7245-94c0-ebd3fa6e0646`. This is the engine's hard contract for the deployer phase.

These contradict. The engine's per-task branch is what's currently checked out; the plan's shared rollup branch (`stack/0041-org-memory-impl`) is not used. **Followed the engine's instruction** per dispatch's "do not block on it" guidance. The rollup-vs-per-task tension needs Sloane's decision before deploy:

- **If per-task branches stand:** each task PRs separately; the stack reconciliation happens at deploy time via `git merge` of sibling task branches into the rollup. The plan's "no PR opened" assumption from stage 5 should be re-read in that light (T1 may need its own PR).
- **If shared rollup stands:** T1 should `git checkout -B stack/0041-org-memory-impl origin/main` and commit there; subsequent tasks commit onto the same branch. The per-task branch above gets abandoned.

Flagging for Sloane. Not a blocker for stage 1.

## Validation status (this stage)

- `lint_pass` (`019e41e0-0cd0-7f5a-b9fe-b43146da6ec1`): pending — `mix format --check-formatted` against the clean worktree (this markdown file is the only addition; `mix format` only touches `.ex`/`.exs`).
- `test_pass` (`019e41e0-0cd0-7c7e-9da5-a4f79dcf2493`): pending — `mix test --max-failures 1` against the clean worktree.

Both run from `apps/platform/` via the `clam-elixir-dev` Docker image (`--network=host`) since the host has no `mix` on PATH.
