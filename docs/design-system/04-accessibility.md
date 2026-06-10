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
| Color            | `var(--color-primary)` (cyan; same in light + dark themes)                            |
| Width            | 2px                                                                                   |
| Offset           | 2px outside the element (so the ring doesn't overlap the element's own border)        |
| Style            | Solid                                                                                  |
| Shape            | Inherits the element's `border-radius` (i.e. matches a rounded button's curve)        |

### 1.3 Tailwind utility shorthand

Use this exact set on every interactive element (Phase 4 components apply globally):

```
focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2
```

`outline-none` removes the browser default (which is inconsistent across browsers), and the `ring-*` utilities provide the consistent replacement.

### 1.4 The exception

Inputs use the ring AT the element edge (not offset), because input borders are themselves visually offset from surrounding content. Apply:

```
focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-0
```

(or equivalently `focus-visible:ring-offset-0` to override the default).

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
