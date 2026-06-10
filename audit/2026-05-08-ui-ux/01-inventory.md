# Phase 1A — Inventory

**Generated:** 2026-05-08 by saru-claude-clode for Marlowe's UI/UX audit.
**Scope (strict):** mobile-first surfaces — `chat`, `tasks`, `activity`, `shell`. Excludes `admin_*`, `changelog`, `usage`, `meeting_bar`.
**Recon source:** see `~/projects/core/audit/2026-05-08-ui-ux/01-inventory.md` (this file). Phase 1B audit references findings here by section ID (e.g. `1A-IA-DRIFT-1`).

> **No recommendations in this file.** Inventory only. Recommendations live in `02-audit.md` (Phase 1B). Decisions live in `docs/design-system/` (Phase 2).

---

## 1. Surface map

5 in-scope LiveView routes. All authenticated, all running through `live_session :authenticated` with `on_mount: [PlatformWeb.ShellLive]` (`router.ex:72-91`). Shell chrome (sidebar / drawer / agent status / presence) is not a route — it's the `ShellLive.on_mount/4` hook applied to every authenticated route.

| Route path           | LV module (file:line)                                              | Primary user task                                                                                                              | Mobile vs desktop                                                                                                                                                | Auth          |
|----------------------|--------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| `/chat`              | `PlatformWeb.ChatLive` (`live/chat_live.ex:48`)                   | Land in chat, see sidebar of channels + DMs, pick a space.                                                                     | Single responsive template. `mobile_browser_open` assign at `chat_live.ex:64` toggles a mobile space-list drawer. Tailwind `md:`/`hidden` breakpoints throughout `chat_live.html.heex`. | Authenticated |
| `/chat/:space_slug`  | `PlatformWeb.ChatLive` (`live/chat_live.ex:114` `handle_params`)  | Read + post messages, attachments, threads, mentions, pins inside a specific space.                                            | Same template. Mobile drawer collapses sidebar; message composer + thread pane reflow via `md:` classes.                                                          | Authenticated |
| `/activity`          | `PlatformWeb.ActivityLive` (`live/activity_live.ex:34`)           | Scan a chronological list of agent-driven actions across spaces; undo/restore individual actions. Paginated 10/page; 24h/7d/30d/all range filter. | Single responsive template; minimal breakpoint use, list reflows naturally.                                                                                       | Authenticated |
| `/tasks`             | `PlatformWeb.TasksLive` (`live/tasks_live.ex:39, :239`)            | Browse tasks grouped into kanban columns; filter by project/epic; create new tasks.                                            | `sidebar_open` (`:57`) and `show_project_sheet` (`:59`) drive a mobile bottom-sheet vs desktop sidebar. `show_task_sheet` (`:82`) opens task detail as a sheet on mobile. | Authenticated |
| `/tasks/:task_id`    | `PlatformWeb.TasksLive` (`live/tasks_live.ex:150` `handle_params`) | Open one task to view/steer its plan, execution log, pending reviews, attached skills, assignees, and reopen flow.             | Same template; mobile uses `show_task_sheet` bottom-sheet, desktop renders inline detail panel via Tailwind responsive classes.                                  | Authenticated |

**Out of scope (excluded; seen in `router.ex` but not analyzed):** `/skills`, `/skills/:slug`, `/changelog`, `/control`, `/control/:agent_slug`, `/control/usage`, `/admin/prompts*`, `/org-context*`, `/admin/federation`, `MeetingBarLive`. Plus all non-LV controllers (auth, attachments, MCP, webhooks).

**Surface size note:** 5 LV routes is small. The audit's mass is **not** in route count — it's in shared chrome (`ShellLive` `on_mount`) and inline component reuse (Section 4).

---

## 2. IA concerns visible from the route map

Architect agent diagnosis (read-only, no recommendations). Severity tags: **blocker** / **annoying** / **cosmetic**.

### 2.1 — Orphan routes (no in-app link)

