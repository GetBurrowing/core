defmodule Platform.Lifecycle.EdgeInventory do
  @moduledoc """
  Orientation record for the task-status half of the lifecycle hook frame.

  No behaviour. This module exists so the facts a hook author needs are in the
  tree next to the code rather than in a plan document, and so the scope
  boundaries below are read before someone ships a hook that never fires.

  ## Where hooks can hang

  `Platform.Tasks.maybe_finalize_transition/3` is the ONLY choke point a
  task-status hook pipeline can hang on. It is reached from
  `transition_task_status/2` and from that function's two internal call sites.

  ## The transition table (verified at this base)

      backlog       -> planning blocked in_progress stack_pending cancelled
      planning      -> in_progress blocked backlog stack_pending cancelled
      in_progress   -> in_review deploying blocked done stack_pending cancelled
      in_review     -> deploying in_progress blocked done
      deploying     -> done in_progress blocked
      blocked       -> backlog planning in_progress in_review deploying cancelled
      done          -> planning
      stack_pending -> in_progress blocked backlog cancelled
      cancelled     -> []

  Consequences to build to, not to discover: `in_progress -> deploying` skips
  review; `in_review -> done` is the ADR-0041 stack-member terminal path and
  never passes through `deploying`; `in_progress -> done` is ALSO legal.
  Derive any declarable edge set FROM `@valid_task_transitions` rather than
  transcribing it here — a second copy goes stale silently.

  ## What this frame DOES NOT OBSERVE

  There are FOUR status writers. Only one reaches the choke point. The other
  three DO NOT OBSERVE the pipeline, and that is a deliberate scope boundary,
  not a bug to fix in passing — routing them through the choke point would
  change the behaviour of manual board drops, plan approval and supersession.

    * `Platform.Tasks.drop_task_to_column/3` — the human drag-and-drop path.
      It writes `task |> Task.changeset(%{status: target_status})
      |> Repo.update()` directly, as its own in-code comment states. It is
      guarded by a SECOND transition table, `@valid_drop_transitions`, which
      contains edges absent from the pipeline table (`backlog -> done`,
      `planning -> done`, `in_review -> backlog`, `deploying -> in_review`,
      `done -> in_progress`, `done -> backlog`) and contains no
      `stack_pending` and no `cancelled`. Manual board drops therefore fire
      NO hooks at all, and that whole second table is outside the pipeline.

    * `Platform.Tasks.update_task/3` — casts `:status` through
      `Task.changeset/2` with no transition guard of any kind.

    * The reopen-done writer, which writes
      `Task.changeset(%{status: "planning"}) |> Repo.update()` inside its
      transaction after rejecting the active plan.

    * The plan-supersession writer, which writes the same changeset after
      marking the plan `superseded`.

  Because BOTH `done -> planning` writers bypass the choke point,
  **the `done -> planning` edge fires nothing today.** Any re-entry-bound
  assertion must be made on an edge that genuinely fires, with the
  substitution documented where it is made.

  ## Outcome vocabulary — keep the two tables apart

  `Platform.Tasks.Task`'s `@planning_step_outcomes ~w(complete not_applicable
  failed)` is a CURSOR domain. `Platform.Lifecycle.StepRun`'s statuses
  (`started/completed/diverted/failed/timed_out/suppressed`) are a per-run
  record. They are not two spellings of one thing; `Platform.Lifecycle.Edges`
  already owns the single mapping between them and it must not be duplicated.

  An edge that is never traversed produces NO run rows and NO recorded
  outcome — emphatically not `not_applicable`, which is reserved for an edge
  that WAS traversed with an empty configured pipeline.
  """
end
