# Implementation plan

**Phase 4 deliverable.** Ordered fix list for whoever builds this. Each item: audit finding → chosen approach → files touched → effort estimate (in agent-hours, not human-days).

> **Status:** All Phase 1-3 deliverables landed and approved by the design lead. This file sequences the actual code work that comes next. No code is modified by this audit; this is the bridge to the implementing tasks.

---

## How to read this list

- **Order is by leverage**, not by audit ID. Quick wins first; structural-change items deeper down.
- **Effort** is "agent-hours assuming a focused agent with the design system docs and audit findings open." Add ~30-50% for human pair-programming.
- **Files touched** uses `~/projects/core/...` paths.
- **Anchors** cite the audit finding ID(s) that justify the work.
- **Each item should be filed as its own Burrow Task** under project `019d1357-cb08-7023-b165-fd19e9462316` once the design lead approves this plan. Recommend NOT batching multiple items into one task — they'll have different validation gates.

---

## 1 — Land the `app.css` diff (1 agent-hour)

**Anchors:** `1B-A11Y-5` (neutral contrast), `1B-A11Y-1` (focus ring), `1B-A11Y-6` (button-loading CSS), `1B-A11Y-3` (motion).

**Source-of-truth diff:** `~/projects/core/docs/design-system/05-app-css-diff.md`.

**Files touched:**
- `~/projects/core/apps/platform/assets/css/app.css` — token value + new utility/component layers + skip-link.

**Verification:**
- `mix assets.build` clean.
- `lighthouse` + `@axe-core/playwright` re-run against `/chat`, `/tasks`, `/activity`. Previous contrast + focus-order findings resolve.

**Why first:** smallest diff, biggest a11y fix per kilobyte. Clears the contrast + focus + motion findings in one PR.

---

## 2 — Add aria-label to 7 icon-only buttons (0.5 agent-hour)

**Anchors:** `1B-A11Y-2`.

**Files touched:**
- `~/projects/core/apps/platform/lib/platform_web/live/chat_live.html.heex` — add `aria-label` at line 412 (`search_clear`).
- `~/projects/core/apps/platform/lib/platform_web/live/tasks_live.html.heex` — add `aria-label` at lines 89 (`clear_filters`), 101 (`toggle_epics_panel`), 410 (`close_detail`), 1407 (`close_review_canvas`), 1524 (`close_project_sheet`), 1705 (`close_task_sheet`).

**Verification:**
- `axe-core` rule `button-name` passes on all surfaces.
- Manual: VoiceOver / NVDA announces each button with the labelled action.

**Why second:** trivial diff (7 string additions), high-leverage for SR + voice-control users. No structural changes.

---

## 3 — Wire `phx-disable-with` + spinner on send/save buttons (2 agent-hours)

**Anchors:** `1B-A11Y-6`.

**Approach:**
- Add `phx-disable-with={...}` attribute to existing `<button type="submit">` and `phx-click="..."` buttons that fire mutations (send-message, save-task, create-task).
- Wire the JS hook `~/projects/core/apps/platform/assets/js/hooks/button_loading.js` (new file) implementing the **delay-before-show** pattern: `setTimeout(showSpinner, 100)`, cleared on response. Per the design lead 2026-05-09: "most messages are near-instant" — don't flash for sub-100ms operations.
- The CSS rule for `.phx-click-loading .btn[aria-busy="true"]` lands in step 1 (`05-app-css-diff.md`).

**Files touched:**
- New: `~/projects/core/apps/platform/assets/js/hooks/button_loading.js`.
- Modify: `app.js` to register the hook.
- `chat_live.html.heex` send button (~line 1185 area), `tasks_live.html.heex` save buttons (lines 784, 1683 + others).

**Verification:**
- Manual: simulate slow network (Chrome DevTools throttling) → spinner appears after 100ms.
- Manual: normal speed → no spinner flash.
- E2E (Playwright): `axe-core` passes; programmatically check `aria-busy="true"` while in flight.

**Why third:** highest-impact UX fix from the audit. Solves the double-submit problem.

---

## 4 — Migrate bare `<input>` / `<textarea>` to `<.input>` (3 agent-hours)

**Anchors:** `1B-VIS-2`, `1A-COMP-INPUT-1`, `1B-A11Y-4`.

