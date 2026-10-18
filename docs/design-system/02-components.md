# 02 — Components

**Phase 2 deliverable.** Component specifications with full state coverage. Consolidation roadmap mapping inline implementations to canonical components.

> **Why this is the audit's biggest-leverage section:** anchored to `1A-COMP-RATIO-1` (only 3 component modules + 15 distinct invocations across ~7,900 lines), `1A-COMP-INPUT-1` (`<.input>` used once), `1B-USE-2` (state coverage necessarily inconsistent), `1B-A11Y-1` / `1B-A11Y-6` (focus + loading state absence). Most other a11y/usability findings collapse into "fix the component layer."

---

## 1. Component philosophy

### What a component is in Burrow (operating definition)

A Phoenix.Component or LiveView component module that:

1. Owns the visual + interactive contract for one named primitive (Button, Input, Sheet, etc.).
2. Defines all its states inline (no consumer is responsible for re-deriving focus / disabled / loading visuals).
3. Maps to DaisyUI base classes via slots/attrs, not by re-implementing DaisyUI behavior.

Components in scope for this system are the ones audit `1A-COMP-RATIO-1` exposed as missing. The existing `<.input>`, `<.button>`, `<.modal>`, `<.icon>` from `core_components.ex` are **kept** — they're correct as-is; the work is migrating consumers onto them.

### State coverage contract

Every interactive component in this spec MUST cover (or explicitly mark N/A):

| State              | When                                                            |
|--------------------|-----------------------------------------------------------------|
| **Default**        | Resting state                                                    |
| **Hover**          | Pointer hover (desktop / mouse)                                   |
| **Focus-visible**  | Keyboard focus (`:focus-visible` only — not `:focus`)            |
| **Active**         | Mouse-down / touch-press                                          |
| **Disabled**       | `disabled` attribute or `aria-disabled="true"`                    |
| **Loading**        | `phx-click-loading` ancestor or explicit `loading={true}` prop    |
| **Error**          | Form-control invalid state (`aria-invalid="true"`)                |
| **Empty**          | List/collection components with no items                          |

If a state is genuinely N/A for a component (e.g. an Avatar has no Loading state), explicitly mark it N/A rather than omit. Phase 4 IMPLEMENTATION.md will not accept a state silently dropped.

---

## 2. Components

### 2.1 Button — **Refined**

**Anchored:** `1B-A11Y-2` (icon-only buttons missing aria-label), `1B-A11Y-6` (no loading state), `1A-TOK-INLINE-1` (inline padding drift).

DaisyUI's `.btn` is the base. This spec defines the wrapper + state coverage on top.

#### Variants

| Variant          | DaisyUI class equivalent     | Use                                                  |
|------------------|------------------------------|------------------------------------------------------|
| `:primary`       | `btn-primary`                 | Primary call-to-action (one per surface, ideally)     |
| `:secondary`     | `btn-secondary` or `btn` (default) | Default action                                  |
| `:tertiary`      | `btn-ghost`                   | Low-emphasis (e.g. "Cancel" in modal)                 |
| `:destructive`   | `btn-error`                   | Delete, irreversible                                  |
| `:icon-only`     | `btn-square btn-ghost` (etc.) | Icon-button — REQUIRES `aria-label` (see below)      |


#### Sizes

| Size  | DaisyUI class | Padding (per `01-foundations.md` §3.3) | Type level |
|-------|---------------|-----------------------------------------|------------|
| `:lg` | `btn-lg`      | `py-3 px-6`                             | `body-strong` (slightly larger) |
| `:md` (default) | `btn` | `py-2 px-4`                             | `body-strong` |
| `:sm` | `btn-sm`      | `py-1.5 px-3`                           | `small-strong` |
| `:xs` | `btn-xs`      | `py-1 px-2`                             | `caption` (12px, 500 weight) |

#### State coverage

| State            | Visual spec                                                                                 |
|------------------|---------------------------------------------------------------------------------------------|
| Default          | DaisyUI variant default.                                                                     |
| Hover            | DaisyUI default hover (lightness shift).                                                     |
| Focus-visible    | 2px ring in `--color-focus-ring` (theme-split; light resolves to `--color-interactive`, dark to `--color-primary`), 2px offset from button edge. Per `04-accessibility.md` §1.2.1. **Apply via `focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2`** — NOT plain `focus:`, and NEVER with an alpha modifier: `ring-focus-ring/60` measures 2.3994:1 in light and fails SC 1.4.11. |
| Active           | DaisyUI default active.                                                                       |
| Disabled         | `aria-disabled="true"` + `pointer-events-none opacity-50`. Click handlers no-op.              |
| **Loading**      | **NEW.** When ancestor has `.phx-click-loading` OR `loading={true}` prop set, replace icon (or prepend if label-only) with `<.icon name="hero-arrow-path" class="animate-spin">`, dim label by `opacity-70`, set `aria-busy="true"`. Click handlers no-op. **Delay-before-show: ~100ms** (Marlowe pin 2026-05-09) — most messages send near-instantly; the spinner should only render once the action exceeds 100ms so fast paths don't flash. Implement via a `setTimeout(showSpinner, 100)` cleared on completion (Phase 4 wires this in the JS hook). |

