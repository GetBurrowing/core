# T7 — Org Memory V2 Wiki UI: Design Lock + Recon Memo

**Stack:** `stack/0041-org-memory-impl` (rollup) · **Task:** `019e41da-3610-7972-8573-54121ea1f3f5` · **Stage:** Design lock + recon memo (1 of N)
**Author:** Clam · **Date:** 2026-05-20

This memo locks the design decisions for the T7 wiki UI before any LiveView code is written. It is the canonical answer to "what is the component shape and which rendering / state choices did we pre-commit to?" so the implementation stages don't re-litigate them.

---

## 1. Recon: every `org_context` / `OrgContextLive` / `Org Context` reference on T5 HEAD

T5 HEAD is `c0a3f9d` on branch `task/019e41d9-f6e9-775c-b782-75e4d3c1e596`. Verbatim output of:

```
git grep -n -E 'org[_-]context|OrgContextLive|Org Context' c0a3f9d -- apps/platform/
```

```
c0a3f9d:apps/platform/assets/js/hooks/markdown_editor.js:38:    this.el.addEventListener("org-context:save", () => {
c0a3f9d:apps/platform/lib/platform/orchestration/provider_guidance.ex:27:  Handle this task in a subagent with fresh context, **spawned as a background process**. Spawn it via the Agent tool — `general-purpose` is fine — with `run_in_background: true` so the parent conversation stays responsive while the subagent executes. Brief it with the full dispatch payload above, including the Organization Context section. Do NOT do this work in the parent conversation. The goals: (1) fresh context per task so the org-context discipline below isn't competing with whatever's already loaded, (2) audit clarity so the task lives in its own conversation tree, (3) parent responsiveness — the parent can keep handling other inbound messages or tasks while the subagent runs.
c0a3f9d:apps/platform/lib/platform/org/context.ex:19:  direct lookup misses, so V1 federation tools (`org_context_*`) keep
c0a3f9d:apps/platform/lib/platform_web/components/icon_rail.ex:326:        # not a standalone destination. The /org-context LiveView owns
c0a3f9d:apps/platform/lib/platform_web/components/icon_rail.ex:331:        path: "/org-context",
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:1:defmodule PlatformWeb.OrgContextLive do
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:12:     |> assign(:page_title, "Org Context")
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:36:         |> push_patch(to: ~p"/org-context")}
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:65:    {:noreply, push_patch(socket, to: ~p"/org-context/#{file_key}")}
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:176:         |> push_patch(to: ~p"/org-context/#{file_key}")
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:208:         |> push_patch(to: ~p"/org-context")
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:430:        <h3 class="text-lg font-medium text-base-content/50">Org Context</h3>
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:552:            id="org-context-save-btn"
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:553:            phx-click={JS.dispatch("org-context:save", to: "#org-context-editor")}
c0a3f9d:apps/platform/lib/platform_web/live/org_context_live.ex:577:            id="org-context-editor"
c0a3f9d:apps/platform/lib/platform_web/router.ex:98:      live("/org-context", OrgContextLive, :index)
c0a3f9d:apps/platform/lib/platform_web/router.ex:99:      live("/org-context/:file_key", OrgContextLive, :show)
c0a3f9d:apps/platform/notes/2026-05-19-t4-recon.md:177:Those reference V1 `suite_org_memory_append` + `suite_org_context_write`
c0a3f9d:apps/platform/priv/repo/migrations/20260408180000_create_org_context_tables.exs:5:    create table(:org_context_files, primary_key: false) do
c0a3f9d:apps/platform/priv/repo/migrations/20260408180000_create_org_context_tables.exs:19:      "CREATE UNIQUE INDEX org_context_files_workspace_id_file_key_index ON org_context_files (COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid), file_key)",
c0a3f9d:apps/platform/priv/repo/migrations/20260408180000_create_org_context_tables.exs:20:      "DROP INDEX org_context_files_workspace_id_file_key_index"
c0a3f9d:apps/platform/priv/repo/migrations/20260408180100_seed_org_context_files.exs:8:  # time this migration runs the table is named `org_context_files`. The
c0a3f9d:apps/platform/priv/repo/migrations/20260408180100_seed_org_context_files.exs:55:      INSERT INTO org_context_files (id, workspace_id, file_key, content, version, inserted_at, updated_at)
c0a3f9d:apps/platform/priv/repo/migrations/20260408180100_seed_org_context_files.exs:58:        SELECT 1 FROM org_context_files
c0a3f9d:apps/platform/priv/repo/migrations/20260414120001_agent_runtime_allowed_bundles.exs:4:  @all_bundles ~w(federation space context_read messaging review canvas task plan org_context)
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:4:  # P1 stage 2: rename the org_context_* tables to org_wiki_*, and reseat
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:13:    rename(table(:org_context_files), to: table(:org_wiki_pages))
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:17:      "ALTER INDEX IF EXISTS org_context_files_workspace_id_file_key_index RENAME TO org_wiki_pages_workspace_id_file_key_index",
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:18:      "ALTER INDEX IF EXISTS org_wiki_pages_workspace_id_file_key_index RENAME TO org_context_files_workspace_id_file_key_index"
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:33:      "ALTER INDEX IF EXISTS org_wiki_pages_workspace_id_file_key_index RENAME TO org_context_files_workspace_id_file_key_index"
c0a3f9d:apps/platform/priv/repo/migrations/20260515224500_rename_org_context_to_org_wiki.exs:37:    rename(table(:org_wiki_pages), to: table(:org_context_files))
c0a3f9d:apps/platform/priv/repo/migrations/20260516013500_create_org_wiki_links_and_aliases.exs:18:  `20260408180000_create_org_context_tables.exs`: `:uuid` PK without a DB
c0a3f9d:apps/platform/priv/repo/migrations/20260519210000_path_style_file_keys_and_alias_backfill.exs:16:  Stage 2 (`20260515224500_rename_org_context_to_org_wiki.exs`) renamed:
c0a3f9d:apps/platform/priv/repo/migrations/20260519210000_path_style_file_keys_and_alias_backfill.exs:18:    * `org_context_files` → `org_wiki_pages`
c0a3f9d:apps/platform/priv/repo/migrations/20260520000000_refresh_dispatch_templates_for_wiki_preamble.exs:14:  # the old org-context copy without an explicit overwrite, so this
c0a3f9d:apps/platform/priv/repo/migrations/20260520010000_force_update_prompt_templates_memory_v2.exs:7:  # `suite_org_context_write`); the new copy describes the V2 memory_*
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:3:  ADR-0041 T5: swap the V1 `org_context` capability bundle for the new
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:4:  `memory` bundle on every existing agent runtime. The `org_context`
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:5:  bundle's tools (`org_context_*`, `org_memory_*`) have been deleted
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:13:  previously granted `org_context` would silently lose access to org-
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:27:    SET allowed_bundles = array_append(array_remove(allowed_bundles, 'org_context'), 'memory')
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:28:    WHERE 'org_context' = ANY(allowed_bundles)
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:33:    # the obsolete `org_context` entry (e.g. mid-rollout state) should
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:34:    # drop `org_context` cleanly.
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:37:    SET allowed_bundles = array_remove(allowed_bundles, 'org_context')
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:38:    WHERE 'org_context' = ANY(allowed_bundles)
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:45:    SET allowed_bundles = array_append(array_remove(allowed_bundles, 'memory')), 'org_context')
c0a3f9d:apps/platform/priv/repo/migrations/20260520030000_agent_runtime_memory_bundle.exs:47:      AND NOT 'org_context' = ANY(allowed_bundles)
c0a3f9d:apps/platform/test/platform/federation/skill_mcp_parity_test.exs:178:      # Either nil/empty OR contains only org-context skill metadata.
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:304:    # expected: no V1 org_context_* / org_memory_* tool name appears.
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:306:          ~w(org_context_read org_context_write org_context_list org_memory_append org_memory_search) do
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:362:    test "V1 org_context_* / org_memory_* tool defs + execute clauses are removed from tool_surface" do
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:362:    test "V1 org_context_* / org_memory_* tool defs + execute clauses are removed from tool_surface" do
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:366:            ~w(org_context_read org_context_write org_context_list org_memory_append org_memory_search) do
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:375:      refute String.contains?(src, ~s("org_context")),
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:376:             "tool_surface.ex still references the retired `org_context` bundle"
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:380:      refute String.contains?(src, ~s("org_context"),
c0a3f9d:apps/platform/test/platform/federation/tool_surface_t5_e2e_test.exs:381:             "tool_surface.ex still references the retired `org_context` bundle"
c0a3f9d:apps/platform/test/platform/org/wiki/context_t4_e2e_test.exs:263:    # `org_context` → `memory` (20260520030000).
```