| ID            | Route                                  | Should-link site (none today)                                  | Severity  |
|---------------|----------------------------------------|----------------------------------------------------------------|-----------|
| 1A-IA-ORPH-1  | `/artifacts/preview` (`router.ex:69`) | Artifact bubbles in `chat_live.html.heex`                     | annoying — users clicking artifact bubbles in chat get no in-app preview path; either dead-end or external redirect, breaking the in-product flow |
| 1A-IA-ORPH-2  | `/api/transcripts/:id/download` (`:70`) | Meeting/transcript surfaces in `chat_live.html.heex`         | annoying — meeting attendees can't download a transcript from the surface they had the meeting on; they have to know the URL or hit it from another tool |
| 1A-IA-ORPH-3  | `/skills/:slug` (`skills_live.html.heex:25`) | List rows are `phx-click` + `push_patch`, not `<.link>` — middle-click / share / right-click open is broken. | annoying  |
| 1A-IA-ORPH-4  | `/org-context/:file_key` (`org_context_live.ex:64-65`) | Same pattern; `phx-click="select_file"` then `push_patch`, no anchor. | annoying  |
| 1A-IA-ORPH-5  | `/control/:agent_slug` (`control_center/agent_card.ex:21`) | Cross-module deep-link from Activity/Tasks rows referencing an agent is absent. | cosmetic  |

### 2.2 — Duplicated entry points

| ID            | What                                                                                                                                                              | Severity  |
|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| 1A-IA-DUP-1   | Chat root reachable as `/`, `/chat`, AND `/chat/:last_slug` (via `LastChatLink` JS hook). Breadcrumb/active-state logic at `shell_live.ex:71-84` handles all three. | cosmetic  |
| 1A-IA-DUP-2   | `/tasks/:task_id` reachable two ways: `select_task` → `push_patch` from the list (`tasks_live.ex:330`) AND `<.link navigate>` from changelog (`changelog_live.ex:192`). Static observation only — `push_patch` keeps LV state and stays on the connected socket, `<.link navigate>` is a full LV navigation that re-mounts. Whether mobile back-stack actually behaves differently per entry needs dev-server confirmation. | cosmetic (downgraded — observable difference deferred to dev-server pass) |
| 1A-IA-DUP-3   | `/control/usage` is its own nav item (`shell.html.heex:103`) AND lives under Control's slug pattern. Phoenix resolves literal-first so it works, but URL/IA mismatch. | annoying  |

### 2.3 — Nav inconsistency

| ID            | Where                                                                                                                                       | Severity  |
|---------------|---------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| 1A-IA-NAV-1   | Nav says "Chat" (`shell.html.heex:46`) → page renders sidebar header "Channels" (`chat_live.html.heex:21,120`). No "Chat" surface in the page. | annoying  |
| 1A-IA-NAV-2   | Nav "Activity" (`shell.html.heex:55`) → page heading "AI Activity" (`activity_live.html.heex:12`); `page_title` "Activity" (`activity_live.ex:39`). Three labels for one screen. | cosmetic  |
| 1A-IA-NAV-3   | Nav "Agent Resources" → URL `/control` → `derive_active_module` returns "Agent Resources" but module is `ControlCenterLive` and partials `ControlCenter.*`. Three names for one thing. | annoying  |
| 1A-IA-NAV-4   | `/chat` active-state computed against `/chat` literal (`shell.html.heex:41`) but `LastChatLink` rewrites `href` to `/chat/:slug` at runtime. Active highlighting can desync on mobile when drawer reopens after a `/chat/:space_slug` patch. | cosmetic  |

### 2.4 — Naming drift (BLOCKER for design system voice)

| ID                  | Concept                                       | Drift                                                                                                                 | Severity      |
|---------------------|-----------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|---------------|
| **1A-IA-DRIFT-1** ✅ resolved | space ↔ channel ↔ conversation ↔ DM ↔ group   | Data model says `space`. UI says all five: list_user_conversations (`chat_live.ex:51`), :spaces and :dm_conversations assigns (`:58, :60`), "Channels" header (`chat_live.html.heex:21,120`), `space.kind == "channel"` / `"group"` / `"dm"` branches (`:217, :241`), "Convert to Channel" (`:262`), `new_conversation_open` (`:411`). Two creation components: `new_channel_component.ex` and `new_conversation_component.ex` — same domain, two names. URL segment `/chat/:space_slug`. | **blocker** → resolved |