#### Icon-only buttons

Anchored to `1B-A11Y-2` — 7 named icon-only buttons currently missing aria-label.

Spec for icon-only:
- MUST set `aria-label="<verb> <object>"` (e.g. `aria-label="Close task panel"`).
- Use `:icon-only` variant + `btn-square` so geometry matches the icon size + padding scale.
- Icon size per `01-foundations.md` §7.3.

#### Loading visualization wiring

Anchored to `1B-A11Y-6` — `phx-click-loading` variant declared in `app.css:122` but no CSS rule consumes it.

Add to `app.css` under the Phoenix LiveView variant block:

```css
@layer components {
  .phx-click-loading .btn,
  .btn[aria-busy="true"] {
    cursor: wait;
    opacity: 0.7;
    pointer-events: none;
  }
  /* Icon spinner is rendered by the component, not by CSS — see Button HEEx spec. */
}
```

Phase 4 lands the actual rule. Phase 2 specifies what it does.

#### HEEx component signature (Phase 4 will produce the actual file)

```elixir
attr :variant, :atom, default: :secondary, values: [:primary, :secondary, :tertiary, :destructive, :icon_only]
attr :size, :atom, default: :md, values: [:lg, :md, :sm, :xs]
attr :loading, :boolean, default: false
attr :disabled, :boolean, default: false
attr :type, :string, default: "button"
attr :aria_label, :string, default: nil  # required if variant == :icon_only
attr :rest, :global, include: ~w(form name value phx-click phx-target ...)
slot :inner_block, required: true
slot :icon  # leading icon
```

Phase 4 lands the implementation.

---

### 2.2 IconButton — **Kept** (subsumed under Button :icon-only variant)

Not a separate module. The `:icon_only` variant of Button is the IconButton. This avoids the dual-implementation drift the audit flagged.

The 7 sites in `1B-A11Y-2` (chat_live.html.heex:412, tasks_live.html.heex:89/101/410/1407/1524/1705) all migrate to:

```elixir
<.button variant={:icon_only} aria_label="Close task panel" phx-click="close_task_sheet">
  <:icon><.icon name="hero-x-mark" /></:icon>
</.button>
```

---

### 2.3 Input (text, email, url, number, password) — **Refined**

**Anchored:** `1B-VIS-2` (`<.input>` used once), `1B-A11Y-4` (composer + search inputs without label).

Use the existing `<.input>` from `core_components.ex` — it already generates the `<label for>`-`<input id>` pair, the error block, and helper-text slot. Refinement is consumer migration, not component re-design.

#### Slot contract (already exists in core_components, restated)

```elixir
attr :field, Phoenix.HTML.FormField
attr :type, :string, default: "text", values: ~w(text email number password url tel ...)
attr :label, :string, default: nil
attr :placeholder, :string, default: nil
attr :helper, :string, default: nil
attr :rest, :global
```

#### State coverage

