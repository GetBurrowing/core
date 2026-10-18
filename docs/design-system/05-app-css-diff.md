# 05 — Proposed `app.css` diff

**Phase 4 deliverable.** The exact diff to apply to `apps/platform/assets/css/app.css` to land the design system. **NOT applied here** — this file is the source-of-truth for whatever future code task lands the actual edit.

> **Status of pivot direction:** The Gemini-suggested brand pivot (deep indigo + tactile micro-depth) was evaluated via `system-preview-v2.html` and **rejected by the design lead** (2026-05-09). V1 (original cyan, flat) is canonical. The diff below reflects that.

---

## 1. Light theme — single value change

**Anchored:** `1B-A11Y-5` (audit found light-mode `--color-neutral` paired with white content gives 3.54:1, fails WCAG 1.4.3 AA).

```diff
@plugin "../vendor/daisyui-theme" {
  name: "light";
  default: true;
  prefersdark: false;

  --color-base-100: oklch(100% 0 0);
  --color-base-200: oklch(96% 0 0);
  --color-base-300: oklch(88% 0 0);
  --color-base-content: oklch(0% 0 0);

  --color-primary: oklch(82% 0.12 207);
  --color-primary-content: oklch(0% 0 0);
  --color-secondary: oklch(30% 0.01 0);
  --color-secondary-content: oklch(100% 0 0);
  --color-accent: oklch(82% 0.12 207);
  --color-accent-content: oklch(0% 0 0);

- --color-neutral: oklch(55% 0.01 0);          /* #888888 — white-on-it = 3.54:1 (fails AA) */
+ --color-neutral: oklch(45% 0.01 0);          /* ~#737373 — white-on-it = 4.7:1 (passes AA per audit 1B-A11Y-5) */
  --color-neutral-content: oklch(100% 0 0);

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

**Trade-off:** slightly darker neutral surface in light theme (10% lightness shift). Visually almost imperceptible; functionally moves white-text-on-neutral from sub-AA to passing AA. No dark-theme change needed (dark already passes contrast).

---

## 2. Dark theme — no changes

```diff
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  prefersdark: true;
  /* All values unchanged — already passes WCAG AA across pairings. */
}
```

---

## 3. New CSS rules to add

**Anchored:** `1B-A11Y-1` (no custom focus-visible rules), `1B-A11Y-6` (no button-loading state CSS), `1B-A11Y-3` (`prefers-reduced-motion` only honored for `.reactor-popover`).

Add the following to `app.css` after the existing `@custom-variant` block (around line 124):

```diff
+ /* ──────────────────────────────────────────────────────
+    Focus ring — canonical spec per docs/design-system/04-accessibility.md §1
+    ────────────────────────────────────────────────────── */
+ @layer utilities {
+   .focus-visible-ring:focus-visible {
+     outline: none;
+     box-shadow:
+       0 0 0 2px var(--color-base-100),
+       0 0 0 4px var(--color-primary);
+     border-radius: inherit;
+   }
+
+   /* Inputs use no-offset variant (border itself acts as offset). */
+   .input.focus-visible-ring:focus-visible,
+   .textarea.focus-visible-ring:focus-visible,
+   .select.focus-visible-ring:focus-visible {
+     box-shadow: 0 0 0 2px var(--color-primary);
+   }
+ }
+
+ /* ──────────────────────────────────────────────────────
+    Button loading state — visualize phx-click-loading
+    Anchored to audit 1B-A11Y-6. See docs/design-system/02-components.md §2.1.
+    ────────────────────────────────────────────────────── */
+ @layer components {
+   .phx-click-loading .btn,
+   .btn[aria-busy="true"] {
+     cursor: wait;
+     opacity: 0.7;
+     pointer-events: none;
+   }
+   /* Spinner icon is rendered by the Button component, not by CSS. */
+   /* Delay-before-show (~100ms) is wired in the JS hook, not here. */
+ }
+
+ /* ──────────────────────────────────────────────────────
+    Motion preference — broaden prefers-reduced-motion to all animations
+    Anchored to audit 1B-A11Y-3. Currently only .reactor-popover is gated.
+    ────────────────────────────────────────────────────── */
+ @media (prefers-reduced-motion: reduce) {
+   *,
+   *::before,
+   *::after {
+     animation-duration: 0.01ms !important;
+     animation-iteration-count: 1 !important;
+     transition-duration: 0.01ms !important;
+     scroll-behavior: auto !important;
+   }
+ }
```

---

## 4. Skip-link CSS (a11y)

**Anchored:** `04-accessibility.md` §3.3 (skip-to-main-content).

```diff
+ /* ──────────────────────────────────────────────────────
+    Skip-link — keyboard users can jump past nav
+    ────────────────────────────────────────────────────── */
+ .skip-link {
+   position: absolute;
+   top: -100px;
+   left: 0;
+   z-index: 1000;
+ }
+ .skip-link:focus-visible {
+   position: fixed;
+   top: 8px;
+   left: 8px;
+   padding: 0.5rem 1rem;
+   background: var(--color-primary);
+   color: var(--color-primary-content);
+   border-radius: 0.375rem;
+   font-weight: 600;
+   text-decoration: none;
+ }
```

---

## 5. What the diff does NOT include

- **No new font imports.** Public Sans is already imported.
- **No new Tailwind plugin.** Existing `@plugin` blocks suffice.
- **No removal of existing CSS.** All current rules stay (the only token-value change is the neutral bump). The `@media (prefers-reduced-motion)` block at `app.css:1700` becomes redundant under the broader rule in §3 above; Phase 4 implementer can remove the narrow rule for cleanliness, but not strictly required.
- **No JS changes.** This file covers CSS only. The button-loading delay-before-show, the focus-management on sheet open/close, and the live-region announcements are all JS-hook work covered in `IMPLEMENTATION.md`.

---

## 6. Verification

After applying this diff, run:

1. `mix assets.build` (or restart `mix phx.server`) — verify no Tailwind compile errors.
2. Open `http://localhost:4000/chat` in light mode — verify the neutral tint is slightly darker; verify focus rings appear when tabbing through the composer / sidebar nav / top buttons.
3. Open the same in dark mode — verify nothing visually changed.
4. Re-run lighthouse + axe-core (now installed) against `/chat`, `/tasks`, `/activity` — verify the previously-flagged contrast and focus-order issues are resolved.

If any verification fails, the diff is not landing as expected; check the `app.css` line where the `@plugin` blocks live.
