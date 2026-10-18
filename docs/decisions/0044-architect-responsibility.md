# ADR 0044 — Architect Responsibility

**Status:** Accepted
**Date:** 2026-07-08
**Author:** the product owner / Dalton
**Related:** ADR-0033 (Org Context Management), ADR-0041 (Org Memory V2 + Responsibilities), ADR-0043 (Security Guard Responsibility — sibling)

---

## Context

Burrow's plan-engine coordinates Planner → Executor → Reviewer → Deployer for every task. Each actor operates on a single task's scope. Nothing in the current flow evaluates architectural coherence *across* tasks, *across* time, or against *previously-decided-then-forgotten* patterns.

Symptoms observed 2026-06 through 2026-07:

- Same-week cascade (`019f3440`) took 3 days to root-cause because no actor was watching for cross-task interactions between #480's seed changes and #481's Router boundary.
- v1 Meeting Producer runtime shipped with an Ecto queue despite existing `[ETS for ephemeral state]` memory (`019f2452-0210` cancelled + recreated); no actor was checking new plans against durable memory.
- Phantom-fix went through v1/v2/v3/v4 (task recreates) before catching the `plan_create` payload's `validations` key omission — no actor was auditing planner-tool payload shapes across attempts.
- Prompt-templates task (#480) surfaced 3 known bugs at PR time (`render_prompt/2` slug-vs-inline, `Seeds.default_roles/0` rename, seed migration for pre-existing templates) — no actor synthesized such follow-ups back into the task tree.

The Roles/Responsibilities machinery landed in ADR-0041 M4/M6/M8 already carries the surface we need. What's missing is (a) an architect role in the closed roster, (b) three responsibility keys keyed at plan-time, drift-time, and periodic cadence, and (c) a progressive-enhancement contract for each hook so the engine's fast path is untouched when no architect is assigned.

## Decision

Introduce an `architect` role in the closed roster with three responsibility keys. Dispatch identically to any other responsibility via `Platform.Responsibilities.Router.fire_trigger/3` and resolve the assignee via `Platform.Roles.assignee_for/1` (which internally consults `Platform.Roles.agent_id_for_role/1` after checking overrides).

**Progressive enhancement is load-bearing**: task engine operates identically when no architect is assigned. Every hook the architect provides MUST default to a no-op when `Roles.assignee_for/1` returns `nil`.

## Non-goals

- Not a new engine state machine — architect is a normal responsibility firing at existing plan-engine transition points.
- Not a code-review replacement — the reviewer stays responsible for per-line verdicts.
- Not a governance gate — architect flags; it doesn't block unless severity dictates and the caller explicitly acts on the flag.
- Not a Historian competitor — architect nudges the Historian toward promotion; it never writes to memory files directly.

## Architecture

### Responsibility keys

| Key                          | Trigger                              | Payload                                              | Output                                |
| ---------------------------- | ------------------------------------ | ---------------------------------------------------- | ------------------------------------- |
| `architecture.review_plan`   | `plan_submit` → before `plan_approve` | full plan payload + sibling task tree + open PR list | plan comments, optional blocker       |
| `architecture.audit_diff`    | `stage_complete` → before reviewer   | stage diff + plan's declared shape                   | audit annotation, optional flag       |
| `architecture.cron_sweep`    | Weekly cron (opt-in)                 | project state                                        | new tech-debt tasks filed             |

The three keys share the `architect` role by default. Operators MAY use `Platform.Roles.set_override/2` to route individual keys to different agents (a heavier model for `review_plan`, a cheaper one for `cron_sweep`).

### Progressive-enhancement contract

Every hook site calls `Platform.Roles.assignee_for("architecture.<verb>")` (directly or via `Router.fire`) and short-circuits when the resolver returns `nil`. Zero code path change if no architect is assigned. Concretely:

- **Plan-time hook** — if no `architecture.review_plan` assignee → engine proceeds directly to `plan_approve` gate. No change to current flow.
- **Drift review** — if no `architecture.audit_diff` assignee → executor's `stage_complete` transitions straight to reviewer as it does today.
- **Cron sweep** — opt-in only via `:enable_architect_cron_sweep` config flag AND requires an assignee; either being absent is a no-op.

Each fire site wraps the invocation in `try/rescue/catch :exit` per the cascade-fix pattern shipped in task `019f3440`: an architect-agent crash cannot stall the plan_submit → pending_review transition or the stage-complete broadcast.

### Dispatch shape

Architect responsibilities dispatch identically to any other responsibility in the M6 router:

1. Hook site calls `Platform.Responsibilities.Router.fire/2` with the canonical key and a `trigger_meta` map carrying `plan`, `stage`, `task`, etc.
2. `Router.fire/2` looks the row up in the `responsibilities` table (registered at boot by the placeholder Provider handlers this ADR ships) and calls `fire_trigger/2`.
3. `fire_trigger/2` calls `Platform.Roles.assignee_for(responsibility.key)`. If `nil`, emits `[:platform, :responsibility, :unfilled]` telemetry and returns `:ok` — the fast path.
4. If an assignee is present, the Router calls `provider_module.gather_context/2`, renders the prompt via `PromptTemplates.render_template/2`, dispatches the LLM call, and hands the parsed output back to `provider_module.handle_output/3`.

The relevant primitives all already exist in the codebase:

- `Platform.Responsibilities.Router.fire/2` (`apps/platform/lib/platform/responsibilities/router.ex:257`)
- `Platform.Responsibilities.Router.fire_trigger/3` (`apps/platform/lib/platform/responsibilities/router.ex:827`)
- `Platform.Roles.assignee_for/1` (`apps/platform/lib/platform/roles.ex:354`)
- `Platform.Roles.agent_id_for_role/1` (`apps/platform/lib/platform/roles.ex:386`)

No new dispatch primitive is introduced. This ADR's stage 1 lands only the registration seam (role, responsibility keys, placeholder handlers); stages 2-5 wire the hook sites and fill in the handler bodies.

### Stage 1 scope (this deliverable)

Placeholder registration only — no handler logic. Specifically:

1. Extend `Platform.Roles.Role.@valid_keys` with `"architect"` and ship the matching `roles_key_check` CHECK-constraint migration.
2. Add the `architect` seed row to `Platform.Roles.Seeds.default_roles/0` with a 3-key bundle: `architecture.review_plan`, `architecture.audit_diff`, `architecture.cron_sweep`.
3. Ship three placeholder Provider modules under `Platform.Responsibilities.Handlers.*` that mirror the `TaskTriage` / `TaskUnblock` / `TaskWeeklyReview` shape from task `019f2455` stage 4: a `register/0` that returns one attribute map, `gather_context/2` returning `missing?: true` slots, and `handle_output/{2,3}` logging a placeholder warning.
4. Add the three handlers to `Platform.Responsibilities.BuiltIns.providers/0` and to `config/config.exs :platform, Platform.Responsibilities, providers:` — the closed-roster template-coverage test enforces sync between the two.
5. Ship a seed migration for the three placeholder prompt templates (`architecture.review_plan.v1`, `architecture.audit_diff.v1`, `architecture.cron_sweep.v1`) so the closed-roster coverage test resolves each seed key to a real template row. Content is intentionally minimal — stages 3-4 iterate via `prompt_template_update` MCP after this seed migration lands.

### Deferred to stages 2-5

- Stage 2: `Platform.Responsibilities` fire seam at `submit_plan_for_review` in `apps/platform/lib/platform/tasks.ex`.
- Stage 3: real prompt template content + `gather_context/2` sibling-task walk.
- Stage 4: post-executor drift hook at `stage_complete` in `apps/platform/lib/platform/tasks/plan_engine.ex`.
- Stage 5: weekly cron in `Platform.Agents.SystemEventScheduler` (or the Router's own cron surface) behind `:enable_architect_cron_sweep`, plus `docs/architecture/timeline.md`.

## Consequences

**Positive:**

- Earliest possible surface for architectural concerns, without changing the engine's fast path.
- Reuses the entire M4/M6/M8 machinery — no new tables, no new dispatch primitive, no new state machine.
- Per-key override support out of the box via `Platform.Roles.set_override/2` — an operator can point `architecture.cron_sweep` at a cheaper model without touching `architecture.review_plan`.

**Negative:**

- New failure mode: an architect agent that crashes could theoretically stall plan approval. Mitigation: `try/rescue/catch :exit` at each hook site — same pattern shipped in cascade-fix `019f3440`.
- Adds one role to the closed roster (`Roles.Role.@valid_keys` and the corresponding `roles_key_check` DB constraint). Both are extended in this stage's migration.

**Neutral:**

- The placeholder handlers are registration-only; they log warnings when fired and return `:ok`. This is consistent with `TaskTriage` / `TaskUnblock` / `TaskWeeklyReview` from `019f2455` stage 4 — the pattern that ships a role's roster before the runtime lands.
- The `[Responsibilities.Router.fire_trigger/3` design abstraction in the earlier drafts of this ADR was directional; the actual dispatch path routes through `Roles.assignee_for/1` (which reads the overrides table first, then the role-assignment table). The Consequences bullet describes intent; implementation reuses the existing Router primitive as documented above.
- **v1 `architecture.audit_diff` limitation (stage 4)**: the stage-complete hook does NOT fetch the executor's git diff. The handler reads only the stage description + plan payload + task metadata, so the prompt asks the agent to flag divergence based on the *planned shape* alone — it cannot cite specific file paths that landed but weren't planned. Wiring a `git diff HEAD~1` capture into `PlanEngine.transition_stage/2` is out of scope for stage 4 (the hook site is a leaf-node emit that must not stall the state machine, and the shipped-branch context is nowhere in the plan-engine payload today). Followup: file a "wire diff capture into stage-complete signal" task if the additive-annotation quality plateaus without it. Until then, ORG_MEMORY drift + new-dep flags + migration-shape checks remain useful even without the diff — the plan's stage description names the intended files, and the agent can compare against ADRs + memory entries the caller supplies in `trigger_meta`.

## Related

- 2026-07-07 architect-design conversation in space `8dc53153-eddc-4235-9812-d2e2c2ff3672`.
- `[Suite ToolSurface smell]` memory — an architectural violation the architect would have caught at plan-time.
- `[plan_submit empty validations]` memory — a durable gotcha memory the architect would have surfaced.
- `[ETS for ephemeral state]` memory — a durable-decision pattern the architect enforces at plan-time.
- Cascade-fix task `019f3440` — a cross-task interaction bug the architect would have caught 3 days earlier.
- Task `019f2455` (Triage Officer bundle) — the registration-only placeholder pattern this stage mirrors.
- ADR-0043 (Security Guard Responsibility) — sibling role landing concurrently, same registration-only pattern in stage 1.
