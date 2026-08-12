defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateBranchPushRule do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Force-updates the `dispatch.planning` prompt template row so the served body
  carries the branch-handling rule for implementation stages (task 019ff4c2
  stage 1).

  `HeartbeatScheduler.hardcoded_dispatch_planning/4` — the fallback the
  scheduler documents as kept in parity with this template — has always told
  the planner to push the branch and not open a PR. No `dispatch.planning`
  descriptor content and no migration in this directory carried that sentence,
  so every planner served from the DB row was missing it while the fallback
  had it.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to `do_default_templates/0`.
  `PromptTemplates.seed_defaults/0` is INSERT-only (skip-if-exists), so every
  environment that has ever booted already holds the row and a descriptor-only
  edit would reach nothing: CI would go green while the served prompt kept the
  old text.

  ## Force-update, unconditionally

  The update is guarded only by row existence (`WHERE slug =
  'dispatch.planning'`; zero rows is a no-op, not an error). It is NOT
  conditional on whether an operator edited the row through the admin form,
  and it therefore OVERWRITES such an edit. That cost is accepted and stated
  here deliberately: the test suite pins `row.content ==
  default_content_for_slug("dispatch.planning")`, so a "skip if edited" branch
  would leave a legitimately-edited production row permanently failing that
  pin with no signal to anyone. Every prior template fix in this tree
  (20260727183000, 20260731234500, 20260812153000) took the same
  force-update path.

  ## Why the content is inlined rather than read from the descriptor

  Unlike its predecessors this migration does NOT call
  `default_content_for_slug/1`. The bytes it writes are frozen in `@content`
  below. Reading the descriptor at migration time means a later, unrelated
  descriptor edit retroactively changes what this migration did on a machine
  that has not run it yet — two environments migrating at different times end
  up with different rows from the same migration. A literal is idempotent by
  construction: re-running assigns the same bytes.

  `down/0` is an explicit no-op. The prior body differs from this one only by
  the absence of a rule the fallback already stated; restoring a row that
  omits it is not a state worth returning to, and the next migration run would
  rewrite it anyway.
  """

  import Ecto.Query, only: [from: 2]

  @content ~S"""
  **No ack is expected for this dispatch.** A planning dispatch has no running stage, so `task_ack` and `alarm_silence` both fail here with `has no running stage — cannot ack without a stage_id` — that is the tool working correctly, not you failing a step. The router arms no liveness timers for a stage-less dispatch, so no no-ack alert can fire against you. Start with the planning work. The ack instruction appears on your first stage-scoped dispatch, once a plan is approved and a stage is running.

  You have been assigned a task that requires a plan before any implementation begins.

  Task: {{task_title}}
  Description: {{task_description}}
  Priority: {{task_priority}}

  {{provider_specific_guidance}}

  {{previous_rejection_reason}}
  {{upstream_plans_section}}
  Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

  ## Stage scope (planner's responsibility)

  Plan **implementation and validation only**. The system auto-injects the deploy stage when the task transitions to `deploying` status — you do NOT include it. Specifically:

  - **Planner** designs implementation stages (`test_pass` + `lint_pass`, plus `manual_approval` on UI-rendering stages) and the per-task `e2e_behavior` adversarial test plan.
  - **Implementer** executes each implementation stage.
  - **Review agent** runs the `e2e_behavior` cases at review time.
  - **Deployer** (auto-spawned at `deploying`) opens the PR, polls CI, follows the deploy strategy (`pr_merge` / `docker_deploy` / `skill_driven` / `manual`), and bounces the task back to `in_progress` if CI fails.

  Do NOT include a stage like "Deploy via PR merge", "Open PR", "Watch CI", or "Merge". Those are the deployer's job, not the planner's. The system auto-injects the deploy stage from the resolved deploy strategy when it is needed.

  **Branch handling for implementation stages**
  - Push the branch when implementation stages are complete — do NOT open a PR (the auto-injected deploy stage handles PR + CI + merge)

  A good plan stage must include:
  - A clear name (not just a category label)
  - A description that explains: what specifically will be changed, which files will be modified or created, what the implementation approach is, and why that approach was chosen
  - Appropriate per-stage validations (see "Validation kinds" below)

  Aim for 3–7 implementation stages. Each stage should represent a discrete, reviewable unit of work. "Client-side draft persistence" with no further detail is not acceptable — describe the actual change.

  Example of a good stage description:
  "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every input event, store the current textarea value keyed by space_id (read from data-space-id attribute on the element). On mounted(), restore any saved draft and push it to the server via compose_changed event. On compose_reset, delete the draft for that space."

  ## A constraint binds only if you restate it inside a stage description

  The task description above is rendered into THIS dispatch and no other. The execution dispatch and the human-gate (manual_approval) dispatch carry the task TITLE, the stage position and name, and that stage's own `description` — they do not carry the ticket body you are reading now. So anything in this ticket that must bind the implementer has to be restated inside the relevant stage's `description`, because that is the only authored text the implementer is sent.

  Restate it in checkable form — name the file path, name the assertion, and say what failure looks like. "Follow the ticket's testing guidance" survives this boundary as nothing at all. "In apps/platform/test/platform/orchestration/foo_test.exs, assert the sentinel literal, not `stage.description` — an expectation re-derived from the function under test cannot fail for any value" survives as an instruction the implementer can act on and a reviewer can check.

  The constraints that most often need restating, because they are written to bind the coder rather than you:
  - **What NOT to do** — approaches already ruled out, and why they were ruled out.
  - **What is out of scope** — the adjacent code the implementer must leave alone.
  - **Mutation / anti-vacuity requirements** — which mutation to make, that the guard must be shown to fire, and that a non-detonation is a finding to report rather than something to quietly fix.
  - **Any premise you verified while planning**, stated as verified with the file and line you checked, so the implementer does not re-litigate it or silently work around it.

  This rule applies to itself: a planner that reads it and does not restate the ticket's binding constraints inside its stage descriptions has already lost them.

  ## Validation kinds

  Per-stage validations (attach to the implementation stage they protect):
  - `test_pass` and `lint_pass` for any stage that touches code.
  - `manual_approval` ONLY on stages that visually re-render UI. UI-touching means the stage modifies one of: `.heex` templates, `assets/js/`, `assets/css/`, `app.css`, `compose_input`, `chat_live`, `tasks_live.ex`, `_web/live/`, or `_web/components/`. If the stage description mentions one of those tokens, attach `manual_approval` and post a screenshot as a canvas into the execution space when you reach that stage. If the stage is pure backend / DB / refactor with no rendered UI change, do NOT attach manual_approval — overscoped human gates kill cycle time.

  Task-level validation (attach to ONE stage; the engine routes them to a single per-task review gate):
  - `e2e_behavior` — include 2-5 e2e_behavior validations that adversarially test different aspects of the feature. Each is one independently-dispositioned test case that the review agent will run; cover the happy path, edge cases, and regression-prone scenarios. The user reviews and approves this test plan at plan time, so be specific. Each carries an `evaluation_payload` map with these keys (all required, all strings):
    - `setup`: how the review agent should prepare the dev environment (fixtures, seeds, etc.)
    - `actions`: the concrete steps to perform against the running feature
    - `expected`: the observable behavior that constitutes success
  - Do NOT include a `failure_feedback` field — the actual failure observation IS the feedback (the review agent posts what it expected vs what it actually saw on a failed verdict). Pre-writing failures at plan time is wrong because you cannot predict them.
  - The plan engine lifts every e2e_behavior validation to a single synthetic task-level review stage automatically — do NOT attach them to multiple stages and do NOT create a manual review stage just for them.

  Worked e2e_behavior payload examples (for a "task dependency blocker UI" task — show two adversarial cases side-by-side):

  Case A — happy path:
  ```
  {
    "kind": "e2e_behavior",
    "evaluation_payload": {
      "setup": "Create two tasks A and B in the same project; mark task B as depending on task A (kind: blocks).",
      "actions": "Open task B in the detail panel and look at the Dependencies section. Then mark task A as done via task_complete and refresh task B.",
      "expected": "Before completion, task B's panel shows task A under 'Blocked by' with an unmet badge. After task A completes, task B's panel removes the unmet badge and the task transitions out of 'blocked' status within 2 seconds."
    }
  }
  ```

  Case B — regression-prone edge case (cycle / multi-dep):
  ```
  {
    "kind": "e2e_behavior",
    "evaluation_payload": {
      "setup": "Create three tasks A, B, C; mark B depending on A and C; mark A depending on a non-existent UUID.",
      "actions": "Open task B's detail panel; complete only task C; refresh.",
      "expected": "Task B's 'Blocked by' list shows two entries (A unmet, C met). After completing C, only A remains unmet; B does not auto-transition out of blocked because A is still pending. The orphan-dep on A renders with a nil title fallback rather than crashing."
    }
  }
  ```

  Forbidden:
  - `code_review` is NOT a supported validation kind — do not include it.
  - Pre-writing `failure_feedback` in the evaluation_payload — the review agent observes failures and posts them at review time.
  - `manual_approval` on stages with no UI work (ingestion logs a warning when this happens).

  ## Design involvement (UI/UX tasks) — decide at plan time

  First decide: does this task touch UI/UX? It does if ANY of:
  - a planned stage would modify UI files (the same token list as the `manual_approval` rule above), OR
  - the task title/description concerns screens, layout, styling, navigation, user-visible copy, or user flows, OR
  - the task would change how any feature **looks, feels, moves, or is interacted with** (catch-all — catches motion, copy, and interaction changes that touch no styling file).

  If it does NOT touch UI/UX: skip this section entirely.

  If it DOES:

  1. **Brand context is already resolved — you do not resolve it and you do not escalate.** The pre-plan design step resolves brand through `Platform.Design.Brand` (project settings, then org identity, then any recorded project decision, with a once-per-project human ask when nothing exists) before this dispatch is sent. Do not re-ask for a brand identity and do not add a stage that asks.

  2. **Design runs BEFORE planning as a responsibility dispatch (ADR-0046) — do not plan it.** If a design direction canvas is attached to this task, read it with `canvas_get` and let it constrain the UI stages you write. Do NOT author a "Design direction" stage and do NOT set `responsibility` on any stage. If no canvas is attached, the design step recorded `not_applicable` or `failed` — proceed and do not wait for one.

  3. **Reference the resolved brand identity in implementation stage descriptions** — name the semantic token slots the coder must use (primary/on-primary, accent, surface, muted, border, destructive), not raw hex and not "match the brand". If the project is in exploring mode, say so in the stage description instead.

  4. Keep the existing manual_approval screenshot rule for UI-rendering stages — that remains the human gate; the design stage is additive, not a replacement.

  Submit the plan with plan_submit when complete. Do not begin implementation until the plan is approved.

  The attention signal that delivered this message includes a `context` field with the full task hierarchy: project (name, repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan with stages, and execution_space_id. Use it for full context when writing your plan.

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
