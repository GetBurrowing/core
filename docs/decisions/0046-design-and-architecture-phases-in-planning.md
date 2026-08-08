# ADR 0046 — Design and Architecture Phases in the Planning Lifecycle

**Status:** Accepted
**Date:** 2026-07-25
**Author:** Rowan Ellis / Brosnan
**Related:** ADR-0044 (Architect Responsibility — this supersedes its stage-level dispatch model), ADR-0032 (Design Handoff Action Cards), ADR-0029 (Task Lifecycle Responsibility Split), ADR-0045 (Task Stacks v2)

---

## Context

Design and architecture input currently reach a task through the **planner**, which authors a stage carrying `responsibility: "designer"` on the stage payload. That mechanism is broken in three separate ways.

**The column lies.** `Stage.responsibility` (`tasks/stage.ex:17`) is named for one concept and holds another. It stores a **role** key, and `orchestration/task_router.ex:832` resolves it via `Roles.agent_id_for_role/1` — the *role* resolver — while the responsibilities tree keys on `<feature>.<verb>`. A stage carrying a genuine responsibility key such as `design.critique` silently resolves to `nil` and falls through to `:role_unresolvable` telemetry that reports `responsibility: stage.responsibility` while the value is a role. "Responsibility" now denotes four unrelated things across the codebase: a trigger row, a stage role key, an ADR-0029 lifecycle phase, and the `:ext_single_responsibility` agent-narrowness property.

**The architect never runs.** `Platform.Responsibilities.Router` resolves a handler by camelising a key's feature prefix into `Platform.Responsibilities.Providers.<Feature>`. Only `Design`, `Meetings`, `Memory` and `Tasks` exist. There is no `Providers.Architecture`, and grep across `lib/` and `test/` returns zero references to one. Because the resolver's fallback treats "module missing" identically to "not applicable", `architecture.review_plan` — fired unconditionally from `tasks.ex:1562` on every plan submission — degrades to generic context and a generic template, and `handle_output/3` is never invoked. `handlers/architecture_review_plan.ex:220`, which posts the architect's annotation into the task's execution space, is live working code called from nowhere. We pay for the inference and discard the result.

**The gate is unobservable.** `Responsibilities.Router.fire_trigger/3` returns `:ok` on every path — external HTTP failure, `rescue`, and caught `:exit` alike. `Responsibilities.fire/2` therefore can only ever return `:ok` despite speccing `{:ok, term} | {:error, term}`. A dead dispatch and a successful one are byte-identical to the caller. Meeting summaries already fail silently through this hole (`meetings/summarizer.ex:111` has a fallback branch unreachable for the exact failure it guards).

Separately, the codebase has an established habit of amending safety nets to accommodate the failures they were built to detect — a regression test encoding a seed/handler key mismatch as `@known_seed_key_aliases`, an audit whitelist justified by a test-only config value, and a `config/test.exs` flag that hid a production crash on the stack-deploy path. Any new gate must be designed against that habit, not merely added alongside it.

---

## Decision

Design and architecture become **first-class steps inside the planning phase**, dispatched through the responsibility router rather than authored as plan stages.

The order is **design → plan → architecture**.

1. **Design runs before planning.** Design here means **UI and brand consistency only** — the visual surface, not the shape of the feature in code. It is applicable only to tasks that touch UI. Its output is attached to the task as an input canvas that the planner and executor both read.

2. **Architecture runs after plan submission and before plan approval**, and may **reject**. Reviewing a concrete plan is actionable in a way that pre-plan speculation is not: the architect can object to a specific stage's module boundary rather than guess at a task description. This ordering also means the existing `architecture.review_plan` responsibility — whose declared `plan_payload` context is meaningless pre-plan — becomes the correct handler unchanged.

3. **Both steps are independently skipped** when no agent holds the corresponding role, and design is additionally skipped for tasks with no UI surface. No UI is rendered for a step that does not apply.

