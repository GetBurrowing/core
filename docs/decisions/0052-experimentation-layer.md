# ADR 0052 — Experimentation Layer: Surfaces, Tenancy, Data-Defined Metrics and Policies

**Status:** Proposed
**Date:** 2026-09-24
**Author:** the product owner / Dalton
**Task:** 01a0d415-b616-7001-b87d-bb5568a776d3
**Related:** ADR-0048 (Experimentation Substrate for Prompt Templates — EXTENDED here, not superseded)

> **Numbering.** Committed as `NNNN-experimentation-layer.md` and numbered
> 0052 at merge, by `ls docs/decisions` on origin/main immediately before the
> merge (0051 was the highest number then taken).

---

## Context

ADR-0048 built an experimentation substrate for exactly one thing: prompt
template bodies. Variants are `content` blobs bound to a
`target_template_slug`; metrics are modules in a compile-time registry; the
policy library (random buckets, cohorts, epic scope, time windows, composite,
shared exclusion) exists but, measured at planning time on origin/main
`afbd0754`, has no caller outside its own directory — `Assignments.pick_variant/1`
is a bare weighted random, so ADR-0048 Decision 4's exclusion lever is not
live. Every new kind of experiment, and every new measurement, needs a deploy.

This ADR generalises the substrate so that the decision point is declared
once in code and every experiment on it afterwards is data.

---

## Decision

### 1. Surfaces: a decision point is declared once, in code

A **surface** is a module implementing `Platform.Experiments.Surface`. It
declares: its `key`, the `subject_type` it decides for, a `payload_schema`
(plain data, so it can be listed over MCP), `validate_payload/1`, the
control arm (`control_payload/2`), and where it is resolved (`path/0`,
`:draft | :dispatch`). The registry is the compile-time list in
`Platform.Experiments.Surfaces`.

After that, every experiment on the surface is data: an `experiments` row with
`surface_key` / `surface_target`, and `experiment_variants` rows. No code
change and no deploy.

There is no `:send` path. A surface resolved at the moment something is sent
would let an experiment change an outbound message after every review point
has passed.

`Surfaces.resolve/4` is the one resolver. It carries ADR-0048's rules
unchanged — they moved out of `PromptTemplates`, they did not change:
an existing assignment wins regardless of experiment status (sticky; a stop
never re-assigns an in-flight subject); only a `running` experiment whose
`approval_state` is not `pending` creates assignments; resolution never raises
into the read point.

The first surface is `dispatch.prompt`, and `PromptTemplates.render_template/2`
now delegates to the resolver for it.

### 2. Variants carry a payload validated by the surface; prompts stay blobs

`experiment_variants.payload` is a map the surface validates. For
`dispatch.prompt` the payload is `%{"content" => <the full blob>}` —
**ADR-0048's rejection of structured prompt overlays STANDS for prompts.** The
payload is an envelope around the blob, not a patch language; existing
variants keep their blob in `content` and are read from there.

### 3. Tenancy is two columns, not a scope map

An experiment's scope is its **`org_id` and `project_id` COLUMNS**. NULL means
wider: a null org is install-wide, a null project is org-wide. Setting a
project derives the org; a project/org mismatch is a changeset error. Both
FKs are `on_delete: :restrict` — nilifying a deleted project would silently
WIDEN a project-scoped experiment to org-wide.

Epic lists, cohorts and time windows are **not** tenancy. They stay in
`assignment_policy`, where the policy modules read them.

Why columns: tenancy must be ONE key shape across experiments and the tables
around them — guardrails, goals, surface defaults — so that it is indexable
(`(org_id, status)` backs the per-org live-experiment count), FK-checked, and
joinable. A scope inside a JSON map is none of those, and two tables holding
tenancy in two shapes is how a query ends up checking one and not the other.

A subject whose project (or org) differs from a non-null experiment column is
never eligible — a column check applied before the policy chain.

### 4. Install-wide singletons carry NULLS NOT DISTINCT unique indexes

Wherever a null `org_id` means "the one install-wide row", the unique index is
built `NULLS NOT DISTINCT`. Under the Postgres default two NULLs never compare
equal, so a second install-wide row would insert cleanly and "the" row would
be whichever the planner returned. The tables:

