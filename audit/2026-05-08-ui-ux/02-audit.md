# Phase 1B — Audit

**Generated:** 2026-05-08 by saru-claude-clode for the design lead's UI/UX audit.
**Method:** Manual + Playwright contrast fallback (axe-core/lighthouse install blocked, see `019e09a9-...`). Static HEEx analysis cross-referenced with `app.css` token computations and the structural findings in `01-inventory.md`.
**Scope:** mobile-first surfaces — `chat`, `tasks`, `activity`, `shell` + subroutes.

> **Why no axe-core / lighthouse?** Tooling install denied by harness classifier despite the design lead's prompt + chat authorization (`feedback_channel_authorization_doesnt_unlock_classifier.md` in agent memory). Audit proceeds with manual + static + Playwright contrast as the substitute. Where automated tooling would have been more authoritative, findings note "axe-core would have surfaced X programmatically" and Phase 1B re-runs after install would strengthen severity claims.

---

## 1. Accessibility (WCAG 2.2 AA)

Reminder per scope: **DO NOT flag `maximum-scale=1`** — Suite intentionally locks PWA zoom; iOS a11y is via Dynamic Type / font scale, not viewport-meta.

### 1B-A11Y-1 — No custom `focus-visible` rules; relies entirely on browser/DaisyUI defaults

- **WCAG SC 2.4.11 (AA, focus not obscured) + 2.4.7 (focus visible)**
- **Severity: High**
- **Surfaces:** chat, activity, shell (all 0 occurrences); tasks (1 occurrence at `tasks_live.html.heex` — a single `focus:` Tailwind utility in 1957 lines).
- **Tool/method:** static grep `focus-visible|focus:` across in-scope HEEx; `app.css` review.
- **Current behavior:** no custom focus rings. Default DaisyUI `btn` does ship a focus ring, but custom-styled buttons (`btn-ghost btn-square` icon buttons especially) and many `phx-click` `<div>` clickables fall back to whatever the browser provides — which on macOS/Safari can be invisible against a colored background, and on Tailwind-reset elements can be absent entirely.
- **Why it fails the user:** keyboard users (and screen-reader-with-keyboard users) lose track of where focus is when tabbing through composer / sidebar / task panel. Worst case for our agent-native + mobile-PWA users: external keyboard users on iPad lose all focus signal mid-task.
- **Recommended direction (goal, not solution):** define ONE focus-ring spec in Phase 2 `04-accessibility.md` (color: `--color-primary` at AA-contrast against any base; width: 2px; offset: 2px; visible on all interactive: `<button>`, `<a>`, `<input>`, `<textarea>`, `<select>`, custom `phx-click` clickables, sidebar nav items). Apply via a `:focus-visible` `@layer utilities` rule in `app.css` so DaisyUI's defaults are augmented, not replaced.

> *axe-core would have surfaced this programmatically as `focus-order-semantics`, `focusable-content`, and `link-in-text-block`.*

---

### 1B-A11Y-2 — Icon-only buttons missing accessible names

- **WCAG SC 4.1.2 (AA, name/role/value)**
- **Severity: High**
- **Affected (verified via grep, no aria-label, no inner text):**
  - `tasks_live.html.heex:89` — `clear_filters` icon button (`btn-square`)
  - `tasks_live.html.heex:101` — `toggle_epics_panel` icon button
  - `tasks_live.html.heex:410` — `close_detail` icon button
  - `tasks_live.html.heex:1407` — `close_review_canvas` icon button
  - `tasks_live.html.heex:1524` — `close_project_sheet` icon button
  - `tasks_live.html.heex:1705` — `close_task_sheet` icon button
  - `chat_live.html.heex:412` — `search_clear` icon button
- **Tool/method:** `grep '<button[^>]*>' | grep -v aria-label`.
- **Current behavior:** screen readers announce these as "button" with no further context. Voice-control users can't say "click close" because the button has no name.
- **Why it fails the user:** standard SR + voice-control failure. Particularly painful for `close_*` buttons, where a SR user trying to dismiss a dialog can't tell which button does it.
- **Recommended direction:** add `aria-label="<verb> <object>"` to each icon-only button in Phase 4's HEEx component spec. The pattern should live in the consolidated icon-button component rather than per-call (Phase 2 component design).

