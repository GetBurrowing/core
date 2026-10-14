defmodule Platform.Lifecycle.EdgeInventory do
  @moduledoc """
  Orientation record for the task-status half of the lifecycle hook frame.

  No behaviour. This module exists so the facts a hook author needs are in the
  tree next to the code rather than in a plan document, and so the scope
  boundaries below are read before someone ships a hook that never fires.

  ## Where hooks can hang

  `Platform.Tasks.maybe_finalize_transition/3` is the ONLY choke point a
  task-status hook pipeline can hang on.

  ## PREMISE CORRECTION (task 019fe1b7 stage 2, found by test, not by reading)

  Stage 1 recorded that the choke point is reached from
  `transition_task_status/2`. **It is not.** `transition_task_status/2` never
  calls it. The two real call sites are `Platform.Tasks.transition_task/3`
  (reached from `transition_task/2`) and the plan-approval finalizer.

  `transition_task_status/2` is therefore a FIFTH bypassing writer, and the
  one that matters most in practice: **the MCP `task_update` status path
  calls it DIRECTLY**, so an agent moving a task by tool call fires no
  lifecycle hooks at all. `phase_pointer_attrs/2`'s own comment in
  `tasks.ex` states this in as many words — it exists precisely because that
  path "bypasses `transition_task/2` + `maybe_finalize_transition/3`".

  This was found by writing a dispatch test against
  `transition_task_status/2` and watching a correctly-configured pipeline
  run nothing. Reading agreed with the wrong answer.

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

  There are SIX status writers. Only one reaches the choke point. The other
  five DO NOT OBSERVE the pipeline, and that is a deliberate scope boundary,
  not a bug to fix in passing — routing them through the choke point would
  change the behaviour of manual board drops, plan approval, supersession and
  operator corrections.

    * `Platform.Tasks.drop_task_to_column/3` — the human drag-and-drop path.
      It writes `task |> Task.changeset(%{status: target_status})
      |> Repo.update()` directly, as its own in-code comment states. It is
      guarded by a SECOND transition table, `@valid_drop_transitions`, which
      contains edges absent from the pipeline table (`backlog -> done`,
      `planning -> done`, `in_review -> backlog`, `deploying -> in_review`,
      `done -> in_progress`, `done -> backlog`) and contains no
      `stack_pending` and no `cancelled`. Manual board drops therefore fire
      NO hooks at all, and that whole second table is outside the pipeline.

    * `Platform.Tasks.transition_task_status/2` — enforces the transition
      table and writes, but calls no finalizer. The MCP `task_update` status
      path reaches it directly. **This is the highest-traffic writer that
      DOES NOT OBSERVE the pipeline**, and closing it is not this stack's
      scope: `transition_task/3` already calls it inside a transaction, so
      firing from both would double-fire every LiveView transition.

    * `Platform.Tasks.update_task/3` — casts `:status` through
      `Task.changeset/2` with no transition guard of any kind.

    * The reopen-done writer, which writes
      `Task.changeset(%{status: "planning"}) |> Repo.update()` inside its
      transaction after rejecting the active plan.

    * The plan-supersession writer, which writes the same changeset after
      marking the plan `superseded`.

    * `Platform.Tasks.apply_operator_correction/6` (task 01a049be) — the
      shared writer behind `Platform.Tasks.reinstate_cancelled_task/3`
      (`cancelled -> backlog`) and `Platform.Tasks.close_as_delivered/3`
      (`backlog|planning|blocked|stack_pending -> done`, now `/4`). BOTH of
      those edges are absent from `@valid_task_transitions` and stay absent:
      the pipeline still cannot leave `cancelled`. These are admin-gated
      bookkeeping repairs for records the pipeline made unrepresentable, so
      they fire no hooks by design — running deploy or review pipelines for
      work that already shipped would be wrong.

      SCOPE UPDATE (task 01a0a552): `close_as_delivered` now has an MCP
      entry point, `task_close_as_delivered` in the `task` bundle. State
      what it admits, not what it forbids — an exception sentence rots and
      a scope sentence survives. The one route it opens is: a root-org admin's
      own authority, exercised through an AgentRuntime that admin OWNS
      (`Platform.Tenancy.root_admin?/1` on the runtime's owner, checked
      before the task is read so a refusal cannot be used to probe the
      board), with a `delivery_reference` that is REQUIRED, parsed strictly
      and RESOLVED against the project's own repo before any write. It
      confers no independent agent authority: `actor_kind` stays `"user"`
      and the agent's id is recorded beside the admin's under
      `metadata.closed_as_delivered.via_agent_id`. `reinstate_cancelled_task/3`
      has NO MCP entry point, so `cancelled` remains absorbing for every
      agent-reachable surface — `close_as_delivered` refuses it with
      `:not_correctable`, because `cancelled` is absent from
      `@undeliverable_statuses`.

      The MCP entry point changes NOTHING about hook firing: this writer
      still does not reach `maybe_finalize_transition/3`, so an
      agent-initiated closure fires no lifecycle edge hooks and appends no
      `TimelineAppender` entry, exactly like the operator-console call it
      delegates to. A reader who sees `done` on a task and expects a
      completion webhook will not find one on this path.

  Because BOTH `done -> planning` writers bypass the choke point,
  **the `done -> planning` edge fires nothing today.** Any re-entry-bound
  assertion must be made on an edge that genuinely fires, with the
  substitution documented where it is made.

  Stage 5 made that substitution: the re-entry bound is asserted on
  `backlog -> blocked` (the `backlog <-> blocked` cycle repeats without a
  gate to route around, and both halves reach the choke point), and the
  reasoning — including the two bypassing writers by name,
  `Platform.Tasks.reopen_with_feedback/3` and
  `Platform.Tasks.supersede_current_plan/3` — is written at the test that
  makes it, in `Platform.Lifecycle.PhaseDiscriminationTest`.

  The manual-drop bypass is likewise pinned as a DECISION rather than left
  to be rediscovered: the same test asserts a board drop across a terminal
  edge fires nothing while the equivalent programmatic transition fires,
  with both halves in one run.

  ## Outcome vocabulary — keep the two tables apart

  `Platform.Tasks.Task`'s `@planning_step_outcomes ~w(complete not_applicable
  failed)` is a CURSOR domain. `Platform.Lifecycle.StepRun`'s statuses
  (`started/completed/diverted/failed/timed_out/suppressed`) are a per-run
  record. They are not two spellings of one thing; `Platform.Lifecycle.Edges`
  already owns the single mapping between them and it must not be duplicated.

  An edge that is never traversed produces NO run rows and NO recorded
  outcome — emphatically not `not_applicable`, which is reserved for an edge
  that WAS traversed with an empty configured pipeline.

  ## The outcome is OBSERVABLE — `[:platform, :lifecycle, :edge]`

  ADDED task 019fe1b7 stage 5, because the distinction above was
  unobservable from outside the executor until then. Both states produce
  ZERO `lifecycle_step_runs` rows, and `Platform.Tasks`' fire point
  DISCARDED `Executor.run_edge/3`'s return, so `:not_applicable` was a value
  no shipped caller could see and no test could assert without calling the
  executor directly — which is not the path production takes.

  The event is emitted ONCE per FIRED edge, with `outcome`, `edge`,
  `task_id`, `run_seq` and `step_count` in its metadata. The three states a
  reader must be able to tell apart:

      never traversed       no rows,  NO EVENT
      traversed, empty      no rows,  outcome: :not_applicable
      traversed, populated  rows,     outcome: :complete | :diverted |
                                               :failed | :suppressed

  Do NOT move the emit outside the fired branch of `fire_status_edge/3`. A
  skipped edge that emitted an event would collapse the first two rows of
  that table back into one, which is the conflation ADR-0046 exists to kill.
  Asserted in `Platform.Lifecycle.PhaseDiscriminationTest`.

  ## PREMISE CORRECTION (task 019fe1b7 stage 3): a run is never persisted

  The stage-3 specification said to "resolve the task's run(s)". There is no
  durable way to. `Platform.Execution.Run` is a VALUE STRUCT held by a
  `RunServer` process; no migration creates a runs table, no column anywhere
  in the schema stores a `run_id`, and the id is randomly generated in
  `Platform.Execution.start_run/2` rather than derived from the task. The only
  task->run index that exists is the live process registry, which is what
  `Platform.Execution.run_ids_for_task/1` reads.

  The consequence for any effect hung on a terminal edge: it reaches the runs
  whose servers are still ALIVE at the transition, and nothing else. After a
  node restart, or once a run's server has exited, its workspace is
  unreachable from the task. Widening that needs a durable index, which is a
  migration nobody has written.

  ## The shipped default was unreachable until stage 3

  `Platform.Lifecycle.Edges.default_steps/1` documented itself as what keeps a
  migrated hook firing for an unconfigured project — and NOTHING on a shipped
  path consulted it: the designer and architect fire points pass `steps:`
  explicitly, and the status-edge fire point deliberately passes nothing at
  all. `Platform.Lifecycle.resolve_steps/2` now falls back to it, which is
  what makes a declared-but-unconfigured effect able to fire.

  ## The declarable edge set is DERIVED, never transcribed

  `status_edges/0` computes the task-status half of the set from
  `Platform.Tasks.valid_task_transitions/0` at call time. It is deliberately
  not a literal list and not a module attribute: a literal would agree with
  itself forever, so widening the transition table would leave the new edge
  quietly undeclarable — configurable in nobody's project, with no error to
  read. Deriving it means the table is the only place an edge is born.
  """

  alias Platform.Lifecycle.Edges
  alias Platform.Tasks

  # Edges that are NOT task-status transitions. They cannot be derived from
  # the transition table because nothing in that table names them: they fire
  # from a plan-status change, from the router's dispatch tick, and from
  # ticket creation respectively. Listed rather than derived because there is
  # no single source to derive them FROM — which is exactly why the two that
  # have one live in `Platform.Lifecycle.Edges` and are read from there.
  @backlog_created_edge "backlog.created"

  # The statuses a task's life ends in. Two, not one: `done` is the success
  # terminal and `cancelled` is the abandonment terminal, and a run — with a
  # worktree on disk — can exist for either.
  @terminal_statuses ["done", "cancelled"]

  # The SUCCESS terminal, alone. Kept apart from `@terminal_statuses` because
  # "the task is over" and "the task succeeded" are different facts and hooks
  # divide along that line — see `completion_edges/0`.
  @completion_status "done"

  @doc """
  The edge key for one status transition. Member 3's `"<from>-><to>"` shape,
  in ONE place so the fire point and the config validator cannot disagree
  about a separator.
  """
  @spec edge_name(binary(), binary()) :: binary()
  def edge_name(from, to) when is_binary(from) and is_binary(to), do: "#{from}->#{to}"

  @doc """
  Every task-status edge, derived from `Platform.Tasks.valid_task_transitions/0`.

  Sorted, so a test can compare an explicit list rather than a set.
  """
  @spec status_edges() :: [binary()]
  def status_edges do
    Tasks.valid_task_transitions()
    |> Enum.flat_map(fn {from, tos} -> Enum.map(tos, &edge_name(from, &1)) end)
    |> Enum.sort()
  end

  @doc """
  Every edge that ends a task's life: the inbound edges to `done` and to
  `cancelled`, DERIVED from the transition table.

  ## Terminal means "the last transition", not "after the deploy agent"

  `deploying` is where a task ends TODAY and will not be forever, and it is
  already not where every task ends: an ADR-0041 stack member rides the
  rollup-PR merge fan-out, owns no per-task deploy stage, and goes
  `in_review -> done` (or `in_progress -> done`) without ever entering
  `deploying`. Anything hung on `deploying->done` alone silently never fires
  for a stack member. Terminality is read off the table — a status with no
  outbound edges, or `done` — never off the presence of a deploy stage.

  ## PREMISE CORRECTION (task 019fe1b7 stage 6, found by mutation probe)

  Stage 3 recorded that the worktree-cleanup effect "hangs on
  `terminal_edges/0`". For the `->cancelled` half that is true. For the
  `->done` half **it is not**: `Platform.Lifecycle.Edges.default_steps/1`
  tests `completion_edges/0` FIRST, and that branch declares the cleanup step
  itself. Shrinking `terminal_edges/0` to `["deploying->done"]` therefore
  leaves a stack member's `in_review -> done` cleanup fully intact — the
  behavioural test still removes the directory — and only the `->cancelled`
  edges lose it.

  Consequence for anyone editing either set: `terminal_edges/0` is the sole
  declaration path for `->cancelled` ONLY. The `->done` edges are declared by
  `completion_edges/0`, so a change intended to affect a completion edge that
  touches only `terminal_edges/0` is a no-op with no failing test to say so.
  Both sets must be read together. Proved by removing the cleanup step from
  the completion branch, which reddens ten tests including the end-to-end
  `in_review -> done` removal.

  `cancelled` is included because a run can genuinely exist for a cancelled
  task: `in_progress -> cancelled` is legal, runs are started while a task is
  in progress, and the cancellation teardown abandons leases without removing
  any directory.
  """
  @spec terminal_edges() :: [binary()]
  def terminal_edges do
    Tasks.valid_task_transitions()
    |> Enum.flat_map(fn {from, tos} ->
      tos
      |> Enum.filter(&(&1 in @terminal_statuses))
      |> Enum.map(&edge_name(from, &1))
    end)
    |> Enum.sort()
  end

  @doc """
  Every edge on which a task COMPLETES: the inbound edges to `done` alone,
  DERIVED from the transition table.

  A strict subset of `terminal_edges/0`, and separate from it on purpose
  (task 019fe1b7 stage 4). `terminal_edges/0` answers "is this task's life
  over" — true of `cancelled` too, which is why the worktree-cleanup effect
  hangs there. This answers the narrower "did this task SUCCEED", which is
  what an outbound completion notification claims. A cancelled task did not,
  and a hook that inherited the wider set from a shared helper would announce
  completion for an abandoned task with nothing in the payload able to
  contradict it.

  Derived, not transcribed, for the same reason as every other set here: an
  ADR-0041 stack member reaches `done` from `in_review` or `in_progress` and
  never enters `deploying`, so anything hung on `deploying->done` alone
  silently never fires for one.
  """
  @spec completion_edges() :: [binary()]
  def completion_edges do
    Tasks.valid_task_transitions()
    |> Enum.flat_map(fn {from, tos} ->
      tos
      |> Enum.filter(&(&1 == @completion_status))
      |> Enum.map(&edge_name(from, &1))
    end)
    |> Enum.sort()
  end

  @doc "The status a task's life ends in SUCCESSFULLY. One, not two."
  @spec completion_status() :: binary()
  def completion_status, do: @completion_status

  @doc "The statuses a task's life can end in."
  @spec terminal_statuses() :: [binary()]
  def terminal_statuses, do: @terminal_statuses

  @doc "The edge fired when a ticket is created. Effects and notifies only."
  @spec backlog_created_edge() :: binary()
  def backlog_created_edge, do: @backlog_created_edge

  @doc """
  Edges that exist but are not task-status transitions: the designer and
  architect edges owned by `Platform.Lifecycle.Edges`, plus `backlog.created`.
  """
  @spec non_status_edges() :: [binary()]
  def non_status_edges, do: Enum.sort([@backlog_created_edge | Edges.all()])

  @doc "Every edge a project may declare a pipeline on."
  @spec declarable_edges() :: [binary()]
  def declarable_edges, do: Enum.sort(status_edges() ++ non_status_edges())

  @doc "Whether `edge` is one a project may declare a pipeline on."
  @spec declarable?(term()) :: boolean()
  def declarable?(edge) when is_binary(edge), do: edge in declarable_edges()
  def declarable?(_edge), do: false
end