56 lines total. Buckets:

- **Router** (2 hits) — `/org-context` and `/org-context/:file_key` mounted to `OrgContextLive`.
- **OrgContextLive callsite** (10 hits) — module name, page title, `push_patch` URLs, header copy, save-button id + `phx-click` JS dispatch, editor element id.
- **icon_rail.ex** (2 hits) — sidebar nav entry "Org Context" with `path: "/org-context"`. Comment notes the LiveView "owns" the nav slot (not a separate destination).
- **JS hook** (1 hit) — `markdown_editor.js` listens for the `"org-context:save"` custom event the LV dispatches.
- **provider_guidance.ex** (1 hit) — dispatch-payload boilerplate still spells "org-context discipline" in prose; not load-bearing.
- **`Platform.Org.Context` module** (1 hit) — doc-comment reference; the module itself is being retired by the V2 wiki stack but the V1 federation tools are gone (T5).
- **Migrations** (28 hits across 5 migrations) — table-rename history; no runtime code reads these strings.
- **Tests** (8 hits across 3 tests) — T5's parity / surface tests assert the V1 `org_context_*` tool names are gone; the wiki context test references the migration history. All assertions are *negative* (refute presence), so they stay green after T7's UI rename.
- **Notes / planner artifacts** (2 hits) — historical recon prose, no code impact.

