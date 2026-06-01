# Suite design system — overview

**Authored:** 2026-05-08 by saru-claude-clode for Marlowe's UI/UX audit + design system refinement.
**Source-of-truth document for:** the visual + interaction conventions the Suite core platform follows. **Refined**, not invented — the existing system is DaisyUI 5 + Tailwind v4 + Public Sans on a Phoenix LiveView app, and this spec sharpens it rather than replacing it.

> **Status:** Approved by Marlowe and committed to the repo 2026-06-01. After approval, Phase 3 produces mock variations against this system, then Phase 4 finalizes with HEEx component specs.

## What this system is

A canonical specification for:

- **Foundations** — color tokens, typography scale, spacing scale, radius/shadow/border, iconography ([`01-foundations.md`](./01-foundations.md))
- **Components** — button, input, sheet, drawer, etc., with full state coverage ([`02-components.md`](./02-components.md))
- **Voice** — copy guidance, button verbs, error messages, agent-native empty states ([`03-voice.md`](./03-voice.md))
- **Accessibility** — focus rings, target sizes, motion, keyboard interaction ([`04-accessibility.md`](./04-accessibility.md))

After Gate 3 (Marlowe picks variations), Phase 4 adds:
- `05-app-css-diff.md` — proposed daisyui-theme diff (NOT applied — proposed only)
- `components/[name].md` — per-component HEEx specs
- `IMPLEMENTATION.md` — ordered fix list with effort estimates

## Authoring rules (apply throughout this directory)

1. **Every decision is labelled** **`Kept`** (working as-is) / **`Refined`** (preserved but improved) / **`New`** (introduced to fix a gap).
2. **Every Refined or New decision cites a Phase 1 finding ID** by reference. No taste claims without reasoning. Phase 1 docs live at `audit/2026-05-08-ui-ux/01-inventory.md` and `02-audit.md`.
3. **No code is modified in any phase.** Workflow ends at handoff specs. Phase 4's IMPLEMENTATION.md is the bridge to actual code work.
4. **DaisyUI 5 + Public Sans + the agent-native voice** is the active system. We sharpen, don't invent. If brand intent is unclear in a specific surface, ask before proposing direction.
5. **Suite intentionally locks `maximum-scale=1`.** iOS a11y is via Dynamic Type / font scale. Do not propose viewport-meta changes.

## Pinned decisions (settled before Phase 2 drafting)

| Decision                                                                  | Source                              | Status         |
|---------------------------------------------------------------------------|--------------------------------------|----------------|
| Canonical term for the chat-entity primitive: **`space`**                  | Marlowe, 2026-05-08, resolves `1A-IA-DRIFT-1` | Pinned         |
| "Channels" and "DMs" remain as section labels / kinds-of-space in copy   | Marlowe, 2026-05-08                    | Pinned         |
| Bigger-picture: data model is already `space` — UI vocabulary aligns to it | Implicit; matches codebase + MCP    | Confirmed      |

Additional canonical-term picks (DRIFT-2/3/4) are deferred to `03-voice.md` for Marlowe's call.

## How Phase 1 findings map to this system

| Phase 1 finding                                                                | Phase 2 section it anchors      |
|--------------------------------------------------------------------------------|----------------------------------|
| `1B-A11Y-5` — `--color-neutral` light fails 4.5:1                               | `01-foundations.md` color        |
| `1A-TOK-INLINE-1` — auto-resize textarea repeated 5x with drift                  | `01-foundations.md` spacing + `02-components.md` Input |
| `1B-A11Y-1` — no custom focus-visible rules                                       | `04-accessibility.md` focus ring |
| `1B-A11Y-6` — no button-loading state                                             | `02-components.md` Button (loading) |
| `1B-A11Y-2` — 7 icon-only buttons missing accessible names                        | `02-components.md` IconButton     |
| `1B-VIS-2` — `<.input>` used once; bare inputs everywhere                          | `02-components.md` Input + Form patterns |
| `1B-USE-3` — empty states lack agent-native context (Marlowe: connect-agent + add-to-space) | `03-voice.md` empty-state pattern |
| `1A-IA-DRIFT-2..4` — naming drift remaining after DRIFT-1 resolved                | `03-voice.md` canonical-term map  |
| `1B-A11Y-3` — `prefers-reduced-motion` narrowly scoped (best-practice)          | `04-accessibility.md` motion rule |
| `1A-COMP-RATIO-1` — only 3 component modules + 15 distinct invocations            | `02-components.md` consolidation roadmap |

## Reading order

For Marlowe: **start with `02-components.md`** if you only have time for one — it's where the audit's biggest leverage lives (consolidation roadmap). Then `03-voice.md` for empty-state copy direction. `01-foundations.md` and `04-accessibility.md` are mostly verification + token diffs.

For Phase 2 reviewers: read in file order (00 → 04). Each subsequent file builds on the prior.

## What this system does NOT cover

- **Marketing site / public landing pages** — out of scope; the audit was mobile-first product scope.
- **Admin / Control Center / Org-context surfaces** — Marlowe excluded these from the audit. Phase 4 may file follow-up tasks if these surfaces would benefit from the same system.
- **Email / push-notification visual templates** — separate concern, not refined here.
- **Print / PDF rendering** — n/a.

## Pointers

- Audit findings: `~/projects/core/audit/2026-05-08-ui-ux/{01-inventory,02-audit}.md`
- Active CSS source: `apps/platform/assets/css/app.css` + `apps/platform/assets/vendor/daisyui-theme.js`
- Active component modules: `apps/platform/lib/platform_web/components/{core_components,avatar_components,layouts}.{ex,heex}`
- AGENTS.md (note: line 33 contains a stale directive flagged in `1A-COMP-DOCDRIFT-1`; Phase 4 proposes a one-line correction)
