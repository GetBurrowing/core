# Phase 3 — tokens cheatsheet

**Purpose:** copy-paste reference for the proposed DaisyUI theme variables, type scale, and spacing scale that Phase 3 mocks consume. Confirm with Marlowe before mock generation begins.

> Sources: `docs/design-system/01-foundations.md` (full rationale), `docs/design-system/04-accessibility.md` (focus ring + motion). This file is a cheatsheet, not a re-derivation.

---

## DaisyUI theme variables

### Light mode (proposed — one Refined value vs. current)

```css
@plugin "../vendor/daisyui-theme" {
  name: "light";
  default: true;
  prefersdark: false;

  --color-base-100: oklch(100% 0 0);          /* #FFFFFF */
  --color-base-200: oklch(96% 0 0);           /* #F5F5F5 */
  --color-base-300: oklch(88% 0 0);           /* #E0E0E0 */
  --color-base-content: oklch(0% 0 0);        /* #000000 */

  --color-primary: oklch(82% 0.12 207);       /* #06D5ED — bright cyan, brand */
  --color-primary-content: oklch(0% 0 0);
  --color-secondary: oklch(30% 0.01 0);       /* #4A4A4A */
  --color-secondary-content: oklch(100% 0 0);
  --color-accent: oklch(82% 0.12 207);
  --color-accent-content: oklch(0% 0 0);

  /* REFINED 2026-05-09 per audit 1B-A11Y-5: */
  --color-neutral: oklch(45% 0.01 0);         /* ~#737373 — was oklch(55%)≈#888 (3.54:1, sub-AA) */
  --color-neutral-content: oklch(100% 0 0);   /* white-on-#737373 = 4.7:1 (passes AA) */

  --color-info: oklch(82% 0.12 207);
  --color-info-content: oklch(0% 0 0);
  --color-success: oklch(70% 0.15 162);       /* #10B981 */
  --color-success-content: oklch(100% 0 0);
  --color-warning: oklch(76% 0.17 70);        /* #F59E0B */
  --color-warning-content: oklch(0% 0 0);
  --color-error: oklch(63% 0.22 25);          /* #EF4444 */
  --color-error-content: oklch(100% 0 0);
}
```

### Dark mode (Kept — no value changes)

```css
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  prefersdark: true;

  --color-base-100: #171b25;                  /* Chat pane */
  --color-base-200: oklch(9% 0.018 240);      /* ~#0a0f14 — sidebar */
  --color-base-300: oklch(20% 0.028 240);     /* ~#1a2332 — raised, input bar */
  --color-base-content: oklch(95% 0 0);       /* near-white text */

  --color-primary: oklch(78% 0.14 200);       /* ~#00bcd4 bright cyan */
  --color-primary-content: oklch(0% 0 0);
  --color-secondary: oklch(70% 0.01 0);       /* #B0B0B0 */
  --color-secondary-content: oklch(0% 0 0);
  --color-accent: oklch(82% 0.12 207);
  --color-accent-content: oklch(0% 0 0);

  --color-neutral: oklch(40% 0.01 0);         /* ~#6A6A6A — already passes contrast vs 90% content */
  --color-neutral-content: oklch(90% 0 0);

  --color-info: oklch(82% 0.12 207);
  --color-info-content: oklch(0% 0 0);
  --color-success: oklch(70% 0.15 162);
  --color-success-content: oklch(100% 0 0);
  --color-warning: oklch(76% 0.17 70);
  --color-warning-content: oklch(0% 0 0);
  --color-error: oklch(63% 0.22 25);
  --color-error-content: oklch(100% 0 0);
}
```

---

## Typography scale

Public Sans family (already imported via Google Fonts in `app.css:2`).

| Token         | Tailwind class | Size (rem)      | Line-height | Weight | Letter-spacing | Use                                             |
|---------------|----------------|-----------------|-------------|--------|----------------|-------------------------------------------------|
| `display`     | `text-4xl`     | 2.25rem (36px)  | 1.1         | 800    | -0.02em        | Empty-state headlines, marketing-style overlays |
| `h1`          | `text-3xl`     | 1.875rem (30px) | 1.2         | 700    | -0.015em       | Top-of-page headings                            |
| `h2`          | `text-2xl`     | 1.5rem (24px)   | 1.25        | 700    | -0.01em        | Section headings ("Channels", "Direct Messages") |
| `h3`          | `text-xl`      | 1.25rem (20px)  | 1.3         | 600    | -0.005em       | Sub-section / card title                         |
| `h4`          | `text-lg`      | 1.125rem (18px) | 1.4         | 600    | 0              | Modal/sheet titles                                |
| `body`        | `text-base`    | 1rem (16px)     | 1.5         | 400    | 0              | Default body, message content, form labels       |
| `body-strong` | `text-base`    | 1rem (16px)     | 1.5         | 600    | 0              | Emphasized body, button labels at default size    |
| `small`       | `text-sm`      | 0.875rem (14px) | 1.45        | 400    | 0              | Helper text, secondary metadata, timestamps       |
| `small-strong`| `text-sm`      | 0.875rem (14px) | 1.45        | 500    | 0              | Status labels, badge text                         |
| `caption`     | `text-xs`      | 0.75rem (12px)  | 1.4         | 500    | 0.01em         | Captions, attribution, taxonomy chips             |
| `mono`        | `font-mono text-sm` | 0.875rem (14px) | 1.5     | 400    | 0              | Code blocks, inline `code`                        |