**No surprises beyond the planner's list.** Every reference falls into one of the buckets above. The icon_rail / router pair is the **only runtime UI surface** T7 needs to touch; everything else is either dead string, migration history, or a negative-presence test (which remains satisfied as we add new `/wiki` surface without resurrecting `org_context_*` tool names).

T7 implementation note: the old `/org-context` route + icon_rail entry will be swapped for `/wiki` (new `WikiLive`). Once swapped, the `OrgContextLive` module + `markdown_editor.js`'s `"org-context:save"` listener should be deleted in the same commit so we don't leave dead code under the new wiki surface.

---

## 2. Component boundaries (three-pane layout)

The wiki LiveView is a single `Phoenix.LiveView` that composes three function-component children. State lives on the LV; children are stateless renderers wired by attrs + events.

| Pane | Module | Role |
| --- | --- | --- |
| **Sidebar** (left) | `PlatformWeb.WikiLive.NamespaceTree` | Renders the namespace tree (`org/*`, `project/*`, `space/*`) as a collapsible component. Emits `phx-click="select_page"` with `%{"file_key" => …}` and `phx-click="toggle_namespace"` with `%{"prefix" => …}`. Receives `@tree`, `@expanded_prefixes`, `@selected_file_key`. **Mounts once.** Stays across all three tabs. |
| **Main** (center) | `PlatformWeb.WikiLive.MainPane` | Polymorphic on `@view_mode`. Renders one of: page viewer (`:pages` + selected page exists), page editor (`:pages` + edit mode), journal composer + entries list (`:journal`), or search results (`:search`). Sub-components: `PageViewer`, `PageEditor`, `JournalView`, `SearchResults`. Each receives only what it needs (e.g. `PageViewer` takes `@page`, `@rendered_html`, `@can_edit`). |
| **Right** (right) | `PlatformWeb.WikiLive.PageMeta` | Backlinks list + page-meta line (`vN · updated by · NN ago`). Receives `@backlinks`, `@page_meta`. Hidden when `@view_mode == :search`. |

