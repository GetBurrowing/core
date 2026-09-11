# 04 — Accessibility

**Phase 2 deliverable.** The accessibility rules every component honors. Anchored to Phase 1 a11y findings; cross-references the focus, motion, and target-size specs from `02-components.md`.

> **Scope reminder:** Suite intentionally locks `maximum-scale=1` because PWA zoom is not the iOS a11y path — Dynamic Type / system font scale is. **Do not propose viewport-meta changes.** This is a Kept decision.

---

## 1. Focus ring spec

**Anchored:** `1B-A11Y-1` (no custom `focus-visible` rules in chat / activity / shell; only 1 in tasks).

### 1.1 The single rule

Every interactive element (`<button>`, `<a>`, `<input>`, `<textarea>`, `<select>`, custom `phx-click` clickables, sidebar nav items, kanban-column drag-handles) MUST show a visible focus indicator on `:focus-visible`. **Not `:focus`** — `:focus` shows on mouse-click, which is visual noise.

### 1.2 Visual spec

| Property         | Value                                                                                |
|------------------|--------------------------------------------------------------------------------------|
| Color            | `var(--color-focus-ring)` — theme-split alias, `#087f93` light / `#06D5ED` dark (see 1.2.1) |
| Width            | 2px                                                                                   |
| Offset           | 2px outside the element (so the ring doesn't overlap the element's own border)        |
| Style            | Solid                                                                                  |
| Shape            | Inherits the element's `border-radius` (i.e. matches a rounded button's curve)        |

### 1.2.1 Why the colour is theme-split, and why it carries no alpha

`--color-primary` (`#06D5ED`) cannot serve as the focus indicator in the light
theme. WCAG 2.2 SC 1.4.11 Non-text Contrast requires **3:1** against every
adjacent ground, and the cyan measures **1.7875:1** on light `base-100`. It gets
worse, not better, on the other grounds. In dark it clears the floor threefold.
One token cannot satisfy both, so the ring has its own slot, `--focus-ring`,
declared per theme and exposed as `--color-focus-ring` (task `01a0833d`):

| theme | resolves to                          | base-100    | base-200    | base-300     |
|-------|--------------------------------------|-------------|-------------|--------------|
| light | `var(--color-interactive)` `#087F93` | 4.7007:1    | 4.1847:1    | 3.2747:1     |
| dark  | `var(--color-primary)` `#06D5ED`     | 9.6304:1    | 11.5762:1   | 10.1049:1    |

Light `base-300` is the tightest pair at 3.2747:1, roughly 0.27 above the floor,
so re-tuning `base-300` lighter is what breaks this first.

**Never write an alpha modifier on the ring colour.** `ring-focus-ring/60` and
`ring-focus-ring/40` both fail the floor even though the token itself passes: in
light they composite to `#6BB2BE` = **2.3994:1** and `#9CCCD4` = **1.7523:1**
over white. An alpha modifier is a change that measures compliant on the token
and fails on the pixels, which is precisely how the previous 37 call sites
passed review while shipping an invisible ring.

Every ratio in this section was computed from `app.css`'s own declarations by
`Platform.Design.WcagContrast`, pinned in
`test/platform/design/focus_ring_slot_test.exs`. None is transcribed from
another document.

### 1.2.2 The `.focus-visible-ring` class reads the same slot

`app.css` also carries a `.focus-visible-ring` **class** (and an
`.input`/`.textarea`/`.select` no-offset variant). Both draw their coloured
band from `var(--color-focus-ring)`, the `@theme inline` mapping of the same
`--focus-ring` the utilities read, so there is exactly ONE backing value per
theme and the class and the utilities cannot drift apart. Task
`01a0785c-bf6f-7001-824d-dd99bcb7db89` stage 3 moved the class off
`var(--color-primary)` (1.7875:1 on light `base-100`) and originally declared
its own `--color-focus-ring` in a bare `:root`; task `01a0833d` landed first
with the `--focus-ring` slot, and the two were collapsed onto it when
`01a0785c` merged. `test/platform/design/primary_contrast_sweep_test.exs`
clauses L6/L7/L8 and D6/D7/D8 measure the class: 4.7007:1 light and 9.6304:1
dark against the page ground for both variants.

### 1.3 Tailwind utility shorthand

### 1.3 How to apply it

