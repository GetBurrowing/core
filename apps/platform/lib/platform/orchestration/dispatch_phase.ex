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
         * else no pending validations at all → fall through to the
           `task.status` mapping, then `dispatch.fallback`
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
  `"Deploy: "` prefix on a name that only `build_stage/3` ever mints (planners
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

  # Phases whose template body is written for a specific running stage. A
  # dispatch of one of these without a stage_id is the fabrication defect 4
  # describes, not a degraded-but-useful prompt.
  @stage_scoped_phases [:in_progress, :in_review, :review_e2e, :deploying]

  # Precedence order applied to the SET of phases implied by the pending kinds.
  # e2e before deploying before in_progress; :in_review is handled separately
  # because it only wins when it is the ONLY phase present.
  @phase_precedence [:review_e2e, :deploying, :in_progress]

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
      true -> Enum.find(@phase_precedence, :in_review, &(&1 in phases))
    end
  end

  def phase_for_pending(_), do: nil

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
      # policy the two signals actually contest.
      kind_phase == :review_e2e -> :review_e2e
      deploy_stage?(stage) -> :deploying
      not is_nil(kind_phase) -> kind_phase
      true -> status_phase(task) || :fallback
    end
  end

  # A stage minted by `DeployStageBuilder.build_stage/3`. Needed because the
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

  defp slug_for(phase), do: "dispatch." <> Atom.to_string(phase)

  # Pending validations live on the stage under :validations. Mirrors
  # HeartbeatScheduler.pending_validations_for_stage/1 — dispatch inputs are
  # plain maps in tests and Ecto structs in prod, so read both key shapes.
  defp pending_validations(stage) do
    validations = field(stage, :validations) || []

    case validations do
      list when is_list(list) ->
        Enum.filter(list, fn v -> (field(v, :status) || "pending") == "pending" end)

      _ ->
        []
    end
  end

  defp kind_of(validation), do: field(validation, :kind)

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_, _), do: nil
end
