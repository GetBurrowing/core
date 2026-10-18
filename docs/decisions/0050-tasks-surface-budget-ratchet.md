# ADR 0050: Surface Line Budgets as a Ratchet

**Status:** Accepted
**Date:** 2026-08-17
**Deciders:** the product owner
**Related:** ADR 0016 (Control Center LiveView Modularization), ADR 0035 (ChatLive Modularization)

---

## Context

Two LiveView surfaces have now been modularized under a written ADR, and both
grew back.

`ControlCenterLive` (ADR 0016, 2025) recorded its result as "3,750 lines
across 12 files." It is **5,874 lines across 14 files** today — 57% growth,
including three modules the ADR never names and a shell that went 719 → 1,023.

`ChatLive` (ADR 0035, 2026-04) set out to split a 5,090-line module into 13
concerns. Eleven landed. `chat_live.ex` is **4,335 lines**, and its
externalized template is another **3,890** — an 8,225-line surface, larger
than the file the ADR was written to fix. Three of the inventoried concerns
(`SpaceNavigation`, `Drafts`, `AgentPicker`) were never extracted at all.

`TasksLive` then reproduced the pattern from the other direction. ADR 0035
described it, in April, as one third of ChatLive's size. By August it was
6,027 `.ex` + 4,906 `.heex` — the largest surface in the repo.

The common thread is not that people write long files. It is that **nothing
measured anything after the ADR shipped**. A modularization that records its
result in prose records the day it landed and no day after.

### The residual-concern attractor

Both prior extractions stopped while concerns remained in the shell, and in
both cases the shell then became the cheapest place to add the next thing.

This is not laziness — it is a real gradient. A shell that still owns a
concern already has the assigns, the imports and the helpers that concern
needs. The marginal cost of adding one more line NEXT TO an existing concern
is near zero, while the cost of adding it to a component is a new attr, a new
notify, and a `send_update/2`. So every partially-emptied shell is an
attractor: work flows into it faster than out.

The corollary is that a modularization must finish. `TasksLive` stage 7 was
scoped as "no large concern remains," not "N modules exist," for this reason.
A half-emptied shell is worse than an untouched one, because it carries the
indirection cost of the extractions that DID happen while retaining the
gravity that caused the problem.

## Decision

### 1. Line budgets are recorded in a machine-checked file, not in prose

`scripts/surface-budgets.txt` holds one `path max` line per tracked surface,
plus `SUM:<name>` lines that budget a group. The file is the record; an ADR
paragraph is not.

### 2. The budget is the SUM of a surface's files, never one of them

A LiveView surface is its module AND its template. ADR 0035's per-feature
checklist asked only that `chat_live.ex` shrink, and that check is fully
satisfied by moving markup from the module into `chat_live.html.heex` — which
is how a surface reaches 8,225 lines while the number under review only ever
went down.

Every surface therefore gets a `SUM:` entry covering all of its files. Where a
per-file cap is also useful (the module specifically should stay small), it is
recorded as well, but the `SUM:` line is the binding one.

### 3. The budget ratchets down and never silently up

Landing under budget re-pins the budget to the achieved actual. This is the
ratchet: the surface can never quietly return to the slack it used to have.

Raising a number requires an explicit justification in the commit message.
This is deliberately a social gate rather than a hard block — there are
legitimate reasons for a surface to grow, and a rule with no escape hatch gets
routed around rather than obeyed. What the rule buys is that the growth is
*stated*, in a diff, at the moment it happens.

### 4. "No large concern remains" is the completion criterion, not module count

Module count measures activity. What matters is whether the shell still holds
something that will attract more of itself. The shipping question is: *what is
still in here, and would a reasonable person add the next feature next to it?*

## Consequences

### Positive

- Drift is visible in a diff instead of discoverable by archaeology.
- The sum rule makes the "move it to the template" evasion fail loudly.
- The ratchet converts a one-off cleanup into a floor.

### Negative

- The budget file is churn: every legitimate feature that grows a surface
  touches it. That churn IS the signal, but it is churn.
- Line count is a proxy. A 400-line module can be worse than a 900-line one.
  The budget catches accretion, not bad structure; only review catches that.
- A per-file cap can be gamed by splitting a module in two without splitting
  the concern. The `SUM:` line is what makes that pointless, which is why it
  is the binding entry.

### Not addressed

- **Other surfaces.** Only Tasks is under budget today. ChatLive and
  ControlCenterLive should be added when someone next works on them; adding a
  budget to a surface nobody is touching just creates a stale number.
- **Enforcement in CI.** The budgets are checked by
  `test/platform_web/live/tasks_live_board_invariance_test.exs`'s pinned
  counts, which run in CI as ordinary tests. A dedicated script that reads
  `surface-budgets.txt` and fails the build is a reasonable next step and is
  not part of this ADR.

## Alternatives Considered

1. **Do nothing; rely on review.** This is what ADRs 0016 and 0035 did. Both
   surfaces grew back. Review catches the line in front of it, not the
   trajectory across two years.
2. **A hard CI failure with no override.** Rejected: a surface sometimes
   genuinely needs to grow, and an un-overridable gate gets worked around
   (a new file that dodges the glob) rather than obeyed. The requirement to
   *say why* in the commit message is the enforceable part.
3. **Budget the module only, as ADR 0035 did.** Rejected — this is the
   specific failure mode being fixed.
4. **Complexity metrics instead of line counts** (cyclomatic complexity, ABC).
   Better signal in principle, but nothing in the repo produces them today,
   and the failure being addressed is accretion, which line count measures
   directly and cheaply.