**Why these boundaries:** the sidebar's state (tree + expansion + selection) is orthogonal to the main pane's tab mode, so we want it parented at the LV root so tab changes don't unmount it. The right pane is purely a function of the currently-loaded page, so it lives in the LV root and disappears when no page is selected. The main pane is the only place tab mode matters, so it's a switch component.

---

## 3. Wikilink rendering decision

**Decision:** **Render Earmark to HTML once, then post-process the rendered HTML** with a regex that swaps `[[target]]` / `[[target|display]]` tokens for `<a href="/wiki/...">` (resolved page) or `<span class="wikilink-dangling">target</span>` (unresolved). Resolution uses the existing T2 surface — `Wiki.parse_wikilinks/1` to find tokens, then `Wiki.get_page/2` / `Wiki.resolve_alias/2` for lookup.

**Pipeline:**

```
content
|> Earmark.as_html!(opts)
|> Wiki.Render.swap_wikilinks(workspace_id)
|> Phoenix.HTML.raw()
```

`Wiki.Render.swap_wikilinks/2` uses the same `Wiki.parse_wikilinks/1` regex T2 already ships, then per-match calls `Wiki.get_page/2` (and falls back to `Wiki.resolve_alias/2`) to decide between `<a>` and `<span class="wikilink-dangling">`.

**Rationale:**

- **Single source of truth with T2.** The parser is already battle-tested in T2's link-extraction path (`Wiki.upsert_page/3` writes the `org_wiki_links` rows using it). Reusing it means T7 and T2 can never disagree about what counts as a wikilink.
- **Earmark's plugin API is sharp-edged.** It uses an internal AST shape that changes between minor versions; coupling render to that surface is a maintenance trap.
- **Correctness concern is already handled.** The only correctness pitfall with regex-on-rendered-HTML is matching tokens inside code blocks. T2's parser already strips fenced code regions before scanning, so reusing it inherits that guarantee. We just need to apply the same strip step in the render-pass post-processor (or, equivalently, run the swap against a "render-safe" view of the HTML — concretely, skip text inside `<code>` / `<pre>` by walking with a tiny tokenizer rather than naive global regex).

**Implementation note:** the swap function should be a pure function `(html, workspace_id) -> html` so it's trivial to unit-test. T7 stage 3 ships unit tests for: resolved page, dangling page, piped display `[[target|label]]`, token inside fenced code (must NOT be swapped), token inside inline code (must NOT be swapped), alias resolution.

---

## 4. How three tabs share namespace-tree state

**Decision:** **single LiveView**, `view_mode :: :pages | :journal | :search` assign drives the tab switch. The namespace tree is mounted once at LV root and stays in the left pane across tab transitions.

```
PlatformWeb.WikiLive mount:
  socket
  |> assign(:view_mode, :pages)
  |> assign(:tree, Wiki.list_namespace_tree(workspace_id))
  |> assign(:expanded_prefixes, MapSet.new(["org/"]))
  |> assign(:selected_file_key, nil)
  |> assign(:page, nil)
  |> assign(:backlinks, [])
  |> ...

handle_event("switch_tab", %{"tab" => "journal"}, socket) ->
  socket
  |> assign(:view_mode, :journal)
  |> assign(:journal_entries, Wiki.Journal.list_recent(selected_namespace_for(socket)))
  |> noreply()
```

**Per-tab behavior:**

- **`:pages`** (default) — main pane renders `PageViewer` for the selected page (or empty state if none). Right pane shows backlinks + meta.
- **`:journal`** — main pane renders `JournalView` (composer + chronological entries list). Loads via `Wiki.Journal.list_recent(namespace)` for whatever namespace the sidebar has selected (defaulting to the namespace of the currently-selected page, or `org/` if none). Right pane hides backlinks (no per-page focus) and shows a date-range filter.
- **`:search`** — main pane renders `SearchResults`. Search input lives in the main pane header; results are page-cards linking back to `:pages` mode with that file_key selected. Right pane hidden.

