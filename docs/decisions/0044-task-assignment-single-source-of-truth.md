# ADR 0044: Task assignment — single source of truth for assignee, sponsor, deploy target

**Status:** Accepted (2026-07-08)

## Context

Three related-but-distinct fields on `Platform.Tasks.Task` — the technical
assignee, the human Sponsor (ADR 0042), and the deploy target — each have
today a different mix of writers, each with different semantics, and the
divergence has already produced silent-clobber bugs in the wild.

**Concrete audit of the assignee shape (2026-07-08):**

- `phase_assignees` (jsonb) is the CANONICAL granular assignment map,
  keyed by lifecycle phase (`"planning" | "execution" | "review"`) with
  values `%{"assignee_id" => uuid, "assignee_type" => "agent" | "user"}`.
- Flat `assignee_id` / `assignee_type` on the Task schema are DERIVED —
  they are the current-phase pointer, re-computed by
  `Platform.Tasks.assignee_for_phase/2`
  (`apps/platform/lib/platform/tasks.ex:1700`) and refreshed via
  `Platform.Tasks.set_phase_assignees/2`
  (`apps/platform/lib/platform/tasks.ex:1745`) on every phase transition.
- The bug: MCP `task_update` and the detail-pane top-level "Assignee
  (task-level)" dropdown both write directly to the flat fields via
  `Tasks.update_task/2`, bypassing `set_phase_assignees/2`. On the next
  phase transition, the derive path over-writes those flat fields from
  the `phase_assignees` map for the incoming phase — silently clobbering
  the direct write.

**Concrete audit of the Sponsor shape:**

- `sponsor_user_id` is nullable per ADR 0042. Explicit-null-unsets is the
  MCP boundary contract, encoded in `task_update` at
  `tool_surface.ex:3282` via the `explicitly_nilable` allowlist. UI
  edit-mode forms encode empty-string-clears at
  `tasks_live.ex:2633`. These agree, but the "explicit null propagates"
  rule is duplicated inline in the handler rather than lifted to a
  shared shape module.

**Concrete audit of `deploy_target`:**

- Nullable string field on `Task`. MCP `task_update` schema documents it
  at `tool_surface.ex:1356`. The detail-pane dropdown writes it via
  `update_task_field`. The new-task bottom sheet does NOT surface it at
  create time — the field is only settable via a follow-up `task_update`
  or by opening the created task and editing the dropdown, which is a
  parity gap between MCP `task_create` and UI create.

**Concrete audit of `auto_approve_plan`:**

- Boolean, default false, documented in ADR 0042 continuation. MCP
  `task_create` normalizes omission to `false`
  (`tool_surface.ex:2937`). `task_update` accepts explicit true/false.
  UI new-task sheet toggles it. This one is already coherent — named
  here so the enumeration below is complete.

## Decision

Establish a single canonical shape for the assignee / sponsor /
deploy-target / auto-approve-plan family of fields, name the module that
owns the shape decisions, and route every writer through it.

### 1. Canonical shape (per field)

| Field | Kind | Nullable? | Nil-clears at MCP boundary? | Empty-string-clears at UI boundary? |
| --- | --- | --- | --- | --- |
| `sponsor_user_id` | FK → users | yes | **yes** (explicit-null-unsets, ADR 0042) | yes |
| `phase_assignees` | jsonb map | yes (default `%{}`) | omitted key is untouched; explicit `%{"planning" => nil}` clears that slot | n/a (canonical writer is the Configure modal) |
| `assignee_id` + `assignee_type` | flat pair | yes | omitted is untouched; when SUPPLIED they route through `set_phase_assignees` at the task's `current_phase(task)` slot | same routing at UI |
| `deploy_target` | string | yes | omitted is untouched; explicit-null clears (mirrors `sponsor_user_id`) | empty string clears |
| `auto_approve_plan` | boolean | no (default false) | omitted is untouched on update; on create omission normalizes to false | omitted on submit normalizes to false |

