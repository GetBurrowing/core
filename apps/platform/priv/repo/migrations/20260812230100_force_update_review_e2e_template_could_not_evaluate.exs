defmodule Platform.Repo.Migrations.ForceUpdateReviewE2eTemplateCouldNotEvaluate do
  use Ecto.Migration

  @slug "dispatch.review_e2e"

  @moduledoc """
  Force-updates the served `dispatch.review_e2e` row so the reviewer is TOLD
  how to say "I could not evaluate this" (task 019ff788 stage 3).

  Stage 3 bounds the gate-failure loop at three rounds. The bound is only
  safe if a review that could not be RUN is distinguishable from a review
  that ran and found the feature wrong — otherwise a dev server that will
  not boot burns three rounds and re-plans a feature that was never wrong.
  The reviewer expresses that with `evidence["disposition"] ==
  "could_not_evaluate"` plus a mandatory `reason`; see
  `Platform.Tasks.ReviewDisposition`.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to the descriptor in
  `PromptTemplates.do_default_templates/0`. `seed_defaults/0` is INSERT-only
  (skip-if-exists), so every environment that has ever booted already holds
  this row and a descriptor-only edit would reach nothing: CI would go green
  while the served prompt kept telling reviewers there are only two verdicts.

  The bytes below are FROZEN, not read from the descriptor at migration
  time, for the reason `20260812190000` states: reading the descriptor lets
  a later unrelated edit retroactively change what this migration did on a
  machine that has not run it yet. The force-update is guarded only by row
  existence and therefore overwrites an operator edit — same accepted cost,
  same rationale (the suite pins `row.content ==
  default_content_for_slug("dispatch.review_e2e")`).

  `down/0` is an explicit no-op: the prior body differs only by the absence
  of an instruction the code now depends on, and restoring that is not a
  state worth returning to.
  """

  import Ecto.Query, only: [from: 2]

  @content ~S"""
Task is in behavioral review — execute each planner-authored e2e_behavior test case and disposition each validation independently.

Task: {{task_title}}
Execution space: {{execution_space_id}}
Repository: {{repo_url}}
Task slug: {{task_slug}}

## What is e2e_behavior

The planner authored an adversarial test plan (a list of `e2e_behavior` validations) describing
what user-visible behavior must hold for this task to be considered done. Each validation is one
independently-dispositioned test case. Your job is to execute every test case in a running dev
environment and report pass/fail per validation with concrete evidence.

## Pending e2e_behavior validations (pre-rendered as JSON)

You have one or more pending e2e_behavior validations on this task. Each entry below carries a
`validation_id` and an `evaluation_payload`. Run each one in turn.

```
{{pending_e2e_validations_json}}
```

Each `evaluation_payload` contains three fields:
- `setup`: prepare the dev environment (fixtures, seeds, etc.)
- `actions`: concrete steps to perform against the running feature
- `expected`: the observable behavior that constitutes success

There is no planner-supplied `failure_feedback` — on a failed verdict, you (the review agent) compose the
feedback yourself from what you actually observed. That is the failure_feedback.

## How to review

1. Start a worktree dev server for this task — reference the `suite-dev-server` skill from the bundled skills payload. The skill explains the dev-host constraints and DB seeding.
2. For each pending validation in the list above:
   a. Perform the `setup` steps from its payload (creating fixtures via Suite MCP tools or DB seeds, depending on what the script asks for).
   b. Perform the `actions` against the running feature.
   c. Compare the observed behavior to `expected`.
   d. Disposition that single validation (see below) before moving to the next test case. Failures on one validation do NOT short-circuit the rest — run them all.

## Disposition (per validation)

On success — observed behavior matches `expected`:
- Call `suite_validation_evaluate` with the matching `validation_id`, `status: "passed"`, and
  `evidence: %{observed: "<what you saw>", notes: "<any caveats>"}`.

On failure — observed behavior does NOT match `expected`:
- Compose your own observation: describe what you EXPECTED (verbatim from the validation's `expected`
  field), what you ACTUALLY OBSERVED, and any diagnostic detail (logs, screenshots, console output,
  stack traces) that will help the implementing agent reproduce and fix.
- Call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"`, and
  `evidence: %{observed: "<what you saw>", expected: "<verbatim from the payload>", diagnostics: "<logs/details>"}`.
- Post that same observation into the execution space ({{execution_space_id}}) so the implementing
  agent reads it on the next dispatch — your observation IS the failure_feedback.

On COULD NOT EVALUATE — you were unable to run the test case at all (the dev server will not boot, a
fixture cannot be built, the case hit a known flake), as distinct from running it and seeing the wrong
behaviour:
- Call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"`, and an
  `evidence` map carrying `disposition: "could_not_evaluate"` AND a non-blank `reason` explaining what
  stopped you: `evidence: %{disposition: "could_not_evaluate", reason: "<what blocked the run>",
  diagnostics: "<logs/details>"}`.
- This raises a blocker and does NOT spend one of the task's three review rounds. A failed verdict
  without that marker DOES spend a round, and after three the task is returned to PLANNING and its
  plan superseded — so a broken environment reported as a plain failure re-plans a feature that was
  never wrong.
- The `reason` is mandatory. A `could_not_evaluate` marker with no reason is counted as a genuine
  failure.
- Use it ONLY when the run was impossible. "The feature looks wrong" is a plain failed verdict.

## Forbidden

- Do NOT call `task_update` to bounce the task status. The plan engine handles the
  in_review→in_progress transition automatically when any `e2e_behavior` validation fails.
- Do NOT create a `suite_review_request_create` for `e2e_behavior` — it is agent-driven, not
  human-gated. Review requests are reserved for `manual_approval` validations.
- Do NOT self-approve. Disposition is your call to make based on observed behavior, but only
  mark `passed` if that test case's `expected` clause was actually met.
- Do NOT skip validations. Run every pending e2e_behavior test case even if an earlier one failed.

The attention signal that delivered this message includes a `context` field with the full task
hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.

{{federation_preamble}}
"""

  def up do
    Platform.Repo.update_all(
      from(t in "prompt_templates", where: t.slug == ^@slug),
      set: [content: @content, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  def down do
    :ok
  end
end
