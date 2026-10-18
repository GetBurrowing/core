# ADR 0048 — Experimentation Substrate for Prompt Templates

**Status:** Proposed
**Date:** 2026-08-09
**Author:** Rowan Ellis / Brosnan
**Related:** ADR-0046 (Design and Architecture Phases in the Planning Lifecycle — the planning lifecycle these experiments perturb), ADR-0025 (Task Router / dispatch — dispatch is the unit at which a prompt variant is delivered), ADR-0005 (Event Stream — where promotion events are recorded)

---

## Context

Prompt templates are live, editable production configuration. `prompt_templates` (migration `apps/platform/priv/repo/migrations/20260324200000_create_prompt_templates.exs`, schema `apps/platform/lib/platform/orchestration/prompt_template.ex`, context `apps/platform/lib/platform/orchestration/prompt_templates.ex`) holds one `content` blob per `slug`, and `PlatformWeb.AdminPromptsLive` (`apps/platform/lib/platform_web/live/admin_prompts_live.ex`) lets a human rewrite that blob at any moment with no versioning behind it. Every agent dispatch renders from whatever is in the row at the instant it is dispatched.

We want to answer questions of the form "does this planner prompt produce better plans than that one" with evidence rather than taste. That means running two or more prompt variants concurrently across real tasks and comparing outcomes.

Nothing for this exists yet. There are no `experiments`, `experiment_assignments`, or `prompt_template_history` tables and no experiment code anywhere under `apps/` — this is greenfield, and this ADR describes what to build, not what is there. The prior art that does exist is the audit stream (`apps/platform/lib/platform/audit.ex`, `apps/platform/lib/platform/audit/event.ex`).

The hazards here are specific and mostly silent. A live-editable control makes a comparison meaningless without raising an error. A subject that receives many dispatches over its life can drift between variants mid-flight. An experiment that runs on the planner that plans this stack's own work can degrade the machinery that would notice it was degrading. And a dashboard reporting a lift number from four samples reads exactly like one reporting a lift number from four hundred. Each decision below names the failure it is bought to prevent.

---

## Decision

### 1. Control is a snapshot, not a pointer

On experiment activation, the current value of `prompt_templates.content` for the target slug is **copied** into a control variant row. Dispatch renders variants from those rows. The live `prompt_templates` row is never read as the control while an experiment is active.

**Failure mode prevented:** someone opens `AdminPromptsLive` mid-experiment and improves the prompt. The control mutates underneath the running comparison, treatment and control are no longer differing by only the thing under test, and nothing anywhere errors. The experiment finishes and reports a number that means nothing, indistinguishable from one that means something.

**Accepted cost, stated plainly:** a variant promoted as the winner may not match what is on `main` at promotion time, because the control it beat is a snapshot taken at activation. Promotion is therefore an explicit act against the current template, not an automatic fast-forward, and the diff between the snapshot and current content must be shown to whoever promotes.

### 2. Assignment is sticky — resolved once, persisted, re-read

A task receives many dispatches over its life: planning, one per stage, review, deploy. The variant is resolved **at first touch** for a subject, written to `experiment_assignments`, and every subsequent dispatch for that subject **reads the stored row** instead of re-resolving.

**Corollary, written down because it will otherwise be treated as a bug:** stopping or promoting an experiment does **not** re-assign in-flight subjects. A subject keeps the variant it was assigned until it is finished. Stops and promotions change what *new* subjects get, nothing else.

**Failure mode prevented:** a task planned under variant A and executed under variant B. The outcome metric is attributed to one of them, arbitrarily. This contamination is invisible to every downstream metric — there is no aggregate that reveals it, because each dispatch looks locally valid.

### 3. Exclusions are visible and reasoned

A subject removed from an experiment's denominator carries a recorded **reason** and remains visible in the assignments view, flagged as excluded. There is no code path that drops a subject from the denominator without writing a reason.

**Failure mode prevented:** silent shrinkage of the denominator. Every silent drop is a free hand on the scale, and a denominator that quietly excludes the cases where a variant did badly will report a lift that survives no replication.

### 4. Self-reference is permitted, but filterable from day one

These experiments run on the planner and executor prompts that drive this stack's own development. That is deliberate — it is the highest-volume, highest-signal traffic we have, and refusing to experiment on it means never experimenting on anything.

