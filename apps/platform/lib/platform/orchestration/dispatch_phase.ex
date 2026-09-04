defmodule Platform.Orchestration.DispatchPhase do
  @moduledoc """
  Derives the shape of a task dispatch from the STAGE's actual contract rather
  than from `task.status`.

  ## Why this exists

  `HeartbeatScheduler.dispatch_prompt/4` currently selects its template with
  five function heads that pattern-match `task.status`. `task.status` lags a
  whole dispatch cycle behind the plan engine: after a previous stage's
  `manual_approval` gate is approved, the task row still reads `"in_review"`
  while the CURRENT stage is `running` with only `test_pass` / `lint_pass`
  pending. The executor then receives the reviewer template.

  Observed three times on task `019f9b29-9c47-7b66-b863-641b50d09eff` (stages 3
  and 4), and once more on task `019fa230`'s DEPLOY dispatch — a stage whose
  sole validation was `pr_merged` also received the review template. That second
  shape is why this is a resolver and not three string patches: selecting on the
  stage's pending validation KINDS covers `pr_merged` for free, whereas an
  `in_review`-specific patch would have missed it entirely.

  ## Contract

  `resolve/3` returns a `%DispatchPhase{}`:

    * `:slug` — one of the existing `dispatch.*` template slugs.
    * `:ack_mode` — `:stage` when a running stage resolved (so `task_ack/3` has
      a `stage_id` to ack against), `:none` otherwise. This is the invariant
      defect 3 taught us: `Platform.Federation.ToolSurface` returns
      `{:error, :no_running_stage}` for a stage-less ack, so a dispatch with no
      resolved stage must not instruct the agent to ack. `ack_mode` is derived
      solely from `stage_id` presence — it is never guessed from status.
    * `:requires_stage?` — whether this dispatch is meaningless without a
      resolved running stage. See the note below; stage 4 of task `019fa469`
      consumes this to suppress dispatch rather than fabricate a stage.
    * `:stage_id` — the resolved running stage's id, or `nil`.

  ## Resolution order (stage contract first, `task.status` last)

    1. No stage and `task.status == "planning"` → `dispatch.planning`.
    2. A stage → classify its PENDING validation kinds (`status == "pending"`)
       through `kind_phase_table/0`, with this precedence:
         * any `e2e_behavior` → `dispatch.review_e2e` (preserves the existing
           e2e-wins-over-`manual_approval` policy documented on
           `HeartbeatScheduler.select_review_template/2`)
         * else a system-injected deploy stage → `dispatch.deploying`
           (see "Deploy stages are not classifiable by kind alone" below)
         * else any deploy-gate kind → `dispatch.deploying`
         * else ALL pending are `manual_approval` → `dispatch.in_review`
         * else any implementation kind → `dispatch.in_progress` (a stage
           mixing `manual_approval` with `test_pass` still needs the work done
           before the gate can be reviewed)
         * else the stage CARRIES gates and every one is met, AND
           `task.status` maps to a review phase → `dispatch.fallback`, NOT the
           reviewer body. There is nothing left for a reviewer to judge, and
           the status saying otherwise is the documented staleness, not
           evidence. A stage with NO gates at all is deliberately excluded —
           see `review_status_without_unmet_gate?/2` (task `01a01b00`).
         * else nothing unmet at all → fall through to the `task.status`
           mapping, then `dispatch.fallback`
    3. No stage and status is not planning → `dispatch.fallback`.

  ### Deploy stages are not classifiable by kind alone

  Stage 2 of task `019fa469` found this while cutting the call site over, and
  it is the reason the kind table is not the whole resolver.
  `Platform.Tasks.DeployStageBuilder` emits, per strategy:

    * `pr_merge` → `pr_merged`; `docker_deploy` / `fly` → `ci_passed` +
      `test_pass` — classifiable.
    * `manual` and `skill_driven` → a lone `manual_approval`.
    * `project_files` → a lone `test_pass`.

  Those last three are indistinguishable BY KIND from a review stage and an
  implementation stage respectively, so a purely kind-keyed resolver would
  route three of the six deploy strategies to the wrong template — a
  regression the old `task.status == "deploying"` head did not have. The
  discriminator is `DeployStageBuilder.deploy_stage_name?/1`, an exact
  `"Deploy: "` prefix on a name that only `build_stage/4` ever mints (planners
  are forbidden from authoring deploy stages). It is checked BELOW the
  `e2e_behavior` arm only because deploy stages never carry one — the builder's
  moduledoc forbids it — so the ordering is defensive, not load-bearing.

  This is emphatically not `infer_stage_type/1` by another name: that is a
  case-insensitive SUBSTRING search that fires on "Rework the deploy strategy
  resolver". See the negative control in `dispatch_phase_routing_test.exs`.

  ### Note on `requires_stage?` when no stage resolved

  Step 3 renders `dispatch.fallback`, which is not itself stage-scoped. But a
  task sitting at `in_progress` / `in_review` / `deploying` with NO running
  stage is precisely defect 4: `TaskRouter.current_running_stage/1` returned
  `nil` and the router dispatched anyway, fabricating `Stage 1/7` and an empty
  `stage_id`. So `requires_stage?` is true whenever the task's own status
  implies a stage-scoped phase but no stage resolved — the caller should decline
  to dispatch and let the next tick re-derive, rather than send a generic prompt
  that answers none of the agent's questions. For a task in a genuinely
  stage-less status (`"todo"`, `"done"`, …) it stays false and the fallback
  dispatches normally.

  ## Source-of-truth reuse

  `@kind_phase`'s keys are checked at COMPILE TIME against
  `Platform.Tasks.Validation.kinds/0`, in both directions. Adding a kind to
  `@kinds` without classifying it here breaks the build instead of silently
  routing to fallback; a typo'd key here breaks the build instead of silently
  never matching. There is deliberately no parallel kind list in this module.

  ## Explicitly NOT reused

  `TaskRouter.infer_stage_type/1` is a case-insensitive SUBSTRING match on the
  stage NAME (`"review"` / `"deploy"` / `"ci"`) feeding
  `LeaseManager.stage_kind_timeouts/0`. It is the same defect class this module
  replaces. Do not build on it and do not mirror it here; retiring it is out of
  scope for task `019fa469`.
  """

  alias Platform.Tasks.DeployStageBuilder
  alias Platform.Tasks.Validation

  @enforce_keys [:slug, :ack_mode, :requires_stage?, :stage_id]
  defstruct [:slug, :ack_mode, :requires_stage?, :stage_id]

  @type phase :: :planning | :in_progress | :in_review | :review_e2e | :deploying | :fallback

  @type t :: %__MODULE__{
          slug: String.t(),
          ack_mode: :stage | :none,
          requires_stage?: boolean(),
          stage_id: String.t() | nil
        }

  # Validation kind -> dispatch phase. Keys are compile-time exhaustive over
  # Platform.Tasks.Validation.kinds/0 (see the guard directly below).
  @kind_phase %{
    "e2e_behavior" => :review_e2e,
    "manual_approval" => :in_review,
    "ci_check" => :deploying,
    "ci_passed" => :deploying,
    "pr_merged" => :deploying,
    "lint_pass" => :in_progress,
    "type_check" => :in_progress,
    "test_pass" => :in_progress,
    "code_review" => :in_progress
  }

  @unclassified Validation.kinds() -- Map.keys(@kind_phase)
  @unknown_keys Map.keys(@kind_phase) -- Validation.kinds()

  if @unclassified != [] do
    raise CompileError,
      description:
        "Platform.Orchestration.DispatchPhase: validation kind(s) #{inspect(@unclassified)} " <>
          "are declared in Platform.Tasks.Validation.kinds/0 but not classified in @kind_phase. " <>
          "Classify them — falling through to dispatch.fallback is the defect task 019fa469 fixes.",
      file: __ENV__.file,
      line: __ENV__.line
  end

  if @unknown_keys != [] do
    raise CompileError,
      description:
        "Platform.Orchestration.DispatchPhase: @kind_phase key(s) #{inspect(@unknown_keys)} " <>
          "are not valid validation kinds (Platform.Tasks.Validation.kinds/0). Likely a typo.",
      file: __ENV__.file,
      line: __ENV__.line
  end

  # Validation kinds that no agent can pass on its own — passing them requires a
  # person (or, for `pr_merged`, a person clicking merge). Compile-time checked
  # against Platform.Tasks.Validation.kinds/0 in the same shape as @kind_phase
  # above, so a renamed kind breaks the build instead of silently never matching.
  #
  # `ci_passed` / `ci_check` are DELIBERATELY absent: a deploy stage sitting on a
  # red or never-reported CI gate IS a stuck agent and must keep alarming.
  @agent_unpassable_kinds ["manual_approval", "pr_merged"]

  @unknown_unpassable @agent_unpassable_kinds -- Validation.kinds()

  if @unknown_unpassable != [] do
    raise CompileError,
      description:
        "Platform.Orchestration.DispatchPhase: @agent_unpassable_kinds entr(ies) " <>
          "#{inspect(@unknown_unpassable)} are not valid validation kinds " <>
          "(Platform.Tasks.Validation.kinds/0). Likely a typo or a renamed kind.",
      file: __ENV__.file,
      line: __ENV__.line
  end

  # Phases whose template body is written for a specific running stage. A
  # dispatch of one of these without a stage_id is the fabrication defect 4
  # describes, not a degraded-but-useful prompt.
  @stage_scoped_phases [:in_progress, :in_review, :review_e2e, :deploying]

  # Phases that summon a REVIEWER. Only `:in_review` is reachable from
  # `status_phase/1` today — there is no `"review_e2e"` task status — but the
  # list is named rather than inlined so a future review-shaped status has to
  # be classified here as well as in the mapping, instead of quietly acquiring
  # the stale-status fallthrough this module now refuses (task 01a01b00).
  @review_phases [:in_review, :review_e2e]

  # Precedence order applied to the SET of phases implied by the pending kinds:
  # deploying, then implementation, then behavioural. :in_review is handled
  # separately because it only wins when it is the ONLY phase present.
  #
  # Implementation kinds outrank :review_e2e (019ff83c). A stage carrying both a
  # pending implementation validation and a pending `e2e_behavior` case is real
  # and in flight today: `PlanEngine.attach_e2e_validations_to_review_stage/2`
  # lifts the e2e case onto an existing stage whose name merely contains
  # "review"/"validation", so plans ALREADY minted hold both kinds on one stage.
  # Ordering the phase by the stage's unmet validations repairs those in-flight
  # plans; teaching PlanEngine to always split the e2e case onto its own gate
  # would not (it cannot reach an approved plan), and would leave a directly
  # built mixed stage still answering :review_e2e here. The PlanEngine
  # name-substring reuse is a separate defect, filed separately, not fixed here.
  @phase_precedence [:deploying, :in_progress, :review_e2e]

  @doc """
  The validation-kind -> phase classification table.

  Exposed so tests can assert exhaustiveness against
  `Platform.Tasks.Validation.kinds/0` without reaching into module attributes.
  """
  @spec kind_phase_table() :: %{String.t() => phase()}
  def kind_phase_table, do: @kind_phase

  @doc """
  Phases whose dispatch template is meaningless without a resolved running stage.
  """
  @spec stage_scoped_phases() :: [phase()]
  def stage_scoped_phases, do: @stage_scoped_phases

  @doc """
  The validations a stage still OWES — those whose status is in
  `Platform.Tasks.Validation.unmet_statuses/0`.

  Public because `TaskRouter` needs the same reading of "still owed" when it
  decides whether to withhold a dispatch, and a second filter spelled in the
  router is exactly the two-classifier drift that produced task `01a01b00`.
  Reads both key shapes: dispatch inputs are plain maps in tests and Ecto
  structs in prod.
  """
  @spec unmet_validations(map() | nil) :: [map()]
  def unmet_validations(stage), do: stage |> validations_of() |> unmet_of()

  defp validations_of(stage) do
    case field(stage, :validations) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp unmet_of(validations) do
    Enum.filter(validations, fn v ->
      (field(v, :status) || "pending") in Validation.unmet_statuses()
    end)
  end

  @doc """
  True when `task.status` maps to a review phase but every gate the RESOLVED
  `stage` carries has already been MET.

  ## Why this is a named predicate and not an inline condition

  Two callers need the identical judgement and must not drift apart:

    * `phase_for/2` — so `resolve/3` stops answering a REVIEWER slug for a
      stage with no gate left to review. `status_phase/1` is this module's
      documented LAST resort and is stale for a full dispatch cycle; when the
      stage says "nothing owed" and the status says "in review", the stage is
      the fresher of the two and wins.
    * `TaskRouter` — so the dispatch can be withheld outright rather than
      degraded to a generic body. The router ANDs this with a plan-wide
      conjunct it alone can evaluate — no stage is `pending` (see
      `no_unmet_gate_dispatch?/3` there). This function deliberately answers
      only about the ONE resolved stage, because that is all it can see and
      all `resolve/3` needs.

  ## A stage with NO validations at all is NOT this shape — read before widening

  "Every gate met" REQUIRES at least one gate. An UNGATED stage answers `false`
  here, and the distinction is not pedantry — it is the whole safety margin
  between this predicate and silent strangulation.

  `PlanEngine` auto-advances a stage from ONE place: the `cond` inside
  `evaluate_validation/2`, which fires `maybe_advance_resolved_stage/1` once
  `all_validations_resolved?/1` holds. That code path is reached only by
  DISPOSITIONING A VALIDATION. So:

    * All gates met — the last `evaluate_validation/2` call has already fired
      the advance. A stage still sitting at `running` is in a transient window
      that closes without anyone's help, so declining to send it a reviewer
      costs nothing.
    * NO gates at all — nothing will ever call `evaluate_validation/2` for it,
      so the engine will never advance it. The only thing that can move it is
      an agent calling `stage_complete`, and the only thing that will make an
      agent do that is the dispatch. Refusing to name that dispatch honestly —
      or, in the router, withholding it — parks the task forever.

  Zero-validation stages are not a curiosity: `task_router_dispatch_suppression_test.exs`'s
  "a task whose current plan is approved with a RUNNING stage still dispatches"
  fixture is exactly one, and so is the `simple_plan_with_stage/0` fixture in
  `heartbeat_scheduler_test.exs`. Both went red against a first draft of this
  predicate that omitted the `!= []` half; that is how this paragraph got
  written.

  Returns `false` when no stage resolved: with no stage there is nothing to
  contradict the status, and that shape belongs to
  `TaskRouter.unresolved_stage_dispatch?/3` instead.
  """
  @spec review_status_without_unmet_gate?(map() | nil, map() | nil) :: boolean()
  def review_status_without_unmet_gate?(task, stage)

  def review_status_without_unmet_gate?(_task, nil), do: false

  def review_status_without_unmet_gate?(task, stage) do
    gates = validations_of(stage)

    status_phase(task) in @review_phases and gates != [] and unmet_of(gates) == []
  end

  @doc """
  Resolve the dispatch shape for `task` / `plan` / `stage`.

  `stage` is the plan's currently-running stage, or `nil` when none resolved.
  `plan` is accepted for call-site symmetry with
  `HeartbeatScheduler.dispatch_prompt/4` and is not consulted — the running
  stage and the task carry every fact this resolver needs, and reading plan
  state here would reintroduce a second source of truth.

  Pure function: no DB access, no process state.
  """
  @spec resolve(map() | nil, map() | nil, map() | nil) :: t()
  def resolve(task, plan, stage)

  def resolve(task, _plan, stage) do
    stage_id = field(stage, :id)
    phase = phase_for(task, stage)

    %__MODULE__{
      slug: slug_for(phase),
      ack_mode: if(is_nil(stage_id), do: :none, else: :stage),
      requires_stage?: requires_stage?(phase, stage_id, task),
      stage_id: stage_id
    }
  end

  @doc """
  The phase implied by a list of pending validations, or `nil` when the list is
  empty or classifies to nothing.

  Split out so `HeartbeatScheduler.select_review_template/2` can delegate its
  e2e-vs-manual decision here in stage 2 instead of keeping a second classifier.
  """
  @spec phase_for_pending([map()]) :: phase() | nil
  def phase_for_pending(pending) when is_list(pending) do
    phases =
      pending
      |> Enum.map(&Map.get(@kind_phase, kind_of(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      phases == [] -> nil
      # in_review only wins when nothing else is pending: a stage mixing a
      # manual_approval gate with implementation validations still needs the
      # implementation done first.
      phases == [:in_review] -> :in_review
      no_implementation_e2e?(phases) -> :review_e2e
      true -> Enum.find(@phase_precedence, :in_review, &(&1 in phases))
    end
  end

  def phase_for_pending(_), do: nil

  # e2e still outranks a deploy gate, but ONLY when no implementation kind is
  # pending. Carried over from the pre-019ff83c order rather than expressed in
  # @phase_precedence, because the three relations are not a total order:
  # deploying beats in_progress, in_progress beats review_e2e, and review_e2e
  # beats deploying. A deploy stage never legitimately carries an e2e_behavior
  # validation (DeployStageBuilder's moduledoc forbids it), so this only decides
  # hand-built stages — but dropping it would silently change that answer.
  defp no_implementation_e2e?(phases),
    do: :review_e2e in phases and :in_progress not in phases

  # -- internals ------------------------------------------------------------

  defp phase_for(task, nil) do
    case status_phase(task) do
      :planning -> :planning
      _ -> :fallback
    end
  end

  defp phase_for(task, stage) do
    kind_phase = stage |> pending_validations() |> phase_for_pending()

    cond do
      # e2e first — a deploy stage never carries one (DeployStageBuilder's
      # moduledoc forbids it), so this arm is a defensive ordering, not a
      # policy the two signals actually contest. Since 019ff83c this can no
      # longer see a stage that also has pending implementation validations:
      # phase_for_pending/1 already answered :in_progress for those, so this
      # arm cannot resurrect the old e2e-first precedence.
      kind_phase == :review_e2e ->
        :review_e2e

      deploy_stage?(stage) ->
        :deploying

      not is_nil(kind_phase) ->
        kind_phase

      # Task 01a01b00 stage 3. A stage resolved, CARRIES gates, and every one
      # of them is met, yet `task.status` still reads `in_review` — the
      # last-resort mapping would hand a reviewer the UI-judgment body for a
      # gate that no longer needs judging.
      #
      # The window is real rather than theoretical: `PlanEngine` advances a
      # stage only from inside `evaluate_validation/2`, so between the write
      # that passes the LAST gate and the advance that follows it, a stage sits
      # at `running` with everything met while `task.status` still lags a full
      # dispatch cycle behind. Answer `:fallback` instead of a review slug.
      #
      # `:fallback` and not `:in_progress`: the stage owes no implementation
      # work either, so claiming otherwise would be the same lie pointed the
      # other way. `:fallback` is already the shape a nameable-but-not-running
      # subject gets (see `TaskRouter.unresolved_stage_dispatch?/3` on why a
      # pending stage keeps its generic body), and it leaves `ack_mode` at
      # `:stage` because a stage genuinely did resolve.
      #
      # This clause only makes the dispatch HONEST. Withholding it entirely is
      # the router's call, because only the router can see whether the rest of
      # the plan has work left — see `no_unmet_gate_dispatch?/3` there.
      review_status_without_unmet_gate?(task, stage) ->
        :fallback

      true ->
        status_phase(task) || :fallback
    end
  end

  # A stage minted by `DeployStageBuilder.build_stage/4`. Needed because the
  # `manual` / `skill_driven` / `project_files` strategies emit validation
  # kinds (`manual_approval`, `test_pass`) that are indistinguishable from a
  # review or implementation stage. See the moduledoc.
  defp deploy_stage?(stage), do: DeployStageBuilder.deploy_stage_name?(field(stage, :name))

  # task.status is the LAST resort, never the first. It is stale for a full
  # dispatch cycle after a stage's gate is approved.
  defp status_phase(task) do
    case field(task, :status) do
      "planning" -> :planning
      "in_progress" -> :in_progress
      "in_review" -> :in_review
      "deploying" -> :deploying
      _ -> nil
    end
  end

  defp requires_stage?(phase, stage_id, task) do
    cond do
      phase in @stage_scoped_phases -> true
      is_nil(stage_id) -> status_phase(task) in @stage_scoped_phases
      true -> false
    end
  end

  @doc """
  True iff every pending validation kind is one no agent can pass alone.

  Used by the no-ack path to distinguish "an agent has gone quiet" from "this
  stage is legitimately waiting on a human". `pr_merged` only counts as
  agent-unpassable when the strategy is a `pr_merge` WITHOUT `auto_merge` — with
  `auto_merge: true` the deployer can drive the merge itself, so the stage is
  agent-drivable and the alarm must still fire.

  Why a predicate and not a strategy-name check: keying off `"pr_merge"` alone
  would also silence a `pr_merge` stage stuck on a red `ci_passed`, which is a
  real stall.

  Why not extend `alarm_silence`: `silenced_until` is operator-initiated,
  time-boxed and 24h-capped, and it suppresses UNCONDITIONALLY. Using it here
  would turn a structural fact ("this gate needs a person") into recurring
  nightly toil and would be unable to tell a healthy wait from a genuine stall.
  This predicate can.
  """
  # MUTATION-COVERED (task 01a01a4a stage 3). Broadening this predicate to
  # `pending_kinds != [] and agent_unpassable?("pr_merged", strategy)` — i.e.
  # keeping the strategy check but dropping the per-kind `Enum.all?` — reds
  # exactly one router test:
  #
  #   test/platform/orchestration/task_router_safety_net_suppression_test.exs
  #   "CONTROL: an agent-passable ci_passed on the SAME strategy still fires"
  #
  # under that mutant a deploy stage stalled on a red `ci_passed` gets parked as
  # `execution.awaiting_human_action` instead of alarming — the suppress-every-
  # deploy-stage regression. The narrower unit tests in
  # test/platform/orchestration/dispatch_phase_human_gate_test.exs kill it too.
  # If you widen this predicate, that test is where the decision lives.
  @spec human_gated_pending?(pending_kinds :: [String.t()], strategy :: map()) :: boolean()
  def human_gated_pending?(pending_kinds, strategy)
      when is_list(pending_kinds) and is_map(strategy) do
    pending_kinds != [] and Enum.all?(pending_kinds, &agent_unpassable?(&1, strategy))
  end

  defp agent_unpassable?("pr_merged", strategy) do
    config = Map.get(strategy, "config")
    strategy_type = Map.get(strategy, "type")

    # Read `auto_merge` exactly the way HeartbeatScheduler does (config first,
    # falling back to the entry itself) so the two never disagree about where the
    # key lives.
    auto_merge = Map.get(config || strategy, "auto_merge", false)

    strategy_type == "pr_merge" and !auto_merge
  end

  defp agent_unpassable?(kind, _strategy), do: kind in @agent_unpassable_kinds

  defp slug_for(phase), do: "dispatch." <> Atom.to_string(phase)

  # Unmet validations live on the stage under :validations. Mirrors
  # HeartbeatScheduler.pending_validations_for_stage/1 — dispatch inputs are
  # plain maps in tests and Ecto structs in prod, so read both key shapes.
  #
  # "Still owed" is `Validation.unmet_statuses/0`, NOT the literal "pending".
  # A gate at `running`, or one that came back `failed` on an earlier review
  # round, is work the stage still owes; classifying only on "pending" made
  # such a stage look gateless, so `phase_for/2` fell through to
  # `status_phase(task)` and rendered the UI-judgment body for a stage with no
  # manual_approval gate (task 01a01b00). The list is NOT re-spelled here:
  # `Platform.Tasks` owns the validation vocabulary and this context already
  # depends on it in that direction.
  #
  # Now `unmet_validations/1` (public, above) — stage 3 of the same task gave
  # `TaskRouter` the same reading. Kept as a one-line internal alias so the
  # call sites below keep reading as the classifier step they are.
  defp pending_validations(stage), do: unmet_validations(stage)

  defp kind_of(validation), do: field(validation, :kind)

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_, _), do: nil
end