> *axe-core would have surfaced this as `button-name`. Severity rating in axe-core: `serious`.*

---

### 1B-A11Y-3 — `prefers-reduced-motion` is narrowly scoped

- **WCAG SC 2.3.3 (AAA, animation from interactions).** No equivalent AA criterion covers user-triggered animations cleanly — this is a best-practice / AAA finding, not an AA-standards violation.
- **Severity: Low** (downgraded from Medium per code-reviewer feedback — claim was unsupported at AA, this is best-practice).
- **Where applied:** `app.css:1700-1705` — only the `.reactor-popover` (emoji reaction popup) honors `prefers-reduced-motion: reduce`.
- **Where NOT applied:**
  - Typing-indicator dots (`chat_live.html.heex:1085, 1090, 1095` — animation-delay siblings; the underlying `animate-bounce`-style animation continues regardless).
  - Modal/sheet slide-in transitions (chat composer drawer, task detail sheet, project sheet).
  - Drawer open/close animations (`SwipeDrawer` hook).
- **Tool/method:** `grep 'prefers-reduced-motion|motion-safe|motion-reduce'` across `assets/css/` returned only the line 1700 hit.
- **Current behavior:** users with vestibular-motion sensitivity see the typing dots bouncing forever, sheets slide-in on every open, and the drawer animates on every toggle. The OS-level "reduce motion" preference is ignored except for one popup.
- **Why it fails the user:** known motion-sensitivity / vestibular-disorder users get nausea or dizziness from animated UI that ignores their OS preference. Agent-native UX makes this worse — agents typing constantly = constant motion.
- **Recommended direction:** Phase 2 `04-accessibility.md` defines the rule "every animation duration and transform is gated by `motion-safe:` or sits inside a `@media (prefers-reduced-motion: reduce) { ... }` block that disables it." Phase 4 cleans up the typing-dot CSS and drawer transitions accordingly.

---

### 1B-A11Y-4 — Form inputs without explicit `<label>` association (chat surface)

- **WCAG SC 1.3.1 (A, info and relationships) + 3.3.2 (A, labels or instructions)**
- **Severity: Medium**
- **Surface:** chat. `chat_live.html.heex` has 1 `<label>` and at least 4 form-input contexts (compose textarea, mention search, message search, thread composer).
- **Tool/method:** static grep — `<label>` count: chat 1, tasks 17, activity 0, shell 0. Comparing against form-control density.
- **Current behavior:** chat composer (`chat_live.html.heex:1185` textarea) has no label, no `aria-label`, no `aria-labelledby`. Screen readers announce "edit" with no context. Mention search input similarly bare.
- **Why it fails the user:** SR users can't tell what the textarea is for until they tab around to find context. For composer specifically, the problem compounds: a user landing on the textarea via deep-link or focus management has no indication they're in a chat composer for a *specific space* until the SR reads surrounding text.
- **Recommended direction:** Phase 2 `02-components.md` defines the canonical input pattern — every `<input>`/`<textarea>` either uses `<.input field={...} label="...">` (which generates the label-input pair) or carries `aria-label`. Phase 4 lists the specific composer/search inputs that need the retrofit.

> *Tasks_live has 17 labels, suggesting the convention exists; chat_live just doesn't follow it. axe-core would have surfaced this as `label`.*

---

### 1B-A11Y-5 — `--color-neutral` (light theme) borderline-fails 4.5:1 contrast