The mitigation is a **project/epic exclusion filter in the policy layer** — the same layer that decides eligibility and traffic split — built before it is needed rather than after. When a variant looks harmful, Burrow-internal work can be excluded from it with a policy change, not a code change and not an emergency stop of the whole experiment.

**Failure mode prevented:** a variant that degrades planning quality degrades the planning of the work that would fix it, and the only available response is a panicked global stop. Improvising an exclusion mechanism under that pressure is how exclusions end up silent (violating Decision 3) and scattered across call sites.

### 5. Promotion guardrails — three, plus the metric gate

Promotion is the only operation that changes production for everyone, so it is the only one with guardrails.

**(a) Snapshot before promote.** The outgoing `prompt_templates.content` is written to a `prompt_template_history` row before the winning variant overwrites it. This table **does not exist today** and is a prerequisite of this decision, not an assumption of it: without it, the "demoting a bad promotion is one revert" guarantee has nowhere to write, and a regrettable promotion is only recoverable by finding the old text by hand.

**(b) Audit the promotion.** A `prompt_template_promoted` event is written to the audit stream (`Platform.Audit`) carrying the experiment id, the template slug, and the observed lift, and is surfaced in the UI. Requires nothing new structurally — the event stream already accepts typed events. **Failure mode prevented:** a prompt changes, behaviour changes, and six weeks later nobody can say when or why.

**(c) Cooldown.** A template cannot be auto-promoted twice within **K days**, where K is a named policy value, not a literal at a call site. **Failure mode prevented:** hill-climbing against a moving baseline — each promotion shifts the control that the next experiment measures against, so a sequence of individually-significant promotions compounds into drift no single experiment could justify.

**(d) Multi-metric gate.** No promotion proceeds if any secondary metric regresses by more than **5%**, even when the primary metric wins. **Failure mode prevented:** optimising plan quality by making planning four times slower, and calling it a win because latency was not the metric.

### 6. Metric honesty rules are decisions, not UI polish

- A result that has not reached its stop-rule threshold reports **"no effect yet"**, not a number.
- **Projected lift is not displayed at all** for an experiment that has not reached its stop rule.

These are recorded as decisions because they will be argued with. The argument will be that the dashboard looks weak, or indecisive, or that the number is "directionally useful" — and the person making it will be right that it looks better with a number on it. A premature lift figure is read as a finding by everyone who did not run the experiment, and once read it is acted on. The honesty rule has to be a decision with a reason attached, or it gets softened by whoever owns the dashboard next.

---

## Rejected alternatives