**Approach:**
- For each bare `<input>` / `<textarea>` site in scope, replace with `<.input field={@form[:field]} type="..." label="..." />` from `core_components.ex`. Where no visible label exists (composer, search), pass `aria_label="..."` and document why.
- Keep the auto-resize composer textarea inline `style="field-sizing: content"` (no Tailwind utility) — see `01-foundations.md` §3.2. Wrap it via the new `.input.input-bordered` class with the inline style preserved.

**Files touched:**
- `chat_live.html.heex` lines 1185 (composer textarea), search input area, mention search, thread composer.
- `tasks_live.html.heex` lines 1188 / 1752 / 1764 / 1898 (auto-resize textareas), other form controls.

**Verification:**
- Every form control has either a visible `<label for>` or an `aria-label` (axe-core `label` rule).
- Validation errors render below each field with `role="alert"`.

**Why fourth:** unifies the form pattern across the audit's biggest inline-UI surface. Sets up step 5 (Sheet consolidation) to find the same input pattern in nested contexts.

---

## 5 — Build the `<.sheet>` component + migrate drawer/sheet sites (4 agent-hours)

**Anchors:** `1B-USE-4`, `1A-IA-DRIFT-5`.

**Approach:**
- New file: `~/projects/core/apps/platform/lib/platform_web/components/sheet.ex` implementing the spec from `~/projects/core/docs/design-system/02-components.md` §2.7.
- Single `:open` boolean replaces:
  - `shell_live.ex:58-59` `drawer_open` + `sidebar_collapsed` — collapse to one `:open` flag.
  - `tasks_live.ex:57, :59, :82` `sidebar_open`, `show_project_sheet`, `show_task_sheet` — three `<.sheet id={...} :open={...}>` instances with their own state.
- JS hook `~/projects/core/apps/platform/assets/js/hooks/sheet.js` for: focus-trap on open, return-focus on close, escape-to-close, drag-to-dismiss on mobile, prefers-reduced-motion gating.

**Files touched:**
- New component + new JS hook.
- `shell_live.ex` + `shell.html.heex` to use the new component.
- `tasks_live.ex` + `tasks_live.html.heex` for three migrations.

**Verification:**
- Manual: open + close every sheet on mobile + desktop; verify focus management matches `04-accessibility.md` §3.2.
- E2E: scroll-lock engages on sheet open; drag-to-dismiss on mobile works.

**Why fifth:** the Sheet consolidation has the highest "future bug prevention" leverage but the biggest blast radius. Land after the smaller fixes so any regression gets cleanly bisectable.

---

## 6 — Build the `<.empty_state>` component (2 agent-hours)

**Anchors:** `1B-USE-3` + the design lead's empty-state direction (2026-05-09).

**Approach:**
- New file: `~/projects/core/apps/platform/lib/platform_web/components/empty_state.ex`.
- Slot contract per `02-components.md` §2.13.
- Each surface's empty state migrates per `03-voice.md` §5:
  - Chat sidebar (no spaces) → V3 conversational with "+ Create a space" / "+ Connect an agent" chips.
  - Chat space (no posts) → V3 conversational with "Connect your agent and @ them..." + "+ Add an agent" chip.
  - Tasks (no tasks) → V3 conversational with "+ Create a task" / "@ Saru, plan a project" chips.
  - **Activity (no actions) → minimal text only** (the design lead pin 2026-05-09 — no V3 conversational here).
  - Search (no results) → simple "no matches" + clear-search.

**Files touched:**
- New component.
- `chat_live.html.heex` (4 empty-state sites: lines 54, 92, 187, 454).
- `tasks_live.html.heex` (1 site: line 331).
- `activity_live.html.heex` (1 site: minimal variant).

**Verification:**
- Manual: each empty state renders the canonical pattern + matches the design lead's verbatim copy.
- The Activity surface deliberately stays minimal — verify no conversational chrome leaks in.

---

## 7 — Apply the canonical naming map (4 agent-hours)

**Anchors:** `1A-IA-DRIFT-2`, `1A-IA-DRIFT-3`, `1A-IA-DRIFT-4`, `1A-IA-DRIFT-5`.

**Approach:**
- Mechanical rename per `03-voice.md` §2 canonical-term map:
  - `member` → `participant` in user-facing copy.
  - `agent` everywhere `principal` / `workspace` / `runtime` appears in user-facing copy (admin/debug surfaces unchanged).
  - `task` framing instead of peer-level `task` / `plan` / `review`. "This task is in planning" / "This task is awaiting review."