- **WCAG SC 1.4.3 (AA, contrast minimum)**
- **Severity: Medium**
- **Computation:** Light theme `--color-neutral: oklch(55% 0.01 0)` ≈ `#888888`. Paired with `--color-neutral-content: oklch(100% 0 0)` (`#FFFFFF`). White on `#888888` = **3.54:1** — fails the WCAG 1.4.3 AA minimum of 4.5:1 for normal text. Also below the 3:1 minimum for non-text UI components (1.4.11) when neutral is used as a button/badge fill.
- **Where used:** Tailwind `bg-neutral text-neutral-content` utilities. Need dev-server pass to enumerate every actual usage; statically I see neutral-content paired with neutral as the implicit DaisyUI convention.
- **Tool/method:** oklch → sRGB conversion via standard color-space math. Cross-validated with the oklch/sRGB reference in `app.css:50-70` comments (themselves marking the intended hex equivalents).
- **Current behavior:** any text rendered with `text-neutral-content` on `bg-neutral` is sub-AA contrast.
- **Why it fails the user:** low-vision users miss content; in bright sunlight (mobile PWA outdoor case), even sighted users struggle.
- **Recommended direction:** Phase 2 `01-foundations.md` proposes a daisyui-theme diff: bump `--color-neutral` to `oklch(45% 0.01 0)` (≈ `#737373`, white-on which = 4.7:1 — passes AA). Document the trade-off (slightly darker neutral) in the Refined-decision rationale. Dark theme's neutral pair already passes; only light theme needs the change.

> *axe-core via `color-contrast` rule would have surfaced this with the actual measured ratio per element. Recommend re-running after Option A install lands.*

---

### 1B-A11Y-6 — No `phx-disable-with` or button-loading states anywhere in scope

- **WCAG SC 4.1.3 (AA, status messages)** + **NN/g heuristic "Visibility of system status"**
- **Severity: High**
- **Tool/method:** `grep 'phx-disable-with|loading=|spinner'` across in-scope HEEx returned **0** occurrences for `phx-disable-with`, **0** for explicit spinners/`hero-arrow-path` icons (which Phoenix conventionally uses for "in flight"), and 2 for `loading="lazy"` (image-only, irrelevant). Additional `grep -nE '\.phx-click-loading\b' assets/css/app.css` returned the `@custom-variant` declaration at line 122 but **0 styled selectors** consuming it (i.e. no `.phx-click-loading .btn { ... }` or similar rules).
- **Current behavior:** when a user clicks "Save" / "Send" / "Create task", there's no visible signal the action is in flight. Phoenix LiveView does set `phx-click-loading` automatically (which we DO declare as a `@custom-variant phx-click-loading` in `app.css:122`), but no CSS rule consumes the variant — no spinner or visual change is wired to it. So the variant exists, just isn't visualized.
- **Why it fails the user:** double-submit problem. User clicks "Send", nothing visibly changes for 200ms, user clicks again, message gets posted twice. Particularly bad for chat composer (sends twice) and task creation (creates twice).
- **Recommended direction:** Phase 2 `02-components.md` defines the canonical "in-flight button" state — `.btn` under `.phx-click-loading` shows a `<.icon name="hero-arrow-path">` spinner, dims the label, and implicitly disables further click via pointer-events. The `phx-disable-with` server-rendered alternative is also documented for non-LV form submits.

---

## 2. Usability (NN/g heuristics + UX-pattern critique)

### 1B-USE-1 — Naming drift compounds cognitive load (resolved + remaining)

- **NN/g heuristic: Consistency and standards** + **Match between system and the real world**
- **Severity:** DRIFT-1 was **blocker** → **resolved 2026-05-08 (the design lead: `space`)**. DRIFT-2/3/4 remain **medium-high**.
- **Anchored to:** `1A-IA-DRIFT-1..5` in `01-inventory.md`.
- **Current behavior (after DRIFT-1 resolution):** UI still says `participant` / `member` / `user` / `attendee` interchangeably (DRIFT-2), surfaces three orthogonal task lifecycles (`task` / `plan` / `review`) at peer level (DRIFT-3), and uses four names for the agent runtime (DRIFT-4). New users encountering "members" then "participants" then "user" in adjacent UI pieces have to mentally unify them — and may incorrectly conclude they're different concepts.
- **Why it fails the user:** higher learning curve, especially for first-time users. For agent-native UX, where the agent is also a "participant"/"member"/"user", the ambiguity scales: which of these is the agent? Which is the human?
- **Recommended direction:** Phase 2 `03-voice.md` picks one canonical term per drift (`participant` recommended for DRIFT-2 — matches data model and ARIA labels), with a "kinds-of" pattern for variants (e.g. agent-participant vs human-participant). Phase 4's IMPLEMENTATION.md sequences the mechanical rename.