Use the `focus-visible-ring` utility class (`app.css:284`):

```
class="focus-visible-ring"
```

It sets `outline: none` (the browser default is inconsistent across browsers) and draws the 2px ring at a 2px offset from `var(--color-focus-ring)`, inheriting the element's `border-radius`.

**Never `ring-primary` for focus.** The set this section used to prescribe
(`focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2`)
paints `--color-primary`, which is the value that failed; the 37 call sites
that carried it were converted to `ring-focus-ring` by task `01a0833d`, and
`test/platform/design/focus_ring_census_test.exs` refuses any new one.

**`ring-focus-ring`, with no alpha modifier and no substitute.** The utility exists only because `--color-focus-ring` is registered in the `@theme inline` block of `app.css`; the vendored daisyUI theme plugin registers nothing with Tailwind on its own. Hand-rolling a `box-shadow` instead looks correct in a screenshot while leaving the utility unminted, so a later reader cannot tell the ring from a styling opinion. See 1.2.1 for the measured ratios.

### 1.4 The exception

Inputs use the ring AT the element edge (not offset), because input borders are themselves visually offset from surrounding content. The same `focus-visible-ring` class covers it: `app.css:293-297` drops the offset for `.input`, `.textarea` and `.select`, and the colour is the same slot.

```
focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-0
```

(or equivalently `focus-visible:ring-offset-0` to override the default).

Its inner neighbour is the control's own border, which a focused input paints `--color-base-content` (`#000000` light, `#EEEEEE` dark) — daisyUI's `utilities`-layer rules win over app.css's `.input:focus` declaration, which does not render. Light measures 4.4674:1 against that border and clears; dark measures 1.5447:1 and is recorded as clause D8 rather than fixed. A colour that clears 3:1 against both the `#EEEEEE` edge and the `#171b25` page ground DOES exist (any relative luminance in [0.132988, 0.252458], e.g. `#797979` at 3.7520:1 and 3.9544:1), so the miss is closable; it was refused on quality, because such a mid-grey ring is the "legal and weak" dark-on-dark indicator the design canvas rejected and drops identification against the page ground from 9.6304:1 to 3.9544:1. A geometric fix (giving the dark no-offset variant a spacer) is the uncosted alternative.

### 1.5 Migration

Phase 4 IMPLEMENTATION.md task: add the ring utilities to every `<.button>`, `<.input>`, `<.link>` site in scope. Where bare `<button>` / `<input>` survives the consolidation, add the utilities directly. Once the consolidated components ship, the ring is component-level and consumers don't think about it.

---

## 2. Target sizes (touch + click)

**Anchored:** WCAG SC 2.5.8 (AA, target size minimum). Static analysis flagged candidates (icon buttons in `1B-A11Y-2`); rendered geometry verification deferred to Phase 1B re-run after lighthouse install (now unblocked).

### 2.1 Minimum sizes

| Context                  | Minimum size                            |
|--------------------------|-----------------------------------------|
| Touch target (mobile, < 768px) | 44 × 44 CSS px                    |
| Click target (desktop)    | 24 × 24 CSS px (WCAG SC 2.5.8 AA min)  |
| Spacing between targets   | At least 8px between adjacent targets   |

### 2.2 How DaisyUI button sizes map

| DaisyUI class | Default rendered size | Mobile-OK?         |
|---------------|-----------------------|--------------------|
| `btn` (md)    | 48 × 48               | ✓                  |
| `btn-sm`      | ~40 × 32              | ✗ (height < 44px)  |
| `btn-xs`      | ~32 × 24              | ✗                  |
| `btn-square` (md) | 48 × 48          | ✓                  |
| `btn-square btn-sm` | ~32 × 32        | ✗                  |
| `btn-square btn-xs` | ~24 × 24        | ✗                  |

### 2.3 The rule

On mobile viewports (< 768px), `btn-sm` and `btn-xs` MUST EITHER:

- (a) Be padded externally so the **hit area** reaches 44×44 (use a wrapper div with `p-2` and `cursor-pointer`), OR
- (b) Be replaced with default-size `btn` on mobile via responsive classes (e.g. `class={["btn-sm md:btn-xs"]}` — desktop-shrunk).

Phase 4 IMPLEMENTATION.md surveys every `btn-sm` / `btn-xs` site in scope and applies one of the two patterns.