### 2. Surface parity matrix

Rows = fields. Columns = writer surfaces. `✔` = writer that respects the
canonical shape today. `✗` = writer that bypasses the canonical shape
(bug or gap). `→` = deferred to the follow-up stages of this task.

| Field | `task_create` MCP | `task_update` MCP | `task_start` MCP | Detail-pane edit mode | New-task bottom sheet |
| --- | --- | --- | --- | --- | --- |
| `sponsor_user_id` | ✔ | ✔ | n/a | ✔ | ✔ |
| `phase_assignees` | ✗ (not accepted) → | ✗ (not accepted) → | n/a | ✔ (Configure modal) | n/a |
| flat `assignee_*` | ✗ (writes flat, silent clobber) → | ✗ (writes flat, silent clobber) → | ✗ (writes flat, same risk; deferred) | ✗ (top-level dropdown) → | ✗ (single-agent picker → flat) → |
| `deploy_target` | ✗ (not accepted at create) → | ✔ | n/a | ✔ | ✗ (not surfaced) → |
| `auto_approve_plan` | ✔ | ✔ | n/a | ✔ | ✔ |

The `→` cells are the work of the follow-up stages 2–4 in the plan
attached to this ADR. This ADR names the target state; the stages land
it.

### 3. Shared shape module

Introduce `Platform.Federation.TaskAttrs` — a pure-function module that
takes a raw args map (from MCP or LiveView) and produces:

- `flat_attrs` — the shape safe to pass to `Tasks.create_task/1` or
  `Tasks.update_task/2`.
- `phase_attrs` — either `nil` (no per-phase intent from this caller) or
  a map suitable for `Tasks.set_phase_assignees/2`.

The routing decision — whether to also call `set_phase_assignees/2`
after the changeset writer — stays at the boundary (in the MCP handler
or the LiveView `handle_event`), but the shape decisions (nullable
semantics, explicit-null propagation, auto-routing of flat assignee
writes to the current-phase slot) live in this one module.

### 4. Nilable-clearing semantics (concrete rules)