- `experiment_guardrails` — unique on `(org_id)`: one row per org, exactly one
  install-wide row.
- `experiment_surface_defaults` — unique on
  `(surface_key, surface_target, org_id, seq)`: the history is append-only, the
  current default is the MAX(`seq`) row, and two writers computing the same
  next `seq` for the install-wide key collide on the index instead of both
  inserting. A unique index on `org_id` alone would forbid the history the
  table exists to keep.

`experiment_goals` is **not** a singleton: many goals per org, and many
install-wide goals, are legal, and it carries no uniqueness on `org_id`. A test
pins that, so the fix is not over-applied.

This requires Postgres 15+. The migration checks the server version first and
fails on a sentence rather than a syntax error.

### 5. Metric kinds are parameterised and instantiated as data

A **metric kind** (`Platform.Experiments.MetricKind`) is a module written
once; an experiment instantiates it with parameters in `metric_spec`. v1 kinds:

- `registered` `{slug}` — the ADR-0048 module registry, by slug. An experiment
  with an empty `metric_spec` falls back to `registered` over its
  `primary_metric`, so existing experiments compute exactly what they did.
- `outcome_rate` `{labels, window_days, anchor}` — the share of eligible,
  non-excluded subjects with at least one `labelled` signal in `labels`
  within the window.
- `duration_between` `{from_status, to_status}` — mean seconds between two
  status entries in `task_phase_transitions`.

Parameters are validated when the spec is written: an unknown kind or a bad
parameter is a changeset error, not a runtime surprise.

### 6. The observation window: young subjects are pending, not failures

Outcome metrics count only subjects whose anchor is older than the window.
Younger subjects are reported as a separate `pending` count and are in
**neither the numerator nor `n`**. They have not had the chance to produce an
outcome; scoring them as non-responses would bias the rate toward zero, most
strongly for whichever arm was assigned most recently. The pending count is
reported even when no subject is yet eligible: an arm whose only subjects are
inside the window reads `value: null`, reason `insufficient_data`, and
`pending: k`, never `pending: 0`.

### 7. Rules carried from ADR-0048, restated as binding

- Sample size `n` travels with every result.
- `:insufficient_data` is never reported as `0.0`. An empty eligible set —
  including every subject still pending — is `:insufficient_data`.
- An exclusion carries a reason and its row is never deleted. A policy's
  `{:excluded, reason}` writes the assignment row with the reason; a
  `:no_opinion` from the whole chain writes no row, because the subject was
  never eligible, and that is not an exclusion.
- `stopped` is not `concluded`.
- The addendum's anti-vacuity rule: metric tests assert literals, never
  recomputed values.

### 8. Policies are data

`assignment_policy` is a JSON map built by `Platform.Experiments.PolicySpec`
into the EXISTING policy modules (`random_buckets`, `task_cohort`,
`epic_scoped`, `time_window`, `composite`, and the shared `exclude` key).
`Assignments.assign_once/3` applies it. An empty map with null project means
today's weighted pick, unchanged. This makes ADR-0048 Decision 4's exclusion
filter a data change, as that decision intended.

### 9. Signals, the labeler and the Scientist (detailed in later stages)

- **Signals** (`experiment_signals`) are the observations outcome metrics
  count. Recording is idempotent on `(experiment_id, source_type, source_id)`;
  an unmatched source is recorded with a null subject, not dropped; there is
  no delete function.
- **Blind labeler plus Scientist split — the injection boundary.** The labeler
  sees a source and returns a label; it never sees the hypothesis or the arm.
  The Scientist proposes experiments and reads results; it never reads raw
  source text. Untrusted text therefore reaches no agent that can change an
  experiment.
- **Mail publishes an event** rather than calling Experiments, so the mail
  path has no dependency on the experimentation layer.
- **A stopped experiment keeps collecting mail signals.** `MailSource` skips
  only `draft` experiments. This is deliberate: a subject assigned before the
  stop stays sticky to its arm, and a reply that arrives after the stop is
  still that subject's outcome. It also means a stopped experiment still
  costs labeler calls for matching mail.
- **The labeler request is mention-escaped.** `ExternalContent.wrap/2`
  neutralises markers but does not escape mentions, so the labeler escapes its
  assembled user message, as the mail-to-channel callers do.