### 2.4 The exception

Composer toolbar buttons (e.g. attach / mention-trigger) stay at `btn-sm` for mobile-keyboard-on coexistence; they get strategy (a) (external padding). The composer textarea takes most vertical space; toolbar buttons need hit-area expansion without making the chrome bigger.

---

## 3. Keyboard interaction patterns

### 3.1 Per-component keyboard contract

Every interactive component MUST honor:

| Action                | Component                                          | Key                                  |
|-----------------------|----------------------------------------------------|--------------------------------------|
| Activate              | Button, Link                                       | Enter, Space                          |
| Submit form           | Form                                               | Enter (in any text input)            |
| Newline in textarea   | Textarea (composer specifically)                    | Shift+Enter (Enter sends)            |
| Send composer         | Composer Textarea                                   | Enter (without Shift)                |
| Close modal / sheet   | Modal, Sheet                                        | Escape                                |
| Navigate menu / list  | Sidebar, Mention dropdown                           | Arrow keys                            |
| Focus next interactive | Page                                              | Tab                                  |
| Focus previous         | Page                                              | Shift+Tab                            |
| Jump to composer       | Chat space                                         | `c` (when chat space focused; document in onboarding) |
| Search                 | Page                                              | `/` (browser-friendly)               |

`c` and `/` are nice-to-haves; Phase 4 implements if the work fits.

### 3.2 Focus management on transitions

- Sheet open → move focus into sheet (first interactive element).
- Sheet close → return focus to the trigger.
- Modal open → focus-trap inside modal.
- Modal close → return focus to trigger.
- Page navigation (`<.link navigate>`) → focus the new page's `<h1>` (Phoenix LiveView default, verify in Phase 4).

### 3.3 Skip-link

Add a skip-link as the first focusable element on every page:

```html
<a href="#main-content" class="skip-link">Skip to main content</a>
```

`.skip-link` CSS:

```css
.skip-link {
  position: absolute;
  top: -100px;
  left: 0;
}
.skip-link:focus-visible {
  position: fixed;
  top: 8px;
  left: 8px;
  z-index: 1000;
  padding: 0.5rem 1rem;
  background: var(--color-primary);
  color: var(--color-primary-content);
  border-radius: var(--radius-md);
}
```

Phase 4: add to `apps/platform/lib/platform_web/components/layouts/shell.html.heex` (one site, applies to every authenticated route).

---

## 4. Form labels + errors

**Anchored:** `1B-A11Y-4` (chat composer + search inputs lack `<label>` association).

### 4.1 The rule

Every `<input>` / `<textarea>` / `<select>` MUST have an accessible name. Three valid patterns:

1. **Visible label** — `<label for="input-id">Field name</label> <input id="input-id">`. Preferred.
2. **`aria-label`** — when no visible label is shown (e.g. composer textarea, search input). The aria-label IS the accessible name.
3. **`aria-labelledby`** — when the label is visually adjacent but not in a `<label>` element (e.g. group header that names multiple inputs).

The `<.input>` component handles pattern 1 automatically. For composer/search inputs that ship without a visible label, Phase 4 applies pattern 2 explicitly.

### 4.2 Error pattern

When a form control has a validation error:

- Set `aria-invalid="true"` on the control.
- Set `aria-describedby="<error-id>"` pointing at the error text.
- Render error text below the field with `id="<error-id>"`, `text-error` class, and `role="alert"` (so screen readers announce on appearance).

The `<.input>` component already implements this. Phase 4 verifies + standardizes via consolidation.

### 4.3 Required-field indicator

Mark required fields with both:

- An asterisk visually (`*` after the label).
- `aria-required="true"` on the control.

Use `<.input required>` and the component handles both.

---

## 5. Motion + animation

**Anchored:** `1B-A11Y-3`. Severity: Low (best-practice / WCAG AAA, not AA standard).

### 5.1 The rule

Every animation, transition, or transform in scope MUST EITHER:

- (a) Sit inside a `motion-safe:` Tailwind variant utility, OR
- (b) Sit inside a `@media (prefers-reduced-motion: reduce) { ... }` block in `app.css` that disables it.

The current `app.css:1700-1705` rule scopes only `.reactor-popover`. Phase 4 broadens.

### 5.2 Specific animations to retrofit