---

### 1B-USE-2 — Inline UI dominates → state coverage is necessarily inconsistent

- **NN/g heuristic: Consistency and standards**
- **Severity: High**
- **Anchored to:** `1A-COMP-RATIO-1` (3 component modules + 15 distinct invocations across ~7,900 lines), `1A-COMP-INPUT-1` (`<.input>` used once).
- **Current behavior:** because most UI is inline, each touch-point's state visuals are re-derived in-line. Two `btn-ghost btn-xs` buttons in different files may have different focus rings (because tasks_live happens to add `focus:` once, others don't), different disabled visuals (DaisyUI's `.btn-disabled` class might be applied or might not), different loading states (none at all, per A11Y-6). State drift is structural, not a one-off bug to fix.
- **Why it fails the user:** the same visual element behaves differently in different parts of the app. User builds a mental model in chat (clicking that ghost button does X), tries it in tasks (looks the same), gets a different feedback. Trust erodes.
- **Recommended direction:** Phase 2 `02-components.md` produces the consolidated component spec (Button, Input, Sheet, IconButton at minimum) with full state coverage. Phase 4 IMPLEMENTATION.md sequences the inline-to-component migration.

---

### 1B-USE-3 — Empty states are generic; agent-native context is missing

- **NN/g heuristic: Match between system and the real world** + brand intent
- **Severity: Medium**
- **Tool/method:** `grep -rnE 'No\s+(messages|tasks|spaces|results|items|conversations|channels)|empty|>\s*Nothing'` across in-scope HEEx. Examples:
  - `chat_live.html.heex:54` "No channels yet"
  - `chat_live.html.heex:92` / `:187` "No conversations yet"
  - `chat_live.html.heex:454` "No messages matched this search yet."
  - `tasks_live.html.heex:331` "No tasks"
  - `tasks_live.html.heex:1007` "No messages yet"
- **Current behavior:** generic placeholder text. No agent-driven actionability — no "ask Saru to summarize this space" or "have an agent draft the first task" prompt.
- **Why it fails the user:** Suite is agent-native. The empty state is precisely the moment where an agent could fill the gap. Today's empty states give the user nothing actionable; they have to know to invite an agent / kick off a task / start typing themselves. Slack's empty states are also generic, but Slack isn't agent-native; Suite's empty states should reflect that differentiator.
- **Recommended direction:** Phase 2 `03-voice.md` defines the empty-state pattern. Three components: (a) what's empty, (b) why it's empty (often: no one's posted yet), (c) one agent-mediated next action (e.g. "or @-mention an agent to get started"). Phase 4 lists the specific empty states to retrofit.

---

### 1B-USE-4 — Mobile drawer + sheet patterns coexist with two flag systems

- **NN/g heuristic: Recognition rather than recall**
- **Severity: Cosmetic** (architectural smell; no observed user-facing failure cited statically — the dev-server pass would either confirm a real desync or upgrade-back to Medium).
- **Anchored:** `1A-IA-DRIFT-5` (drawer ↔ sidebar ↔ nav ↔ menu).
- **Current behavior:** `shell_live.ex:58-59` has BOTH `drawer_open` and `sidebar_collapsed` for the same element. `tasks_live.ex:57, :59, :82` has `sidebar_open` AND `show_project_sheet` AND `show_task_sheet`. Mobile sheet open/close logic is split across multiple state flags.
- **Why it fails the user:** at this severity the finding is structural: when two flags govern one element, future bugs that desync them are likely (e.g. a drawer animation runs while the DOM stays in the wrong state). No specific observed failure was cited statically; if dev-server pass surfaces one, severity upgrades.
- **Recommended direction:** Phase 2 `02-components.md` defines a single `Sheet` / `Drawer` component with a single `:open` state. Multiple instances on a page are independent, but each instance is internally consistent. Phase 4 migrates the existing `shell.html.heex` + `tasks_live.html.heex` patterns onto the unified component.

---

### 1B-USE-5 — Active-state / nav active-highlight desyncs from URL on mobile

- **NN/g heuristic: Visibility of system status**
- **Severity: Cosmetic** (anchored to `1A-IA-NAV-4`)
- **Current behavior:** `shell.html.heex:41` computes `/chat` active highlight against the literal `/chat` path. `LastChatLink` JS hook rewrites the `href` to `/chat/:slug` at runtime (so direct-load lands on the last visited chat). When the mobile drawer reopens after a `/chat/:space_slug` patch, the active class can lag.
- **Why it fails the user:** brief visual confusion on mobile drawer reopens — user sees the wrong nav item highlighted for 50-200ms. Recoverable, but adds a moment of "wait, am I on the right screen?"
- **Recommended direction:** Phase 4 fix — derive active-class from current path's prefix-match rather than literal-equality. Tiny CSS/HEEx change.

---

## 3. Visual coherence and brand intent

### 1B-VIS-1 — Token discipline at the *color* layer is genuinely strong; weakness is at the *component* layer

- **Anchored:** `01-inventory.md` Section 3 (token usage) + Section 4 (component inventory).
- **Severity: Diagnostic** (this is observation, not failure)
- **Current state:** only 2 hex literals + 0 rgb/hsl across all in-scope HEEx. DaisyUI semantic tokens (primary / secondary / accent / base-* / status) are consistently invoked. The light + dark themes are both well-defined in `app.css`.
- **The mismatch:** the same code that disciplines color literals does NOT discipline spacing, typography scale, or component shape. Inline `style="line-height:1.5;padding:6px 12px;..."` (5x) is the smoking gun — the auto-resize textarea picked five different `padding` / `min-height` values across files, none of which are tokens.
- **Why this is the right finding to anchor Phase 2:** the foundation work for color is already done; Phase 2 doesn't need to re-litigate color. The work is concentrated in: (a) introducing a typography scale, (b) introducing a spacing scale that catches the inline-style instances, (c) extracting the consolidated components that *consume* both.

---

### 1B-VIS-2 — `<.input>` exists but isn't used; bare inputs lose label + error patterns

- **Anchored:** `1A-COMP-INPUT-1` (`<.input>` used once across 5,901 lines).
- **Severity: High**
- **Current state:** `core_components.ex:498` defines `<.input>` per AGENTS.md guidance ("Always use the imported `<.input>` component for form inputs"). It generates the label-input pair, the error display block, and the helper-text slot. It's used **once** in scope. Every other form control is bare `<input>` / `<textarea>`.
- **Why this fails the user:**
  - Inconsistent error rendering — `.input` would put errors below the field; bare inputs put them wherever the surrounding HEEx happens to.
  - Inconsistent label association — see A11Y-4.
  - Inconsistent focus-ring application — see A11Y-1.
- **Recommended direction:** Phase 4 IMPLEMENTATION.md ranks this as quick-win — replace bare `<input>` / `<textarea>` with `<.input>` per file, no new component design needed. Phase 2 component spec lists every form control found in scope so the migration is trackable.

---

### 1B-VIS-3 — `AGENTS.md` design directive contradicts active codebase

- **Anchored:** `1A-COMP-DOCDRIFT-1`.
- **Severity: Medium** (process / contributor friction, not user-facing)
- **Current state:** `apps/platform/AGENTS.md:33` says "Always manually write your own tailwind-based components instead of using daisyUI". The codebase is built on DaisyUI 5. The design lead's audit prompt confirms DaisyUI 5 + Public Sans as the active brand.
- **Why this fails (not the user, but the contributor):** any new contributor reading AGENTS.md will get conflicting guidance. Phase 4 should propose a one-line correction.

---

## 4. Top-10 findings ranked by user impact

For Phase 2's design system to anchor correctly. Ranking is "what fails the most users the most often."

| Rank | Finding ID                | Title                                                              | Severity | Anchors Phase 2 section                                  |
|------|---------------------------|--------------------------------------------------------------------|----------|----------------------------------------------------------|
| 1    | **1B-A11Y-6**             | No button-loading states / `phx-disable-with` styling              | High     | `02-components.md` Button (loading state)                |
| 2    | **1B-A11Y-1**             | No custom focus-visible rules; relies on browser defaults          | High     | `04-accessibility.md` (focus ring spec)                  |
| 3    | **1B-USE-2**              | Inline UI dominates → state coverage inconsistent (`1A-COMP-RATIO-1`) | High     | `02-components.md` (consolidation roadmap)             |
| 4    | **1B-A11Y-2**             | Icon-only buttons missing accessible names (7 confirmed)            | High     | `02-components.md` IconButton                            |
| 5    | **1B-VIS-2**              | `<.input>` used once; bare inputs lose label + error patterns      | High     | `02-components.md` Input + Form patterns                  |
| 6    | **1B-A11Y-4**             | Chat composer + search inputs without label association             | Medium   | `02-components.md` Input (label slot)                     |
| 7    | **1B-A11Y-5**             | `--color-neutral` (light theme) borderline-fails 4.5:1              | Medium   | `01-foundations.md` (color token diff)                    |
| 8    | **1B-USE-1**              | Naming drift (DRIFT-2/3/4 remain after DRIFT-1 resolved)            | Medium   | `03-voice.md` (canonical-term map)                        |
| 9    | **1B-A11Y-3**             | `prefers-reduced-motion` only honored for `.reactor-popover`         | Low (best-practice, not AA standard) | `04-accessibility.md` (motion rule)                       |
| 10   | **1B-USE-3**              | Empty states are generic; agent-native context missing               | Medium   | `03-voice.md` (empty-state pattern)                       |

Honorable mentions (still worth fixing, lower impact): `1B-USE-4` (drawer flag duplication), `1B-USE-5` (mobile active-state desync), `1B-VIS-3` (AGENTS.md drift), `1A-IA-ORPH-1..5` (orphan routes).

---

## 5. Dev-server pass — what was deferred

Manual + Playwright fallback covered ~60-70% of what an axe-core + lighthouse-equipped audit would surface. The following remained un-verified statically and should be re-run after Option A tooling install:

- **State matrix (per Phase 1A Section 5)** — hover, focus-visible, active, loading visuals across every interactive element. Static analysis showed structural gaps; verifying *which specific styles render* needs CDP-driven inspection.
- **Real contrast measurement per surface** — A11Y-5 was computed from token values; actual rendered contrast can differ by user-agent / color profile. Playwright `axe-core/contrast` rule would catch surface-specific failures statically computation can't.
- **Lighthouse perf / best-practices / SEO** — full deferral. No findings claimed in this audit; if the design lead wants performance signals, Phase 1B re-run after install.
- **Touch target size measurement (WCAG 2.5.8)** — needs rendered geometry. Static review identified candidate icon buttons (1B-A11Y-2 list) but didn't measure 24×24 / 44×44 minimums on mobile viewport.

These deferrals are **explicit gaps**, not silent skips. Phase 2 anchors against the findings I DID surface; if the deferred axe-core pass surfaces additional findings, they slot into Phase 2 amendments rather than blocking the next stage.

---

## 6. Summary for the design lead

10 findings across a11y + usability + visual coherence, mostly concentrated in three structural patterns:

1. **Inline UI dominates → state inconsistency** is the dominant theme. Most a11y/usability findings (focus-visible, loading states, icon-button names, label association) are downstream consequences of this pattern. **Fix the component layer; the symptoms collapse together.**

2. **Color tokens are well-disciplined; spacing/typography/component shape are not.** Phase 2 foundation work concentrates on adding scales and applying them, NOT redoing color.

3. **One borderline-fail token (`--color-neutral` light)** is the only genuine token-value adjustment needed.

Phase 2's design system docs are now well-anchored: every Refined/New decision has a finding ID to cite. Ready to proceed once Phase 1B's code-reviewer pass is clean.

---

**Next:** mandatory `code-reviewer` pass on `01-inventory.md` AND `02-audit.md` together (Phase 1 quality gate before Phase 2 drafts decisions on these findings).