4. **`auto_approve_plan` is redefined** to mean *"no **human** gate"*, not *"no gate at all."* The architecture check occupies the same lifecycle slot the human reviewer occupies. Machine reviewer and human reviewer become interchangeable occupants of one position rather than two parallel mechanisms.

5. **Rejection reuses the existing path.** Architecture rejection emits structured feedback through `reject_plan` / `submit_reject_with_feedback` (`tasks_live.ex:2361`, `:2425`) and produces a v2 plan via the supersession machinery that already exists. No new rejection mechanism is built.

6. **The reject loop is bounded at 2 iterations**, after which the task escalates to a human with both the plan and the accumulated architecture objections attached. With `auto_approve_plan` on there is no human in the circuit to notice a spin.

7. **Failure falls open, visibly.** A dispatch that fails when an agent *is* assigned proceeds to the implementing agent rather than blocking, but records the failure on the task and surfaces it **at merge time** — not only in logs.

---

## Non-goals

- Pre-plan architectural constraint-setting. The post-plan slot can only reject, never shape; a wrong module boundary costs a full replan rather than a cheap upfront constraint. This is accepted for v1. The pre-plan slot can be added later without redoing this work.
- Feature design in code. Design's remit is UI and brand consistency. Architectural shape is the architect's remit.
- Per-project design systems. Brand resolution follows the existing project-then-org merge rule.
- Living documents. Design and architecture canvases are point-in-time inputs. A later stage invalidating an architecture canvas is accepted drift, not a re-dispatch trigger.

---

## Architecture

### Lifecycle position

```
backlog
  └─ planning
       ├─ [design]        · skipped unless a designer is assigned AND the task touches UI
       ├─ plan authored   · planner agent
       ├─ [architecture]  · skipped unless an architect is assigned; may reject → v2 (max 2)
       └─ approve         · human, or system:auto when auto_approve_plan
  └─ in_progress
```

### Sub-phase state, not task status

The step is tracked in a **`planning_step`** field (`:designing | :planning | :architecting`), not as a `task.status` value. Adding statuses would drag in the transition table, which currently has four writers with four different gate sets — and one of them, `update_task/3`, is entirely unguarded because `Task.changeset/2` casts `:status`. The card extension is a pure render concern reading `planning_step`.

### Per-step outcome

Two states are insufficient. Each step resolves to one of:

| Outcome | Meaning | UI |
| --- | --- | --- |
| `not_applicable` | No agent in the role, or no UI surface (design) | Nothing rendered |
| `complete` | Dispatch returned and output was captured | Canvas attached |
| `failed` | Agent assigned, dispatch died | Marker visible through to merge |

`not_applicable` and `failed` must never be conflated. The first is the progressive-enhancement path; the second is a gate that did not run.

### Prerequisites

Three items are load-bearing and none is optional:

1. **`fire_trigger/3` must return a real result.** Until it can express failure, "track the failure" ships as a no-op and nothing surfaces for months.

   **Shipped** — task `019f9b27`. Read the contract from here, not from source. `Platform.Responsibilities.Router.fire_trigger/2,3` and `Router.fire/2` return:

   ```elixir
   @type fire_outcome :: {:ok, :dispatched} | {:ok, :unfilled} | {:error, term()}
   ```

   `Router.fire/2` additionally answers `{:ok, :unknown_responsibility}` for a key with no seeded row — an unseeded key is a progressive-enhancement state, identical in kind to an unfilled assignee, so it belongs in the ok channel. `Platform.Responsibilities.fire/2` now returns the Router value verbatim; it no longer launders every outcome into `:ok`.

   `Platform.Responsibilities.outcome/1` is the single mapper onto the per-step vocabulary above. Members 2–9 call it rather than re-deriving the mapping — if each derives it independently, one of them maps `unfilled` to `failed` and re-opens the conflation this table forbids:

   | Return | `outcome/1` |
   | --- | --- |
   | `{:ok, :dispatched}` | `:complete` |
   | `{:ok, :unfilled}` | `:not_applicable` |
   | `{:ok, :unknown_responsibility}` | `:not_applicable` |
   | `{:error, _reason}` | `:failed` |

   `outcome/1` deliberately has **no catch-all clause**, so an unhandled future shape raises `FunctionClauseError` at the call site instead of silently mis-mapping. Call sites inside an Ecto transaction must therefore match the shape themselves before calling it. The Router's own non-raising contract is unchanged and load-bearing: the two lifecycle hooks fire inside a plan-submit transition and inside `evaluate_validation/2`'s transaction, so dispatch failure is *returned*, never raised — a raise there would roll back the validation update.

   Two limits the value does **not** cover, so downstream members do not over-trust it:

   - On the **native** dispatch branch, `{:ok, :dispatched}` means *handoff accepted*, not *agent responded*. `Platform.Chat.AgentResponder.maybe_dispatch/1` wraps the work in `Task.start/1` outside sync mode and returns `:ok` unconditionally, so post-handoff native failure is still invisible. Closing that is separate work. The external branch is honest: there, `{:ok, :dispatched}` means the endpoint answered.
   - `:complete` means the dispatch returned, which is weaker than the "output was captured" wording in the table above. The `handle_output` leg reports separately and a step can be `:complete` with no canvas attached.

2. **`Providers.Architecture` must exist.** Without the shim every `architecture.*` dispatch black-holes, and the feature is UI over a discarded call.
3. **Context resolvers must exist** for `plan_payload`, `sibling_tasks` and `adr_index`. `handlers/architecture_review_plan.ex:106` declares all three; none is a `ContextGatherer` resolver, so all three currently resolve to `nil`. The architect would receive an empty context even after the shim lands.

### Architect prompt contract

The architect rejects only for what is **expensive to undo later** — module boundaries, data model, cross-context coupling, duplicated logic. Explicitly not for taste, naming, or stylistic preference. Rejection carries the offending stage and the violated constraint, not prose; the planner needs to know *what* to change to produce a better v2 rather than a differently-worded one. Simple hotfixes and one-line changes warrant a fast pass, not an aggressive review.

### Removal of stage-level responsibility

**Shipped** — task `019f9b29-e447`, stack member 9, landing last as planned. Read the outcome from here rather than from the plan text, which was written on a premise that turned out to be wrong (see the correction below).

Four things came out, in dependency order:

1. **The planning-template instruction** (member 7). `dispatch.planning` no longer tells the planner to author an advisory "Design direction (Saru)" stage tagged `responsibility: "designer"`. It now tells the planner to read the pre-plan design canvas if one is attached, to author no design stage, and to set no stage responsibility at all. Retiring the producer first meant the remaining removals were not racing new writes.
2. **The resolution path.** `resolve_stage_dispatch_assignee/3` in `orchestration/task_router.ex`, together with the `:role_unresolvable` telemetry that reported `responsibility: stage.responsibility` while the value was a role key.
3. **The MCP surface.** `responsibility` is gone from the `plan_create` stage schema and from `serialize_stage/1`, on both the read and the write side. A stale key sent by an older planner session is **ignored, not rejected** — `tools/list` catalogues are cached per session, so rejecting would hard-fail `plan_create` for every planner runtime spawned before the deploy.
4. **The column and the schema field**, via `20260726052350_drop_responsibility_from_stages.exs`. The in-flight-plan hazard resolved to nothing to drain: the pre-migration census found no non-terminal stage carrying a value, and the stage *name* ("Design direction (Saru)") preserves the human-readable intent that the column did not.