**Live-pointer control.** Have the control variant reference `prompt_templates.content` by pointer and read it at dispatch time. Rejected: it makes the control mutable by any admin edit during the experiment (Decision 1's failure mode) and the corruption is undetectable after the fact, because nothing records what the control's content was at each dispatch. The snapshot's cost — a winner that may not match current `main` — is a visible, one-time diff at promotion; the pointer's cost is an invisible, permanent loss of the result.

**Per-dispatch variant resolution.** Resolve the variant fresh on each dispatch from the traffic split, with no stored assignment. Rejected: it is simpler and it is wrong. A subject with N dispatches gets an independent draw at each one, so nearly every multi-stage task is a mixture rather than a sample of either arm, and the mixture is invisible to the outcome metric (Decision 2's failure mode).

**Silent exclusion.** Drop ineligible or anomalous subjects from the denominator without a reason record, on the grounds that the assignment table is an internal implementation detail. Rejected: unreasoned exclusion is unauditable, and an unauditable denominator makes every reported lift unfalsifiable. If we cannot answer "which subjects were dropped and why", the result is not evidence.

**Structured prompt overlays.** Model a variant as a set of structured patches — sections, fragments, ordered overlays — applied over a base template, instead of a full replacement blob. Rejected in favour of **full-blob variants**: overlays require a prompt schema we do not have and would have to invent to serve the experiment framework rather than the prompts; they make "what exactly did this dispatch see" a computation rather than a lookup; and they constrain a variant to differences the overlay grammar can express, which excludes exactly the wholesale rewrites we most want to test. Full blobs are larger and duplicate text between variants; that is the accepted cost.

---

## Falsification conditions

This ADR is **wrong**, not merely dated, if any of the following stops holding. Each is checkable.

1. **Dispatch stops being the unit of prompt delivery.** If a single dispatch renders more than one template such that no single variant assignment describes what the agent received, or if prompts are delivered through a channel other than dispatch, then assignment-at-dispatch (Decisions 1 and 2) no longer identifies what was tested. Check: every prompt-bearing path resolves through the dispatch layer.
2. **A subject receives concurrent dispatches under two different experiments touching the same slug.** The design assumes at most one active assignment per (subject, slug). If overlapping experiments on one slug become possible, the assignment row is no longer a unique description of what the subject saw, and every per-subject metric is confounded. Check: no subject holds two active assignments for the same template slug.
3. **Templates become composed rather than blob-valued.** If `prompt_templates.content` stops being a single self-contained blob — composed from fragments, includes, or runtime assembly — then a snapshot control is no longer a faithful copy of what the control arm receives, and the rejection of structured overlays must be revisited on its merits. Check: `content` renders without reference to another template row.
4. **Per-subject stickiness stops being the dominant bias.** Stickiness is bought at a cost in statistical power. If metric volume grows to where between-subject variance dominates and the mid-flight-switch bias is negligible by comparison, Decision 2's cost/benefit inverts and per-dispatch resolution deserves re-argument. Check: measured variance attributable to within-subject variant switching, versus between-subject variance, on real traffic.
5. **Promotion stops being a write to a single template row.** If promoting a winner requires changing more than one template, or coordinating with a non-template artefact, then snapshot-and-revert (Decision 5a) no longer makes a demotion one operation. Check: promotion touches exactly one `prompt_templates` row plus its history row.
   *Amended 2026-09-24 (task 01a0d415, the experimentation-layer ADR-0052):* this condition is scoped to the `dispatch.prompt` surface. For every other surface, promotion is the append of one `experiment_surface_defaults` row (and a revert the append of another), never a write to a template row; the equivalent check there is that a promotion or revert appends exactly one history row and updates none.

---

## Non-goals

**Attention-payload experiments (DEFERRED).** Varying the non-prompt contents of a dispatch — which skills are attached, which MCP tools are exposed, how much memory context is injected — is second-slice work. It is named here so the schema does not foreclose it: an experiment's variant should be modelled as *a payload the dispatcher applies*, of which a prompt blob is the first and currently only kind, rather than as a prompt string with an experiment id bolted on.

**The fine-tuning corpus (DEFERRED).** Harvesting assignment and outcome records into training data for a fine-tuned model is also second slice. It is named here so that assignments and outcomes are stored as durable, individually-addressable rows retaining the exact rendered variant, rather than being aggregated away once an experiment closes — aggregation is cheap to add later and impossible to undo.

---

## Consequences

- A new domain must be built: `experiments`, variant rows carrying full content snapshots, and `experiment_assignments` with a reason column for exclusions. All of it is new; none of it modifies the existing `prompt_templates` contract.
- `prompt_template_history` becomes a hard prerequisite of promotion, not an enhancement. Promotion cannot ship before it.
- `Platform.Audit` gains a `prompt_template_promoted` event type and the UI gains a surface for it.
- The dispatch path gains an assignment lookup. It must be a read of an existing row on all but the first dispatch per subject, and it must fail loudly rather than falling back to the live template — a silent fallback would reintroduce Decision 1's failure mode through the back door.
- The policy layer owns eligibility, traffic split, the project/epic exclusion filter, the cooldown value K, and the stop rule. Nothing else may decide these, or the exclusion filter of Decision 4 stops being a single lever.
- Experiments will sometimes report "no effect yet" for a long time. That is the design working, and it will be uncomfortable.
- Editing a template in `AdminPromptsLive` while an experiment targets its slug now has a defined meaning — it changes the live row and does not change the experiment — which must be shown in that UI, or the surprise merely moves.

---

## Addendum (2026-09-01, task 01a05bef): `plan_revision_count` counts in-place corrections

This extends **Decision 6** — metric honesty rules are decisions, not UI polish
— to what a metric *counts*, not only to what the dashboard is willing to
print. A number that is displayed honestly but measures the wrong population is
the same failure one layer down.

### What `plan_revision_count` counts, as of this task

A revision is any act of re-planning, and a planner can perform one two ways:

- **Discard and re-plan** — a new `plans` row for the task.
- **Correct the draft in place** — the MCP `plan_update` tool, which calls
  `Tasks.replace_plan_stages/3` to swap the stage tree on the **same** plan row.

The metric is the sum of both: plan rows per task, plus that task's
`platform.tasks.plan_updated` rows read from the audit stream
(`Platform.Audit`, ADR-0005). The two sources are **additive, not
alternatives** — they are disjoint writers on disjoint tables, so a new plan row
never emits `plan_updated` and an in-place correction never inserts a plan row.
No revision is counted twice.

The combine is keyed on the **plan** map and never on the union of the two. An
audit row naming a task with no surviving plan row must not manufacture a unit:
that would fabricate exactly the zero the "`n` counts tasks that have at least
one plan" grouping exists to avoid, and it would move `n`.

### Why rows alone was wrong

`plan_revision_count` is registered `direction: :lower_is_better`. That is an
assertion: **fewer re-plans is a better planner.** Counting plan rows alone made
a draft corrected five times in place score `1.0` — identically to a plan
written correctly the first time.

**Failure mode prevented:** under Decision 5(d)'s multi-metric promotion gate, a
planner prompt variant that favours `plan_update` over discard-and-replan wins
on a metric that structurally cannot see its re-planning. The gate is designed
to catch a secondary metric regressing while the primary wins; here the
secondary metric could not regress, because the behaviour it exists to price was
invisible to it. Nothing errors, no dashboard looks wrong, and the promotion is
recorded (Decision 5(b)) as though the evidence were sound.

### Rejected alternative: accept and document the undercount

**Leave the query counting rows, and write down that in-place corrections are
out of scope.** Rejected. That would have been the right call only if the metric
were a *versioning-hygiene* measure — "how many plan versions does this task
carry" — which is a fact about the data model, neither good nor bad.
`direction: :neutral` is how this ADR's registry signals such a metric, and
`stages_per_plan` carries it for exactly that reason: more stages per plan is
neither a win nor a loss, and colouring it as either asserts a judgement the
metric does not support. `plan_revision_count` does **not** carry `:neutral`. It
carries `:lower_is_better`, and a directional metric is a claim about planner
quality, so its population must be every act of re-planning or the direction is
a lie. Documenting the gap in a moduledoc does not repair a number that
promotion is gated on.

### `replace_plan_stages/3` is endorsed, not changed

`Tasks.replace_plan_stages/3` keeps a stable `plan_id` and a stable `version`
across an in-place correction. That is deliberate and **correct**: a draft being
corrected before approval is one plan, and minting a version per keystroke would
make `version` meaningless. It was not changed by this work.

The general rule, worth stating because the opposite is always the cheaper
patch: **the metric was moved to the data, not the data to the metric.** A write
path that is right for the domain does not get bent to make a measurement
convenient; the measurement learns to read what the domain actually writes.

### Residual gap, stated plainly

The `plan_updated` audit row is written by the MCP tool path only —
`Platform.Federation.ToolSurface.do_plan_update/4` in
`apps/platform/lib/platform/federation/tool_surface.ex` — and **not** by
`Tasks.replace_plan_stages/3` itself. A future in-process caller of the context
function would therefore perform a revision this metric cannot see, silently
reintroducing the undercount this addendum records fixing.

This is tolerable today only because the tool is the sole non-test caller of
`replace_plan_stages/3` in `lib/`. It is recorded here as a known thing to fix,
not a surprise to rediscover. The fix is one of: move the emit into the context
function, or count from a source the context function itself writes.

### The anti-vacuity rule this pinned

**Metric expectations are asserted against literals, never recomputed from the
function under test.** `assert value == 3.0`, `assert n == 1` — never a value
derived from the fixtures, from a second copy of the metric's query, or from
`length(audit_rows)`. An expected value computed from the same inputs the metric
reads cannot fail for any value the metric returns; it restates the
implementation and calls that a check. Ranges are the same failure wearing a
seatbelt: `value > 1.0` passes just as happily for a metric that counts the
wrong thing twice.

The literal `n` is load-bearing independently of the literal value. In the case
where a correction names a task with no plan row, both the correct behaviour and
the union-keyed bug yield `value == 1.0`; only `n` separates them (`1` versus
`2`). Asserting the value alone would have been vacuous precisely where the
grouping decision needed defending.
