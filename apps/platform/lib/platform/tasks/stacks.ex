defmodule Platform.Tasks.Stacks do
  @moduledoc """
  Persistent context for the Task Stacks domain (ADR 0041).

  Task stacks group co-related tasks that ship together as a single rollup PR.
  Members of a stack reuse the existing `tasks.dependencies` machinery to
  govern in-stack execution order, so members with no inter-dependency can
  be implemented in parallel.

  This module exposes the lifecycle surface for stacks themselves; member
  attachment, DAG validation, dispatch helpers, and rollup-status
  recomputation land in subsequent T2 stages.
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, ReviewRequests, Stack, StackDeployer, Task}
  alias Platform.Tasks.{Stage, Validation}
  alias Platform.Tasks.Stacks.{CommencementGate, DepInference}

  @slug_regex ~r/^[a-z0-9][a-z0-9-]*$/
  @max_slug_length 60

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new stack.

  Validates via `Stack.changeset/2`. Caller is responsible for supplying a
  `rollup_branch` consistent with `rollup_branch_name/1` (typically the
  stack's slug); future stages may auto-derive it.
  """
  @spec create_stack(map()) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def create_stack(attrs) when is_map(attrs) do
    %Stack{}
    |> Stack.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a stack by id. Returns the struct or nil."
  @spec get_stack(binary()) :: Stack.t() | nil
  def get_stack(id) when is_binary(id), do: Repo.get(Stack, id)

  @doc "Fetch a stack by id, raising `Ecto.NoResultsError` if absent."
  @spec get_stack!(binary()) :: Stack.t()
  def get_stack!(id) when is_binary(id), do: Repo.get!(Stack, id)

  @doc """
  Look up a non-abandoned stack by its rollup-branch name.

  Used by the GitHub webhook controller (T6) to detect whether a merged
  PR's head branch corresponds to a stack rollup branch, so the
  `pr_merged` validation can be fanned out across all member tasks.
  Abandoned stacks are excluded; if a stale stack/<slug> branch survives
  in the repo, its webhook should fall through to the no-op path rather
  than re-pass member validations.

  Returns the `%Stack{}` or `nil`. `nil` for any non-binary input so
  callers don't have to pre-filter `head_branch == nil`.
  """
  @spec get_stack_by_rollup_branch(String.t() | nil) :: Stack.t() | nil
  def get_stack_by_rollup_branch(rollup_branch) when is_binary(rollup_branch) do
    Stack
    |> where([s], s.rollup_branch == ^rollup_branch and s.status != "abandoned")
    |> limit(1)
    |> Repo.one()
  end

  def get_stack_by_rollup_branch(_), do: nil

  @doc """
  List stacks, optionally filtered by `:project_id`, `:status`, and/or
  `:sponsor_user_id`.

  Results are ordered by `inserted_at` descending so the most recent stacks
  come first. The `:sponsor` association is preloaded so LiveView / MCP
  callers don't lazy-load per card (ADR 0042 Decision 8).
  """
  @spec list_stacks(map()) :: [Stack.t()]
  def list_stacks(filters \\ %{}) when is_map(filters) do
    Stack
    |> filter_by_project(Map.get(filters, :project_id))
    |> filter_by_status(Map.get(filters, :status))
    |> filter_by_sponsor(Map.get(filters, :sponsor_user_id))
    |> order_by([s], desc: s.inserted_at)
    |> preload(:sponsor)
    |> Repo.all()
  end

  defp filter_by_project(query, nil), do: query

  defp filter_by_project(query, project_id) when is_binary(project_id) do
    where(query, [s], s.project_id == ^project_id)
  end

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) when is_binary(status) do
    where(query, [s], s.status == ^status)
  end

  # `:sponsor_user_id` filter mirrors the tasks-side sponsor pill (ADR 0042):
  # nil is passthrough (unfiltered), a binary UUID narrows to only stacks
  # whose sponsor_user_id equals the given id. NULL rows (unsponsored
  # stacks) are excluded by the equality — nil never equals a user id, so
  # the "sponsored by me" toggle correctly hides unsponsored work.
  defp filter_by_sponsor(query, nil), do: query

  defp filter_by_sponsor(query, sponsor_user_id) when is_binary(sponsor_user_id) do
    where(query, [s], s.sponsor_user_id == ^sponsor_user_id)
  end

  @doc "Update a stack via `Stack.changeset/2`."
  @spec update_stack(Stack.t(), map()) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def update_stack(%Stack{} = stack, attrs) when is_map(attrs) do
    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Terminal transition for the rollup-PR merge path (T6 stage 2).

  Marks `stack` as `done` and records the rollup-merge summary into
  `stack.metadata["rollup_merge"]`. Existing metadata keys are
  preserved (deep merge at the top level; the `rollup_merge` subtree
  is replaced wholesale because each rollup-PR merge produces a single
  canonical summary).

  Expected `attrs` shape:

      %{
        passed_member_ids: [task_id, ...],
        anomalies: [%{"task_id" => id, "reason" => "...", "recorded_at" => iso8601}, ...],
        merge_commit_sha: sha,
        merged_at: %DateTime{} | iso8601_string
      }

  When `passed_member_ids` is empty (every member was an anomaly), the
  resulting `metadata["rollup_merge"]["degraded"]` flag is set to
  `true` and the caller is expected to emit an ERROR log alongside.
  The stack still transitions to `done` so the rollup-PR's deploy
  surface accurately reflects what happened on GitHub; the degraded
  flag signals that no member validations were actually flipped here
  and operator triage is warranted.

  Idempotency: a stack already at `done` with `metadata["rollup_merge"]`
  populated is left untouched; the function returns `{:ok, stack}`
  with the existing metadata so a replayed webhook does NOT clobber
  the original history.
  """
  @spec complete_rollup_merge(Stack.t(), %{
          optional(:passed_member_ids) => [String.t()],
          optional(:anomalies) => [map()],
          optional(:merge_commit_sha) => String.t() | nil,
          optional(:merged_at) => DateTime.t() | String.t() | nil
        }) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def complete_rollup_merge(%Stack{} = stack, attrs) when is_map(attrs) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    if stack.status == "done" and Map.has_key?(base_meta, "rollup_merge") do
      {:ok, stack}
    else
      passed = Map.get(attrs, :passed_member_ids, [])
      anomalies = Map.get(attrs, :anomalies, [])
      sha = Map.get(attrs, :merge_commit_sha)
      merged_at = format_merged_at(Map.get(attrs, :merged_at))

      rollup_merge =
        %{
          "merged_at" => merged_at,
          "merge_commit_sha" => sha,
          "members_passed" => passed,
          "anomalies" => anomalies
        }
        |> maybe_set_degraded(passed)

      new_meta = Map.put(base_meta, "rollup_merge", rollup_merge)

      stack
      |> Stack.changeset(%{status: "done", metadata: new_meta})
      |> Repo.update()
    end
  end

  defp maybe_set_degraded(rollup_merge, []), do: Map.put(rollup_merge, "degraded", true)
  defp maybe_set_degraded(rollup_merge, _passed), do: rollup_merge

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(str) when is_binary(str), do: str
  defp format_merged_at(_), do: nil

  @doc """
  Status cascade for `stack_start`: transition a `forming` stack to
  `in_progress` and fan its members out per ADR 0041 §"Status cascade —
  entering a stack".

  Behavior:

    * Stack must be at `forming` to start — any other status returns
      `{:error, :invalid_stack_status}`.
    * Compute `executable_members/1` (level-0 roots in the in-stack DAG).
    * Transition every root currently at `backlog` to `in_progress` via
      `Tasks.transition_task/2`. Roots already past `backlog` are left
      alone — the cascade is additive, not destructive.
    * Transition every non-root member currently at `backlog` to
      `stack_pending` via `Tasks.transition_task/2`. Same backlog-only
      filter so we never overwrite committed work.
    * Flip the stack-level status from `forming` to `in_progress`.

  Returns `{:ok, %{stack: stack, started: roots, parked: pending}}` on
  success. Per-member transition failures (e.g. a root with no
  approved plan) are surfaced in the returned shape as
  `{:partial, %{stack: stack, started: ok_roots, parked: ok_pending,
  errors: errors}}` so the caller can choose to halt-and-fix or
  proceed.

  ADR 0042 Decision 4: refuses upfront with
  `{:error, :stack_plans_pending, %{stack_id, waiting_on}}` when any
  member is still missing an approved plan. The stack status is NOT
  flipped and NO members are cascaded — partial cascades while plans
  are still landing would leave the stack in an inconsistent half-open
  state.
  """
  @spec start_stack(Stack.t() | binary()) ::
          {:ok, %{stack: Stack.t(), started: [Task.t()], parked: [Task.t()]}}
          | {:partial,
             %{
               stack: Stack.t(),
               started: [Task.t()],
               parked: [Task.t()],
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:error, :invalid_stack_status | :stack_not_found | term()}
          | {:error, :stack_plans_pending, %{stack_id: String.t(), waiting_on: [String.t()]}}
  def start_stack(%Stack{status: status}) when status != "forming",
    do: {:error, :invalid_stack_status}

  def start_stack(%Stack{} = stack) do
    # ADR 0042 Decision 4: the commencement gate short-circuits the cascade
    # entirely when any member is still missing an approved plan. We check
    # BEFORE mutating anything so the stack is left untouched — a partial
    # cascade over a mostly-ready stack would leak `stack_pending` /
    # `in_progress` members from a stack that never actually opened.
    if CommencementGate.plans_ready?(stack) do
      do_start_stack(stack)
    else
      {:error, :stack_plans_pending,
       %{stack_id: stack.id, waiting_on: CommencementGate.waiting_on(stack.id)}}
    end
  end

  defp do_start_stack(%Stack{} = stack) do
    # ADR 0042 Decision 4: flip the stack to `in_progress` BEFORE cascading
    # members. The commencement gate (`CommencementGate.open?/1`) enforced
    # inside `transition_task_status/2` reads `stack.status` and refuses
    # unless it's `in_progress`, so the stack must be opened first for the
    # cascade's `member → in_progress` transitions to pass the guard.
    # Previously the stack was flipped after the cascade, but the existing
    # `:partial` semantics already flip the stack even when cascade errors
    # surface, so the observable invariant is unchanged.
    case Stack.changeset(stack, %{status: "in_progress"}) |> Repo.update() do
      {:ok, updated} ->
        # Stage 1 of T5: kick off rollup-branch creation as soon as the
        # stack flips into `in_progress`. The deployer runs async so
        # the cascade returns quickly, and any failure is logged via
        # `Logger.warning` rather than crashing the cascade. We invoke
        # via Stacks for testability — handle_stack_transition is the
        # public seam and is itself a no-op when `from`/`to` don't
        # match.
        _ = StackDeployer.handle_stack_transition(updated, :forming, :in_progress)

        members = members(updated)
        roots = executable_members(updated)
        root_ids = MapSet.new(roots, & &1.id)

        {started, root_errors} =
          Enum.reduce(roots, {[], []}, fn member, {ok, errors} ->
            cascade_member(member, "in_progress", ok, errors)
          end)

        non_roots = Enum.reject(members, &MapSet.member?(root_ids, &1.id))

        {parked, pending_errors} =
          Enum.reduce(non_roots, {[], []}, fn member, {ok, errors} ->
            cascade_member(member, "stack_pending", ok, errors)
          end)

        result = %{
          stack: updated,
          started: Enum.reverse(started),
          parked: Enum.reverse(parked)
        }

        case root_errors ++ pending_errors do
          [] -> {:ok, result}
          errors -> {:partial, Map.put(result, :errors, Enum.reverse(errors))}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def start_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_stack(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # ADR 0041 Status cascade — entering a stack.
  #
  # Members at `backlog` are dragged forward to whatever target the
  # caller passes — `in_progress` (roots via `start_stack/1`),
  # `stack_pending` (non-roots via `start_stack/1`), or `planning`
  # (wave-gated dispatch via `start_planning/1`).
  #
  # Additionally, roots targeted at `in_progress` accept `stack_pending`
  # as a valid source status: `stack_pending` roots arrive there when
  # `task_create` side effects or an operator `task_update` already
  # flipped the member out of `backlog` before `start_stack/1` ran, and
  # the state machine allows `stack_pending → in_progress` (see
  # `Tasks.@allowed_transitions`). Without this second clause the
  # cascade would leave those roots stranded — silently swallowing the
  # router dispatch downstream (incident 019f5e29). The transitioned
  # roots are folded into `started:` alongside the `backlog → in_progress`
  # promotions so operators see what actually happened.
  #
  # Anything else — a member already past the target (`planning`,
  # `in_progress`, `in_review`, …) or a non-root already at
  # `stack_pending` — is left alone: no cascade write, no reported
  # transition. The wildcard clause is idempotent by design.
  defp cascade_member(%Task{status: "backlog"} = member, target, ok, errors) do
    do_cascade_member(member, target, ok, errors)
  end

  defp cascade_member(%Task{status: "stack_pending"} = member, "in_progress" = target, ok, errors) do
    do_cascade_member(member, target, ok, errors)
  end

  defp cascade_member(_member, _target, ok, errors), do: {ok, errors}

  defp do_cascade_member(member, target, ok, errors) do
    case Tasks.transition_task(member, target) do
      {:ok, updated} ->
        {[updated | ok], errors}

      {:error, reason} ->
        {ok, [%{task_id: member.id, target_status: target, reason: reason} | errors]}
    end
  end

  @doc """
  Stack-level "Start Planning": drive members into the `planning`
  lifecycle using wave-gated dispatch (ADR 0045 / stack v2).

  Wave-gated dispatch replaces the previous all-at-once cascade. The
  topological DAG built from `tasks.dependencies` (agent-inferred and/or
  user-authored) is split into "waves" — level 0 is the roots (no
  in-stack deps), level N contains members whose in-stack deps all land
  in waves 0..N-1. See `planning_waves/1` for the level structure.

  The mode key on the parent stack governs how many waves fan out per
  call:

    * `stack.auto_plan == false` (default): dispatch **wave 0 only**.
      Downstream waves advance when their upstream members' plans clear
      review — either the operator approves via `Tasks.approve_plan/3`,
      which fires `maybe_advance_stack_planning/1` and re-enters this
      module through `advance_planning_waves/1`, or an integrator calls
      `advance_planning_waves/1` directly.
    * `stack.auto_plan == true`: **every** wave fans out in a single
      pass. Each wave still emits its own `:wave_dispatched` telemetry
      event (`wave_index: 0..N-1`, in order), so downstream observers
      see the same event contract as manual mode — just N events in one
      call instead of one now plus N-1 later. Plans still submit
      individually; `auto_accept_plan` (below, resolved by
      `Tasks.maybe_auto_approve/1`) is the flag that also auto-approves
      each plan on submit.

  ## Composition with the dep-inference planner

  Before wave computation, `start_planning/1` calls the same
  `DepInference.infer_edges/2` + persist path that member 1 landed
  (see below). Inferred edges land through `add_dependency_edge/4`, so
  they inherit the DAG validation, cross-stack guard, and rollback
  semantics of any hand-authored edge. Idempotent: if any member
  already carries an in-stack `dependencies` entry, inference is skipped
  entirely to respect the override and avoid duplicate LLM spend.

  ## Idempotency guard

  If **any** member is past `backlog` (planning, stack_pending,
  in_progress, in_review, deploying, done, or blocked), planning has
  already been kicked off for this stack. The function returns
  `{:noop, :already_in_flight}` **without** re-running dep inference or
  telemetry so a double-click on the UI action doesn't produce a
  duplicate `dep_inference` event. A `Logger.info` line records the
  short-circuit.

  ## Cycle / cross-stack guard

  If `planning_waves/1` returns `{:error, :cycle, path}` or
  `{:error, :cross_stack_dep, payload}`, the error is passed through
  unchanged and NO members transition. Wave-gated dispatch is
  meaningless on an invalid DAG; the caller decides how to surface it.

  ## Dep-inference behaviour

    * `try_infer_with_retry/2` calls `DepInference.infer_edges/2` and
      retries once on `{:error, :parse_failed}` or `{:error,
      :adapter_failed}`; up to 2 adapter calls per attempt.
    * Returned edges are written sequentially through
      `add_dependency_edge/4`. If any write returns `{:error, :cycle, _}`
      the already-committed inference edges are reverted via
      `remove_dependency_edge/4` and inference is retried ONCE. A second
      cycle logs a `[Stacks.start_planning]` warning and falls through to
      the cascade with `edges_authored: 0, edges_skipped_reason: :cycle`.
    * Terminal `:parse_failed` / `:adapter_failed` after retry logs a
      warning, sets `edges_authored: 0`, `edges_skipped_reason: reason`,
      and lets the cascade run.

  ## Telemetry

    * `[:platform, :stacks, :dep_inference, :computed | :failed]` —
      emitted after the dep-inference stage (unchanged from member 1).
    * `[:platform, :stacks, :planning, :started]` — emitted exactly
      **once** per dispatching invocation, immediately after the DAG is
      validated and before any wave fans out.
      Measurements: `%{member_count}` (total stack members).
      Metadata: `%{stack_id, mode: :manual | :auto, waves_total}`.
      Skipped on the `:already_in_flight`, `:cycle`, and
      `:cross_stack_dep` short-circuits — those fire `:noop` instead.
    * `[:platform, :stacks, :planning, :wave_dispatched]` — emitted
      once per wave that this call dispatches.
      Measurements: `%{member_count}` (members promoted in this wave).
      Metadata: `%{stack_id, wave_index}`.
      Manual mode fires it exactly once (wave 0); auto mode fires it N
      times (wave_index 0..N-1) in order.
    * `[:platform, :stacks, :planning, :noop]` — emitted when the entry
      short-circuits without dispatching. Measurements: `%{}`. Metadata:
      `%{stack_id, reason: :already_in_flight | :cycle | :cross_stack_dep}`.
    * `[:platform, :stacks, :planning, :advanced]` — emitted by
      `advance_planning_waves/1` when a wave is promoted from `backlog`
      into `planning`. Measurements: `%{member_count}`. Metadata:
      `%{stack_id, wave_index}`. Sibling of `:wave_dispatched` — the
      latter continues to fire from advance for backwards compatibility;
      `:advanced` lets observers distinguish the initial start from a
      later approval-hook promotion without regex-matching the wave
      index.

  ## Persistence deviation from ADR

  The ADR describes a conceptual `stack_dependencies` shape; the actual
  storage is the JSONB `tasks.dependencies` column already used by the
  broader edge-mutation surface. This module reuses that path and does
  NOT introduce a new table — a future refactor can migrate if needed.

  ## Return shape

    * `{:ok, %{stack, planning, edges_authored, edges_skipped_reason,
       waves_total, mode}}` — success. `planning` is the list of members
      this call transitioned to `planning`. `waves_total` is the total
      number of waves in the stack's DAG (informational; drives the
      progress UI). `mode` is `:manual | :auto`.
    * `{:partial, %{..., errors}}` — cascade partial success; the
      inferred edges are NOT rolled back to match the pre-existing
      partial semantics of the wider cascade family.
    * `{:noop, :already_in_flight}` — idempotency short-circuit.
    * `{:error, :cycle, [Task.t()]}` /
      `{:error, :cross_stack_dep, %{...}}` — invalid DAG; no
      side effects.
    * `{:error, :stack_not_found}` — unknown id.
  """
  @spec start_planning(Stack.t() | binary()) ::
          {:ok,
           %{
             stack: Stack.t(),
             planning: [Task.t()],
             edges_authored: non_neg_integer(),
             edges_skipped_reason: atom() | nil,
             waves_total: non_neg_integer(),
             mode: :manual | :auto
           }}
          | {:partial,
             %{
               stack: Stack.t(),
               planning: [Task.t()],
               edges_authored: non_neg_integer(),
               edges_skipped_reason: atom() | nil,
               waves_total: non_neg_integer(),
               mode: :manual | :auto,
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:noop, :already_in_flight}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found | term()}
  def start_planning(%Stack{} = stack) do
    members = members(stack)

    if any_member_past_backlog?(members) do
      Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: already_in_flight")
      emit_planning_noop_telemetry(stack.id, :already_in_flight)

      {:noop, :already_in_flight}
    else
      do_start_planning(stack, members)
    end
  end

  def start_planning(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_planning(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # ── start_planning inner path ──────────────────────────────────────────
  #
  # Split out of the public head so the idempotency short-circuit avoids
  # (a) firing a duplicate `dep_inference` telemetry event, and (b) a
  # duplicate LLM adapter call.
  defp do_start_planning(%Stack{} = stack, members) do
    start_time = System.monotonic_time(:millisecond)

    # Compose with member 1: the dep-inference planner. `infer_and_persist_edges/2`
    # invokes `DepInference.infer_edges/2` (or no-ops when a user override is
    # already present). The `function_exported?/3` guard is a belt-and-braces
    # against future refactors that might extract this into a peer module —
    # today it's inline, so the call is direct.
    {edges_authored, edges_skipped_reason, retry_count} = infer_and_persist_edges(stack, members)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    emit_dep_inference_telemetry(
      stack,
      edges_authored,
      edges_skipped_reason,
      retry_count,
      duration_ms
    )

    # Re-read members so downstream wave computation sees any freshly-written
    # dep edges. Not strictly required for the cascade math (it only
    # inspects `status`), but keeps the returned struct consistent
    # with the post-inference DB state.
    members_for_cascade = if edges_authored > 0, do: members(stack), else: members

    case planning_waves(stack) do
      {:error, :cycle, _path} = err ->
        Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: cycle")
        emit_planning_noop_telemetry(stack.id, :cycle)
        err

      {:error, :cross_stack_dep, _payload} = err ->
        Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: cross_stack_dep")
        emit_planning_noop_telemetry(stack.id, :cross_stack_dep)
        err

      {:ok, waves} ->
        mode = if stack.auto_plan, do: :auto, else: :manual

        emit_planning_started_telemetry(
          stack.id,
          mode,
          length(waves),
          length(members_for_cascade)
        )

        dispatch_waves(stack, members_for_cascade, waves, edges_authored, edges_skipped_reason)
    end
  end

  # `any_member_past_backlog?/1` — idempotency check. Members at
  # `backlog` are still eligible for wave dispatch; members at
  # `cancelled` are terminal skips and do not block a fresh dispatch.
  # Everything else (planning, stack_pending, in_progress, in_review,
  # deploying, done, blocked) is treated as "planning already kicked off"
  # for this stack.
  defp any_member_past_backlog?(members) do
    Enum.any?(members, fn %Task{status: status} ->
      status not in ["backlog", "cancelled"]
    end)
  end

  # Manual vs auto branch. Wave 0 dispatch in manual; all-at-once in
  # auto (stage 4 stub — this stage preserves the legacy shape so the
  # plan-approval hook can be exercised end-to-end while stage 4 is
  # still pending).
  defp dispatch_waves(%Stack{auto_plan: true} = stack, members, waves, edges_authored, reason) do
    # Auto mode: fan out EVERY wave in a single pass — no gating on plan
    # approval. Downstream planners still receive `parent_plans` context
    # (empty on the first invocation because no upstream plan is approved
    # yet; a subsequent `advance_planning_waves/1` no-ops because every
    # member has already left `backlog`). Emit one
    # `[:platform, :stacks, :planning, :wave_dispatched]` event per wave
    # with `wave_index: 0..N-1` so telemetry consumers see the same
    # contract as manual mode — just N events fired in one call instead
    # of a single wave-0 event followed by later N-1 advance events.
    member_by_id = Map.new(members, &{&1.id, &1})

    {reversed_dispatched, errors} =
      waves
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {wave_members, wave_index}, {ok_acc, err_acc} ->
        {wave_dispatched, wave_errors} =
          Enum.reduce(wave_members, {[], []}, fn wave_member, {ok, errs} ->
            member = Map.get(member_by_id, wave_member.id, wave_member)
            cascade_member(member, "planning", ok, errs)
          end)

        wave_dispatched = Enum.reverse(wave_dispatched)

        :telemetry.execute(
          [:platform, :stacks, :planning, :wave_dispatched],
          %{member_count: length(wave_dispatched)},
          %{stack_id: stack.id, wave_index: wave_index}
        )

        {Enum.reverse(wave_dispatched, ok_acc), wave_errors ++ err_acc}
      end)

    dispatched = Enum.reverse(reversed_dispatched)

    finalize_dispatch(stack, dispatched, errors, waves, edges_authored, reason, :auto)
  end

  defp dispatch_waves(%Stack{} = stack, members, waves, edges_authored, reason) do
    # Manual mode: dispatch ONLY wave 0. Downstream waves advance via
    # `advance_planning_waves/1` when each upstream member's plan lands
    # `approved` (see `Tasks.approve_plan/3` → `maybe_advance_stack_planning/1`).
    member_by_id = Map.new(members, &{&1.id, &1})
    wave0 = List.first(waves) || []

    {dispatched, errors} =
      Enum.reduce(wave0, {[], []}, fn wave_member, {ok, errs} ->
        # `waves` was built against the freshly-read DAG, but member
        # structs it holds carry statuses as of the DAG query. Prefer the
        # `members` list we just read for cascade decisions so the
        # `backlog` guard reflects the current DB state.
        member = Map.get(member_by_id, wave_member.id, wave_member)
        cascade_member(member, "planning", ok, errs)
      end)

    dispatched = Enum.reverse(dispatched)

    :telemetry.execute(
      [:platform, :stacks, :planning, :wave_dispatched],
      %{member_count: length(dispatched)},
      %{stack_id: stack.id, wave_index: 0}
    )

    finalize_dispatch(stack, dispatched, errors, waves, edges_authored, reason, :manual)
  end

  defp finalize_dispatch(stack, dispatched, errors, waves, edges_authored, reason, mode) do
    result = %{
      stack: stack,
      planning: dispatched,
      edges_authored: edges_authored,
      edges_skipped_reason: reason,
      waves_total: length(waves),
      mode: mode
    }

    case errors do
      [] -> {:ok, result}
      errs -> {:partial, Map.put(result, :errors, Enum.reverse(errs))}
    end
  end

  @doc """
  Advance a manual-mode stack's planning cascade one wave at a time.

  Called from `Tasks.approve_plan/3` post-commit (see
  `maybe_advance_stack_planning/1`) so approving the last member of the
  highest currently-approved wave immediately dispatches the next
  wave's members into `planning`. Safe to call from operator tools,
  cron sweeps, or manual iex sessions — the function is fully idempotent.

  ## Algorithm

    1. Compute `planning_waves/1`. Pass through cycle / cross-stack-dep
       errors unchanged; on `:stack_not_found` return the tuple.
    2. Find the highest wave N where **every** member has an
       `approved`/`completed` plan (via `Tasks.current_plan/1`).
    3. If wave N+1 exists AND any of its members is still at `backlog`,
       transition those members `backlog → planning` via `cascade_member/4`
       and emit `[:platform, :stacks, :planning, :wave_dispatched]` with
       `wave_index: N+1`.
    4. Return `{:ok, %{stack, dispatched, wave_index}}` when a wave
       advanced or `{:ok, :noop, reason}` when nothing changed.

  ## No-op reasons

    * `:no_next_wave` — the highest fully-approved wave IS the last
      wave (or the stack is empty).
    * `:next_wave_already_dispatched` — wave N+1 exists but every
      member is already past `backlog`.
    * `:upstream_incomplete` — wave 0 (or wave N) is not yet fully
      approved; the caller re-enters when the next approval lands.
  """
  @spec advance_planning_waves(Stack.t() | binary()) ::
          {:ok,
           %{
             stack: Stack.t(),
             dispatched: [Task.t()],
             wave_index: non_neg_integer()
           }}
          | {:ok, :noop, :no_next_wave | :next_wave_already_dispatched | :upstream_incomplete}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found}
  def advance_planning_waves(%Stack{} = stack) do
    case planning_waves(stack) do
      {:error, _reason, _detail} = err ->
        err

      {:ok, []} ->
        {:ok, :noop, :no_next_wave}

      {:ok, waves} ->
        approved_wave_indices =
          waves
          |> Enum.with_index()
          |> Enum.filter(fn {wave, _idx} -> wave_fully_approved?(wave) end)
          |> Enum.map(fn {_wave, idx} -> idx end)

        highest_approved = List.last(approved_wave_indices)

        next_index =
          case highest_approved do
            nil -> if wave_fully_approved?(List.first(waves)), do: 1, else: 0
            n -> n + 1
          end

        cond do
          highest_approved == nil and next_index == 0 ->
            # Wave 0 not yet fully approved — nothing to advance.
            {:ok, :noop, :upstream_incomplete}

          next_index >= length(waves) ->
            {:ok, :noop, :no_next_wave}

          true ->
            advance_specific_wave(stack, Enum.at(waves, next_index), next_index)
        end
    end
  end

  def advance_planning_waves(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> advance_planning_waves(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  defp advance_specific_wave(stack, wave_members, wave_index) do
    # Re-read the wave members so `cascade_member/4`'s `backlog` guard
    # sees the current DB state — the `planning_waves/1` result may be
    # a few tens of ms stale by the time this fires from a post-commit
    # hook.
    fresh_members =
      Enum.map(wave_members, fn %Task{id: id} ->
        Repo.get(Task, id) || %Task{id: id, status: "unknown"}
      end)

    if Enum.all?(fresh_members, &(&1.status != "backlog")) do
      {:ok, :noop, :next_wave_already_dispatched}
    else
      {dispatched, _errs} =
        Enum.reduce(fresh_members, {[], []}, fn member, {ok, errs} ->
          cascade_member(member, "planning", ok, errs)
        end)

      dispatched = Enum.reverse(dispatched)

      :telemetry.execute(
        [:platform, :stacks, :planning, :wave_dispatched],
        %{member_count: length(dispatched)},
        %{stack_id: stack.id, wave_index: wave_index}
      )

      # Stack v2 stage 6: distinguish advance-driven promotions from the
      # initial start_planning dispatch. Both fire :wave_dispatched
      # (backwards-compatible); only advance_planning_waves fires
      # :advanced. Downstream observers that need to count "how many
      # promotions happened after the initial start" attach to
      # :advanced without regex-parsing wave indices.
      :telemetry.execute(
        [:platform, :stacks, :planning, :advanced],
        %{member_count: length(dispatched)},
        %{stack_id: stack.id, wave_index: wave_index}
      )

      {:ok, %{stack: stack, dispatched: dispatched, wave_index: wave_index}}
    end
  end

  # A wave is "fully approved" when every member's `current_plan/1`
  # returns an approved/completed plan.
  defp wave_fully_approved?([]), do: true

  defp wave_fully_approved?(members) do
    Enum.all?(members, fn %Task{id: id} ->
      not is_nil(Tasks.current_plan(id))
    end)
  end

  # ── Dep inference helpers ─────────────────────────────────────────────

  # Returns `{edges_authored, edges_skipped_reason, retry_count}`.
  #   * `{n, nil, r}` — inference ran, n edges committed, r retries used
  #   * `{0, :user_override_present, 0}` — pre-existing in-stack edge, skipped
  #   * `{0, :cycle | :parse_failed | :adapter_failed | :empty_response, r}`
  #     — inference (and retry) failed terminally; cascade still proceeds.
  defp infer_and_persist_edges(_stack, []), do: {0, nil, 0}

  defp infer_and_persist_edges(%Stack{} = stack, members) do
    if any_in_stack_edge_present?(members, stack.id) do
      {0, :user_override_present, 0}
    else
      attempt_inference(stack, members, 0)
    end
  end

  # `attempt` counter guards the single-shot cycle retry. `0` = first
  # attempt, `1` = retry after cycle. Returns
  # `{edges_authored, reason_or_nil, cumulative_retry_count}`.
  defp attempt_inference(stack, members, attempt) do
    case try_infer_with_retry(stack, members) do
      {:ok, edges, adapter_retries} ->
        case commit_edges(stack, edges) do
          {:ok, count} ->
            {count, nil, adapter_retries + attempt}

          {:error, :cycle} when attempt == 0 ->
            Logger.warning(
              "[Stacks.start_planning] cycle detected in inferred edges (stack #{stack.id}); retrying once"
            )

            attempt_inference(stack, members, 1)

          {:error, :cycle} ->
            Logger.warning(
              "[Stacks.start_planning] cycle detected on retry (stack #{stack.id}); dropping inferred edges"
            )

            {0, :cycle, adapter_retries + attempt}
        end

      {:error, reason, adapter_retries} ->
        Logger.warning(
          "[Stacks.start_planning] dep inference terminal failure (stack #{stack.id}, reason=#{reason})"
        )

        {0, reason, adapter_retries + attempt}
    end
  end

  # `DepInference.infer_edges/2` plus a single retry on parse/adapter
  # failure. Empty-response and terminal errors bubble up as-is.
  # Returns `{:ok, edges, retries}` / `{:error, reason, retries}` where
  # `retries` is 0 when the first call succeeded / bubbled, 1 when a
  # single retry fired.
  defp try_infer_with_retry(stack, members) do
    case DepInference.infer_edges(stack, members) do
      {:ok, edges} ->
        {:ok, edges, 0}

      {:error, reason} when reason in [:parse_failed, :adapter_failed] ->
        case DepInference.infer_edges(stack, members) do
          {:ok, edges} -> {:ok, edges, 1}
          {:error, reason2} -> {:error, reason2, 1}
        end

      {:error, reason} ->
        {:error, reason, 0}
    end
  end

  # Sequentially write edges via `add_dependency_edge/4`. On the first
  # `{:error, :cycle, _}`, revert already-committed inference edges via
  # `remove_dependency_edge/4` and return `{:error, :cycle}` so the
  # caller can retry inference. Non-cycle write errors (duplicate edge,
  # cross-stack dep, etc.) are logged and skipped — the caller's edge
  # count reflects only what actually landed.
  defp commit_edges(stack, edges) do
    Enum.reduce_while(edges, {:ok, 0, []}, fn edge, {:ok, count, committed} ->
      case add_dependency_edge(stack, edge.from_task_id, edge.to_task_id) do
        {:ok, _} ->
          {:cont, {:ok, count + 1, [edge | committed]}}

        {:error, :cycle, _path} ->
          revert_edges(stack, committed)
          {:halt, {:error, :cycle}}

        {:error, other} ->
          Logger.warning(
            "[Stacks.start_planning] skipping inferred edge #{edge.from_task_id}->#{edge.to_task_id}: #{inspect(other)}"
          )

          {:cont, {:ok, count, committed}}

        {:error, other, _payload} ->
          Logger.warning(
            "[Stacks.start_planning] skipping inferred edge #{edge.from_task_id}->#{edge.to_task_id}: #{inspect(other)}"
          )

          {:cont, {:ok, count, committed}}
      end
    end)
    |> case do
      {:ok, count, _committed} -> {:ok, count}
      {:error, :cycle} -> {:error, :cycle}
    end
  end

  defp revert_edges(stack, edges) do
    Enum.each(edges, fn edge ->
      _ = remove_dependency_edge(stack, edge.from_task_id, edge.to_task_id)
    end)
  end

  # Fire dep-inference telemetry after the inference/persist stage
  # finishes. Downstream aggregation (Prometheus, LiveDashboard) can
  # subscribe to `[:platform, :stacks, *]` globs; we deliberately do NOT
  # attach a handler here — telemetry is fire-and-forget at emit time.
  #
  # Two events:
  #   * `:computed` — inference ran (successfully OR was skipped due to
  #     a pre-existing user override). Measurements include `edges_count`
  #     and `duration_ms`; metadata carries `source` = `:agent` for a
  #     real inference call, `:user_override_skip` for the idempotency
  #     short-circuit.
  #   * `:failed` — terminal failure after any retry: :cycle,
  #     :parse_failed, :adapter_failed, :empty_response. Measurements
  #     carry `duration_ms`; metadata carries the terminal `reason`.
  defp emit_dep_inference_telemetry(stack, edges_authored, reason, retry_count, duration_ms) do
    case reason do
      nil ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :computed],
          %{edges_count: edges_authored, duration_ms: duration_ms},
          %{stack_id: stack.id, retry_count: retry_count, source: :agent}
        )

      :user_override_present ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :computed],
          %{edges_count: 0, duration_ms: duration_ms},
          %{stack_id: stack.id, retry_count: 0, source: :user_override_skip}
        )

      terminal ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :failed],
          %{duration_ms: duration_ms},
          %{stack_id: stack.id, reason: terminal, retry_count: retry_count}
        )
    end
  end

  # Stack v2 stage 6 — planning-lifecycle telemetry helpers.
  #
  # `:started` fires exactly once per dispatching `start_planning/1`
  # call, immediately after DAG validation and before the first wave
  # fans out. `member_count` is the total member count (all-mode); a
  # per-wave count still lives on `:wave_dispatched`.
  defp emit_planning_started_telemetry(stack_id, mode, waves_total, member_count) do
    :telemetry.execute(
      [:platform, :stacks, :planning, :started],
      %{member_count: member_count},
      %{stack_id: stack_id, mode: mode, waves_total: waves_total}
    )
  end

  # `:noop` fires when `start_planning/1` short-circuits without
  # dispatching a wave — the idempotency guard (`:already_in_flight`),
  # or the cycle / cross-stack DAG guards.
  defp emit_planning_noop_telemetry(stack_id, reason) do
    :telemetry.execute(
      [:platform, :stacks, :planning, :noop],
      %{},
      %{stack_id: stack_id, reason: reason}
    )
  end

  # Returns true if any member already has a `dependencies` entry whose
  # `task_id` is another same-stack member's id — the signal that
  # something (user, prior invocation) has already authored an in-stack
  # edge and inference should be skipped for idempotency.
  @spec any_in_stack_edge_present?([Task.t()], binary()) :: boolean()
  defp any_in_stack_edge_present?(members, _stack_id) do
    member_ids = MapSet.new(members, & &1.id)

    Enum.any?(members, fn %Task{id: id, dependencies: deps} ->
      deps
      |> List.wrap()
      |> Enum.any?(fn
        %{"task_id" => task_id} when is_binary(task_id) ->
          task_id != id and MapSet.member?(member_ids, task_id)

        _ ->
          false
      end)
    end)
  end

  @doc """
  Terminal transition: mark a stack `abandoned` and record the reason.

  Per ADR 0041 (Lifecycle / Rollback / abandon), the per-member handling on
  abandon is non-trivial: members already merged into the rollup retain
  their status with `stack_id` cleared, while unmerged members return to
  `backlog`. That logic depends on the membership/eject helpers landing in
  stage 2 of this task; for now this function only flips the stack-level
  status and stamps the reason into `description`.
  """
  @spec abandon_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def abandon_stack(%Stack{} = stack, reason \\ nil) do
    # TODO(stage 2): per-member handling — clear stack_id on every member;
    # leave already-merged members at their current status, return unmerged
    # members to backlog. Requires `eject_task/2` from the membership stage.
    attrs = %{status: "abandoned", description: abandon_description(stack, reason)}

    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  defp abandon_description(%Stack{description: existing}, nil), do: existing

  defp abandon_description(%Stack{description: nil}, reason) when is_binary(reason),
    do: "Abandoned: #{reason}"

  defp abandon_description(%Stack{description: existing}, reason) when is_binary(reason),
    do: "#{existing}\n\nAbandoned: #{reason}"

  @doc """
  Terminal transition: mark a stack `done`.

  Only allowed when every member task is already `done`. The natural close
  for a stack whose work has fully shipped — including the manual-ship lane
  where members merged via individual PRs rather than the rollup branch,
  which `recompute_stack_status/1` doesn't recognize as completion.

  Returns `{:error, :members_not_done, %{pending: [%{id, title, status}]}}`
  when any member is still in flight. Returns `{:error, changeset}` on a
  schema-level write failure. Returns `{:ok, stack}` on success.
  """
  @spec complete_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()}
          | {:error, :members_not_done, %{pending: [map()]}}
          | {:error, Ecto.Changeset.t()}
  def complete_stack(%Stack{} = stack, note \\ nil) do
    case pending_members(stack.id) do
      [] ->
        attrs = %{status: "done", description: complete_description(stack, note)}

        stack
        |> Stack.changeset(attrs)
        |> Repo.update()

      [_ | _] = pending ->
        {:error, :members_not_done, %{pending: pending}}
    end
  end

  defp pending_members(stack_id) do
    Task
    |> where([t], t.stack_id == ^stack_id and t.status != "done")
    |> select([t], %{id: t.id, title: t.title, status: t.status})
    |> Repo.all()
  end

  defp complete_description(%Stack{description: existing}, nil), do: existing

  defp complete_description(%Stack{description: nil}, note) when is_binary(note),
    do: "Completed: #{note}"

  defp complete_description(%Stack{description: existing}, note) when is_binary(note),
    do: "#{existing}\n\nCompleted: #{note}"

  # ── Membership ───────────────────────────────────────────────────────────

  @doc """
  Attach a task to a stack as a new member.

  Loads the stack and task fresh inside a transaction. Rejects with
  `{:error, :already_in_stack}` if the task is already attached to any
  stack. Computes the next `stack_position` as `max(existing) + 1`
  (starting at 1) and writes via `Platform.Tasks.update_task/2` so the
  existing changeset + broadcast pipeline runs.

  After the write, runs `validate_dag/1` against the augmented member
  set; on `:cycle` or `:cross_stack_dep` the transaction is rolled back
  and the error tuple is returned unchanged. On success, calls
  `recompute_stack_status/1` and returns `{:ok, task}`.

  ## Stack-level assignment inheritance (ADR 0041)

  If the stack has a stack-level `phase_assignees` map AND the joining
  task is NOT individually overridden (`task.metadata["assignee_override"]`
  is not `true`), the stack default is applied to the new member via
  `Platform.Tasks.set_phase_assignees/2` inside this transaction (after
  the `stack_id` write, before `recompute_stack_status/1`). A task that
  carries its own `assignee_override` flag keeps its own assignment.
  """
  @spec add_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :already_in_stack | :stack_not_found | :task_not_found | term()}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  def add_task(stack_or_id, task_or_id) do
    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             {:ok, %Task{} = task} <- load_task(task_or_id),
             :ok <- ensure_not_in_stack(task),
             position = next_stack_position(stack.id),
             {:ok, attached_task} <-
               Tasks.update_task(task, %{stack_id: stack.id, stack_position: position}),
             {:ok, updated_task} <- maybe_inherit_stack_assignees(stack, attached_task),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          updated_task
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # `validate_dag/1`'s richer 3-tuple errors are stuffed into a
    # 2-tuple shape on the way into `Repo.rollback/1` so the `with`
    # chain stays uniform; unpack them here so callers see the
    # original `{:error, :cycle, path}` / `{:error, :cross_stack_dep,
    # payload}` shape without wrapping.
    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      other -> other
    end
  end

  # Bridge `validate_dag/1`'s 3-tuple errors into the `with` chain's
  # 2-tuple convention so they roll back the transaction. Unwrapped
  # back into the original 3-tuple after `Repo.transaction/1` returns.
  defp normalize_dag_result({:ok, levels}), do: {:ok, levels}
  defp normalize_dag_result({:error, :cycle, path}), do: {:error, {:cycle, path}}

  defp normalize_dag_result({:error, :cross_stack_dep, payload}),
    do: {:error, {:cross_stack_dep, payload}}

  @doc """
  Detach a task from its stack.

  Returns `{:error, :not_in_stack}` when the task's `stack_id` does not
  match the supplied stack. Before clearing, computes which other
  members of the stack depend on this task (in-stack edges only) and
  refuses with `{:error, {:has_dependents, [%{id, title}]}}` if any
  exist.

  On a clean eject, clears `stack_id` and `stack_position` via
  `Platform.Tasks.update_task/2`. Per ADR 0041, the member's
  `status` is intentionally left as-is — the caller (or the stack-level
  abandon flow) decides whether to drop it back to backlog. After the
  write, calls `recompute_stack_status/1` and returns `{:ok, task}`.
  """
  @spec eject_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error,
             :not_in_stack
             | :stack_not_found
             | :task_not_found
             | {:has_dependents, [%{id: String.t(), title: String.t()}]}
             | term()}
  def eject_task(stack_or_id, task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_in_stack(stack, task),
           :ok <- ensure_no_in_stack_dependents(stack, task),
           {:ok, updated_task} <-
             Tasks.update_task(task, %{stack_id: nil, stack_position: nil}),
           {:ok, _stack} <- recompute_stack_status(stack) do
        updated_task
      else
        # `eject_task` predates the 3-tuple `:not_in_stack` shape and its
        # callers (incl. existing tests + the `stack_eject` MCP envelope at
        # tool_surface.ex:2776) match on the bare 2-tuple. Collapse here so
        # the new shape stays scoped to the dependency-edge surfaces.
        {:error, :not_in_stack, _task_id} -> Repo.rollback(:not_in_stack)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Add an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors the `add_task/2` shape: loads the stack and both endpoint tasks
  fresh inside a `Repo.transaction`, runs membership/self guards
  up-front, delegates to `Platform.Tasks.add_dependency/3` (stage 1 of
  this skill) for the JSONB read-modify-write, then runs
  `validate_dag/1` against the now-augmented edge set so multi-hop
  cycles get caught and the dep write is rolled back atomically when
  they're found.

  `opts` accepts `:kind` (default `"blocks"`).

  ## Up-front guards

    * `{:error, :stack_not_found}` — the stack id has no row
    * `{:error, :task_not_found}` — either endpoint id has no row
    * `{:error, :self_edge}` — `from_task_id == to_task_id`
    * `{:error, :not_in_stack, offending_task_id}` — one endpoint's
      `stack_id` does not match the supplied stack id (covers both "not
      in any stack" and "member of a different stack" — `validate_dag/1`
      would also flag cross-stack deps, but the explicit membership
      check is a cleaner up-front signal for an explicitly stack-scoped
      tool). The id of the offending endpoint is threaded out so MCP
      callers can render it in error envelopes without a follow-up
      lookup.

  ## Errors bubbled from stage 1 unchanged

    * `{:error, :duplicate_edge}` — the same `(to_task_id, kind)` pair
      already exists on `from_task`
    * `{:error, :self_edge}` — same condition as the up-front guard,
      defensively repeated by `Tasks.add_dependency/3`

  ## Errors from DAG validation (transaction rolled back)

    * `{:error, :cycle, path}` — the new edge introduces a cycle in the
      in-stack subgraph; the dep write is undone before returning.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now}}` on
  success, where `executable_now` is the recomputed
  `executable_members/1` id list so callers don't need a follow-up
  `stack_get` to see the new ready set.
  """
  @spec add_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :duplicate_edge}
          | {:error, :cycle, [Task.t()]}
          | {:error, term()}
  def add_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             {:ok, _updated_from} <- Tasks.add_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} -> Repo.rollback({:not_in_stack, task_id})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      {:error, {:not_in_stack, task_id}} -> {:error, :not_in_stack, task_id}
      other -> other
    end
  end

  @doc """
  Remove an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors `add_dependency_edge/4` — same membership/self guards,
  delegates to `Platform.Tasks.remove_dependency/3` for the JSONB
  read-modify-write, and runs `validate_dag/1` defensively (removal
  cannot create a cycle, but the cheap re-validation keeps the
  recomputed-status path identical to the add side).

  `opts` accepts `:kind` (default `"blocks"`).

  Returns `{:error, :not_an_edge}` when no `(to_task_id, kind)` entry
  exists on `from_task` (so callers can disambiguate an idempotent
  re-remove from a successful one). All other guards match the add
  side.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now}}` on
  success.
  """
  @spec remove_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :not_an_edge}
          | {:error, term()}
  def remove_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             {:ok, _updated_from} <- Tasks.remove_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} -> Repo.rollback({:not_in_stack, task_id})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      {:error, {:not_in_stack, task_id}} -> {:error, :not_in_stack, task_id}
      other -> other
    end
  end

  defp ensure_distinct_endpoints(id, id) when is_binary(id), do: {:error, :self_edge}
  defp ensure_distinct_endpoints(_from, _to), do: :ok

  @doc """
  List the (non-deleted) members of a stack, ordered by `stack_position` asc.
  """
  @spec members(Stack.t() | binary()) :: [Task.t()]
  def members(%Stack{id: stack_id}), do: members(stack_id)

  def members(stack_id) when is_binary(stack_id) do
    Task
    |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
    |> order_by([t], asc: t.stack_position)
    |> Repo.all()
  end

  @doc """
  List all open (pending) review requests across every member of a stack.

  Composes over `members/1` and reuses
  `Platform.Tasks.ReviewRequests.list_pending_for_task/1` so the per-task
  scoping rules (status `"pending"`, items preloaded) stay in one place.
  Resolved requests and tasks not in the stack are excluded by
  construction.

  Returns a flat list of `%ReviewRequest{}` structs ordered by
  `inserted_at` descending (newest first), matching the per-task ordering
  from `list_pending_for_task/1`.
  """
  @spec list_open_review_requests(Stack.t() | binary()) :: [
          Platform.Tasks.ReviewRequest.t()
        ]
  def list_open_review_requests(%Stack{id: stack_id}),
    do: list_open_review_requests(stack_id)

  def list_open_review_requests(stack_id) when is_binary(stack_id) do
    stack_id
    |> members()
    |> Enum.flat_map(&ReviewRequests.list_pending_for_task(&1.id))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Count open (pending) review requests across every member of a stack.

  Convenience wrapper around `list_open_review_requests/1` for callers
  (e.g. the stack-detail chrome pill) that only need a number.
  """
  @spec count_pending_reviews(Stack.t() | binary()) :: non_neg_integer()
  def count_pending_reviews(stack), do: length(list_open_review_requests(stack))

  @doc """
  List stacks with the precomputed board-card display data the kanban view
  needs to render a collapsed stack card and its inline expansion (ADR 0041
  §"UI surface — Board view"; T7 stage 1).

  Returns a list of `{%Stack{}, board_data}` tuples ordered by
  `updated_at` descending. `board_data` is a map with:

    * `:members` — list of member task structs ordered by `stack_position`
      ascending. Each member is a regular `%Task{}` (no extra preloads;
      the existing detail-panel flow handles deep loads).
    * `:member_count` — `length(members)`.
    * `:dep_edge_count` — count of dependency edges among members
      restricted to the in-stack subgraph (deps from a member pointing
      at another member of the same stack). Self-edges are dropped
      defensively.
    * `:ready_count` — members whose status is in `~w(in_review
      deploying done)`, matching ADR 0041's "ready" threshold for the
      `3/4 ready` rollup-progress text.

  Filters mirror `list_stacks/1` (`:project_id`, `:status`,
  `:sponsor_user_id`). Excluded statuses (`abandoned`) are NOT filtered
  here — callers may want to show abandoned stacks for audit; the
  tasks-live board passes through the same project filter the task list
  uses and accepts whatever statuses the backing data carries.

  The `:sponsor` association is preloaded on the stacks query so the
  board can render the sponsor avatar without a follow-up query per
  card. Applying the sponsor filter BEFORE the member fetch means the
  per-stack member fetch is naturally scoped — narrowing to a single
  sponsor also narrows the second-query cost.

  Implementation note: two-query fetch (stacks, then all member tasks
  for those stacks) followed by an in-memory group_by. The kanban
  board typically renders single-digit stack counts per project, so
  N+1 over `members/1` would also be acceptable, but the two-query
  form keeps the page-load cost flat as project size grows.
  """
  @spec list_stacks_with_members(map() | keyword()) :: [{Stack.t(), map()}]
  def list_stacks_with_members(filters \\ %{})

  def list_stacks_with_members(filters) when is_list(filters) do
    list_stacks_with_members(Map.new(filters))
  end

  def list_stacks_with_members(filters) when is_map(filters) do
    stacks =
      Stack
      |> filter_by_project(Map.get(filters, :project_id))
      |> filter_by_status(Map.get(filters, :status))
      |> filter_by_sponsor(Map.get(filters, :sponsor_user_id))
      |> order_by([s], desc: s.updated_at)
      |> preload(:sponsor)
      |> Repo.all()

    case stacks do
      [] ->
        []

      stacks ->
        stack_ids = Enum.map(stacks, & &1.id)

        # `:plans` preload is required by Tasks.needs_human_action_reason/2's
        # `:plan_pending_review` branch (task 019e2c25 stage 4 — mobile
        # stack-member badge). Members are otherwise rendered against the
        # board's `@review_counts` map, but the plan-pending-review check
        # reads `task.plans` directly (predicate returns false when not
        # preloaded rather than triggering a lazy query). Adding the
        # preload here keeps the board view (only caller) consistent with
        # the desktop stack-detail panel, which already preloads `:plans`
        # via `load_stack_member_panel_data/1` in TasksLive.
        members_by_stack =
          Task
          |> where([t], t.stack_id in ^stack_ids and is_nil(t.deleted_at))
          |> order_by([t], asc: t.stack_position)
          |> preload(:plans)
          |> Repo.all()
          |> Enum.group_by(& &1.stack_id)

        Enum.map(stacks, fn stack ->
          members = Map.get(members_by_stack, stack.id, [])
          {stack, build_board_data(members)}
        end)
    end
  end

  # Public-ish (private) helper exposed for tests that want to build the
  # board-data map from a hand-seeded member list without touching the DB.
  @doc false
  def build_board_data(members) when is_list(members) do
    member_ids_set = MapSet.new(members, & &1.id)

    dep_edge_count =
      Enum.reduce(members, 0, fn %Task{id: from_id} = m, acc ->
        in_stack_deps =
          m
          |> Tasks.dependency_task_ids()
          |> Enum.reject(&(&1 == from_id))
          |> Enum.filter(&MapSet.member?(member_ids_set, &1))
          |> Enum.uniq()

        acc + length(in_stack_deps)
      end)

    ready_count = Enum.count(members, &(&1.status in ~w(in_review deploying done)))

    %{
      members: members,
      member_count: length(members),
      dep_edge_count: dep_edge_count,
      ready_count: ready_count
    }
  end

  # ── DAG validation / status recompute ────────────────────────────────────

  @doc """
  Validate the in-stack dependency DAG and return execution levels.

  Loads all current members of the stack, derives the dependency edges
  among them (dropping self-references and cross-stack-to-non-stack
  edges per ADR 0041 §"DAG validation"), then runs Kahn's topological
  sort over the in-stack subgraph.

  Returns:

    * `{:ok, levels}` — `levels` is a list of lists of `%Task{}`. Each
      inner list is a "level" of members runnable in parallel; level 0
      members have no in-stack predecessors, level 1 members depend
      only on level 0, and so on.
    * `{:error, :cycle, path}` — the in-stack subgraph contains a
      dependency cycle. `path` is a best-effort list of `%Task{}` along
      one offending cycle (recovered by walking back-edges through the
      residue Kahn could not drain).
    * `{:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}` —
      member `from` declares a dependency on `to_id`, which itself
      belongs to a different (non-nil) stack. Cross-stack edges are
      rejected at v1 because two stacks must be independently
      shippable.
  """
  @spec validate_dag(Stack.t() | binary()) ::
          {:ok, [[Task.t()]]}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  def validate_dag(%Stack{id: stack_id}), do: validate_dag(stack_id)

  def validate_dag(stack_id) when is_binary(stack_id) do
    members = members(stack_id)

    case build_in_stack_subgraph(members, stack_id) do
      {:ok, edges} ->
        case kahn_levels(members, edges) do
          {:ok, levels} ->
            {:ok, levels}

          {:error, :cycle, residue_ids} ->
            {:error, :cycle, find_cycle(residue_ids, edges, members)}
        end

      {:error, :cross_stack_dep, payload} ->
        {:error, :cross_stack_dep, payload}
    end
  end

  @doc """
  Recompute and persist a stack's rollup status from its members.

  Implements the ADR 0041 §"Status mapping" table:

      done        — all members done
      deploying   — any member deploying, none earlier
      in_review   — all members in_review/deploying/done
      in_progress — any member in_progress
      forming     — any backlog/planning/stack_pending, no member past in_progress

  Stacks already at `abandoned` are terminal and are NEVER auto-recomputed;
  this function returns `{:ok, stack}` for them unchanged. The DB write is
  skipped when the computed status matches the existing status. Members
  whose status falls outside the recognized set are treated conservatively
  as not-yet-past-in_progress.
  """
  @spec recompute_stack_status(Stack.t() | binary()) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | :stack_not_found}
  def recompute_stack_status(%Stack{status: "abandoned"} = stack), do: {:ok, stack}

  def recompute_stack_status(%Stack{} = stack) do
    members = members(stack.id)
    new_status = rollup_status_for(members)

    result =
      if new_status == stack.status do
        {:ok, stack}
      else
        stack
        |> Stack.changeset(%{status: new_status})
        |> Repo.update()
      end

    # Piggy-back: any state change that re-rolls up the stack should also
    # re-attempt the rollup PR open. The deployer's `maybe_open_stack_pr/1`
    # is idempotent — it noops when the rollup PR is already open or when
    # not all members are ready — so calling it on every recompute is safe.
    # Failures here are logged but never propagated; the recompute return
    # value is the source of truth for callers.
    case result do
      {:ok, %Stack{} = updated} -> trigger_pr_open(updated)
      _ -> :ok
    end

    result
  end

  def recompute_stack_status(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> recompute_stack_status(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # Wrap `StackDeployer.maybe_open_stack_pr/1` so a deployer crash or
  # `{:error, _}` return is logged but never propagates back into the
  # recompute return value. The deployer's gate is internally idempotent
  # (`:already_open` / `:not_ready`), so re-firing on every recompute is
  # safe.
  defp trigger_pr_open(%Stack{} = stack) do
    try do
      case StackDeployer.maybe_open_stack_pr(stack) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
              "failed for stack #{stack.id}: #{inspect(reason)}"
          )

          :ok
      end
    rescue
      e ->
        Logger.warning(
          "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
            "raised for stack #{stack.id}: #{Exception.message(e)}"
        )

        :ok
    end
  end

  # Pure rollup of member statuses → stack rollup status. Empty stack
  # stays at `forming` (no members have advanced past `forming` yet).
  defp rollup_status_for([]), do: "forming"

  defp rollup_status_for(members) do
    statuses = Enum.map(members, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == "done")) -> "done"
      Enum.any?(statuses, &(&1 == "deploying")) -> "deploying"
      Enum.all?(statuses, &(&1 in ["in_review", "deploying", "done"])) -> "in_review"
      Enum.any?(statuses, &(&1 == "in_progress")) -> "in_progress"
      true -> "forming"
    end
  end

  # ── Dispatch helpers ─────────────────────────────────────────────────────

  @doc """
  Return the stack members that have no in-stack dependencies — the
  level-0 "roots" of the in-stack DAG.

  Thin wrapper over `validate_dag/1`. If validation fails (cycle or
  cross-stack edge), returns `[]` so callers don't crash on a stack with
  a transient invalid state.
  """
  @spec executable_members(Stack.t() | binary()) :: [Task.t()]
  def executable_members(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, []} -> []
      {:ok, [roots | _]} -> roots
      {:error, _reason, _detail} -> []
    end
  end

  # ── Deploy readiness (Stack v2 stage 2) ────────────────────────────────

  @doc """
  Pure predicate: is the stack ready to deploy as a single rollup PR?

  Distinct from `Platform.Tasks.StackDeployer`'s private
  `all_members_ready?/1`, which additionally requires each member's
  `metadata["merged_into_rollup_at"]` stamp — a downstream signal that
  the member's branch has been merged into the rollup branch. This
  predicate answers the upstream question deploy-side callers actually
  need: has every member finished its validation-set so the stack CAN
  deploy? Keyed on validation-pass counts, not rollup-merge stamps.

  Returns `true` iff ALL of:

    * the stack's own status is not `"deploying"`, `"done"`, or
      `"abandoned"` (short-circuit against double-fire and terminal
      states);
    * `members/1` is non-empty;
    * every member's status is in `["in_review", "deploying"]`;
    * every non-deploy validation on every non-superseded, non-rejected
      plan across every member has `status == "passed"`.

  Deploy-stage validations are excluded via
  `Platform.Tasks.PlanEngine.deploy_stage?/1`. Stack members shouldn't
  ever carry a deploy stage — `Tasks.dispatch_deploy_for_task/1`'s
  atomic-ship guard (stage 1 of this task) blocks the injection — but
  the exclusion is a defensive regression guard against future engine
  changes.

  No writes, no side effects, safe to call from any hot path.
  """
  @spec deploy_ready?(Stack.t() | binary()) :: boolean()
  def deploy_ready?(%Stack{status: status})
      when status in ["deploying", "done", "abandoned"],
      do: false

  def deploy_ready?(%Stack{} = stack) do
    case members(stack) do
      [] -> false
      members -> Enum.all?(members, &member_deploy_ready?/1)
    end
  end

  def deploy_ready?(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> deploy_ready?(stack)
      nil -> false
    end
  end

  @doc """
  Return the members that are NOT ready for deploy — the complement of
  the `deploy_ready?/1` gate (modulo the stack-status guard).

  Used for logging + telemetry attribution when the gate remains closed.
  A member appears in the returned list if its status is outside
  `["in_review", "deploying"]` OR if any of its non-deploy validations
  is still not `"passed"`.

  Relationship: `deploy_ready?/1 == true` implies
  `pending_members_for_deploy/1 |> Enum.empty?()`. The reverse implication
  holds only when the stack's own status is not `"deploying"`, `"done"`,
  or `"abandoned"` — the stack-status guard on `deploy_ready?/1` is not
  reflected here because the "who's pending" surface is orthogonal to
  the stack-level short-circuit.

  Returns `[]` for an unknown stack id (mirrors `deploy_ready?/1`'s
  fail-safe behavior).
  """
  @spec pending_members_for_deploy(Stack.t() | binary()) :: [Task.t()]
  def pending_members_for_deploy(%Stack{} = stack) do
    stack
    |> members()
    |> Enum.reject(&member_deploy_ready?/1)
  end

  def pending_members_for_deploy(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> pending_members_for_deploy(stack)
      nil -> []
    end
  end

  # A member is deploy-ready when both:
  #   * its status signals a completed validation set — `in_review` (the
  #     usual case) or `deploying` (mid-rollup-merge, stamped by the
  #     deployer as it walks members through), AND
  #   * every non-deploy validation on every non-superseded plan across
  #     the member has `status == "passed"`.
  defp member_deploy_ready?(%Task{status: status} = task)
       when status in ["in_review", "deploying"] do
    all_non_deploy_validations_passed?(task)
  end

  defp member_deploy_ready?(_task), do: false

  # Load every stage on every non-superseded, non-rejected plan for the
  # task, drop the deploy stages via `PlanEngine.deploy_stage?/1`, and
  # confirm every remaining validation is `passed`. Superseded/rejected
  # plans are excluded because their stale validations should not gate
  # the current deploy — the "live" plan is what matters.
  #
  # Empty-set case is vacuously `true` (a member with no validations at
  # all can never block deploy — matches `Enum.all?/2` on `[]`).
  defp all_non_deploy_validations_passed?(%Task{id: task_id}) do
    from(s in Stage,
      join: p in Plan,
      on: s.plan_id == p.id,
      where: p.task_id == ^task_id and p.status not in ["superseded", "rejected"],
      preload: [:validations]
    )
    |> Repo.all()
    |> Enum.reject(&PlanEngine.deploy_stage?/1)
    |> Enum.flat_map(& &1.validations)
    |> Enum.all?(&(&1.status == "passed"))
  end

  # ── Deploy dispatch (Stack v2 stage 3) ─────────────────────────────────

  @doc """
  Transition a fully-ready stack to `"deploying"` and fire the rollup-PR
  open trigger asynchronously.

  Called from `PlanEngine.maybe_inject_deploy_or_complete/2`'s stacked-task
  branch every time a stack member's plan completes; the atomicity guard
  in this function turns concurrent double-fires (two members completing
  in the same tick) into exactly one `[:platform, :stacks, :deploy,
  :dispatched]` telemetry event and one state transition. Calls from
  members 1..N-1 short-circuit as `:noop` because `deploy_ready?/1`
  returns `false` while any member remains pending.

  Behavior:

    1. Reloads the stack and checks `deploy_ready?/1`. If `false`,
       returns `{:ok, :noop}` — no side effects.
    2. Stamps `metadata["first_deploy_ready_at"]` set-once-if-nil (a
       previously-stamped value survives across recovery retries).
    3. Performs a **compare-and-swap** on `stacks.status` via
       `Repo.update_all` guarded by `status IN
       ("forming", "in_progress", "in_review")`. Postgres serializes
       concurrent writes on the row and the second query re-reads the
       committed `"deploying"` value → 0 rows updated → loser returns
       `:noop`. Exactly one winner per race.
    4. Emits telemetry `[:platform, :stacks, :deploy, :dispatched]`
       with `%{count: 1}` measurements and metadata
       `%{stack_id, member_count, duration_ms_from_first_member_ready}`.
    5. Async-calls `StackDeployer.maybe_open_stack_pr/1` under the same
       `Task.Supervisor` used by the deployer's other async triggers,
       mirroring `StackDeployer.trigger_maybe_open_stack_pr/1`.

  Returns:

    * `{:ok, :dispatched}` — the stack was transitioned to `"deploying"`
      on this call and the PR-open trigger fired.
    * `{:ok, :noop}` — the stack was not ready OR another concurrent
      caller won the transition race.
    * `{:error, :stack_not_found}` — the stack id doesn't resolve.
  """
  @spec dispatch_stack_deploy(Stack.t() | binary()) ::
          {:ok, :dispatched | :noop} | {:error, :stack_not_found}
  def dispatch_stack_deploy(%Stack{id: id}) when is_binary(id) do
    dispatch_stack_deploy(id)
  end

  def dispatch_stack_deploy(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      nil ->
        {:error, :stack_not_found}

      %Stack{} = stack ->
        if deploy_ready?(stack) do
          try_dispatch(stack)
        else
          {:ok, :noop}
        end
    end
  end

  def dispatch_stack_deploy(_), do: {:error, :stack_not_found}

  # Atomic transition to "deploying" via compare-and-swap on stacks.status.
  # The guarded WHERE ensures exactly one concurrent caller wins the race.
  defp try_dispatch(%Stack{} = stack) do
    now = DateTime.utc_now()
    now_iso = DateTime.to_iso8601(now)
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    first_ready_iso =
      case Map.get(base_meta, "first_deploy_ready_at") do
        iso when is_binary(iso) -> iso
        _ -> now_iso
      end

    new_meta = Map.put(base_meta, "first_deploy_ready_at", first_ready_iso)

    {count, _} =
      from(s in Stack,
        where:
          s.id == ^stack.id and
            s.status in ["forming", "in_progress", "in_review"],
        update: [
          set: [
            status: "deploying",
            metadata: ^new_meta,
            updated_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])

    case count do
      1 ->
        updated_stack = Repo.get!(Stack, stack.id)
        member_count = length(members(updated_stack))
        duration_ms = deploy_ready_duration_ms(first_ready_iso, now)

        emit_deploy_dispatched_telemetry(updated_stack, member_count, duration_ms)
        trigger_stack_deploy_pr_open(updated_stack.id)

        Logger.info(
          "[Stacks] dispatch_stack_deploy stack #{updated_stack.id}: transitioned to " <>
            "deploying (member_count=#{member_count}, duration_ms=#{duration_ms})"
        )

        {:ok, :dispatched}

      0 ->
        {:ok, :noop}
    end
  end

  defp deploy_ready_duration_ms(first_ready_iso, %DateTime{} = now) do
    case DateTime.from_iso8601(first_ready_iso) do
      {:ok, %DateTime{} = ready_at, _} -> DateTime.diff(now, ready_at, :millisecond)
      _ -> 0
    end
  end

  defp emit_deploy_dispatched_telemetry(%Stack{id: stack_id}, member_count, duration_ms) do
    :telemetry.execute(
      [:platform, :stacks, :deploy, :dispatched],
      %{
        count: 1,
        duration_ms_from_first_member_ready: duration_ms
      },
      %{
        stack_id: stack_id,
        member_count: member_count,
        duration_ms_from_first_member_ready: duration_ms
      }
    )

    :ok
  end

  # Mirrors `StackDeployer.trigger_maybe_open_stack_pr/1` — same
  # `Task.Supervisor` + `async: true|false` config knobs so tests can
  # observe the runner call synchronously via
  # `Application.put_env(:platform, :stack_deployer, async: false)`.
  defp trigger_stack_deploy_pr_open(stack_id) when is_binary(stack_id) do
    if stack_deployer_async?() do
      Task.Supervisor.async_nolink(stack_deployer_task_supervisor(), fn ->
        log_deploy_pr_open(stack_id, StackDeployer.maybe_open_stack_pr(stack_id))
      end)

      :ok
    else
      log_deploy_pr_open(stack_id, StackDeployer.maybe_open_stack_pr(stack_id))
      :ok
    end
  end

  defp log_deploy_pr_open(stack_id, {:ok, outcome}) do
    Logger.info(
      "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open outcome: #{inspect(outcome)}"
    )

    :ok
  end

  defp log_deploy_pr_open(stack_id, {:error, reason}) do
    Logger.warning(
      "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open failed: #{inspect(reason)}"
    )

    :ok
  end

  defp stack_deployer_config do
    Application.get_env(:platform, :stack_deployer, [])
  end

  defp stack_deployer_async? do
    Keyword.get(stack_deployer_config(), :async, true)
  end

  defp stack_deployer_task_supervisor do
    Keyword.get(stack_deployer_config(), :task_supervisor, Platform.TaskSupervisor)
  end

  @doc """
  Detect whether a just-completed plan approval was the transition point
  that opened the stack-v2 commencement gate (ADR 0042 Decision 4).

  Called from inside `Platform.Tasks.approve_plan/3`'s transaction,
  AFTER the plan write. The `task` is the member whose plan was just
  approved; `pre_update_plan` is that plan as it looked immediately
  before the write (i.e. `status: "pending_review"` in the normal call
  path).

  Returns:

    * `{:opened, stack, executable_ids}` — the gate flipped closed →
      open on this approval. `executable_ids` is the list of member ids
      that are level-0 roots of the in-stack DAG (the members that are
      now callable via `task_start` / `transition_task_status/2`).
      Non-root members remain at `stack_pending` until an explicit
      transition — the gate broadcast is a signal, not an auto-advance.

    * `:noop` — the task doesn't belong to a stack, the stack is
      missing, `plans_ready?/1` is still false, or the pre-approval plan
      was already counted as approved (so this call was a re-approval
      that didn't change the gate).

  ## The "was closed before" check

  `plans_ready?/1` collapses to "every member's latest plan is in
  `["approved", "completed"]`". The only member whose latest-plan
  status changed inside this txn is the one owning `pre_update_plan`
  (older siblings that get auto-superseded only slide from `approved`
  → `rejected`, so the LATEST plan for those tasks — which is still
  this newly-approved plan — is unaffected). So the pre-write gate
  state is equivalent to the post-write state, minus this task's
  contribution, plus this task's pre-approval contribution:

    * If `pre_update_plan.status in ["approved", "completed"]`, this
      task was already counted as approved before → post-write ready
      status equals pre-write ready status → no transition happened
      here even if the gate is currently open.

    * Otherwise, this task went from "not counted" to "counted", so
      a post-write `plans_ready? = true` means the gate JUST opened.
  """
  @spec detect_gate_open_transition(Task.t(), Plan.t()) ::
          {:opened, Stack.t(), [String.t()]} | :noop
  def detect_gate_open_transition(task, pre_update_plan)

  def detect_gate_open_transition(%Task{stack_id: nil}, _pre_update_plan), do: :noop

  def detect_gate_open_transition(%Task{stack_id: stack_id}, %Plan{} = pre_update_plan)
      when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      nil ->
        :noop

      %Stack{} = stack ->
        if CommencementGate.plans_ready?(stack) and
             not pre_update_plan_already_counted?(pre_update_plan) do
          executable_ids = stack |> executable_members() |> Enum.map(& &1.id)
          emit_gate_opened_telemetry(stack.id, executable_ids)
          {:opened, stack, executable_ids}
        else
          :noop
        end
    end
  end

  # Telemetry emission for the closed→open transition. Fires exactly
  # once per stack per opening because `detect_gate_open_transition/2`
  # is gated by `pre_update_plan_already_counted?/1` — a re-approval that
  # lands after the gate is already open returns `:noop` without touching
  # this helper. Mirrors `:telemetry.execute/3` shape from
  # `PlanEngine` / `StackDeployer`.
  defp emit_gate_opened_telemetry(stack_id, executable_ids) do
    :telemetry.execute(
      [:platform, :stacks, :commencement, :gate_opened],
      %{executable_count: length(executable_ids)},
      %{stack_id: stack_id, executable_task_ids: executable_ids}
    )
  end

  # A plan whose pre-write status was already in the "approved" set means
  # `plans_ready?/1`'s DISTINCT-ON-latest query counted this task as ready
  # BEFORE this approval too — so today's write did not change the gate
  # boolean even if it's currently `true`.
  defp pre_update_plan_already_counted?(%Plan{status: status}),
    do: status in ~w(approved completed)

  # ── Terminal cascade (Stack v2 stage 5) ────────────────────────────────

  @doc """
  Cascade every stack member that hasn't landed at `"done"` to `"done"`.

  Called from `StackDeployer.handle_rollup_pr_merged/1` as a safety net
  after the rollup PR has merged. On the canonical happy path the T6
  webhook fan-out (`GithubWebhookController.process_stack_merged_pr/4`
  at `github_webhook_controller.ex:505`) has already flipped each
  member to `done` via its per-task `pr_merged` validation — this
  helper is then a no-op (every member is already `done`).

  The fallback path fires when a member is at `in_review` with no
  `pr_merged` validation (e.g. it never got a per-task deploy stage —
  the exact case for stack members, which ship via the rollup PR).
  Those members are transitioned to `done` directly via
  `Tasks.transition_task/2`. Failed transitions surface in `skipped`
  so callers can log-and-continue rather than crash the whole
  rollup-merge handler.

  Returns `%{cascaded: [Task.t()], skipped: [%{task_id, status,
  reason}]}`. `cascaded` lists members transitioned by THIS call
  (members already at `"done"` are silently omitted from both keys —
  the point of the helper is "make sure everyone is done", not "report
  who was already done"). `skipped` lists members whose transition
  attempt failed for any reason (invalid transition, changeset error,
  etc.).

  Returns `%{cascaded: [], skipped: [%{reason: :stack_not_found}]}` for
  an unknown stack id — the helper never raises.
  """
  @spec cascade_members_to_done(Stack.t() | binary(), :webhook | :backfill) :: %{
          cascaded: [Task.t()],
          skipped: [%{task_id: String.t(), status: String.t(), reason: term()}]
        }
  def cascade_members_to_done(stack_or_id, trigger \\ :webhook)

  def cascade_members_to_done(%Stack{} = stack, trigger)
      when trigger in [:webhook, :backfill] do
    all_members = members(stack)
    to_transition = Enum.reject(all_members, &(&1.status == "done"))

    # Stage 3 (019f5bc4-3521): wrap the per-member reduce in a
    # `Repo.transaction/1` so a single illegal transition rolls back
    # every sibling flip. Prevents the half-done stack we saw when a
    # rollup PR merged but one member had drifted into a status that
    # can't legally reach `done`. On rollback we still return the
    # cascaded/skipped shape (with `cascaded: []`) and still fire the
    # `:cascade_completed` telemetry so dashboards count the failure —
    # per stage 2's idempotency contract, every entry into the cascade
    # helper emits exactly one event.
    transaction_result =
      Repo.transaction(fn ->
        Enum.reduce(to_transition, %{cascaded: [], skipped: []}, fn member, acc ->
          case Tasks.transition_task(member, "done") do
            {:ok, updated} ->
              Logger.warning(
                "[Stacks.cascade_members_to_done] member #{member.id} (status=#{member.status}) " <>
                  "was not flipped to done by the rollup-merge fan-out; transitioned directly. " <>
                  "This usually means the member had no pr_merged validation — expected for " <>
                  "stack members but worth confirming ops didn't lose a webhook."
              )

              %{acc | cascaded: [updated | acc.cascaded]}

            {:error, reason} ->
              Repo.rollback(
                {:member_transition_failed, member.id, %{status: member.status, reason: reason}}
              )

            {:error, reason, _details} ->
              Repo.rollback(
                {:member_transition_failed, member.id, %{status: member.status, reason: reason}}
              )
          end
        end)
      end)

    result =
      case transaction_result do
        {:ok, acc} ->
          %{
            cascaded: Enum.reverse(acc.cascaded),
            skipped: Enum.reverse(acc.skipped)
          }

        {:error, {:member_transition_failed, task_id, %{status: status, reason: reason}}} ->
          Logger.warning(
            "[Stacks.cascade_members_to_done] transaction rolled back for stack #{stack.id}: " <>
              "member #{task_id} (status=#{status}) failed to transition to done " <>
              "(reason=#{inspect(reason)}); all sibling transitions reverted"
          )

          %{
            cascaded: [],
            skipped: [%{task_id: task_id, status: status, reason: reason}]
          }
      end

    emit_cascade_completed_telemetry(stack, all_members, result, trigger)

    result
  end

  def cascade_members_to_done(stack_id, trigger)
      when is_binary(stack_id) and trigger in [:webhook, :backfill] do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack ->
        cascade_members_to_done(stack, trigger)

      nil ->
        # Deliberately no telemetry emission for the unknown-stack branch:
        # there's no stack_id to key dashboards on and the caller learns
        # about it via the returned `:stack_not_found` skip entry.
        %{cascaded: [], skipped: [%{task_id: nil, status: nil, reason: :stack_not_found}]}
    end
  end

  # Fire `[:platform, :stacks, :deploy, :cascade_completed]` after every
  # invocation of `cascade_members_to_done/2` on a real stack. Emits even
  # in the no-op case (nothing to cascade) so dashboards can count how
  # often the cascade helper is entered — the metric shape mirrors
  # `StackDeployer.emit_pr_merged_telemetry/4` (measurements carry
  # `count: 1` + the total member roll; metadata carries the stack
  # identity + cascade-specific counters + the trigger tag).
  #
  # Trigger `:webhook` is the canonical happy path (from
  # `StackDeployer.handle_rollup_pr_merged/1` after the rollup PR closes
  # merged); `:backfill` is the Mix-task recovery path landing in a
  # later stage of task 019f5bc4-3521.
  defp emit_cascade_completed_telemetry(
         %Stack{id: stack_id, rollup_branch: rollup_branch},
         all_members,
         %{cascaded: cascaded, skipped: skipped},
         trigger
       ) do
    :telemetry.execute(
      [:platform, :stacks, :deploy, :cascade_completed],
      %{count: 1, member_count: length(all_members)},
      %{
        stack_id: stack_id,
        rollup_branch: rollup_branch,
        cascaded_count: length(cascaded),
        skipped_count: length(skipped),
        trigger: trigger
      }
    )

    :ok
  end

  @doc """
  Return the stack members flattened into the order they should be merged
  into the rollup branch — foundational members first.

  On success this is `validate_dag/1`'s level structure flattened in level
  order (level 0 roots, then level 1, …), i.e. a topological ordering of the
  in-stack DAG. Members WITHIN a level are independent (parallel), so we
  sort each level by `stack_position` for a deterministic, creation-ordered
  tiebreak. A stack with members but ZERO declared edges collapses to a
  single level, so the result is exactly `stack_position` (creation) order.

  Fallback semantics: when the DAG is invalid (a dependency cycle or a
  cross-stack edge), `validate_dag/1` returns `{:error, ...}`; we fall back
  to `members/1`, which orders by `stack_position` (creation) order, so this
  function never crashes on a cyclic stack.
  """
  @spec members_in_merge_order(Stack.t() | binary()) :: [Task.t()]
  def members_in_merge_order(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, levels} ->
        Enum.flat_map(levels, fn level ->
          Enum.sort_by(level, & &1.stack_position)
        end)

      {:error, _reason, _detail} ->
        members(stack_or_id)
    end
  end

  @doc """
  Return the stack's planning execution waves — the topological levels of
  its in-stack DAG, roots-first.

  Thin wrapper over `validate_dag/1` that exposes the same level structure
  as a first-class public helper so downstream callers (the wave-gated
  planning cascade in `start_planning/1` and `advance_planning_waves/1`)
  can iterate waves without repeating Kahn's algorithm inline.

  Each inner list is a "wave" — members whose in-stack predecessors are
  satisfied by the union of prior waves. Wave 0 contains the members
  with no in-stack deps (the roots); wave N depends only on members in
  waves 0..N-1. Waves are ordered from foundational to dependent and
  each inner list is already stack-position-sorted by `validate_dag/1`.

  ## Return shape

    * `{:ok, levels}` — `levels` is `[[Task.t()]]`. Empty stack collapses
      to `{:ok, []}` — distinguishable from `{:error, :cycle, ...}` so
      the idempotency guard in `start_planning/1` can safely no-op on
      empty stacks without swallowing cycle errors.
    * `{:error, :cycle, path}` — passed through unchanged from
      `validate_dag/1`; `path` is a best-effort list of `%Task{}` along
      one offending cycle.
    * `{:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}` —
      passed through unchanged from `validate_dag/1`.
    * `{:error, :stack_not_found}` — the string-id branch got an id
      that has no row. Distinct from `{:ok, []}` (empty-but-real
      stack) so callers can surface a proper error envelope.

  ## Naming intent — why a separate function, not just `validate_dag/1`

  Callers use this named entry-point rather than reaching for
  `validate_dag/1` directly so that if the DAG source is later swapped
  — e.g. once the dep-inference planner persists inferred edges into
  `tasks.dependencies` — the swap is a one-liner here and nothing at
  the cascade layer changes. Today `validate_dag/1` already reads
  `tasks.dependencies` via `build_in_stack_subgraph/2`, so inferred
  edges flow through automatically with no code change here.
  """
  @spec planning_waves(Stack.t() | binary()) ::
          {:ok, [[Task.t()]]}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found}
  def planning_waves(%Stack{} = stack), do: validate_dag(stack)

  def planning_waves(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> validate_dag(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  @doc """
  Check whether a stack member's in-stack dependencies have all crossed the
  ADR 0041 §"Unblock threshold".

  An in-stack dep clears when its status is one of `in_review`, `deploying`,
  or `done` AND its `metadata["merged_into_rollup_at"]` is set. Returns
  `false` for any task whose `stack_id` is nil (non-members are out of
  scope; cross-stack deps to non-members are handled by the existing
  `done`-only sweep elsewhere). Returns `true` for a member with no
  in-stack deps (vacuously unblocked).

  Cross-stack deps (deps pointing at tasks NOT in this stack) are
  ignored here on purpose — they're gated by the existing
  `done`-threshold sweep.

  This function is the dispatch gate's contract: the dispatcher
  (`Platform.Orchestration.TaskRouterWatcher`) intentionally excludes
  `stack_pending` from its active-status set so a `stack_pending` task
  is invisible to dispatch. `unblocked_in_stack?/1` answers the
  separate question of whether the task is ready to be promoted out of
  `stack_pending` and become visible to the dispatcher — see
  `try_promote/1` below.
  """
  @spec unblocked_in_stack?(Task.t()) :: boolean()
  def unblocked_in_stack?(%Task{stack_id: nil}), do: false

  def unblocked_in_stack?(%Task{stack_id: stack_id} = task) when is_binary(stack_id) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    in_stack_dep_ids =
      task
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == task.id))
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(member_ids, &1))

    case in_stack_dep_ids do
      [] ->
        true

      ids ->
        deps =
          from(t in Task, where: t.id in ^ids, select: %{status: t.status, metadata: t.metadata})
          |> Repo.all()

        # If a declared dep id has no row (e.g. soft-deleted out from
        # under us), treat it as unmet — better to stall than to
        # falsely promote.
        length(deps) == length(ids) and
          Enum.all?(deps, &threshold_cleared?/1)
    end
  end

  defp threshold_cleared?(%{status: status, metadata: metadata})
       when status in ["in_review", "deploying", "done"] do
    is_map(metadata) and not is_nil(Map.get(metadata, "merged_into_rollup_at"))
  end

  defp threshold_cleared?(_), do: false

  @doc """
  Promote a `stack_pending` member to `in_progress` iff its in-stack deps
  have all cleared the ADR 0041 §"Unblock threshold".

  Behavior:

    * Task is not in any stack (`stack_id` nil) → `:noop`.
    * Task is in a stack but not at `stack_pending` → `:noop`.
    * Task is at `stack_pending` and deps NOT cleared → `:noop`.
    * Task is at `stack_pending` and deps cleared → transitions
      `stack_pending` → `in_progress` via `Tasks.transition_task/2`. That
      call emits the standard `{:task_updated, task}` board broadcast which
      `TaskRouterWatcher` already consumes, so the dispatcher picks the
      promoted task up on the next event.

  Returns `{:ok, task}` on a successful transition, `:noop` for any
  case that should leave the task untouched, or `{:error, reason}` if
  the transition itself fails.
  """
  @spec try_promote(Task.t() | binary()) ::
          {:ok, Task.t()} | :noop | {:error, term()}
  def try_promote(%Task{stack_id: nil}), do: :noop

  def try_promote(%Task{status: "stack_pending"} = task) do
    if unblocked_in_stack?(task) do
      case Tasks.transition_task(task, "in_progress") do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      :noop
    end
  end

  def try_promote(%Task{}), do: :noop

  def try_promote(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> try_promote(task)
      nil -> {:error, :task_not_found}
    end
  end

  @doc """
  Given a stack and a member task that just crossed the unblock threshold
  (its `merged_into_rollup_at` was just stamped), return the list of
  current `stack_pending` members that are now unblocked.

  Pure read-side helper: does NOT mutate. The caller (the sweep) is
  responsible for transitioning the returned members to `in_progress`.
  Members already past `stack_pending` are skipped — only `stack_pending`
  rows can be auto-promoted, since they were the ones blocked.
  """
  @spec unblocked_after(Stack.t() | binary(), Task.t()) :: [Task.t()]
  def unblocked_after(stack_or_id, %Task{id: just_merged_id}) do
    stack_id =
      case stack_or_id do
        %Stack{id: id} -> id
        id when is_binary(id) -> id
      end

    stack_id
    |> members()
    |> Enum.filter(fn %Task{} = member ->
      member.status == "stack_pending" and
        just_merged_id in Tasks.dependency_task_ids(member) and
        unblocked_in_stack?(member)
    end)
  end

  @doc """
  Stack-internal dependent sweep — the second of the two unblock paths
  in the engine.

  Keyed on a stack member's `metadata["merged_into_rollup_at"]` being
  newly set (typically by the deployer when a member's branch is merged
  into the stack rollup branch). Finds every other stack member whose
  status is `stack_pending` and whose dependency list includes the
  just-merged task, then promotes any whose in-stack deps have now all
  cleared the unblock threshold via `try_promote/1`.

  Partition with the existing cross-stack sweep (`tasks.ex` ~L1031,
  `sweep_unblocked_dependents/1`): that sweep matches `status==blocked`
  and uses the `done`-threshold; this sweep matches `status==stack_pending`
  and uses the rollup-merge threshold. They do NOT overlap — distinct
  source-task statuses, distinct candidate-task statuses, distinct
  thresholds.

  Returns `{:ok, promoted}` where `promoted` is the list of `{:ok, task}`
  results from successful promotions (failures are dropped, mirroring
  the existing sweep's permissive behavior). A non-stack-member task or
  a stack member without `merged_into_rollup_at` set is a no-op
  returning `{:ok, []}`.
  """
  @spec sweep_stack_dependents(Task.t()) :: {:ok, [Task.t()]}
  def sweep_stack_dependents(%Task{stack_id: nil}), do: {:ok, []}

  def sweep_stack_dependents(%Task{metadata: metadata}) when not is_map(metadata),
    do: {:ok, []}

  def sweep_stack_dependents(%Task{stack_id: stack_id, metadata: metadata} = task)
      when is_binary(stack_id) do
    if is_nil(Map.get(metadata, "merged_into_rollup_at")) do
      {:ok, []}
    else
      promoted =
        stack_id
        |> unblocked_after(task)
        |> Enum.reduce([], fn member, acc ->
          case try_promote(member) do
            {:ok, updated} -> [updated | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, promoted}
    end
  end

  # ── Regression handling (ADR 0041 §"Status divergence handling") ─────────

  # Ordering for regression detection only — higher index == "further
  # along the lifecycle". `stack_pending`/`blocked`/`backlog`/`planning`
  # are intentionally treated as the same conceptual rung; the only
  # comparison that matters is whether the new rung is strictly LOWER
  # than the old rung among the execution-phase statuses.
  @status_progression %{
    "backlog" => 0,
    "planning" => 0,
    "blocked" => 0,
    "stack_pending" => 0,
    "in_progress" => 1,
    "in_review" => 2,
    "deploying" => 3,
    "done" => 4
  }

  @doc """
  Detect whether `prev_status -> new_status` is a regression in the
  ADR 0041 lifecycle order (a backward step among the execution-phase
  rungs).

  Returns `true` for transitions like `in_review -> in_progress`,
  `deploying -> in_review`, `in_progress -> stack_pending`. Returns
  `false` for forward transitions or no-ops.
  """
  @spec regression?(String.t(), String.t()) :: boolean()
  def regression?(prev, new) when is_binary(prev) and is_binary(new) do
    Map.get(@status_progression, new, 0) < Map.get(@status_progression, prev, 0)
  end

  @doc """
  Handle a stack member regressing (status moving backward).

  Per ADR 0041 §"Status divergence handling":

    1. Recompute the stack rollup status. (No-op here — already wired
       into `Tasks.maybe_finalize_transition/3`'s tail via
       `maybe_recompute_stack/1`, so we don't double-recompute.)
    2. For every downstream member (another stack member listing this
       task in its dependencies) currently at `in_progress`:
       - If the downstream has NOT committed work (heuristic: no plan
         stage has reached `status: "passed"`) AND its unblock
         threshold is no longer met → revert it to `stack_pending` via
         `Tasks.transition_task/2`.
       - Otherwise leave its status alone and stamp
         `metadata["stack_dep_regressed_at"]` with the current
         timestamp so the UI / operator can see that an upstream dep
         regressed.

  Cross-stack regressions are silenced: a task without a `stack_id`
  short-circuits with `:ok` (the existing done-threshold sweep is the
  cross-stack path and is NOT modified by this handler).

  Returns `{:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}` on
  success.
  """
  @spec handle_member_regression(Task.t(), String.t()) ::
          :ok | {:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}
  def handle_member_regression(%Task{stack_id: nil}, _prev_status), do: :ok

  def handle_member_regression(%Task{stack_id: stack_id} = task, _prev_status)
      when is_binary(stack_id) do
    members = members(stack_id)
    member_ids = MapSet.new(members, & &1.id)

    downstream =
      members
      |> Enum.reject(&(&1.id == task.id))
      |> Enum.filter(fn member ->
        task.id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)

    Enum.reduce(downstream, {[], []}, fn member, {reverted, flagged} ->
      cond do
        member.status != "in_progress" ->
          {reverted, flagged}

        unblocked_in_stack?(member) ->
          # Threshold still met — no need to revert. Don't flag either,
          # since nothing was actually invalidated.
          {reverted, flagged}

        committed_work?(member) ->
          # Threshold no longer met but work exists — record the regression
          # marker without disrupting the in-flight task.
          case mark_dep_regressed(member) do
            {:ok, updated} -> {reverted, [updated | flagged]}
            _ -> {reverted, flagged}
          end

        true ->
          case Tasks.transition_task(member, "stack_pending") do
            {:ok, updated} -> {[updated | reverted], flagged}
            _ -> {reverted, flagged}
          end
      end
    end)
    |> then(fn {reverted, flagged} ->
      {:ok, %{reverted: Enum.reverse(reverted), flagged: Enum.reverse(flagged)}}
    end)
  end

  # "Committed work" heuristic: any stage on any plan for this task has
  # reached `status: "passed"` (the engine's stage_complete signal).
  defp committed_work?(%Task{id: task_id}) do
    Repo.exists?(
      from(s in Platform.Tasks.Stage,
        join: p in Platform.Tasks.Plan,
        on: s.plan_id == p.id,
        where: p.task_id == ^task_id and s.status == "passed"
      )
    )
  end

  defp mark_dep_regressed(%Task{} = member) do
    metadata = member.metadata || %{}
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    merged = Map.put(metadata, "stack_dep_regressed_at", stamp)
    Tasks.update_task(member, %{metadata: merged})
  end

  # ── Membership internals ─────────────────────────────────────────────────

  # Always reload from the DB so callers can hand us potentially-stale
  # structs without false negatives on membership checks.
  defp load_stack(%Stack{id: id}), do: load_stack(id)

  defp load_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> {:ok, stack}
      nil -> {:error, :stack_not_found}
    end
  end

  defp load_task(%Task{id: id}), do: load_task(id)

  defp load_task(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :task_not_found}
    end
  end

  defp ensure_not_in_stack(%Task{stack_id: nil}), do: :ok
  defp ensure_not_in_stack(%Task{}), do: {:error, :already_in_stack}

  defp ensure_in_stack(%Stack{id: stack_id}, %Task{stack_id: stack_id}), do: :ok
  defp ensure_in_stack(_stack, %Task{id: task_id}), do: {:error, :not_in_stack, task_id}
  defp ensure_in_stack(_stack, _task), do: {:error, :not_in_stack}

  defp ensure_no_in_stack_dependents(%Stack{id: stack_id}, %Task{id: task_id}) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    dependents =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at) and t.id != ^task_id)
      |> Repo.all()
      |> Enum.filter(fn member ->
        task_id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)
      |> Enum.map(fn %Task{id: id, title: title} -> %{id: id, title: title} end)

    case dependents do
      [] -> :ok
      _ -> {:error, {:has_dependents, dependents}}
    end
  end

  defp next_stack_position(stack_id) when is_binary(stack_id) do
    max_pos =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], max(t.stack_position))
      |> Repo.one()

    (max_pos || 0) + 1
  end

  # ── DAG internals ────────────────────────────────────────────────────────

  # Walk every member's declared dependencies and partition each edge:
  #
  #   * self-edges → silently dropped (matches `unmet_dependencies/1`).
  #   * dep target IS a member of THIS stack → retained as an in-stack edge.
  #   * dep target is some other task whose `stack_id` is non-nil and
  #     differs from this stack → reject as `:cross_stack_dep`.
  #   * dep target is unknown or has no stack → silently dropped per ADR
  #     0041 §"DAG validation" point 3 (allowed cross-stack-to-non-stack).
  #
  # The cross-stack lookup hits the DB exactly once: we batch every
  # not-in-stack dep id and ask Postgres for their `stack_id`s.
  @spec build_in_stack_subgraph([Task.t()], String.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  defp build_in_stack_subgraph(members, stack_id) do
    member_ids = MapSet.new(members, & &1.id)

    # First pass: filter self-edges, classify each remaining edge as
    # in-stack vs. external (deferred check).
    {in_stack_edges, external_edges, external_ids} =
      Enum.reduce(members, {[], [], MapSet.new()}, fn %Task{id: from_id} = member,
                                                      {in_acc, ext_acc, ext_ids} ->
        member
        |> Tasks.dependency_task_ids()
        |> Enum.reject(&(&1 == from_id))
        |> Enum.uniq()
        |> Enum.reduce({in_acc, ext_acc, ext_ids}, fn dep_id, {ia, ea, ei} ->
          cond do
            MapSet.member?(member_ids, dep_id) ->
              {[{from_id, dep_id} | ia], ea, ei}

            true ->
              {ia, [{member, dep_id} | ea], MapSet.put(ei, dep_id)}
          end
        end)
      end)

    # Second pass: a single DB hit to resolve `stack_id` for every
    # external dep target. Anything with a non-nil stack_id ≠ ours is
    # a cross-stack edge.
    foreign_stack_by_id =
      case MapSet.size(external_ids) do
        0 ->
          %{}

        _ ->
          ids = MapSet.to_list(external_ids)

          from(t in Task,
            where: t.id in ^ids and not is_nil(t.stack_id) and t.stack_id != ^stack_id,
            select: {t.id, t.stack_id}
          )
          |> Repo.all()
          |> Map.new()
      end

    case Enum.find(external_edges, fn {_member, dep_id} ->
           Map.has_key?(foreign_stack_by_id, dep_id)
         end) do
      nil ->
        {:ok, in_stack_edges}

      {from_member, dep_id} ->
        {:error, :cross_stack_dep, %{from: from_member, to_task_id: dep_id}}
    end
  end

  # Kahn's algorithm over the in-stack subgraph.
  #
  # Edges have shape `{from_id, to_id}` meaning "`from` depends on
  # `to`". Execution flows in the reverse direction: `to` must run
  # first, and `from`'s in-degree counts *outgoing* dep edges (number
  # of in-stack tasks `from` waits on).
  #
  # Each level pops every member whose remaining wait-count is zero,
  # then decrements the wait-count of every member that was depending
  # on a popped node. Continues until the graph drains; if any node
  # remains with a non-zero wait-count, returns `{:error, :cycle, ids}`
  # with the residue id list.
  @spec kahn_levels([Task.t()], [{String.t(), String.t()}]) ::
          {:ok, [[Task.t()]]} | {:error, :cycle, [String.t()]}
  defp kahn_levels(members, edges) do
    by_id = Map.new(members, &{&1.id, &1})

    # in_degree[id] = number of in-stack deps `id` is still waiting on.
    in_degree =
      Enum.reduce(members, %{}, fn %Task{id: id}, acc -> Map.put(acc, id, 0) end)
      |> then(fn acc ->
        Enum.reduce(edges, acc, fn {from_id, _to_id}, a ->
          Map.update(a, from_id, 1, &(&1 + 1))
        end)
      end)

    # reverse_adj[to_id] = ids that depend on `to_id`. When `to_id`
    # pops, decrement each of these.
    reverse_adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        Map.update(acc, to_id, [from_id], &[from_id | &1])
      end)

    do_kahn_levels(by_id, in_degree, reverse_adj, [])
  end

  defp do_kahn_levels(by_id, in_degree, _reverse_adj, levels) when map_size(in_degree) == 0 do
    {:ok, Enum.reverse(levels) |> Enum.reject(&(&1 == [])) |> hydrate_levels(by_id)}
  end

  defp do_kahn_levels(by_id, in_degree, reverse_adj, levels) do
    {ready_ids, remaining} =
      Enum.split_with(in_degree, fn {_id, deg} -> deg == 0 end)

    case ready_ids do
      [] ->
        # Nothing has zero in-degree → cycle in the residue.
        {:error, :cycle, Enum.map(remaining, fn {id, _} -> id end)}

      _ ->
        ready_ids = Enum.map(ready_ids, fn {id, _} -> id end)
        remaining = Map.new(remaining)

        next_in_degree =
          Enum.reduce(ready_ids, remaining, fn popped_id, acc ->
            popped_id
            |> then(&Map.get(reverse_adj, &1, []))
            |> Enum.reduce(acc, fn dependent_id, a ->
              case Map.get(a, dependent_id) do
                nil -> a
                deg -> Map.put(a, dependent_id, deg - 1)
              end
            end)
          end)

        do_kahn_levels(by_id, next_in_degree, reverse_adj, [ready_ids | levels])
    end
  end

  defp hydrate_levels(levels, by_id) do
    Enum.map(levels, fn ids -> Enum.map(ids, &Map.fetch!(by_id, &1)) end)
  end

  # Best-effort cycle recovery: starting from any node still in the
  # residue, follow outgoing edges (`from → to`, i.e. the dependency
  # arrow) until we revisit a node. The walk is bounded by the residue
  # size, so a cycle must be hit before we run out of frontier — even
  # for diamond-shaped residues every dep chain bottoms out in a back
  # edge by definition (otherwise Kahn would have drained it).
  #
  # Returns the cycle as a list of `%Task{}` in dependency order.
  @spec find_cycle([String.t()], [{String.t(), String.t()}], [Task.t()]) :: [Task.t()]
  defp find_cycle([], _edges, _members), do: []

  defp find_cycle([start | _] = residue_ids, edges, members) do
    by_id = Map.new(members, &{&1.id, &1})
    residue = MapSet.new(residue_ids)

    # Restrict to edges fully inside the residue so we only walk
    # cycle-relevant arrows.
    adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        if MapSet.member?(residue, from_id) and MapSet.member?(residue, to_id) do
          Map.update(acc, from_id, [to_id], &[to_id | &1])
        else
          acc
        end
      end)

    walk_cycle(start, adj, [], MapSet.new())
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  # Walks one path through the residue subgraph until it repeats a
  # node, then returns just the cycle (slice from the first occurrence
  # of the repeated node onward). If the path dead-ends (no outgoing
  # adj), returns the visited path as a best-effort.
  defp walk_cycle(node, adj, path, visited) do
    cond do
      MapSet.member?(visited, node) ->
        # Found the cycle — slice `path` from the first occurrence of
        # `node`. `path` is in reverse-walk order (head = most recent).
        ordered = Enum.reverse([node | path])
        idx = Enum.find_index(ordered, &(&1 == node))
        Enum.slice(ordered, idx..-1//1)

      true ->
        case Map.get(adj, node, []) do
          [] -> Enum.reverse([node | path])
          [next | _] -> walk_cycle(next, adj, [node | path], MapSet.put(visited, node))
        end
    end
  end

  # ── Pure helpers ─────────────────────────────────────────────────────────

  @doc """
  Return the normalized stack-level `phase_assignees` map from a stack's
  metadata (ADR 0041 stack-level agent assignment).

  Mirrors `Platform.Tasks.Task.validate_phase_assignees/1`: unknown phase
  keys are dropped, and malformed per-phase entries (anything that is not
  a map with at least an `"assignee_id"`) are dropped. Defaults to `%{}`
  for a stack with no metadata, non-map metadata, or no `"phase_assignees"`
  key. The `@phases` list is reused from `Platform.Tasks.Task` rather than
  redefined here.

  Returned shape: `%{phase => %{"assignee_id" => uuid, "assignee_type" => type}}`.
  """
  @spec stack_phase_assignees(Stack.t() | map() | nil) :: map()
  def stack_phase_assignees(%Stack{metadata: metadata}), do: stack_phase_assignees(metadata)

  def stack_phase_assignees(metadata) when is_map(metadata) do
    case Map.get(metadata, "phase_assignees") do
      pa when is_map(pa) ->
        pa
        |> Map.take(Task.phases())
        |> Enum.flat_map(fn {phase, entry} ->
          case normalize_phase_entry(entry) do
            nil -> []
            normalized -> [{phase, normalized}]
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  def stack_phase_assignees(_), do: %{}

  # A valid per-phase entry is a map carrying a non-nil `"assignee_id"`.
  # `"assignee_type"` defaults to `"agent"` (matching `Tasks.assignee_for_phase/2`).
  defp normalize_phase_entry(%{"assignee_id" => nil}), do: nil

  defp normalize_phase_entry(%{"assignee_id" => id} = entry) when is_binary(id) do
    %{"assignee_id" => id, "assignee_type" => Map.get(entry, "assignee_type") || "agent"}
  end

  defp normalize_phase_entry(_), do: nil

  @doc """
  Return `{assignee_id, assignee_type}` for the stack-level default in the
  given phase, or `{nil, nil}` if no stack-level assignee is configured for
  that phase.

  Mirrors `Platform.Tasks.assignee_for_phase/2`, but reads from the stack's
  `metadata["phase_assignees"]` (via `stack_phase_assignees/1`) instead of a
  task's `phase_assignees`.
  """
  @spec stack_assignee_for_phase(Stack.t() | map() | nil, String.t()) ::
          {String.t() | nil, String.t() | nil}
  def stack_assignee_for_phase(stack_or_metadata, phase) when is_binary(phase) do
    case stack_phase_assignees(stack_or_metadata) |> Map.get(phase) do
      %{"assignee_id" => id, "assignee_type" => type} -> {id, type}
      _ -> {nil, nil}
    end
  end

  # ── Stack-level agent assignment (ADR 0041) ──────────────────────────────

  @doc """
  Set the stack-level `phase_assignees` default and percolate it to every
  member that is not individually overridden.

  `attrs_by_phase` is a map keyed by phase (`"planning"` | `"execution"` |
  `"review"`) with values `%{"assignee_id" => id, "assignee_type" => type}`,
  identical to the shape `Platform.Tasks.set_phase_assignees/2` accepts.

  In a single `Repo.transaction`:

    1. The normalized map is merged into `stack.metadata["phase_assignees"]`
       and persisted via `update_stack/2`. Other metadata keys are
       preserved; the `phase_assignees` subtree is merged phase-by-phase so
       a partial update (e.g. only `"execution"`) leaves the other phases
       intact.
    2. For every member returned by `members/1` whose
       `metadata["assignee_override"]` is NOT `true`, the merged
       stack-level map is applied via `Platform.Tasks.set_phase_assignees/2`.
       That reuses the existing changeset + `maybe_apply_phase_assignee`
       re-derivation + board broadcast, so the task router and every read
       path see the new current-phase assignee.

  Members flagged `assignee_override` are skipped entirely — a stack-level
  reassignment must never clobber an individually-assigned member.

  Returns `{:ok, %{stack: stack, percolated: [task], skipped: [task]}}` on
  success, where `percolated` are the members that received the new
  default and `skipped` are the overridden members left untouched.
  """
  @spec set_stack_phase_assignees(Stack.t() | binary(), map()) ::
          {:ok, %{stack: Stack.t(), percolated: [Task.t()], skipped: [Task.t()]}}
          | {:error, :stack_not_found | term()}
  def set_stack_phase_assignees(stack_or_id, attrs_by_phase) when is_map(attrs_by_phase) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           merged_map = merge_stack_phase_assignees(stack, attrs_by_phase),
           new_metadata = Map.put(stack.metadata || %{}, "phase_assignees", merged_map),
           {:ok, updated_stack} <- update_stack(stack, %{metadata: new_metadata}) do
        {percolated, skipped} =
          updated_stack
          |> members()
          |> Enum.split_with(&(not member_overridden?(&1)))

        percolated_tasks =
          Enum.map(percolated, fn member ->
            case Tasks.set_phase_assignees(member, merged_map) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        %{stack: updated_stack, percolated: percolated_tasks, skipped: skipped}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Return the current stack-level `phase_assignees` default merged with a
  partial `attrs_by_phase` update.

  The merge is phase-by-phase: phases present in `attrs_by_phase` replace
  the stored phase entry; phases absent from `attrs_by_phase` are carried
  through from the existing stack-level map. The result is normalized via
  `stack_phase_assignees/1` semantics (unknown keys / malformed entries
  dropped) so the persisted map is always well-formed.
  """
  @spec merge_stack_phase_assignees(Stack.t() | map() | nil, map()) :: map()
  def merge_stack_phase_assignees(stack_or_metadata, attrs_by_phase)
      when is_map(attrs_by_phase) do
    current = stack_phase_assignees(stack_or_metadata)

    incoming =
      attrs_by_phase
      |> Map.new(fn {phase, entry} -> {to_string(phase), entry} end)
      |> Map.take(Task.phases())
      |> Enum.flat_map(fn {phase, entry} ->
        case normalize_phase_entry(entry) do
          nil -> [{phase, :clear}]
          normalized -> [{phase, normalized}]
        end
      end)
      |> Map.new()

    Enum.reduce(incoming, current, fn
      {phase, :clear}, acc -> Map.delete(acc, phase)
      {phase, entry}, acc -> Map.put(acc, phase, entry)
    end)
  end

  @doc """
  Whether a stack member is individually overridden — i.e. its
  `metadata["assignee_override"]` is `true`.

  An overridden member is excluded from stack-level fan-out: its assignment
  was set by hand and stack-level reassignment must not touch it.
  """
  @spec member_overridden?(Task.t() | map() | nil) :: boolean()
  def member_overridden?(%Task{metadata: metadata}), do: member_overridden?(metadata)

  def member_overridden?(metadata) when is_map(metadata),
    do: Map.get(metadata, "assignee_override") == true

  def member_overridden?(_), do: false

  @doc """
  Clear a member's individual override and return it to inheriting the
  stack-level default.

  Unsets `task.metadata["assignee_override"]` and, if the member's stack
  has a stack-level `phase_assignees` map, re-applies that default via
  `Platform.Tasks.set_phase_assignees/2`. Runs in a single transaction.

  Returns `{:ok, task}` (the re-inheriting member), `{:error, :not_in_stack}`
  for a task with no `stack_id`, `{:error, :task_not_found}` /
  `{:error, :stack_not_found}` for missing rows, or `{:error, reason}` if a
  write fails.
  """
  @spec clear_member_override(Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :not_in_stack | :task_not_found | :stack_not_found | term()}
  def clear_member_override(task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_has_stack(task),
           {:ok, %Stack{} = stack} <- load_stack(task.stack_id),
           cleared_metadata = Map.delete(task.metadata || %{}, "assignee_override"),
           {:ok, cleared_task} <- Tasks.update_task(task, %{metadata: cleared_metadata}) do
        stack_map = stack_phase_assignees(stack)

        if stack_map == %{} do
          cleared_task
        else
          case Tasks.set_phase_assignees(cleared_task, stack_map) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Apply the stack-level default to a freshly-attached member, unless the
  # member is individually overridden or the stack has no stack-level map.
  # Used inside `add_task/2`'s transaction.
  defp maybe_inherit_stack_assignees(%Stack{} = stack, %Task{} = task) do
    stack_map = stack_phase_assignees(stack)

    cond do
      stack_map == %{} -> {:ok, task}
      member_overridden?(task) -> {:ok, task}
      true -> Tasks.set_phase_assignees(task, stack_map)
    end
  end

  defp ensure_has_stack(%Task{stack_id: nil}), do: {:error, :not_in_stack}
  defp ensure_has_stack(%Task{stack_id: stack_id}) when is_binary(stack_id), do: :ok

  @doc """
  Build the canonical rollup-branch name for a slug.

  Mirrors the convention documented in ADR 0041 (Branch model) so callers
  do not assemble the prefix in multiple places.
  """
  @spec rollup_branch_name(String.t()) :: String.t()
  def rollup_branch_name(slug) when is_binary(slug), do: "stack/#{slug}"

  @doc """
  Validate a stack slug.

  Slugs must be lowercase alphanumeric with optional hyphens, must start
  with an alphanumeric character, and must be 60 characters or fewer.
  """
  @spec valid_slug?(any()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    String.length(slug) <= @max_slug_length and Regex.match?(@slug_regex, slug)
  end

  def valid_slug?(_), do: false
end
