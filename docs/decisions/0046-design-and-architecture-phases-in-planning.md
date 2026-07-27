# ADR 0046 — Design and Architecture Phases in the Planning Lifecycle

**Status:** Proposed
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