- **Guardrails** (`experiment_guardrails`) bound each org: `max_live`,
  `allowed_surfaces`, `require_human_approval`, `allow_auto_promote`.

### 10. Launch approval is opt-in per org; default launches within guardrails

`require_human_approval` **defaults to false** (the product owner, 2026-09-24), both as
the column default and as the built-in default `Guardrails.for_org/1`
returns when no row exists. **Approval is opt-in per org; by default an
agent's start launches within the guardrails** — it still has to pass
`allowed_surfaces`, `max_live` and `surface_busy`. When an org turns approval
on, an agent's `experiment_start` sets `approval_state: pending`, leaves the
status `draft`, returns `pending_human_approval`, and creates no assignments
until a human calls `Experiments.approve_launch/2` (a `%User{}` only; there
is no MCP tool for it). Whatever the guardrail says, the UI controls —
approve, stop, promote, revert — are always present.

Consequence: under the default, "configured end to end through MCP" means
exactly that. With approval on, it means everything except one human
approval click in the UI.

### 11. A human stop with feedback is a first-class signal

`experiments` carries `stop_feedback`, `stopped_by_user_id` and `stopped_at`.
The changeset accepts them only on the transition into `stopped`: feedback
attached to a running experiment would read as the reason for a stop that
never happened. **A human stop with feedback is a first-class signal the
Scientist must read before proposing the next experiment on that goal.** A
Scientist that re-proposes what a human just stopped, without answering the
feedback, is ignoring the most direct evidence the system has.

### 12. `dispatch.model` is deferred, not forgotten

A model surface is **not** a v1 surface. The dispatch payload built in
`heartbeat_scheduler.ex` carries no model field (measured: `grep model` there
is empty), because a federated runtime picks its own model. A model surface
needs a runtime-contract change first — the dispatch has to be able to say
which model to use and the runtime has to honour it — and that change is its
own decision.

### 13. Promotion on non-prompt surfaces appends a default-history row

ADR-0048 falsification condition 5 is amended (see that ADR): for
`dispatch.prompt`, promotion is still one template row plus its history row.
For every other surface, promotion APPENDS a row to
`experiment_surface_defaults` (`kind: promote`), and a revert appends another
(`kind: revert`, `reverts_seq`) whose payload is the effective payload after
the revert. Nothing updates a history row in place.

### 14. The `experiments` MCP bundle and its guardrails (stage 2)

Every create, start, stop, conclude, exclude, goal and promote step is an MCP
call (`Platform.Federation.ExperimentTools` defines them;
`Platform.Experiments.Tools` implements them). `tool_surface.ex` carries only
the bundle name, one `tools_for_bundle/1` clause and one `experiment_*`
prefix `execute/3` clause.

- **The bundle is not a default grant.** `experiments` is grantable
  (`AgentRuntime.valid_bundles/0`) but absent from `@default_allowed_bundles`.
  Holding it is the first guardrail. **The Scientist's runtime needs this
  grant, or every tool is refused** by `ToolAuthorization` above `execute/3`.
- **Built-in guardrails** (no row for the org, no install-wide row):
  `require_human_approval: false`, `max_live: 3`, `allow_auto_promote: false`,
  and `allowed_surfaces` = **every registered surface except a mail send
  path**. The stored column default is `[]`; the built-in default is not,
  because with no row at all `[]` would refuse every surface and "default
  launches" would launch nothing. **An explicit row is authoritative and can
  only narrow**: its list is used as written, so a stored `[]` allows no
  surface to an agent. `allowed_surfaces` accepts only registered keys, and
  the registry has no send-path surface, so a `mail.send*` key cannot be
  stored.
- **Agent rules** (`Guardrails.check/3`, refusals as
  `%Refusal{code, limit, current, surface}`): `surface_not_allowed`;
  `max_live_reached` counting `running` rows on the `org_id` column (null =
  install-wide, counted separately); `surface_busy` when another running
  experiment on the same `(surface_key, surface_target)` overlaps on the
  columns (null is wider); promote refused unless `allow_auto_promote`, and
  refused for any `mail.*` surface whatever the row says. A human bypasses
  the approval and the agent-only switches, never `max_live` or
  `surface_busy`.