| State           | Visual spec                                                                          |
|-----------------|--------------------------------------------------------------------------------------|
| Default         | DaisyUI `input input-bordered`.                                                       |
| Hover           | Border slightly darker.                                                               |
| Focus-visible   | 2px ring `--color-primary`, no offset (the input border itself is the offset). Per `04-accessibility.md`. **This is what ships today and it is a known SC 1.4.11 miss** — 1.7875:1 in light. See `04-accessibility.md` §1.2.2; owned by task `01a0785c`, not yet merged. New work should use `focus-visible:ring-focus-ring` per §1.4 rather than copying this row. |
| Active          | N/A (form controls don't have a separate active state).                                |
| Disabled        | `disabled` attribute + `bg-base-200 opacity-50 cursor-not-allowed`.                   |
| Loading         | N/A (input loading is the form's button loading).                                      |
| Error           | `aria-invalid="true"` + red border (`border-error`) + error text below in `text-error`. |
| Empty           | N/A.                                                                                  |

#### Migration sites (Phase 4 punch-list)

Every bare `<input>` and `<textarea>` in scope migrates to `<.input>`. Specific sites identified by audit:
- chat_live.html.heex compose textarea (line ~1185) → `<.input type="textarea" field={...}>` with `aria_label` set.
- chat_live.html.heex search input → `<.input type="search">`.
- chat_live.html.heex thread composer → same pattern as above.
- tasks_live.html.heex 4 instances of the auto-resize textarea → `<.input type="textarea">` with the inline-style retrofit per `01-foundations.md` §3.2.

Phase 4 IMPLEMENTATION.md sequences the migration.

---

### 2.4 Textarea (auto-resize variant) — **New**

**Anchored:** `1A-TOK-INLINE-1`.

A specialization of `<.input type="textarea">` for the auto-resize composer pattern. Single component replaces the 5 inline implementations.

#### Slot contract

```elixir
attr :field, Phoenix.HTML.FormField
attr :placeholder, :string, default: nil
attr :aria_label, :string, default: nil  # required if no label visible
attr :max_height, :string, default: "max-h-50"  # 200px scale token, override per surface
attr :min_height, :string, default: "min-h-8"   # 32px scale token
attr :rest, :global
```

The `field-sizing: content` declaration is the auto-resize hint. Kept inline as `style="field-sizing: content"` because there's no Tailwind utility for it (per `01-foundations.md` §3.2).

#### State coverage

Same as Input.

---

### 2.5 Select — **Kept**

DaisyUI `<select class="select select-bordered">`. No drift surfaced in the audit. Phase 4 may extract a `<.select>` wrapper if Form patterns need consistent state coverage.

---

### 2.6 Checkbox / Radio / Toggle — **Kept**

DaisyUI defaults. Add to Phase 4's checklist: verify focus-visible ring applies to these via `04-accessibility.md` global rule.

---

### 2.7 Sheet (mobile bottom-sheet, desktop side-panel) — **New**

**Anchored:** `1B-USE-4` (drawer flag duplication), `1A-IA-DRIFT-5` (drawer ↔ sidebar ↔ nav ↔ menu).

The audit found two flag systems for the same element. This component unifies them.

> **Why a New component for cosmetic-severity findings:** static analysis rated `1B-USE-4` Cosmetic (no confirmed user-facing failure cited statically) and `1A-IA-DRIFT-5` cosmetic (architectural smell, two flags governing one element). The component is escalated to New because the *architectural risk* is high — every future bug class where one flag updates without the other (drawer animation runs but DOM stays in wrong state, sheet open but scroll-lock doesn't engage, back-navigation desync) traces to this pattern. The Phase 4 cost of the unified component is trivial; the cost of one production scroll-lock-desync incident is not. Severity-to-priority mismatch is intentional and earned by future-bug-prevention rather than current-bug-fixing.

#### Slot contract

```elixir
attr :id, :string, required: true
attr :open, :boolean, default: false
attr :placement, :atom, default: :bottom, values: [:bottom, :right, :left, :top]
attr :on_close, :string, default: "close_sheet"  # phx-click event when backdrop tapped
slot :title
slot :inner_block, required: true
slot :actions  # bottom action bar
```

#### State coverage

| State       | Visual spec                                                                              |
|-------------|------------------------------------------------------------------------------------------|
| Closed      | Display: none.                                                                            |
| Open        | Visible. Backdrop with 50% black, sheet panel with `elev-2` shadow (per `01-foundations.md` §5.1). |
| Opening     | Slide-in animation per `04-accessibility.md` motion rule. `prefers-reduced-motion: reduce` disables. |
| Closing     | Reverse of Opening.                                                                       |
| Loading     | N/A (sheet content owns loading).                                                          |

#### Mobile vs desktop behavior

- Mobile (< 768px): full-width bottom-sheet with handle, drag-to-dismiss.
- Desktop (≥ 768px): side-panel sliding in from `placement` direction, fixed-width.

The single `:open` state replaces the multi-flag patterns at:
- `shell_live.ex:58-59` (`drawer_open` + `sidebar_collapsed`)
- `tasks_live.ex:57, :59, :82` (`sidebar_open`, `show_project_sheet`, `show_task_sheet`)

Phase 4 ports each call site.

---

### 2.8 Modal — **Kept**

`<.modal>` from `core_components.ex` is correct. Phase 4 verifies it has focus-trap + escape-to-close (likely already does).

---

### 2.9 Toast / Banner / Inline alert — **Kept structurally, document state coverage**

DaisyUI's `<div class="alert alert-info|success|warning|error">` is the base. Phase 4 may extract `<.alert>` if usage proliferates. For Phase 2 this is documented:

| Variant       | Use                                                       |
|---------------|-----------------------------------------------------------|
| `:info`       | Informational, non-blocking                                 |
| `:success`    | Action confirmation (e.g. "Task created")                   |
| `:warning`    | Caution (e.g. "Approaching usage limit")                    |
| `:error`      | Failure (e.g. "Couldn't save — retry?")                     |

#### State coverage (toast)

| State    | Visual spec                                       |
|----------|---------------------------------------------------|
| Default  | Variant fill + icon.                               |
| Closing  | Fade out per motion rule.                           |
| Auto-dismiss | After 5s for `:success` / `:info`; persistent for `:warning` / `:error` until user dismisses. |

---

### 2.10 Card — **Kept** (no drift)

DaisyUI `<div class="card">`. Used inline in chat / tasks. Padding from `01-foundations.md` §3.3.

---

### 2.11 List / Stream container — **Kept**

LiveView streams are the data contract. No visual component change needed — visuals come from the list-item component (e.g. message bubble, task card) which Phase 4 may extract as needed.

---

### 2.12 Avatar — **Kept**

`<.human_avatar>` from `avatar_components.ex` is correct. Phase 4 may add an `<.agent_avatar>` companion if `1A-IA-DRIFT-4` consolidation surfaces a need; for now agents render via `<.human_avatar>` with a participant_type-derived border.

---

### 2.13 Empty state — **New**

**Anchored:** `1B-USE-3` (empty states lack agent-native context). Marlowe's direction (2026-05-08): brand-new Burrow users' first action is to connect an agent + add them to a channel (or create a channel + add an agent).

#### Slot contract

```elixir
attr :icon, :string, default: nil  # heroicon name
attr :title, :string, required: true
attr :body, :string, default: nil
slot :actions  # primary CTA(s)
```

#### State coverage

Empty state is itself a state visualization. Single visual spec:
- Centered vertically + horizontally in container.
- Icon (large, `w-12 h-12`) above title.
- Title in `display` or `h2` type level.
- Body in `body` type level.
- Action CTAs: 1-2 primary + secondary buttons.

#### Per-surface canonical empty states (`03-voice.md` defines copy)

| Surface               | When                                  | CTA pattern (full copy in `03-voice.md` §5)                                                  |
|-----------------------|---------------------------------------|----------------------------------------------------------------------------------------------|
| Chat sidebar          | Brand-new user, no spaces yet         | "Create a space" + "Connect an agent" (`03-voice.md` §5.1)                                   |
| Chat space (no messages) | Brand-new space / channel, no posts yet | "Add an agent" — body copy: "Connect your agent and @ them to plan and work in this space." (`03-voice.md` §5.2) |
| Tasks                 | No tasks                              | "Create a task" — body copy: "Create a task and assign to an agent to plan and execute." (`03-voice.md` §5.3) |
| Activity              | No agent actions in range             | "Adjust the time range" + "Connect an agent" — body copy explains agent-mediated upstream action (`03-voice.md` §5.4) |

---

## 3. Consolidation roadmap (the audit's biggest leverage)

### Inline-to-component migration order (anchored to Phase 1 finding IDs)

| Order | Pattern (currently inline) | Target component | Sites identified | Anchored finding |
|-------|---------------------------|------------------|------------------|-------------------|
| 1     | Auto-resize composer textarea | `<.input type="textarea">` (Section 2.4) | 5 sites: tasks_live `:1188, :1752, :1764, :1898`, chat_live `:1185` | `1A-TOK-INLINE-1`           |
| 2     | Icon-only buttons missing aria-label | `<.button variant={:icon_only} aria_label="...">` | 7 sites listed in audit | `1B-A11Y-2` |
| 3     | Bare `<input>` / `<textarea>` | `<.input>` | All form-control sites in scope (chat composer, search, mention search, task forms) | `1B-VIS-2`, `1A-COMP-INPUT-1` |
| 4     | Mobile sheet / drawer with multi-flag state | `<.sheet>` (Section 2.7) | shell_live + tasks_live | `1B-USE-4`, `1A-IA-DRIFT-5` |
| 5     | `phx-click-loading` CSS rule | One-liner in `app.css` (Section 2.1) | Global | `1B-A11Y-6` |

Each is a discrete Phase 4 task with effort estimate. Order optimizes for "biggest a11y / consistency win per change."

### What stays inline (intentional)

- LiveView streams (LiveView's own primitive; not a component to consolidate).
- Per-agent accent overrides via `var(--agent-accent, ...)` (per `01-foundations.md` §1.4).
- The `field-sizing: content` declaration on auto-resize textareas (no Tailwind utility; kept inline by `<.input>` Phase 4 wrapper).

---

## 4. Cross-references

- Component padding scale: `01-foundations.md` §3.3.
- Focus-visible ring spec: `04-accessibility.md` §1.
- Loading-state CSS rule: `04-accessibility.md` §5 (motion); reproduced here in Section 2.1.
- Voice for component-level copy (button verbs, error messages, empty-state CTAs): `03-voice.md`.
- Phase 4 ports each component spec to a HEEx file under `docs/design-system/components/[name].md`.