Four overloaded meanings of "responsibility" became three. `test/platform/tasks/stage_responsibility_retired_test.exs` is the absence guard that keeps it that way: it refutes the word in `tasks/stage.ex`, `orchestration/task_router.ex` and `federation/tool_surface.ex`, and asserts — as a positive control — that the three surviving meanings are still present. The `tool_surface.ex` half is narrowed rather than dropped: that file legitimately still names `ext_single_responsibility` in the `agent_directory` result-row description, so the guard exempts exactly that literal and forbids every other occurrence. Widening it to "the file may contain the word" would retire the guard, not the concept.

#### Correction: `agent_id_for_role/1` was never dead code

The paragraph this section replaces cited `task_router.ex:832` as *the* resolution site, and the task brief inherited that framing. It was one caller among nine. A plan written on the "only caller" premise would have deleted a function that eight live paths still depend on. Verified with `grep -rn "agent_id_for_role" apps/platform/lib/` at the head of member 9's branch; every one of these is untouched by this task:

| Call site | Role key resolved |
| --- | --- |
| `platform/chat.ex` | `"historian"` |
| `platform/agents/historian_dispatcher.ex` | `"historian"` |
| `platform/org/wiki/routing.ex` | `@historian_role_key` — the Historian write-gate predicate |
| `platform/meetings.ex` | `"meeting_scribe"` |
| `platform/meetings.ex`, via `safe_agent_id_for_role/1` | `"triage_officer"` |
| `platform/meetings/intent_classifier.ex` | the classified target role |
| `platform/meetings/intent_dispatcher.ex`, via `safe_agent_id_for_role/1` | the dispatched intent's role |
| `platform_web/live/meeting_live.ex` | `"meeting_producer"` — intent-panel visibility |
| `platform/roles.ex` itself | the `{:role_assignment_changed, …}` broadcast payload |

`test/platform/agents/system_event_scheduler_t6_e2e_test.exs` additionally asserts `function_exported?(Platform.Roles, :agent_id_for_role, 1)`.

Line numbers are omitted deliberately. During this task alone the `meetings.ex` sites moved by roughly two hundred lines, and effectively every line citation in this member's planning documents had drifted by the time it was executed. Cite the function, not the line.

#### Known inconsistency, not fixed here

`Roles.assignee_for/1` takes a **responsibility key** and consults `responsibility_overrides` via `lookup_override_agent/1` before falling back to role assignment. `Roles.agent_id_for_role/1` takes a **role key** and queries `role_assignments` directly; it never consults overrides. Consequence: a per-responsibility override set in the Control Center roles panel (the `set_responsibility_override` handler) is invisible to every surviving call site in the table above — the meeting scribe, the triage officer, the Historian dispatcher and the wiki write-gate all ignore it.

That is a real inconsistency in the override feature and it is tracked as its own task. It is explicitly out of scope here: this member removed one caller, it did not change either resolver's semantics, and unifying the two would have put a behaviour change inside a deletion.

---

## Consequences

**Positive:**

- The architect becomes real. ADR-0044's Stage 1 hook stops being unreachable code that bills for inference.
- `Stage.responsibility` — a column named for one concept holding another — is retired.
- Design and architecture are skippable by construction, so the engine behaves identically for orgs with neither role assigned.
- Machine and human plan review become one lifecycle slot instead of two mechanisms.
- Fixing `fire_trigger/3` repairs meeting-summary silent failure as a side effect.

**Negative:**

- Post-plan architecture can only reject. A wrong architectural choice costs a full replan cycle.
- One additional sequential LLM round-trip before execution begins.
- Two models can disagree; the iteration bound converts that from an infinite loop into a human escalation, which is better but is not free.

**Neutral:**

- `auto_approve_plan`'s meaning changes. Existing callers keep working; the semantics of what they opted out of narrows from "all review" to "human review."
- Design's applicability test needs a UI-surface heuristic. The `manual_approval` rule already carries one (`.heex`, `assets/js/`, `assets/css/`, `_web/live/`, `_web/components/`) and should be reused rather than reinvented.

---

## Amendment 1 — Lifecycle hook pipelines (2026-08-08)