- **The start race** is closed by `pg_advisory_xact_lock` on the org (a fixed
  key for a null org) and then on the surface key and target, in that order,
  in the same transaction as the check and the status write.
- **Stop with feedback.** `experiment_stop` takes an optional `feedback`; an
  agent stop records `stopped_at` and the feedback with
  `stopped_by_user_id` null. A human stop (`Experiments.stop/3`) records all
  three. `experiment_get` and `experiment_list` return `stop_feedback`.
  Stopped is never concluded, and no tool maps one onto the other.
- **Results moved to core.** `Platform.Experiments.Results` (formerly
  `PlatformWeb.ExperimentResults`, which now delegates) serves both the page
  and `experiment_results`; `value` is null unless the figure is earned.

### 15. Operating the Scientist (stage 5)

The Scientist is the `experiments.scientist` responsibility
(`Platform.Responsibilities.Handlers.ExperimentsScientist`), a cron fire every
six hours (`0 */6 * * *`) in the `scientist` role's bundle beside the blind
labeler. To turn it on:

1. **Pin an agent to `scientist`** (Control Center, Roles). Assignment is the
   enable signal: with nobody pinned the Router returns `{:ok, :unfilled}` and
   dispatches nothing.
2. **Grant that agent's runtime the `experiments` bundle.** Without it every
   `experiment_*` tool is refused by `ToolAuthorization` above `execute/3`,
   and the Scientist can read its dispatch but change nothing.
3. **Set guardrails in the UI** for the org (or the install-wide row):
   `max_live`, `allowed_surfaces`, `allow_auto_promote`, and
   `require_human_approval` if the org wants to approve launches (off by
   default; see section 10).
4. **Set a goal** with `experiment_goal_set` (a statement plus `org_id` /
   `project_id`). The Scientist works only on `active` goals.

**The context is scoped to the assignee's org.** A tenant-pinned assignee
(the stage-2 tools' `home_org/1` check) receives only its own org's goals,
experiments, signals, stop feedback and guardrails, plus install-wide (null
org) goals and experiments. Only an unpinned or root-pinned assignee sees
every org.

What each fire hands it: every visible active goal with its live and recently ended
experiments, their `Results` rows (every figure with `n`, `pending` and
`excluded`; a missing figure as words, never 0.0), any `stop_feedback` a human
left (section 11), signal label counts and the last 20 label tuples, the
guardrails with the live count, and the surface list. **It never receives a
mail body or any `mail_inbound_messages` field**; the signal query selects
only label, subject_id, confidence, reason and status.

The Scientist writes only through the `experiments` MCP tools, so the
guardrails are enforced on every write and there is no second path.
`handle_output/3` is a logged no-op because a native dispatch never reaches
it (the `AgentsGoalHeartbeat` defect, task `01a0c332`).

---

## Rejected alternatives

**A JSON `scope` column on experiments.** The v1 plan of this ADR. Rejected
(architect review): tenancy in a JSON map is not indexable, not FK-checked,
and a different key shape from every table around it.

**A `reverted_at` column on surface defaults.** Contradicts "never update in
place" — a revert would rewrite history. A revert is a new row.

**Ordering the default history by `inserted_at`.** Two rows in one
microsecond tie, broken by the planner. `seq` under a NULLS NOT DISTINCT
unique index makes "the latest row" structural.

---

## Falsification conditions

This ADR is wrong, not merely dated, if any of the following stops holding:

1. **A surface needs code per experiment.** If running a new experiment on a
   registered surface requires a code change, surfaces are not the unit of
   declaration. Check: every experiment on a surface is rows only.
2. **A second install-wide guardrail row inserts.** Check: the singleton test
   in `schema_constraints_test.exs`.
3. **Tenancy appears in two shapes.** If any experimentation table scopes by
   something other than `org_id` / `project_id` columns, the one-key-shape
   argument has failed. Check: no `scope` map on any experimentation table.
4. **A pending subject is scored.** If an outcome metric's `n` includes a
   subject inside its window, the observation-window rule is broken. Check:
   the literal `pending` assertion in `metric_kinds_test.exs`.