| Animation                           | Current state                  | Phase 4 retrofit                                       |
|-------------------------------------|--------------------------------|--------------------------------------------------------|
| Typing-indicator dots (chat_live.html.heex `:1085, :1090, :1095`) | Always animates           | `motion-safe:animate-bounce` per dot; no animation in reduce mode |
| Sheet slide-in                       | Always animates                | Wrap CSS keyframe in `@media (prefers-reduced-motion: reduce) { animation: none; }` |
| Drawer transitions (`SwipeDrawer` hook) | Always animates             | Same — gate the CSS animation                                  |
| Modal fade-in                         | Always animates                | Same                                                              |

### 5.3 The default for new animations

Phase 4 + future work: any new CSS keyframe or Tailwind animation utility MUST include the reduce-motion gate. Add to AGENTS.md as a check item.

### 5.4 Rationale for severity Low

WCAG 2.3.3 (Animation from Interactions) is AAA, not AA. There's no clean AA criterion covering user-triggered animations. Suite still honors the rule because: (a) motion-sensitive users are a real population, (b) the agent-native UX has constant motion (typing indicators) which exacerbates, (c) the cost of adding the gates is trivial.

---

## 6. Color contrast

**Anchored:** `1B-A11Y-5`.

### 6.1 The rule

Every text/background pairing in scope MUST meet WCAG SC 1.4.3 (AA):

- Normal text (< 18pt or < 14pt bold): 4.5:1 minimum.
- Large text (≥ 18pt or ≥ 14pt bold): 3:1 minimum.
- Non-text UI components (icons, button fills, focus rings against backgrounds): 3:1 minimum (SC 1.4.11).

### 6.2 The exception (now resolved)

Light theme `--color-neutral` paired with `--color-neutral-content` (white-on-#888888) measures 3.54:1. **Resolved** in `01-foundations.md` §1.2 by bumping `--color-neutral` to `oklch(45% 0.01 0)` ≈ `#737373` (white-on-which = 4.7:1).

### 6.3 Verification

Phase 4 IMPLEMENTATION.md task: re-run lighthouse + axe-core (now unblocked, Marlowe installed) against each in-scope surface to surface any contrast failures static computation missed. The single-token fix in §6.2 may not be the only finding.

---

## 7. Screen reader patterns

### 7.1 Live regions for status updates

Where the UI updates without user-initiated action (e.g. new message arrives, agent finishes a tool call), use ARIA live regions:

- `aria-live="polite"` for non-urgent (most cases — new message, save confirmation).
- `aria-live="assertive"` for critical (errors that interrupt user flow). Use sparingly.

Phase 4 audits where Suite currently fires LiveView updates without live-region wrapping. The chat surface specifically: incoming messages should announce sender + first 50 chars or so.

### 7.2 Heading hierarchy

Each route has exactly one `<h1>`. Sections within the page use `<h2>` etc. Skip-link in §3.3 lands on the `<h1>`'s container.

### 7.3 Landmark roles

Use semantic HTML over ARIA roles:

- `<header>`, `<nav>`, `<main>`, `<footer>`, `<aside>` for page chrome.
- ARIA roles only where semantic HTML doesn't fit (e.g. `role="dialog"` on the modal — though `<dialog>` is an option Phase 4 should evaluate).

---

## 8. What this doc does NOT cover

- **Specific axe-core / lighthouse scan results** — re-run after install lands. Findings slot into `02-audit.md` amendments + Phase 4's IMPLEMENTATION.md.
- **Voice-control compatibility** (e.g. Voice Access on Android, Voice Control on iOS) — out of scope for Phase 2; Phase 4 may re-audit per surface if Marlowe raises.
- **High-contrast / forced-colors mode** — not in audit scope; Phase 4 follow-up.

---

## 9. Cross-references

- Focus ring is consumed by Button (`02-components.md` §2.1), Input (§2.3), Link, and any custom `phx-click` clickable.
- Target sizes interact with Button size variants (`02-components.md` §2.1).
- Motion rule applies to Sheet (`02-components.md` §2.7), Modal (§2.8), Toast (§2.9), and any new animated component.
- Color contrast is enforced via the foundations diff (`01-foundations.md` §1.2).
- Form-label/error patterns are enforced via Input (`02-components.md` §2.3).