0046 introduced two hard-coded lifecycle hooks: design before planning, architecture after plan submission. This amendment generalises that into a configurable **hook pipeline** model, and extends — rather than forks — the `complete / not_applicable / failed` vocabulary defined in `### Per-step outcome` above.

Eight decisions. Each carries its rationale **and** its cost; a decision recorded with only its benefits is an advertisement, and the next reader cannot tell what was traded away.

### 1. Hook points are phase-boundary edges, not stages

A hook point is an edge between lifecycle phases (`backlog → planning`, `planning → in_progress`, and so on), not a position within a plan's stage list.

**Why.** Stages are user-authored and variable — 3 to 9 per plan is typical, and the count and meaning differ per task. Hanging hook points off stages would mint `2N` configuration slots per plan, nearly all of them meaningless, and none of them stable across a replan. Phase boundaries are the only positions that exist identically for every task.

**Cost.** An edge cannot express "after the third stage specifically". Any requirement of that shape has no home in this model and needs a different mechanism.

### 2. A phase that never occurs fires nothing

If a task never reaches a phase boundary, that edge's pipeline does not run and **no** hook event is recorded. It specifically does **not** fire `not_applicable`.

**Why.** `not_applicable` keeps the meaning 0046 gave it: the hook point **ran** and nothing was configured — the progressive-enhancement path. A phase that never occurred is a different fact entirely. Conflating "ran, nothing configured" with "never ran" is the exact defect this ADR was written to kill; see `### Per-step outcome` above — "`not_applicable` and `failed` must never be conflated" — and the same reasoning applies to this third state.

**Cost.** Absence of a hook event is not distinguishable in the log from a phase never reached. Answering "did this edge run?" requires correlating the hook log against the task's transition history; neither source answers it alone.

### 3. Each edge owns an ordered pipeline; `await` and `can_divert` are declared per step, never positional

A step declares its own `await` (does the pipeline block on it) and `can_divert` (may it send the task back) as explicit fields. Neither is inferred from the step's index.

**Why.** State this in full, because the alternative is superficially attractive. If divert authority came from being first in the pipeline, then someone adding a Slack notify at the top of the post-plan pipeline six months from now would silently demote the architect to advisory. There would be no error, no failing test, and no visible change — the pipeline would still run, the architect would still be dispatched, and its verdict would simply stop being able to stop anything. The defect would be discovered when a bad plan ships. That is the same failure shape as a check that still appears present and has quietly stopped discriminating: the most expensive class of bug this codebase produces.

**Cost.** Two extra fields on every step config, including the majority of steps — plain notifies — that will always carry `await: false, can_divert: false`. The configuration is more verbose than it needs to be for the common case, deliberately.

### 4. The first divert halts the remainder of the pipeline

When a step diverts, no subsequent step on that edge runs.

**Why.** A task diverting back to planning must not then fire the "entering execution" webhook. Downstream steps were written on the premise that the transition is happening; once it is not, running them publishes claims that are false.

**Implementation note, because the natural code is wrong.** An `Enum.reduce` over the steps runs every step regardless of what the accumulator says. The halt must be threaded explicitly — `Enum.reduce_while/3` or an equivalent that can stop — otherwise the divert is recorded and ignored.

**Cost.** Later steps are not guaranteed to run. A notify placed after a gate is therefore a **conditional** notify, whether or not its author intended that, and its author has no signal at configuration time that they have written one.

### 5. Two budgets: per-step and per-edge wall clock

Each step carries a timeout, and each edge carries a wall-clock budget for the whole pipeline.

**Why.** Per-step budgets alone do not bound the edge. Three awaited agent steps at the current 30-minute design timeout is a 90-minute silent stall with no single component misbehaving — every step is inside its own limit, and there is nothing to page on. The edge budget is the only thing that can observe the aggregate.