- `sponsor_user_id: nil` in `:update` mode → propagates as `nil`
  (clears). In `:create` mode → dropped (create defaults are managed by
  the changeset; there's no sponsor to "clear").
- `deploy_target: nil` in `:update` mode → propagates as `nil` (clears).
  In `:create` mode → dropped.
- `deploy_target: ""` (empty string) → normalized to `nil` in both
  modes. The UI form uses empty string to mean "(none)"; the MCP
  boundary treats it identically.
- Every other field: `nil` means "untouched" and is dropped from the
  emitted attrs map.

### 5. Flat-assignee auto-routing (the load-bearing rule)

When a caller supplies flat `assignee_id` + `assignee_type` AND passes
`auto_route_flat_assignee_current_phase: true` in opts AND passes
`current_phase: "<phase>"` in opts, the builder:

- Removes `assignee_id` and `assignee_type` from `flat_attrs`.
- Emits `phase_attrs = %{<current_phase> => %{"assignee_id" => id,
  "assignee_type" => type}}`.

The caller then does the standard write dance:
`create_task(flat_attrs)` (or `update_task/2`) FOLLOWED BY
`set_phase_assignees(task, phase_attrs)` (only when `phase_attrs` is
non-nil). `set_phase_assignees/2` re-derives the flat pointer, so the
final task row has both `phase_assignees["<current_phase>"]` populated
AND the derived flat `assignee_id` — the two are consistent and
survive the next phase transition.

When both `phase_assignees` AND flat `assignee_id/type` are supplied
by the caller, `phase_assignees` wins — the flat pair is dropped.

## Consequences

**Positive**
- One place to change nilable semantics. When we add another
  explicit-nilable field, we amend `TaskAttrs.explicitly_nilable/0` and
  every writer inherits.
- The silent-clobber bug is impossible after stage 2 lands: MCP
  `task_update({assignee_id: A})` no longer hits `update_task/2`
  directly with a flat pair; it goes through `set_phase_assignees/2`
  which is by construction phase-transition-safe.
- The parity matrix is legible — a reader can point at any surface and
  read what it accepts vs. what it should.

**Negative / cost**
- MCP `task_create` gains a new `phase_assignees` param (stage 2). This
  is additive — existing callers keep working — but agents that were
  hand-crafting attrs based on the current schema will not know about
  the granular variant until they re-read.
- The detail-pane's top-level "Assignee (task-level)" dropdown goes away
  (stage 3). Users who preferred a top-of-detail one-click assignment
  now go via the Configure modal. Documented in the stage-3 UI change.
- The new-task bottom sheet gets one more visible field (`deploy_target`
  in stage 4). Minor UI clutter, but exactly matches the detail-pane
  editor.

## Alternatives considered

**Overload `Tasks.create_task/1` and `Tasks.update_task/2` to accept
`phase_assignees` and route internally.** Rejected — `Task.changeset`
already casts `phase_assignees` (for direct-write callers that WANT to
overwrite the whole map), but re-deriving the flat pointer from the
per-phase map is currently only done by `set_phase_assignees/2`. If we
smuggle that re-derive into `update_task/2`, we silently change the
semantics of every existing caller of `update_task/2` — including
migration back-fills and admin scripts — and re-introduce the exact
"invisible action-at-a-distance" bug this ADR is trying to eliminate.
The seam belongs at the MCP/UI boundary where the caller MADE the
decision to route through per-phase, not in the domain function.

**Keep two writer paths and add a runtime assertion that a flat write
followed by a phase transition would be a clobber.** Rejected — this
turns silent clobbers into loud runtime errors, but the semantic bug
remains and every writer has to defensively call the assertion. Fixing
the shape at the boundary is strictly less code.

**Delete flat `assignee_id` / `assignee_type` entirely; require every
caller to construct a `phase_assignees` map.** Rejected — the flat pair
is the natural mental model for the common case of "assign this whole
task to one agent". Forcing the caller to construct a three-phase map
for that case is friction. Auto-routing is the compromise: callers
still SEE the flat API, the builder converts to per-phase behind the
scenes, and both shapes stay valid.

## Implementation surface

Concrete stages in the plan attached to task `019f42fd`:

1. **This stage.** Land the ADR, land
   `Platform.Federation.TaskAttrs.build_task_attrs/2` with the shape
   decisions above, land the module's unit tests. No writer is
   re-wired yet.

2. **Wire MCP `task_create` / `task_update`.** Both handlers accept the
   `phase_assignees` param, both handlers pipe args through
   `TaskAttrs.build_task_attrs/2`, both handlers dispatch to
   `create_task` / `update_task` and (when `phase_attrs` is non-nil)
   `set_phase_assignees/2`. `task_create` also gains `deploy_target`
   at create time.

3. **Consolidate detail-pane assignee affordances.** Remove the
   top-level flat dropdown; keep the readonly current-phase badge; the
   Configure modal is the sole assignee writer. `@editable_task_fields`
   drops `assignee_id`.

4. **Surface `deploy_target` on the new-task bottom sheet.** Adds a
   dropdown next to the existing "Deploy Strategy" block, plumbed
   through the same `TaskAttrs` helper.

## Deferred (explicitly out of scope)

- **`task_start` MCP.** It writes flat `assignee_id/type` today with
  the same silent-clobber risk as `task_update`. Same fix pattern
  applies, but changing it here would balloon the scope. Filed for a
  follow-up task once stages 1–4 land.
- **`phase_assignees` at create time in the new-task sheet.** Rare
  case; the sheet's simple Agent dropdown (auto-routing to
  `phase_assignees["planning"]` per this ADR) covers it.
- **Cross-org sponsorship UI.** Same status as ADR 0042 — nullable FK
  allows it, no UI surfaces it, revisit when someone actually needs it.
