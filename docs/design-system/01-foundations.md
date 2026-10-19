# 01 — Foundations

**Phase 2 deliverable.** Tokens for color, typography, spacing, radius, shadow/elevation, border-weight, and iconography. Every decision labelled `Kept` / `Refined` / `New` with rationale.

The token model is **two-layer for now**: primitive (oklch values) → semantic (DaisyUI variable names). Component-level tokens (e.g. `--btn-padding-x`) are deferred to Phase 4 unless the audit surfaced a specific need (it didn't — color tokens are well-disciplined, and component-token scaffolding adds complexity without payoff at this scale).

---

## 1. Color

### 1.1 Semantic token names — **Kept**

DaisyUI 5's semantic vocabulary is preserved verbatim. Every component reads from these names; underlying primitive values change between themes.

| Token name              | Role                                     |
|-------------------------|------------------------------------------|
| `--color-base-100`      | Surface background (chat pane, content)   |
| `--color-base-200`      | Sidebar / secondary surface                |
| `--color-base-300`      | Raised surface (input bar, modal frame)    |
| `--color-base-content`  | Text on `base-*` surfaces                 |
| `--color-primary`       | Accent / call-to-action / brand           |
| `--color-primary-content` | Text on primary fill                    |
| `--color-secondary`     | Secondary action / muted accent            |
| `--color-secondary-content` | Text on secondary fill                |
| `--color-accent`        | Tertiary accent                            |
| `--color-accent-content` | Text on accent fill                      |
| `--color-neutral`       | Neutral surface (badges, default chip)     |
| `--color-neutral-content` | Text on neutral fill                    |
| `--color-info`          | Informational state                        |
| `--color-info-content`  | Text on info fill                          |
| `--color-success`       | Success state                              |
| `--color-success-content` | Text on success fill                    |
| `--color-warning`       | Caution state                              |
| `--color-warning-content` | Text on warning fill                    |
| `--color-error`         | Failure state                              |
| `--color-error-content` | Text on error fill                          |

**Why kept:** the audit's token-discipline finding (`1A-COMP-RATIO-1` and `01-inventory.md` Section 3) confirmed the existing color tokenization is genuinely strong — only 2 hex literals across all in-scope HEEx, 0 rgb/hsl. The semantic names are already right.

### 1.2 Light theme primitive values — **Refined** (one value)

**Anchored:** `1B-A11Y-5`.

> **2026-05-09 update:** brand-pivot direction (Gemini-suggested deep indigo + tactile micro-depth) was evaluated via `system-preview-v2.html` and **rejected by the design lead** — V1 (original cyan, flat) is the canonical brand. Pivot artifact preserved at `audit/2026-05-08-ui-ux/mocks/_preview/system-preview-v2.html` for record-keeping.

The single token-value change in this entire system: bump `--color-neutral` (light theme) so neutral-content (white) on it meets WCAG 1.4.3 AA contrast.

| Token                       | Current (`oklch`)        | Current sRGB | White-on-it | Proposed (`oklch`)     | Proposed sRGB | White-on-it |
|-----------------------------|--------------------------|--------------|--------------|--------------------------|----------------|--------------|
| `--color-neutral` (light)   | `oklch(55% 0.01 0)`      | `#888888`    | **3.54:1 ✗** | `oklch(45% 0.01 0)`     | `~#737373`     | **4.7:1 ✓**  |

All other token pairings in both themes already meet WCAG AA when computed (light: black-on-white 21:1, primary cyan with black-content very high, secondary `#4A4A4A` with white-content ~9:1; dark: all pairings derived from base-100 `#171b25` with `oklch(95%)` content meet 13:1+).

**Refined `app.css` diff (proposed; Phase 4 lands the actual edit):**

```diff
@plugin "../vendor/daisyui-theme" {
  // light-mode block, line 44-71 in app.css
- --color-neutral: oklch(55% 0.01 0);         /* #888888 */
+ --color-neutral: oklch(45% 0.01 0);         /* ~#737373 — bumped to meet 4.5:1 contrast vs neutral-content per audit 1B-A11Y-5 */
}
```

Trade-off: slightly darker neutral surface in light theme. Visually almost imperceptible (10% lightness shift); functionally moves white-text-on-neutral from sub-AA to passing AA. No dark-theme change needed.

### 1.3 Dark theme — **Kept** (no value changes)

Dark theme already passes contrast across pairings. The base-100 `#171b25` with `oklch(95%)` text content gives ~13:1, well above AAA. Other tokens follow.

### 1.4 Per-agent accent override — **Kept** (existing pattern)

The existing inline use of `var(--agent-accent, oklch(82% 0.12 207))` (chat_live.html.heex:1066, :1070) is a runtime per-agent customization and is preserved. Phase 2 does not add a new token; it documents the existing one.

| Token            | Default                  | When set        |
|------------------|--------------------------|-----------------|
| `--agent-accent` | `oklch(82% 0.12 207)` (cyan, renders `#4EDAEB`; no longer tracks `--color-primary`, which is `#06D5ED` in both themes as of task 01a07435) | Overridden per-agent at runtime; agents may set their own accent within a contrast-safe range. |

Phase 4 should add a runtime contrast guard: if a user-supplied `--agent-accent` lightness is outside `[35%, 80%]`, clamp it (or warn). Out of scope for Phase 2 spec.

### 1.5 Scope-pill label text — `text-<scope>-label` — **New** (AA-tuned label token)

**Anchored:** `1B-A11Y-5` (same label-on-tint contrast finding as §1.2).

The scope pill (§8.3) renders its label in the scope's own hue on a soft 12 %
`bg-<scope>` tint. The full-saturation `text-<scope>` token (returned by
`Platform.Tenancy.scope_color/1`, tuned for the dot and active fill) sat
**below WCAG 1.4.3 AA** as label text on that tint at `text-xs` — e.g. initech
~3.0 : 1 in light. A dedicated, darker **`text-<scope>-label`** token now colors
the non-active chip label only: same hue + chroma, lower lightness, so the scope
identity is preserved while the label clears AA (≥ 4.5 : 1).

It is **theme-aware** — the base rule is the light (darker) value, and a
`[data-theme=dark] .text-<scope>-label` override carries the dark value (only
initech is nudged, `0.65 → 0.67` L, to clear AA in dark; the rest reuse the
existing dark lightness).

| Scope | Light `oklch` | Dark `oklch` | Light ratio¹ | Dark ratio² |
|---------|----------------|----------------|--------|--------|
| initech      | `55% 0.20 295` | `67% 0.20 295` | 4.66 ✓ | 4.56 ✓ |
| vandelay_ind | `52% 0.15 240` | `68% 0.15 240` | 4.66 ✓ | 5.11 ✓ |
| globex       | `51% 0.15 162` | `70% 0.15 162` | 4.56 ✓ | 5.71 ✓ |
| hooli        | `54% 0.16 95`  | `80% 0.16 95`  | 4.65 ✓ | 7.31 ✓ |

¹ label vs composited 12 % tint over light base-100 `#FFFFFF`.
² label vs composited 12 % tint over dark base-100 `#171b25`.
All ten pairings ≥ 4.5 : 1 (OKLCH → sRGB → WCAG 2.x, recomputed 2026-06-23).

**Deliberately out of scope of this token:** the colored dot (`bg-<scope>-dot`)
stays full-saturation as the WCAG 1.4.1 redundant-colour cue; the active pill
(`bg-<scope>-active`) bakes its own contrast-safe text; and
`Platform.Tenancy.scope_color/1` is **unchanged** — it has a second consumer
(`inheritance_pill.ex`) and is not pill-specific, so a pill-only token is the
correct seam rather than editing the shared one. Defined in `app.css`
`@layer utilities`; consumed by `ScopePill.chip_color_classes/3` (`active: false`
clause only).

---

## 2. Typography

### 2.1 Family — **Kept**

Public Sans (already imported via Google Fonts in `app.css:2`). Variable weights 400, 500, 600, 700, 800, 900 loaded.

### 2.2 Type scale — **New** (no scale exists today)

**Anchored:** `1B-VIS-1` (token discipline at the *component* layer is the weakness).

The audit found no explicit type scale; sizes are picked ad-hoc per HEEx via Tailwind utilities (`text-xs`, `text-sm`, `text-base`, `text-lg`, etc.). The proposed scale formalizes purpose per size, so Phase 4 components can map to scale levels rather than re-pick sizes.

| Token name        | Tailwind class equivalent | Size (rem)       | Line-height | Weight   | Letter-spacing | Use                                                       |
|-------------------|----------------------------|------------------|-------------|----------|------------------|-----------------------------------------------------------|
| `display`         | `text-4xl`                | 2.25rem (36px)   | 1.1         | 800      | -0.02em          | Empty-state headlines, marketing-style overlays           |
| `h1`              | `text-3xl`                | 1.875rem (30px)  | 1.2         | 700      | -0.015em         | Top-of-page headings                                       |
| `h2`              | `text-2xl`                | 1.5rem (24px)    | 1.25        | 700      | -0.01em          | Section headings (e.g. "Channels", "Direct Messages")     |
| `h3`              | `text-xl`                 | 1.25rem (20px)   | 1.3         | 600      | -0.005em         | Sub-section / card title                                  |
| `h4`              | `text-lg`                 | 1.125rem (18px)  | 1.4         | 600      | 0                | Modal/sheet titles                                        |
| `body`            | `text-base`               | 1rem (16px)      | 1.5         | 400      | 0                | Default body, message content, form labels                |
| `body-strong`     | `text-base`               | 1rem (16px)      | 1.5         | 600      | 0                | Emphasized body, button labels at default size            |
| `small`           | `text-sm`                 | 0.875rem (14px)  | 1.45        | 400      | 0                | Helper text, secondary metadata, timestamps                |
| `small-strong`    | `text-sm`                 | 0.875rem (14px)  | 1.45        | 500      | 0                | Status labels, badge text                                 |
| `caption`         | `text-xs`                 | 0.75rem (12px)   | 1.4         | 500      | 0.01em           | Captions, attribution, taxonomy chips                     |
| `mono`            | `font-mono text-sm`       | 0.875rem (14px)  | 1.5         | 400      | 0                | Code blocks, monospace inline (`code`)                    |

**Why these choices:**

- 9 levels covers Burrow's surface variety without over-fragmenting (audited surfaces have at most 3 hierarchy levels visible per screen).
- `body-strong` and `small-strong` exist as paired weight-variants to avoid re-tokenizing weight per surface (e.g. button labels are `body-strong`, not a separate `button-label-bold` token).
- Letter-spacing tightens at display sizes (perceptual default for large type), neutral at body, opens slightly at caption.
- Mono via Tailwind's default mono stack — no new font import needed.

### 2.3 Mapping to surface — **New**

| Surface element                       | Type level     |
|---------------------------------------|----------------|
| Page titles (`/chat`, `/tasks`, `/activity`) | `h1`     |
| Sidebar section headers ("Channels", "Direct Messages") | `h2` |
| Message author name in chat            | `body-strong`  |
| Message body                            | `body`         |
| Message timestamp / "edited" affix      | `small`        |
| Task card title                         | `body-strong`  |
| Task card metadata (assignee, due date) | `small`        |
| Empty-state headline                    | `display` or `h2` (depending on viewport) |
| Empty-state body                        | `body`         |
| Empty-state action label                | `body-strong`  |
| Form labels                              | `small-strong` |
| Form helper text                         | `small`        |
| Form error text                          | `small`        |
| Button label (default size)             | `body-strong`  |
| Button label (sm)                       | `small-strong` |
| Toast / banner content                   | `body`         |

---

## 3. Spacing

### 3.1 Base unit — **Kept**

Tailwind v4 default: 4px base. `1` = 4px, `2` = 8px, `3` = 12px, `4` = 16px, etc.

### 3.2 Scale — **Refined** (constrain inline-style values to scale)

**Anchored:** `1A-TOK-INLINE-1`.

The audit found 5 verbatim repeats of an inline style declaring `padding: 6px 12px` and `min-height: 33px` for the auto-resize textarea. None of these values are on the Tailwind scale. Phase 2 ratifies the existing scale and pins composer values to it.

| Scale token     | Tailwind class | px value | Use                                          |
|-----------------|----------------|----------|----------------------------------------------|
| `space-0`       | `p-0`          | 0        | Reset                                         |
| `space-half`    | `p-0.5`        | 2px      | Hairline separator gap                        |
| `space-1`       | `p-1`          | 4px      | Tight inline gap (icon + label)               |
| `space-2`       | `p-2`          | 8px      | Default inline gap, small button padding-y    |
| `space-3`       | `p-3`          | 12px     | Card / sheet padding-x at small size          |
| `space-4`       | `p-4`          | 16px     | Default card padding, modal padding-y         |
| `space-6`       | `p-6`          | 24px     | Section spacing                                |
| `space-8`       | `p-8`          | 32px     | Page-level section gap                        |
| `space-12`      | `p-12`         | 48px     | Empty-state vertical breathing                  |
| `space-16`      | `p-16`         | 64px     | Page top/bottom padding on hero surfaces       |

**The composer auto-resize textarea retrofit (anchor of `1A-TOK-INLINE-1`):**

| Property            | Current inline (5x)            | Refined (Tailwind class)                     |
|---------------------|--------------------------------|----------------------------------------------|
| `padding`           | `6px 12px` (1.5x scale, 3x scale) | `py-1.5 px-3` (still 6px 12px — pin to scale tokens, no value change) |
| `min-height`        | `33px` (off-scale)               | `min-h-[2rem]` (32px — 1px shift to scale)   |
| `max-height`        | `200px` (off-scale)              | `max-h-50` (200px — Tailwind v4 supports `50` as 200px on the spacing scale) |
| `line-height`       | `1.5`                            | `leading-normal` (Tailwind default ~1.5)     |
| `field-sizing`      | `content`                        | (no Tailwind utility; keep inline as `style="field-sizing:content"`) |

The `field-sizing: content` declaration is the **only** inline style that survives — it's a CSS property without a Tailwind utility, and it's what makes the textarea auto-resize. Component spec (Phase 2 02-components.md / Phase 4) calls out the surviving inline.

### 3.3 Mapping to surface — **New**

| Component               | Padding spec                                                                   |
|-------------------------|--------------------------------------------------------------------------------|
| Button (default size)   | `py-2 px-4`                                                                    |
| Button (`btn-sm`)       | `py-1.5 px-3`                                                                  |
| Button (`btn-xs`)       | `py-1 px-2`                                                                    |
| Button (`btn-square`)   | `p-2` (default), `p-1.5` (`btn-sm`), `p-1` (`btn-xs`) — width/height auto from icon size |
| Input / textarea (default) | `py-2 px-3`                                                                  |
| Input (composer textarea, retrofit) | `py-1.5 px-3` per Section 3.2 above                                  |
| Card (default)          | `p-4`                                                                          |
| Card (compact, e.g. task-card in column) | `p-3`                                                            |
| Sheet / modal           | `p-6` body, `px-6 py-4` header                                                 |
| Section gap             | `space-y-6` between sections                                                   |

---

## 4. Radius

### 4.1 Scale — **Kept** (DaisyUI defaults)

| Scale token   | Tailwind class    | Use                                 |
|---------------|-------------------|-------------------------------------|
| `radius-none` | `rounded-none`    | Reset                                |
| `radius-sm`   | `rounded`         | Default chip / badge / button-xs    |
| `radius-md`   | `rounded-md`      | Card / button (default)              |
| `radius-lg`   | `rounded-lg`      | Sheet / modal frame                  |
| `radius-xl`   | `rounded-xl`      | Hero surface (rare)                   |
| `radius-full` | `rounded-full`    | Avatar / circular icon button         |

DaisyUI's default `--radius-*` variables are preserved. No audit finding flagged radius drift.

---

## 5. Shadow / elevation

### 5.1 Scale — **New** (no explicit scale today)

**Anchored:** `1B-VIS-1`.

The audit found ad-hoc shadow utilities. Phase 2 introduces a 5-level scale to give floating elements consistent perceived elevation.

| Token             | Tailwind class | Use                                                            |
|-------------------|----------------|----------------------------------------------------------------|
| `elev-0`          | `shadow-none`  | Resting surface; no shadow                                       |
| `elev-1`          | `shadow-sm`    | Subtle separation (raised card on a sea of cards)                |
| `elev-2`          | `shadow`       | Default modal / sheet over background                             |
| `elev-3`          | `shadow-md`    | Floating popover / tooltip / dropdown                              |
| `elev-4`          | `shadow-lg`    | Modal-over-modal (rare); attention-demanding banner                 |

Mapping:
- Sheet (mobile bottom-sheet): `elev-2`
- Modal: `elev-2`
- Popover (mention dropdown, emoji picker): `elev-3`
- Toast: `elev-3`
- In-content cards: `elev-0` or `elev-1`

---

## 6. Border-weight

### 6.1 Scale — **Kept**

| Token        | Tailwind class | Use                                                                |
|--------------|----------------|--------------------------------------------------------------------|
| `border-0`   | `border-0`     | Reset                                                              |
| `border-1`   | `border`       | Default 1px (most surfaces)                                         |
| `border-2`   | `border-2`     | Focus ring base; emphasized boundary                                |
| `border-3`   | `border-[3px]` | Focus-ring with offset (specific to `04-accessibility.md` focus spec) |

Border colors source from `--edge` (subtle, via the `border-edge` class) or `--color-primary` (focus / accent).

`--color-base-300` is a FILL token only. Do not use it for borders. On the dark theme it is darker than `--color-base-100`, so a `base-300` border on a card surface measured 1.0478:1 and could not be seen (task 01a0740b). Retuning the token could not fix that, because base-300 is also the raised fill on the near-black `base-200` sidebar, where it has to stay lighter than `base-200` while sitting darker than `base-100`. One token, two jobs, opposite requirements. The border job therefore moved to `--edge`, which is lighter than `base-100` on dark and identical to the shipped light value on light.

---

## 7. Iconography

### 7.1 Family — **Kept**

Heroicons via the `<.icon name="hero-...">` Phoenix component (per `apps/platform/AGENTS.md`).

### 7.2 Style — **Refined** (formalize when to use outline vs solid)

**Anchored:** `1B-VIS-1` — the same token discipline finding that exposed weakness at the component layer applies to icon variant discipline. The audit didn't enumerate icon-variant drift specifically, but the current code uses outline and solid interchangeably without a rule, which is the same class of inconsistency the visual-coherence finding covers. Pinning the rule:

| Icon variant   | When                                                                                |
|----------------|--------------------------------------------------------------------------------------|
| **Outline**    | Default. Used everywhere unless there's a reason to switch.                          |
| **Solid**      | Only for: (a) active / selected nav item, (b) filled state of a toggle (e.g. star, pin, bookmark), (c) emphasized status icons in toasts. |
| **Mini** (size variant) | Inline with body text only (e.g. inside a sentence). Otherwise use the size-prop spec below. |

### 7.3 Sizing — **New**

| Context                              | Size class       |
|--------------------------------------|------------------|
| Inline with body text                  | `w-4 h-4` (16px) |
| Default standalone (button icon)        | `w-5 h-5` (20px) |
| Hero / illustration empty-state         | `w-8 h-8` (32px) or larger |
| Sidebar nav item                        | `w-5 h-5` (20px) |
| Action bar (e.g. toolbar)               | `w-5 h-5` (20px) |
| Avatar fallback (when no image)         | `w-6 h-6` (24px) inside circular container |

---

## 8. Mobile primitives

> Added 2026-06-13 (mobile foundation primitives task). Records what shipped so
> the sibling mobile-parity surfaces lift these without rediscovery. Descriptive
> of current reality, not new policy.

### 8.1 Navigation rail — responsive, two renders

`PlatformWeb.Components.IconRail` exposes one canonical destination list with two
renders (`apps/platform/lib/platform_web/components/icon_rail.ex`):

- **Desktop** (`icon_rail/1`, `≥ lg`): vertical left rail, 56px collapsed / 224px
  expanded.
- **Mobile** (`bottom_rail/1`, `< lg`): a fixed-bottom **5-tile** bar —
  Chat / Tasks / Inbox / Activity / **More**. The long tail (Skills, Org Memory,
  Meetings, and root-org-only Admin/Prompts) lives in the `MoreSheet` bottom sheet
  behind the More tile.

This settles the task's open "9 icons vs 5 + More at 375px" question: **5 + More**.
At 375px, 5 tiles ≈ 75px each (thumb-comfortable); 9 would be ≈ 41px, below the
44px touch-target floor.

**Active state** uses segment-boundary longest-prefix matching against the
request path, so a nested route (`/chat/:slug`, `/tasks/:id`) lights its parent
tile and the longest match wins (`/admin/prompts` → Prompts, not Admin). A single
`active_key` drives both the highlight class and `aria-current="page"`. On the
mobile bar the winner is computed over the 4 primary tiles only, so a
More-sheet-only surface lights nothing in the bar.

### 8.2 Fixed-bottom clearance — `--bottom-nav-height`

`app.css` exposes `--bottom-nav-height` (0px on desktop, 56px below `lg`, matching
`.bottom-nav-tab` min-height). Any always-on bottom-anchored UI (floating panels,
toasts, scroll-to-bottom buttons) must offset above the bar with
`calc(… + var(--bottom-nav-height))` rather than hard-coding 56px. `.bottom-nav`
already bakes in `padding-bottom: env(safe-area-inset-bottom)` so the bar extends
into the iOS home-indicator gesture zone.

### 8.3 Scope pill — `:size` density variant

`PlatformWeb.Components.ScopePill` takes `size={:default | :compact}`. **Text
stays `text-xs` (12px) at both sizes** — the caption token (§2.2) is the
legibility floor; density comes from chrome, never from shrinking type. At that
size the non-active label uses the AA-tuned `text-<scope>-label` token (§1.5),
not the full-saturation `text-<scope>`, so the colored label clears WCAG 1.4.3
on the 12 % `bg-<scope>` tint.

| | `:default` | `:compact` |
|---|---|---|
| Use | chat header, filter rails, kanban | message rows, card chrome (tight space) |
| Chrome | bordered, `px-2 py-0.5`, `size-2` dot | **no border**, `px-1.5 py-px`, `size-1.5` dot, label `truncate max-w-20` |
| Clickable | defaults to `true` | defaults to **`false`** (a ~16px tap target fails WCAG 2.5.8); opt in with `clickable={true}`, which adds `.scope-pill-hit-expand` (≥24px invisible tap area) |
| Active | colored fill + check icon | colored fill + dot (a ~12px check is illegible) |
| Propagated (`A → B`) | two chips + arrow | source chip only; full provenance in `title` + `aria-label` |

Guidance: keep dense message-row pills non-clickable (read-only provenance);
surfaces that need tap-to-filter use `:default`.

---

## 9. What's NOT in foundations

- **Component-level tokens** (e.g. `--btn-padding-x` per-button-size). Adds complexity without payoff at this scale; the Tailwind utility classes mapping to scale tokens IS the component-level spec for Burrow. If component-token scaffolding becomes a need later (e.g. a third-party theming layer), Phase 4 can promote.
- **Animation timing tokens** (e.g. `--duration-fast`, `--duration-slow`). Deferred to `04-accessibility.md` as part of the motion rule, since the audit's only animation finding is `1B-A11Y-3` (`prefers-reduced-motion`), which gates *whether* animation runs more than how long it takes.
- **Iconography weight tokens** beyond outline/solid. Heroicons doesn't expose a weight axis; a custom icon font would, but Phase 2 keeps the system on Heroicons.

---

## Cross-references

- Color contrast computation: anchored to audit `1B-A11Y-5`.
- Scope-pill label contrast (`text-<scope>-label`, §1.5): anchored to audit `1B-A11Y-5`.
- Inline-style retrofit (composer textarea): anchored to audit `1A-TOK-INLINE-1`.
- Component-level state visualization (focus ring, loading, etc.): see `04-accessibility.md` and `02-components.md`.
- Voice / copy decisions that apply to Display / Empty-state typography: see `03-voice.md`.