> **Pinned 2026-05-08 by Marlowe:** canonical term is **`space`**. "Channels" and "Direct Messages" become *kinds of space* in copy (sidebar sections / filters can keep those labels, the underlying noun is `space`). Phase 2 voice section locks to this. Slack-vocabulary users get a beat of translation; mitigation = keep "Channels" sidebar header.
| 1A-IA-DRIFT-2       | participant ↔ member ↔ user ↔ attendee        | "members" count (`chat_live.html.heex:244`); `data-participant-id` (`:600`); presence_list filtered by `participant_type == "user"` rendered under "Participants" (`shell.html.heex:256`); icon `title="Online participants"` (`:247`). | annoying      |
| 1A-IA-DRIFT-3       | task ↔ plan ↔ review ↔ column                 | Tasks grouped into "columns", gated by "plan" status, surfacing "review" counts at peer level (`tasks_live.ex:43, :61, :63, :64`). Three orthogonal lifecycles named at peer level with no hierarchy. | annoying      |
| 1A-IA-DRIFT-4       | agent ↔ principal ↔ workspace ↔ runtime       | `Agent`, `AgentServer`, `WorkspaceBootstrap` aliases (`shell_live.ex:9`); `default_agent_status` reads `WorkspaceBootstrap.status` (`:185`); UI label "principal" (`shell.html.heex:204`); button labelled "Agents" (`:183`). Mixes domain/role/boot-context/status-source without disambiguation. | annoying      |
| 1A-IA-DRIFT-5       | drawer ↔ sidebar ↔ nav ↔ menu                 | One element with two flags: `drawer_open` and `sidebar_collapsed` (`shell_live.ex:58-59`). DOM `id="shell-sidebar"`, hook `phx-hook="SwipeDrawer"`, `aria-label="Close menu"` / `"Open menu"` (`shell.html.heex:13, 14, 29, 158`). | cosmetic      |

> **`1A-IA-DRIFT-1` is the highest-leverage finding in the audit.** Phase 2's voice section cannot write button verbs, navigation labels, or empty-state copy until one canonical term wins. Recommend Marlowe settle the term explicitly before Gate 2.

---

## 3. Token usage

Source: `apps/platform/assets/css/app.css` (1748 lines) + `apps/platform/assets/vendor/daisyui-theme.js` (plugin) + Tailwind v4 utilities throughout in-scope HEEx.

### 3.1 — DaisyUI theme plugin blocks

Two themes defined inline in `app.css`:

- **Light** (`@plugin "../vendor/daisyui-theme"` at `app.css:44`) — all colors as `oklch(L% C H)`. Key tokens: `--color-primary: oklch(82% 0.12 207)` (cyan), `--color-secondary: oklch(30% 0.01 0)` (near-black), `--color-base-100: oklch(100% 0 0)` (white), `--color-base-content: oklch(0% 0 0)` (black). Status: `--color-success/warning/error` set; all `*-content` set.
- **Dark** (`@plugin "../vendor/daisyui-theme"` at `app.css:82`) — same structure. Cyan-tinted bases (`--color-base-100: #171b25`, `--color-base-200: oklch(9% 0.018 240)`). All status tokens mirrored. The dark cyan primary is `oklch(78% 0.14 200)`, slightly lower lightness than light.

Both themes use `oklch` — modern, perceptually-uniform color space. **No HSL or RGB color values defined** in the theme blocks.

### 3.2 — Color literal usage in templates (one-offs)

Grepping all in-scope HEEx + components/layouts:

- **2 hex literals total**: `#e5e7eb` (1 use), `#000000` (1 use). Both in templates, both arguably one-offs.
- **0 `rgb()` / `hsl()` literals** in any in-scope HEEx.
- **0 hardcoded HSL** in app.css custom CSS.

This is genuinely clean — the existing system is **well-tokenized at the color layer**. Phase 1B's accessibility work focuses on token *values* (do they meet contrast?), not on de-tokenizing one-offs.

### 3.3 — Inline `style=""` attributes (19 instances in scope)

Material patterns (verbatim string repeats — Phase 2 consolidation candidates):