- DRIFT-1 (`space`) is already partially aligned; complete the mechanical rename of remaining "channel" and "conversation" references in copy (sidebar headers stay as kinds-of-space labels).
- DRIFT-5 (drawer/sidebar/nav/menu) unifies under the `<.sheet>` component from step 5.

**Files touched:** primarily HEEx templates + assigns names + ARIA labels. NOT data-model field names — those stay as the canonical engineering names. This is a copy-rename only.

**Verification:**
- Manual: each surface now uses one term per concept.
- Grep: `participant_type == "user"` should be the only "user" reference in scope (it's fine in the data filter; not in display copy).

**Why seventh:** highest ratio of touched-files-to-actual-functional-impact. Schedule for a quiet week.

---

## 8 — Tasks-list mobile redesign per hero mock (3 agent-hours)

**Anchors:** `1B-USE-2` (inline UI dominates) + the design lead's hero approval (2026-05-09).

**Approach:**
- Rebuild `tasks_live.html.heex` task list per `~/projects/core/audit/2026-05-08-ui-ux/mocks/_hero/all-surfaces-redesign.html` Tasks frame:
  - Status-dot + agent-chip per card.
  - Section headers with counts ("In progress · 2") instead of empty kanban columns on mobile.
  - Floating + button (FAB) using the new IconButton variant for "Create a task".
- Tap-card opens task detail in a Sheet from step 5.

**Verification:**
- Mobile (390×844 viewport): tasks list reads cleanly; FAB doesn't overlap content; tap target ≥44×44.
- Desktop unchanged for now (Phase 5 / future task can pick up desktop refresh).

---

## 9 — Activity feed day-grouping + inline undo (2 agent-hours)

**Anchors:** `1B-USE-2` + hero approval.

**Approach:**
- Rebuild `activity_live.html.heex` per the hero mock:
  - Group items by day ("Today", "Yesterday", explicit date) — relative for ≤2 days, absolute for older.
  - Inline `Undo` button on each item card.
  - Card border replaces the unbordered list.
- Empty state stays minimal (intro text only) per the design lead.

**Verification:**
- Manual: undo button still triggers the existing `:undo_action` event handler (no API change).
- Mobile: cards remain tappable / readable.

---

## 10 — Update `AGENTS.md` design directive (5 agent-minutes)

**Anchors:** `1A-COMP-DOCDRIFT-1`.

**Files touched:** `~/projects/core/apps/platform/AGENTS.md` line 33.

**Approach:** replace "Always manually write your own tailwind-based components instead of using daisyUI" with a one-line corrected directive: "Build on top of DaisyUI 5 + the design system tokens in `docs/design-system/`. Custom Tailwind only when DaisyUI lacks an equivalent component."

**Why last:** trivial doc fix; can land any time. Just preventing future contributor confusion.

---

## What's NOT in this plan

- **Performance work** (lighthouse signals). Re-run lighthouse after step 1 lands and file findings as separate Burrow Tasks if any new ones surface.
- **Desktop redesign of tasks / activity.** Mobile-first scope per the audit; desktop refresh is a follow-up phase.
- **Marketing site / public landing pages.** Out of audit scope.
- **i18n.** Voice doc is English-only. When Burrow goes multilingual, `03-voice.md` becomes the source-of-truth for English voice; per-locale equivalents are separate work.

---

## Burrow Tasks — recommend filing

Once the design lead approves this implementation plan, recommend filing each numbered item above as its own Burrow Task under project `019d1357-cb08-7023-b165-fd19e9462316`. Don't batch — each item has different validation needs (CSS-only items just need `lint_pass` + `test_pass`; component-rebuild items need `manual_approval` for visual verification).

**Suggested task naming:**
- "01: Land app.css design-system diff (contrast + focus + motion)"
- "02: Aria-label 7 icon-only buttons"
- "03: Wire phx-disable-with + delay-before-show spinner"
- "04: Migrate bare inputs to <.input>"
- "05: Build <.sheet> component + migrate drawer/sheet sites"
- "06: Build <.empty_state> component + migrate empty surfaces"
- "07: Apply canonical naming map"
- "08: Tasks list mobile redesign"
- "09: Activity feed day-grouping + inline undo"
- "10: Update AGENTS.md design directive"

Filing 10 tasks in one batch is fine; ask before filing if you want them sequenced as task dependencies (1 blocks 3, 4 blocks 5, etc.) or filed independently.