**Cost.** An edge budget can kill a step that was comfortably within its own budget. A step author cannot reason about their own timeout in isolation: the effective limit depends on what else is configured on the same edge, and on how long those steps happened to take on that run.

### 6. No gates on `backlog.created` — effects and notifies only

The `backlog.created` edge accepts steps that produce effects or notifications. It does not accept steps with `can_divert` or `await`.

**Why.** Ticket creation is agent-paced and bursty — triage sweeps, follow-up filing, webhook intake all create tickets in rapid succession and often concurrently. A gate on that edge lets one agent's hook block another agent from filing a ticket, coupling unrelated work through the creation path.

**Cost.** The earliest point at which a task can be blocked is later than the earliest point at which it exists. A policy that wants to refuse a ticket outright cannot be expressed here; it has to run at the next edge and reject something already created.

### 7. Deterministic steps resolve against an allowlisted registry of compiled functions

A deterministic step names a `{Module, :fun, 1}` that is resolved against a compile-time registry. A name is **never** resolved at runtime from task data. Webhook destinations are allowlisted by host.

**Why.** Task descriptions and stage text are agent-authored, and agent-authored text derives from ticket content that can originate outside the org. A step whose target is looked up by name from that data — or any `eval`-shaped equivalent — is an arbitrary-code-execution path with an ordinary-looking configuration field in front of it. Host-allowlisting webhooks closes the same hole on the network side: otherwise the pipeline is an SSRF primitive driven by task text.

**Cost.** Adding a step type requires a deploy, not a configuration change. Operators cannot extend the pipeline vocabulary themselves, and the feedback loop for a new deterministic step is a release cycle.

### 8. Config is per-project and replaces org defaults; there is no `locked` flag

A project's hook configuration **replaces** the org's for that edge. Projects may remove org-configured gates. Nothing at the org level can be marked unremovable.

**Why.** Replacement means what you read in a project's config is exactly what executes. There is no merge order to simulate, no inheritance chain to trace, and no case where a step runs because of a document you were not looking at.

**Cost — stated plainly, because it is real.** A project that wants to add one webhook must restate the **entire** org pipeline. From that moment the two configurations drift independently, and the drift is invisible: an org adding a new gate does not propagate it, and nothing reports that a project is running a stale copy. The failure mode is something silently not running, which is the failure mode this ADR is most concerned with elsewhere. The trade accepted is a legible config surface today against a class of staleness bug later; a `locked` flag would have bought the reverse, and inheritance you cannot see is worse than duplication you can.

---

## Implementation order

1. Fix `fire_trigger/3` return contract *(prerequisite)*
2. `Providers.Architecture` shim *(prerequisite)*
3. Context resolvers for `plan_payload` / `sibling_tasks` / `adr_index` *(prerequisite)*
4. `planning_step` field + per-step outcome persistence
5. Architecture gate between `plan_submit` and approve; redefine `auto_approve_plan`
6. Bounded reject → v2 loop with structured feedback
7. Design step before planning, gated on UI-surface heuristic
8. UI: card extension rendering `planning_step`
9. Strip stage-level responsibility *(last)*

Steps 1–3 are unglamorous and carry the feature. Without them the remainder is an interface over a dispatch that discards its output.

---

## Related

- ADR-0044 (Architect Responsibility) — this supersedes its stage-level dispatch model; the responsibility keys and progressive-enhancement contract stand.
- ADR-0032 (Design Handoff Action Cards)
- ADR-0029 (Task Lifecycle Responsibility Split) — note this ADR's use of "responsibility" is unrelated to the `responsibilities/` tree.
- ADR-0045 (Task Stacks v2) — stack members inherit this lifecycle per-member.

**Numbering note:** `docs/decisions/` currently carries four duplicate-number collisions (0017, 0036, 0042, 0044) plus a byte-identical 0027/0028 pair, and no ADR carries a `Superseded` status. 0046 was verified free before allocation. Repairing the existing collisions is tracked separately.

---