| Pattern (one-line)                                                                                          | Occurrences | Files                                                                                              | What this is                              |
|-------------------------------------------------------------------------------------------------------------|-------------|----------------------------------------------------------------------------------------------------|-------------------------------------------|
| `line-height:1.5;padding:6px 12px;min-height:33px;max-height:200px;overflow-y:auto;field-sizing:content`    | **5**       | `tasks_live.html.heex:1188, :1752, :1764, :1898` + variant `chat_live.html.heex:1185` (28px min)  | Auto-resize textarea (composer)           |
| `style="border-color: color-mix(in oklch, var(--agent-accent, oklch(82% 0.12 207)) 30%, transparent);"`     | 1 + 1 sib   | `chat_live.html.heex:1066, :1070`                                                                  | Per-agent accent border/background        |
| `style="position: absolute; bottom: 100%; left: 0; z-index: 50; width: 16rem; margin-bottom: 4px;"`         | 1           | `chat_live.html.heex:958`                                                                          | Mention dropdown positioning              |
| `style="animation-delay: 0/150/300ms"`                                                                      | 3           | `chat_live.html.heex:1085, :1090, :1095`                                                           | Typing-indicator dot stagger              |
| `style="width:28px;height:28px;font-size:10px"`                                                             | 1           | `chat_live.html.heex:911`                                                                          | Avatar variant                            |
| Misc layout styles                                                                                          | ~7          | thread composer, image-lightbox, etc.                                                               | One-off layout fixes                      |

**Anchor finding `1A-TOK-INLINE-1`:** the auto-resize textarea pattern is repeated five times verbatim across chat + tasks, with one minor variant (chat thread composer uses `min-height:28px` instead of `33px`). This is the strongest single component-extraction candidate.

### 3.4 — Tailwind utility frequency (deferred)

A full utility-frequency count across ~7,900 lines of HEEx is expensive and not required for Phase 1B. The token findings above are sufficient to anchor the Phase 1B visual-coherence audit. If Phase 2 needs a deeper utility distribution (e.g. spacing-scale conformance), defer the analysis until then.

---

## 4. Component inventory

### 4.1 — Reusable component modules in scope

Only **3 component modules** in `apps/platform/lib/platform_web/components/`, totaling 801 lines:

| Module                                          | Lines | Purpose                                                                                                |
|-------------------------------------------------|-------|--------------------------------------------------------------------------------------------------------|
| `core_components.ex`                            | 498   | Phoenix-default scaffolding: `<.input>`, `<.button>`, `<.flash_group>`, `<.icon>`, `<.modal>`, `<.simple_form>`. |
| `avatar_components.ex`                          | 116   | `<.human_avatar>` (snapshot fields → avatar render).                                                  |
| `layouts.ex` + `layouts/{root,shell}.html.heex` | 187   | Layout components and the shell frame.                                                                 |

That's it. **No** dedicated chat-message component, **no** task-card component, **no** typing-indicator component, **no** auto-resize textarea component. These all live inline in their LV templates.

### 4.2 — `<.component>` usage frequency in in-scope HEEx (total 5,901 lines)

15 distinct invocations across the four primary HEEx files (`chat_live`, `tasks_live`, `activity_live`, `shell`):

| Component             | Count | Notes                                                                                |
|-----------------------|-------|--------------------------------------------------------------------------------------|
| `<.link`              | 15    | Phoenix builtin                                                                      |
| `<.form`              | 6     | Phoenix builtin                                                                      |
| `<.live_component`    | 4     | LiveComponent invocations (per AGENTS.md: "avoid LiveComponents")                    |
| `<.local_time`        | 3     | Custom (likely a hook-based component)                                                |
| `<.live_file_input`   | 3     | Phoenix builtin                                                                      |
| `<.human_avatar`      | 3     | Custom (avatar_components)                                                            |
| `<.plan_body`         | 2     | Tasks-specific                                                                        |
| `<.upload_dialog>`, `<.notification_banner>`, `<.meeting_panel>`, `<.live_img_preview>`, `<.input>`, `<.image_lightbox>`, `<.flash_group>`, `<.canvas_overlay>`, `<.canvas_document>` | 1 each | Mostly chat-specific; `<.input>` only used once in 5,901 lines despite forms being everywhere |

**Anchor finding `1A-COMP-RATIO-1`:** ~7,900 lines of in-scope HEEx + LV use only **3 reusable component modules** with **15 distinct invocations**. The vast majority of UI is inline. Phase 1B will quantify the consolidation opportunity; Phase 2 designs the unified components.