---

## Spacing scale (Tailwind v4 base 4px)

| Token        | Tailwind class | px value | Use                                              |
|--------------|----------------|----------|--------------------------------------------------|
| `space-half` | `p-0.5`        | 2px      | Hairline separator gap                            |
| `space-1`    | `p-1`          | 4px      | Tight inline gap (icon + label)                   |
| `space-2`    | `p-2`          | 8px      | Default inline gap, small button padding-y        |
| `space-3`    | `p-3`          | 12px     | Card / sheet padding-x at small size              |
| `space-4`    | `p-4`          | 16px     | Default card padding, modal padding-y             |
| `space-6`    | `p-6`          | 24px     | Section spacing                                   |
| `space-8`    | `p-8`          | 32px     | Page-level section gap                            |
| `space-12`   | `p-12`         | 48px     | Empty-state vertical breathing                     |
| `space-16`   | `p-16`         | 64px     | Page top/bottom padding on hero surfaces           |

### Component padding (key ones from `01-foundations.md` §3.3)

- Button default (md): `py-2 px-4`
- Button sm: `py-1.5 px-3`
- Button xs: `py-1 px-2`
- Input default: `py-2 px-3`
- Composer textarea (retrofit, anchored to `1A-TOK-INLINE-1`): `py-1.5 px-3 min-h-8 max-h-50` + inline `style="field-sizing: content"`
- Card default: `p-4`
- Sheet body: `p-6`

---

## Radius (Kept — DaisyUI defaults)

| Token         | Tailwind class | Use                                  |
|---------------|----------------|--------------------------------------|
| `radius-sm`   | `rounded`      | Default chip / badge / button-xs     |
| `radius-md`   | `rounded-md`   | Card / button (default)              |
| `radius-lg`   | `rounded-lg`   | Sheet / modal frame                  |
| `radius-full` | `rounded-full` | Avatar / circular icon button        |

---

## Shadow / elevation (New scale)

| Token   | Tailwind class | Use                                                  |
|---------|----------------|------------------------------------------------------|
| `elev-0` | `shadow-none` | Resting surface                                       |
| `elev-1` | `shadow-sm`   | Subtle separation (card-on-cards)                     |
| `elev-2` | `shadow`      | Modal / sheet over background                          |
| `elev-3` | `shadow-md`   | Floating popover / tooltip / dropdown                   |
| `elev-4` | `shadow-lg`   | Modal-over-modal (rare)                                  |

---

## Focus ring (canonical class set)

Apply to every interactive element (`<button>`, `<a>`, `<input>`, `<textarea>`, `<select>`, custom `phx-click` clickables):

```
focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2
```

For inputs (no offset — input border itself is the offset):

```
focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-0
```

---

## Phase 3 mock conventions

Every mock HTML file:

1. Loads Tailwind v4 + DaisyUI 5 from CDN (no local build required for browser-open).
2. Includes the proposed `@plugin "daisyui-theme"` blocks above inline (so contrast fix is applied).
3. Imports Public Sans from Google Fonts.
4. Uses ONLY tokens from this cheatsheet — no invented hex values, no inline `style="color: ..."`. Inline `style=` is permitted ONLY for `field-sizing: content` (no Tailwind utility) and per-agent accent overrides via `style="--agent-accent: ..."`.
5. Default viewport is mobile-first (390×844 reference); desktop variant (1280×800) per finding when relevant.

---

## Confirmation checklist (Marlowe)

Before mock generation begins:

- [ ] Light theme `--color-neutral` bump from `oklch(55%)` → `oklch(45%)` is OK (the only token-value change).
- [ ] Type scale (display / h1-h4 / body / body-strong / small / small-strong / caption / mono) is the right granularity — not too many levels, not too few.
- [ ] Spacing scale stops are right — no missing increment that mocks will need.
- [ ] Shadow / elevation 5-level scale is OK.
- [ ] No tokens missing from this cheatsheet that the mocks will need.

Reply "confirm" or flag specific items to revise. Mocks won't generate until you say so.