### Addendum (2026-07-28, task 019fa605): a user planning assignee under auto-approval is supported

**Decided.** A task carrying `auto_approve_plan: true` — or a stack member under a stack's `auto_accept_plan: true` — whose **planning** phase assignee is a **user** is a **supported** configuration. It is not refused at the write boundary, not warned about, and not migrated away from. Where ADR-0046's original text left the combination undiscussed, this is the ruling: support it.

**Why.** The obvious reading is that the combination is incoherent — "auto-approve" implies an engine driving the task, and `Platform.Orchestration.TaskRouterWatcher.should_run?/1` will not start a router for a non-agent assignee, so it looks like nothing can ever drive it. That reading is wrong on the facts, in two independent places:

- **The architect does not need the task's router.** `architecture.review_plan` is dispatched through `Platform.Responsibilities.fire/2` to the *architect's own* runtime. Its verdict arrives back through the MCP verdict tool calling `Tasks.resolve_architecture_gate/3`. The whole gate opens and closes without the task ever having a router of its own. Whenever the architect answers, this configuration already worked.
- **An unheld responsibility already falls open.** With nobody holding `architecture.review_plan`, `submit_plan_for_review/1` takes the not-applicable branch into `settle_ungated_plan_submission/1` and auto-approves inline, again with no router involved.

Only one corner ever stalled: the **silent-architect** case — the gate opens, the architect never answers, the deadline passes, and there is no router to fire `{:architecture_gate_deadline, plan_id}`. Refusing the combination at the write boundary would therefore have rejected two arrangements that demonstrably make progress in order to close one that does not. The correct fix is the one taken in task 019fa605: settle the stalled corner from `TaskRouterWatcher.sweep_expired_architecture_gates/0`, a level-triggered sweep on the reconcile tick that makes the identical single call the router's deadline handler makes.

Two design bounds fall out of that and are part of the ruling, not implementation detail. The sweep re-asks `Tasks.architecture_gate/1` rather than re-deriving the overdue rule, so the projection stays the single authority. And it settles a gate to `expired` and never to `passed`: the plan is approved *and* the record that nobody reviewed it survives, so `Tasks.planning_gate_failed?/1` still refuses the merge downstream. An approved plan whose gate reads `passed` would be strictly worse than the stall it replaced.

The resulting invariant, in one line: **THE ROUTER IS AN OPTIMISATION, THE WATCHER SWEEP IS THE GUARANTEE.** The same shape as `architecture_gate/1`'s projection being the guarantee and the deadline timer the eager edge.

**Revisit this ruling if any of these stops holding.** Each is checkable, and any one of them falsifies the argument above rather than merely aging it:

1. **`should_run?/1` stops keying on `assignee_type`.** If a router can be started for a user-assigned task — a router flavour with no runtime, say — the stall disappears at its source and the sweep becomes dead weight, not a guarantee.
2. **The reconcile tick stops being reliable.** The sweep is the *only* settler for this class. If reconcile is disabled in an environment, or `@gate_expiry_sweep_cap` is hit persistently rather than transiently, then this configuration has no settler in that environment and refusing it there becomes the honest answer.
3. **The architect gains a synchronous verdict path.** If `fire_trigger/3` ever hands the parsed verdict back inline, the gate resolves at submit and the whole asynchronous deadline apparatus — sweep included — is unnecessary for this shape.
4. **`maybe_auto_approve/1` stops reading both flags.** The ruling covers `auto_approve_plan` and `auto_accept_plan` together only because one function resolves both. Split them and this addendum covers whichever one keeps that resolution, and says nothing about the other.

**Recorded because the alternative is worse than being wrong.** A rule kept after its justification lapsed is obeyed longer than a rule that was never written down; task `019fa63a-02a0` tracks that failure mode across three repos. Cited by `Platform.Tasks.emit_architecture_gate_opened/1` and by the `architecture_verdict` migration's no-index note, both by filename and heading.