**Anchor finding `1A-COMP-INPUT-1`:** `<.input>` (the canonical form-input component per AGENTS.md) is used **once** across 5,901 lines, despite multiple forms being present (compose, search, task detail, project sheet). Forms are using bare `<input>` / `<textarea>` with inline classes. Form-input consolidation is a Phase 2 priority.

### 4.3 — AGENTS.md vs. reality: stale design directive

`apps/platform/AGENTS.md:33` says:

> "Always manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design"

But the app **is** built on DaisyUI 5 — the daisyui-theme plugin is invoked twice in `app.css` (light + dark themes), DaisyUI utilities are referenced throughout HEEx, and Marlowe's audit prompt confirms "DaisyUI 5 + Tailwind v4 themes" as the active system to refine.

**Anchor finding `1A-COMP-DOCDRIFT-1`:** the AGENTS.md design directive contradicts the active codebase. Phase 4 should propose a one-line correction to AGENTS.md (e.g., "Build on top of DaisyUI 5; only fall back to bare Tailwind when DaisyUI lacks an equivalent"). Not a code-quality issue, but it does mean any new contributor reading AGENTS.md will get conflicting guidance.

---

## 5. State coverage matrix

### 1A-STATE-DEFERRED-1 — Per-interactive-element state visualization matrix

**STATUS: Deferred. Tracked here so Phase 2 can cite this anchor when calling out un-verified states.**

Programmatic state inspection (hover, focus-visible, active, disabled, loading, error, empty) requires the `agent-chrome-cdp` skill driving a running dev server. Phase 1B fell back to manual + Playwright contrast checks per the tooling blocker (axe-core/lighthouse install denied, see `019e09a9-...`). The state matrix specifically depends on CDP-driven hover/focus inspection that Playwright manual fallback can do but at higher per-surface cost.

**What this deferral covers:**

- Per interactive component (button, input, select, textarea, toggle, link, tab, menu item, sheet drawer-handle, sidebar nav item, kanban-column drop-target):
  - Default / hover / focus-visible / active / disabled / loading / error / empty states
  - Tabular result: present in DOM ✓ vs visually-distinct-from-default ✓ vs missing ✗
  - Specific failed states cited for Phase 2 to fix.

**What Phase 1B's static analysis covered instead:**

- A11y findings 1B-A11Y-1 (focus-visible absence — derived from grep, not from rendered state inspection).
- A11y finding 1B-A11Y-6 (loading state absence — derived from `phx-disable-with` + spinner grep).
- Visual coherence 1B-USE-2 (state inconsistency — derived structurally from `1A-COMP-RATIO-1`).

**What's still open after Phase 1B:**

- Hover/active styling for every `btn`, `btn-ghost`, `btn-square` instance (DaisyUI defaults vs custom overrides).
- Per-input invalid/error state rendering (Phoenix `<.input>` has it; bare `<input>` instances may not).
- Sheet/drawer transition states on actual mobile viewport (390×844).

**Phase 2 may proceed citing this anchor;** Phase 4 should re-run the state matrix once tooling lands.

---

## 6. Outstanding questions for Marlowe (before Phase 1B)

These questions affect Phase 1B's anchoring and Phase 2's voice work:

1. **`1A-IA-DRIFT-1` — canonical chat-entity term.** Pick one from `space` / `channel` / `conversation` / `room` / `group`. Recommend `space` (matches data model, URL slug, MCP tool names like `space_id`). Phase 2 voice section can't ship without this.
2. **`1A-IA-DRIFT-2` — canonical participant term.** `participant` vs `member` vs `user`. Recommend `participant` (matches data model + ARIA `Online participants`). Lower urgency — Phase 2 can write around this if needed.
3. Tooling blocker (`019e09a9-0a28-7cf6-ad9f-0de954058b4c`) and `TRACKING_TASK_SPACE_ID` ambiguity — already raised in chat thread.

---

## 7. Pointers for Phase 1B

When Phase 1B starts:

- Anchor a11y findings against per-route surfaces from Section 1.
- Anchor visual-coherence findings against `1A-TOK-INLINE-1` (textarea repeats) and `1A-COMP-RATIO-1` / `1A-COMP-INPUT-1` (component-extraction targets).
- Anchor naming/usability findings against Section 2.4 drift.
- Use the dev server boot to do the deferred state-coverage matrix inline.
- axe-core unavailable per blocker — fall back to manual + Playwright contrast checks.