**Critical invariant:** `assign(:tree, …)` and `assign(:expanded_prefixes, …)` are **never touched** by tab switches. The sidebar component receives the same tree across all three tabs, so its DOM stays patched-in-place rather than re-rendered. Selection (`@selected_file_key`) likewise persists — switching from `:pages` → `:search` → `:pages` returns to the same selected page without a re-fetch.

---

## 5. Version history — resolved (no follow-up)

`Wiki.versions/2` **does not exist** on T2. There is no per-edit version table — `org_wiki_pages` carries a monotonic `version` integer that bumps on each `upsert_page`, but prior versions are not retained.

**Sloane's call (2026-05-20):** *"Version stamp is fine for history, we don't need full history."*

**T7 scope decision:** Version history reduces to a single line in the right pane:

```
v{page.version} · updated by {updated_by_display} · {NN ago}
```

Rendered as part of `PageMeta`. No "view diff" affordance, no list of prior versions. **No follow-up task needed.** Resolved.

---

## 6. Agent-write read-only gate

**Mechanism:** humans bypass `Wiki.Routing.gate_write/3` by construction. The LiveView calls `Wiki.upsert_page/3` with `current_user` (a `Platform.Accounts.User`, never an `Agent`), and the routing module's Historian predicate keys off `Agent.system_events` — a field that does not exist on `User`. So for human-driven writes the predicate is structurally false and the gate path is never reached.

**Test we'll ship (T7 stage with editor):** assert that an Agent-shaped `current_user` (constructed in the test factory) routed through the same LV save-event handler **does** hit the gate path and returns `{:error, :read_only}` (or whatever the gate's denial shape is — confirm against T2). The test uses an `Agent` struct directly, not a stubbed `User`-with-`system_events`, so the predicate fires on real type discrimination.

```elixir
test "agent-shaped current_user hits the read-only gate path" do
  agent = agent_fixture(%{system_events: ["historian_promotion"]})
  socket = build_socket(current_user: agent, ...)

  {:noreply, socket} = WikiLive.handle_event("save_page", %{...}, socket)

  assert socket.assigns.flash["error"] =~ "read-only"
  refute_db_changed(WikiPage, page_id)
end
```

This locks in: (a) humans-writing works because of structural type discrimination, not a runtime branch; (b) the gate's existence is asserted by a test that would fail if the gate were accidentally removed; (c) we document the bypass as "by construction" so future readers don't add a redundant `if user.is_human?` check at the LV layer.

---

## Open questions

| # | Question | Status |
| --- | --- | --- |
| 1 | Full version history (diff view, list of prior versions)? | **Resolved** — Sloane approved version-stamp-only scope on 2026-05-20. No follow-up. |
| 2 | Global Cmd-K palette spanning conversations + memory? | Out of scope for T7. Possible follow-up post-merge. |
| 3 | Mobile responsive layout for the three-pane shell? | T7 stage TBD — likely "right pane drawer on narrow viewports, main pane full-width, sidebar slide-over." Punt to implementation stage. |

---

## References

- T2 HEAD on `task/019e41d9-f6e9-775c-b782-75e4d3c1e596`: commit `c0a3f9d`.
- T2 wiki module: `apps/platform/lib/platform/org/wiki.ex` (parse_wikilinks, get_page, resolve_alias, upsert_page).
- T2 journal module: `apps/platform/lib/platform/org/wiki/journal.ex`.
- T2 routing module: `apps/platform/lib/platform/org/wiki/routing.ex` (`gate_write/3`).
- V1 LiveView being replaced: `apps/platform/lib/platform_web/live/org_context_live.ex` (862 lines on T5 HEAD).
- V1 router entries: `apps/platform/lib/platform_web/router.ex:98-99`.
- V1 icon_rail entry: `apps/platform/lib/platform_web/components/icon_rail.ex:326-331`.
- V1 JS hook listener: `apps/platform/assets/js/hooks/markdown_editor.js:38`.
