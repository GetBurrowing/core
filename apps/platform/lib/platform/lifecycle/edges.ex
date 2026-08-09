defmodule Platform.Lifecycle.Edges do
  @moduledoc """
  The two lifecycle edges this stack member migrates onto the pipeline
  frame, and the mapping from a `Platform.Lifecycle.StepRun` status to the
  `complete / not_applicable / failed` planning-step outcome vocabulary
  (ADR-0046 Amendment 1, task 019fe1b7-6b6f-7c04-9f3c-d4f44ec87d26).

  This module is a NAMING AND MAPPING TABLE. It holds no runtime state,
  starts nothing, and intercepts nothing. It exists so the designer edge,
  the architect edge, and the run-status translation are declared in ONE
  place rather than re-derived at each of the two call sites.

  ## The two fire points are NOT the same kind of edge

  That asymmetry is the finding that shapes the migration, and it is why
  the two edges are named separately rather than folded into one
  "planning hook" abstraction.

    * `designer_edge/0` — `"planning.design_requested"`. Fires from the
      ROUTER'S DISPATCH TICK, not from a task-status transition. The
      machinery is bespoke and lives in
      `Platform.Orchestration.TaskRouter`: a hold predicate
      (`design_step_open?/1`, reading `task.planning_step == "designing"`
      plus the absence of a plan), a level-check expiry
      (`design_hold_expired?/2`, computed off `task.updated_at`), an
      eager `:design_deadline` timer with arm/cancel, a wake-up
      (`release_design_hold_if_closed/1`) and an expiry writer
      (`expire_design_step/1` calling `Platform.Design.PreplanStep.expire/2`).
      THIS is the bespoke lifecycle machinery the migration replaces —
      described in the past tense as of task 019fe1b7 stage 2, which deleted
      all of it bar the hold predicate and moved the expiry onto the edge's
      own runner. The step itself is
      `Platform.Design.PreplanLifecycleStep`, declared by `default_steps/1`.

    * `architect_edge/0` — `"plan.review_requested"`. Fires from a
      PLAN-status transition, not a task-status transition:
      `fire_architecture_review_plan/1` in `Platform.Tasks`, called from
      `submit_plan_for_review/1` on `draft -> pending_review`. Resolution
      is a SINGLE function, `resolve_architecture_gate/3`, whose
      `resolution` argument already spans
      `:pass | :reject | :expired | :dispatch_failed | :human_override`.

  ## Premise correction: there is no separate architect expiry path

  The ticket's framing that the two hooks have divergent expiry paths to
  be unified is FALSE for the architect. `:expired` is a RESOLUTION VALUE
  on `resolve_architecture_gate/3`, alongside the other four. There is no
  second expiry function to unify with. The genuine asymmetry is
  narrower: THE DESIGNER HAS BESPOKE LIFECYCLE MACHINERY; THE ARCHITECT
  LARGELY DOES NOT. A truthful small architect diff is the correct
  outcome, not a defect in the migration.

  ## Run status -> planning-step outcome

  `Platform.Lifecycle.StepRun` statuses are a PER-RUN RECORD. They are not
  a second outcome table and must not become one: the
  `complete / not_applicable / failed` trio on `Platform.Tasks.Task` is
  the hard-won part of ADR-0046 — it is what distinguishes "no hook
  configured" from "hook configured and broken". The migration EXPRESSES
  hook results in that vocabulary; `run_outcome/1` is the whole
  translation.

  | edge outcome / run status | planning-step outcome | why |
  | ------------------------- | --------------------- | --- |
  | `:complete`               | `"complete"`          | every step that ran resolved |
  | `:not_applicable`         | `"not_applicable"`    | the edge RAN with no steps configured |
  | `:suppressed`             | `"not_applicable"`    | the re-entry bound refused the firing; no step ran, so nothing is broken |
  | `:diverted`               | `"complete"`          | a divert is a SUCCESSFUL gate result — the hook did its job and sent the task back. Mapping it to `"failed"` would make every working rejection look like a broken hook |
  | `:failed`                 | `"failed"`            | a step ran and errored |
  | `:timed_out`              | `"failed"`            | a budget expired with the step unresolved; indistinguishable from broken at this level of the vocabulary |
  | `:started`                | `"failed"`            | terminal-read of a non-terminal status: a run left `started` never settled |

  `:suppressed -> "not_applicable"` is the one row worth arguing about.
  It is chosen because the outcome table answers "is this hook working?",
  and a refusal is not a malfunction. The refusal itself remains visible
  as a `StepRun` row with `status: "suppressed"` and no `step_name`, so
  the distinction is not lost — it is recorded where it belongs, on the
  run, not in the outcome trio.

  ## What this member does NOT cover

  Stated explicitly because the alternative design looks total and is
  not.

  This member INTERCEPTS NEITHER SEAM. It does not wrap
  `Platform.Responsibilities.fire/2` and it does not wrap
  `Platform.Responsibilities.Router.fire/2`. It migrates TWO NAMED
  CALLERS — the designer and the architect gate — onto explicit pipeline
  steps.

  Consequence: **the lifecycle frame does NOT observe every
  responsibility fire.** `Platform.Tasks.PlanEngine`'s
  `architecture.audit_diff` fire and `Platform.Meetings.Summarizer`'s
  `meetings_summarize` fire are OUT OF SCOPE and continue to fire outside
  any pipeline. The summarizer calls the Router DIRECTLY, bypassing the
  facade, so — in member 3's words — *"if member 4 intends to intercept
  every fire, wrapping the facade is insufficient and will silently miss
  the meetings summary path; member 4 must either intercept
  `Router.fire/2` or move the summarizer onto the facade first."* Wrapping
  the facade was rejected for exactly that reason: it would look complete,
  with every facade call site intercepted and the tests green, while the
  summary path never entered the pipeline. Scoping out is honest; a total
  claim with a silent hole is not.
  """

  alias Platform.Lifecycle.StepRun

  @designer_edge "planning.design_requested"
  @architect_edge "plan.review_requested"

  @designer_step "design_preplan"
  @architect_step "architect_gate"

  @doc "Edge name for the designer hook, fired from the router's dispatch tick."
  @spec designer_edge() :: binary()
  def designer_edge, do: @designer_edge

  @doc "Edge name for the architect gate, fired on plan `draft -> pending_review`."
  @spec architect_edge() :: binary()
  def architect_edge, do: @architect_edge

  @doc "Both edges this member owns, in no significant order."
  @spec all() :: [binary()]
  def all, do: [@designer_edge, @architect_edge]

  @doc """
  The registry name of the designer's step.

  A step NAME, never a module: `Platform.Lifecycle.StepRegistry` is the only
  thing that turns it into code.
  """
  @spec designer_step_name() :: binary()
  def designer_step_name, do: @designer_step

  @doc "The registry name of the architect gate's step. A NAME, never a module."
  @spec architect_step_name() :: binary()
  def architect_step_name, do: @architect_step

  @doc """
  The steps that run on an edge when the project configures none.

  ## Why a shipped default exists at all

  `Platform.Lifecycle.resolve_steps/2` reads the project row and nothing
  else, so an unconfigured project resolves to `[]` — and `[]` on the
  designer edge would mean THE DESIGN STEP SIMPLY STOPS FIRING for every
  project that exists today. A migration whose observable effect is deleting
  the feature it migrates is not a migration.

  So the designer is a SHIPPED step, not a configured one, exactly as it was
  before: `await: true` because the planner must actually wait, and
  `can_divert: true` because a gate that cannot send the task back is
  advisory. String keys, so the declaration is byte-identical in shape to one
  that came out of jsonb — a shipped default that a configured pipeline could
  not have expressed would be a second, hidden step language.

  The architect gate is a shipped step for the SAME reason (task 019fe1b7
  stage 3): `resolve_steps/2` on an unconfigured project answers `[]`, the
  edge reports `:not_applicable`, and a green suite records that every plan
  submission had no architecture hook. `await: true` because the plan
  genuinely waits at the gate, `can_divert: true` because `:reject` sends the
  plan back — and BOTH are read from this declaration by
  `Platform.Lifecycle.Executor`, never from the step's position.

  Returns `[]` for an edge with no shipped default.
  """
  @spec default_steps(binary()) :: [map()]
  def default_steps(@designer_edge) do
    [%{"step" => @designer_step, "await" => true, "can_divert" => true}]
  end

  def default_steps(@architect_edge) do
    [%{"step" => @architect_step, "await" => true, "can_divert" => true}]
  end

  def default_steps(_edge), do: []

  @doc """
  Translate an executor edge outcome or a `StepRun` status into the
  `Platform.Tasks.Task.planning_step_outcomes/0` vocabulary.

  Accepts an atom (the executor's outcome) or a binary (a persisted
  `StepRun.status`). See the table in the moduledoc for the reasoning,
  in particular why `:diverted` is `"complete"` and `:suppressed` is
  `"not_applicable"`.
  """
  @spec run_outcome(atom() | binary()) :: binary()
  def run_outcome(status) when is_binary(status) do
    status |> String.to_existing_atom() |> run_outcome()
  end

  def run_outcome(:complete), do: "complete"
  def run_outcome(:completed), do: "complete"
  def run_outcome(:diverted), do: "complete"
  def run_outcome(:not_applicable), do: "not_applicable"
  def run_outcome(:suppressed), do: "not_applicable"
  def run_outcome(:failed), do: "failed"
  def run_outcome(:timed_out), do: "failed"
  def run_outcome(:started), do: "failed"

  @doc """
  Every `StepRun` status maps to some planning-step outcome.

  Exposed so a test can assert TOTALITY against
  `Platform.Lifecycle.StepRun.statuses/0` rather than against a list
  written by hand here — a hand-written list would agree with itself
  after someone adds a sixth status and forgets the mapping.
  """
  @spec mapped_run_statuses() :: [binary()]
  def mapped_run_statuses, do: StepRun.statuses()
end
