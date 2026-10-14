defmodule Platform.Tasks.StackDeployer do
  @moduledoc """
  Owns the rollup-branch lifecycle for Task Stacks (ADR 0041).

  Stage 1 (this module's current surface): when `Stacks.start_stack/1`
  transitions a stack `forming -> in_progress`, ensure the stack's
  `rollup_branch` exists on the project's git remote at `base_branch` HEAD.

  This mirrors the shell-out pattern used by `Platform.Tasks.AutoMerger`
  and `PlatformWeb.GithubWebhookController` (System.cmd `gh`/`git`,
  Logger.info on success, Logger.warning on failure). Failures are
  surfaced as `{:error, reason}` tuples — the `Stacks` cascade calls us
  asynchronously and never crashes on a deployer failure.

  ## Idempotency

  `create_rollup_branch/1` is safe to re-invoke. If the rollup branch
  already exists on origin (`git push` exits non-zero with "already
  exists" / `ls-remote` reports a hit), the function returns
  `{:ok, %{branch: branch, base_sha: existing_sha, status: :already_exists}}`
  rather than erroring. This makes the deployer recoverable from partial
  failures (e.g. push succeeded but the response was lost).

  ## Stage 2 (this module's added surface)

  `merge_member_into_rollup/1` performs the per-member rollup-merge.
  It is invoked via `handle_member_transition/3` from the
  `Tasks.transition_task/2` finalizer when a stack member reaches
  `in_review` AND every validation in its review-stage(s) is `passed`.

  Since ADR-0042 Decision 2 (branch side), the merge is
  fast-forward-only. Every `task/<uuid>` member branch is cut from
  the rollup HEAD, so a validated pass fast-forwards trivially.

  Failure modes:

    * On `:not_fast_forwardable` the deployer stamps
      `task.metadata["paused_reason"] = %{kind: "rollup_diverged", …}`
      AND files a needs_human `execution.blocked` runtime event addressed
      to the member's execution assignee, naming both SHAs, the rebase,
      and the `stack_retry_member_merge` retry. It does NOT flip the stack
      to `blocked` — divergence is a task-scoped anomaly (someone rebased
      manually, a race left the branch cut from stale HEAD, etc.). Other
      stack members can keep merging. A later successful merge clears the
      stamp in the same write that records `merged_into_rollup_at`.
    * On `:conflict` (practically unreachable under `--ff-only`, kept
      as defence-in-depth) the deployer halts the stack: stack
      `status -> "blocked"` and `metadata.conflict` records the
      offending member, file list, and timestamp. No auto-resolve is
      attempted.

  ## Stage 4 (this module's added surface)

  `maybe_open_stack_pr/1` opens the single rollup PR
  (`rollup_branch -> base_branch`) once every stack member has been
  merged into the rollup AND every member's status is in
  `["in_review", "deploying"]`. It is invoked asynchronously after
  every successful per-member rollup merge so the gate fires the
  moment the last member crosses the line.

  Idempotent: re-invocation with `metadata["rollup_pr"]` already
  populated returns `{:ok, :already_open}` without shelling out.

  `handle_rollup_pr_merged/1` is the success path T6 will call when
  the GitHub `pull_request.closed` webhook fires for the rollup
  branch: it transitions the stack to `done` (member statuses are
  handled by T6's fan-out, not here).

  ## The rollup branch is deleted after the rollup PR merges (intentional)

  After the rollup PR merges, `handle_rollup_pr_merged/1` deletes the
  stack's rollup branch (`stack/<name>`) on origin, through
  `kick_off_rollup_branch_delete/1`. It does this whatever the repository's
  `delete_branch_on_merge` setting is: the deployer owns the rollup branch's
  lifecycle, per ADR 0045 (`docs/decisions/0045-task-stacks-v2.md`, "On
  merge, `stack/<name>` is deleted"). A missing rollup branch after a
  shipped stack is therefore expected, not a GitHub setting. An abandoned
  stack keeps its rollup branch (same ADR, `stack.abandon`).

  ## Stage 5 (this module's added surface)

  `handle_rollup_ci_failure/2` is the failure path T6 will call when
  the GitHub `check_run` / `check_suite` webhook (or the `ci_passed`
  validation evaluation pipeline) reports a failing CI run for a PR
  whose head is the stack's `rollup_branch`.

  The atomic all-members bounce protocol (stage 4 rewrite):

    1. **Identify offender for the git revert** — load all stack
       members ordered by `metadata["merged_into_rollup_at"]["at"]`
       descending. The offender is the most-recently-merged member;
       its merge commit is the ONE we revert on the rollup branch
       (reverting earlier merges would conflict against base). If
       multiple merges fit the window an `[StackDeployer] CI
       attribution heuristic: ...` warning is logged. This is the
       only piece of the flow that is scoped to a single member —
       everything else is atomic across the stack.
    2. **Atomic bounce of every member** — for EVERY stack member
       (merged or not): clear `metadata["merged_into_rollup_at"]`;
       stamp `metadata["bounced_from_rollup"] = %{at, ci_run_url,
       head_sha, sha: merge_sha_if_known}`; transition to
       `"in_progress"` (the ship-or-no-ship guarantee: if the stack
       PR failed, nobody rides forward alone).
    3. **Revert the offender's merge commit** on the rollup branch
       via the runner (best-effort; failure is fatal to the bounce
       so operators see the divergence).
    4. **Close the rollup PR** so the next `maybe_open_stack_pr/1`
       cycle opens a fresh PR after fixes land.
    5. **Flip the stack** back to `"in_progress"` (not
       `"in_review"`) and clear `metadata["rollup_pr"]`.

  Idempotent: if every member with a merge stamp already carries
  `metadata["bounced_from_rollup"]["ci_run_url"]` matching this
  invocation's `ci_run_url`, the function no-ops with
  `{:ok, :already_bounced}`.

  ## Test injection

  Git operations are dispatched through a runner module configurable
  via `:platform, :stack_deployer, git_runner: Module`. The default
  runner is `Platform.Tasks.StackDeployer.GitShellRunner`, which
  shells out to `git`. Tests substitute an in-memory runner.
  """

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PostCommit, Stack, Stacks}
  alias Platform.Tasks.Stage, as: PlanStage
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tasks.Validation

  import Ecto.Query

  require Logger

  @default_runner Platform.Tasks.StackDeployer.GitShellRunner

  @type create_result :: %{
          branch: String.t(),
          base_sha: String.t() | nil,
          status: :created | :already_exists,
          created_at: DateTime.t()
        }

  @doc """
  Ensure the stack's rollup branch exists on origin at `base_branch` HEAD.

  Behavior:

    1. Loads the project to obtain `repo_url`. Returns
       `{:error, :no_repo_url}` if the project has none configured (the
       deployer can't push without a remote).
    2. Asks the configured git runner to ensure the rollup branch exists
       on `origin`. The runner is responsible for fetching, resolving
       `base_branch` HEAD, checking remote-existence, and pushing.
    3. Logs `:info` on success, `:warning` on failure. Never raises.

  Returns `{:ok, %{branch, base_sha, status, created_at}}` on success
  (with `status: :created` or `:already_exists`) or `{:error, reason}`
  on failure.
  """
  @spec create_rollup_branch(Stack.t()) :: {:ok, create_result()} | {:error, term()}
  def create_rollup_branch(%Stack{} = stack) do
    case Tasks.get_project(stack.project_id) do
      nil ->
        Logger.warning(
          "[StackDeployer] stack #{stack.id} project #{stack.project_id} not found; aborting"
        )

        {:error, :project_not_found}

      project ->
        cond do
          is_nil(project.repo_url) or project.repo_url == "" ->
            Logger.warning(
              "[StackDeployer] stack #{stack.id} project has no repo_url; cannot create rollup branch"
            )

            {:error, :no_repo_url}

          true ->
            do_create_rollup_branch(stack, project.repo_url)
        end
    end
  end

  @doc """
  Gap 1 FIX 1 (task 019f921d): idempotently ensure the stack's rollup
  branch exists on origin before a member merge.

  Thin delegate to `create_rollup_branch/1`, which is already idempotent:
  it short-circuits with `:already_exists` when the branch is present and
  stamps `metadata["rollup_branch_ready"]`. Named `ensure_rollup_branch/1`
  so the merge path reads as an explicit guarantee ("ensure before merge")
  and so the two subsystems can't drift on which entry point creates the
  branch.

  Returns `{:ok, create_result()}` on success (branch present or freshly
  created) or `{:error, reason}` when the branch cannot be made to exist —
  the caller (`do_merge_member/3`) escalates that into
  `{:error, {:rollup_branch_unavailable, reason}}` instead of merging into
  a non-existent ref.
  """
  @spec ensure_rollup_branch(Stack.t()) :: {:ok, create_result()} | {:error, term()}
  def ensure_rollup_branch(%Stack{} = stack), do: create_rollup_branch(stack)

  @doc """
  Hook called by `Platform.Tasks.Stacks.start_stack/1` after the status
  cascade completes successfully.

  Only fires for the `forming -> in_progress` transition (stage 1's only
  trigger). Runs `create_rollup_branch/1` asynchronously under
  `Task.Supervisor` so the caller (typically the MCP `stack_start`
  handler) returns quickly. Failures are logged but never crash the
  caller.

  Returns the spawned `Task` reference for callers (mostly the test
  suite) that want to await completion. Returns `:ok` if dispatch is
  disabled by config (`:platform, :stack_deployer, async: false`) — in
  that case the create runs synchronously and the result is logged.
  """
  @spec handle_stack_transition(Stack.t(), atom(), atom()) :: :ok | TaskRecord.t()
  def handle_stack_transition(%Stack{} = stack, :forming, :in_progress) do
    if async?() do
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        log_create_result(stack, create_rollup_branch(stack))
      end)
    else
      log_create_result(stack, create_rollup_branch(stack))
      :ok
    end
  end

  def handle_stack_transition(%Stack{} = _stack, _from, _to), do: :ok

  @doc """
  Hook called by the MCP `stack_create` handler immediately after a stack
  is created (while it is still `forming`).

  Eagerly ensures the rollup branch exists on origin at `base_branch` HEAD
  so the branch is visible the moment the stack is created, rather than
  waiting for the `forming -> in_progress` transition (`stack_start`).

  Fire-and-forget: like `handle_stack_transition/3`, runs
  `create_rollup_branch/1` asynchronously under `Task.Supervisor` so the
  `stack_create` MCP call returns immediately. Failures are logged but
  never crash the caller, and a project with no `repo_url` is a logged
  no-op (`create_rollup_branch/1` returns `{:error, :no_repo_url}`).

  Idempotent against `handle_stack_transition/3`: both ultimately call the
  runner's `ensure_rollup_branch/1`, which short-circuits with
  `:already_exists` when the branch is already on origin. So running this
  hook at create-time and the start-time hook later does not error.

  Returns the spawned `Task` reference (for tests that want to await it),
  or `:ok` when dispatch is disabled by config
  (`:platform, :stack_deployer, async: false`) — in that case the create
  runs synchronously and the result is logged.
  """
  @spec handle_stack_created(Stack.t()) :: :ok | TaskRecord.t()
  def handle_stack_created(%Stack{} = stack) do
    if async?() do
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        log_create_result(stack, create_rollup_branch(stack))
      end)
    else
      log_create_result(stack, create_rollup_branch(stack))
      :ok
    end
  end

  @doc """
  Hook called by `Tasks.transition_task/2`'s finalizer when a task
  reaches `in_review`.

  Stack members fire the rollup-merge attempt; non-members are a no-op.
  Runs asynchronously under `Task.Supervisor` so the caller (the
  transition finalizer) returns quickly. Failures are logged but never
  crash the caller.

  Returns the spawned `Task` reference for callers (mostly the test
  suite) that want to await completion. Returns `:ok` if the task is
  not a stack member, or if dispatch is disabled by config.
  """
  @spec handle_member_transition(TaskRecord.t(), atom() | String.t(), atom() | String.t()) ::
          :ok | TaskRecord.t()
  def handle_member_transition(%TaskRecord{stack_id: nil}, _from, _to), do: :ok

  def handle_member_transition(%TaskRecord{stack_id: stack_id} = task, _from, to)
      when is_binary(stack_id) and to in [:in_review, "in_review"] do
    if async?() do
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        attempt_member_merge(task)
      end)
    else
      attempt_member_merge(task)
    end
  end

  def handle_member_transition(%TaskRecord{}, _from, _to), do: :ok

  @doc """
  `handle_member_transition/3`, deferred until the enclosing
  `Platform.Tasks.PostCommit` scope commits (task 01a136c1).

  The plan engine's write paths open that scope around their transaction.
  The merge child reads through its own connection under `async: true`, so
  firing it before commit showed it the transaction's own writes (the
  validation just passed, the stage just settled) as not yet there, and it
  declined the merge.

  At run time the member is RE-READ, so the merge sees the committed row,
  including a stamp written by an earlier thunk of the same commit. The
  deferral is keyed per member and target status: one commit fires at most
  one merge attempt per member, however many trigger sites asked for it.
  With no scope open it runs immediately, as `handle_member_transition/3`
  always did.
  """
  @spec handle_member_transition_after_commit(
          TaskRecord.t(),
          atom() | String.t(),
          atom() | String.t()
        ) :: term()
  def handle_member_transition_after_commit(%TaskRecord{stack_id: nil}, _from, _to), do: :ok

  def handle_member_transition_after_commit(%TaskRecord{id: task_id} = task, from, to) do
    PostCommit.run_after_commit(
      fn ->
        case Tasks.get_task_record(task_id) do
          %TaskRecord{} = fresh -> handle_member_transition(fresh, from, to)
          nil -> handle_member_transition(task, from, to)
        end
      end,
      key: {:stack_member_transition, task_id, to_string(to)}
    )
  end

  # Bug #1 (task 019f708f): `Task.Supervisor.async_nolink` swallows any
  # exception raised inside the fn, silently stranding the member in
  # `deploying` forever. Wrap `merge_member_into_rollup/1` in try/rescue so
  # a git conflict / disk-full / network raise files a needs_human blocker
  # via the runtime-event path (mirroring `tool_surface.ex`'s
  # `report_blocker` shape) instead of vanishing. Applied to BOTH the
  # async and non-async branches so `async?: false` mode behaves
  # identically.
  defp attempt_member_merge(%TaskRecord{} = task) do
    result = merge_member_into_rollup(task)
    log_merge_result(task, result)
    maybe_escalate_merge_error(task, result)
    :ok
  rescue
    e ->
      stacktrace = __STACKTRACE__
      message = Exception.message(e)

      Logger.error(
        "[StackDeployer] task #{task.id} rollup merge raised: #{message}\n" <>
          Exception.format(:error, e, stacktrace)
      )

      record_merge_blocker(task, "Rollup merge raised: #{message}")
      :ok
  end

  # Gap 1 FIX 2 (task 019f921d): a `{:error, reason}` RETURN from
  # `merge_member_into_rollup/1` (network blip, auth misconfig, git shell
  # failure, or the new `{:rollup_branch_unavailable, _}`) was previously
  # only logged by `log_merge_result/2`, silently stranding the member in
  # `deploying`. File the same needs_human blocker a raise would, so a
  # failed merge surfaces / self-heals instead of vanishing.
  #
  # Only two outcomes are benign and must NOT file a blocker here:
  #   * `{:ok, _}` (merged / already_merged / not_ready) — success or no-op.
  #   * `{:error, :conflict, _}` — records its own conflict + flips the
  #     stack to blocked; a blocker row would be redundant.
  #
  # Divergence (`{:error, :not_fast_forwardable, _}`) IS escalated (task
  # 01a05392 stage 2) — but by `record_divergence/3`, not here. That
  # function has the member/rollup SHAs in hand and owns the double-file
  # guard (same `rollup_sha` == same fact), so it files the blocker in the
  # same breath as the `paused_reason` stamp. Adding a clause for it here
  # would file twice; it falls through to the catch-all below because the
  # tuple is 3-ary and never matches the 2-ary `{:error, reason}` clause.
  defp maybe_escalate_merge_error(_task, {:ok, _}), do: :ok
  defp maybe_escalate_merge_error(_task, {:error, :conflict, _}), do: :ok

  defp maybe_escalate_merge_error(%TaskRecord{} = task, {:error, reason}) do
    record_merge_blocker(task, "Rollup merge returned error: #{inspect(reason)}")
    :ok
  end

  defp maybe_escalate_merge_error(_task, _other), do: :ok

  # `extra_payload` is merged UNDER the canonical keys so a caller can add
  # routing / remediation fields (assignee, SHAs, retry call) without being
  # able to downgrade `needs_human` or re-point the event.
  #
  # Public (`@doc false`) since task 01a05392 stage 4: the dispatch prompt
  # renderer (`HeartbeatScheduler.stack_member_git_workflow_section/2`) files
  # the same needs_human shape when a member of an `in_progress` stack is
  # dispatched without the `rollup_branch_ready` stamp. It holds a task MAP
  # (not always a `%TaskRecord{}`), hence the binary `task_id` clause.
  @doc false
  def record_merge_blocker(task, description, extra_payload \\ %{})

  def record_merge_blocker(%TaskRecord{id: task_id}, description, extra_payload) do
    record_merge_blocker(task_id, description, extra_payload)
  end

  def record_merge_blocker(task_id, description, extra_payload) when is_binary(task_id) do
    attrs = %{
      "task_id" => task_id,
      "phase" => "execution",
      "runtime_id" => "stack_deployer",
      "event_type" => "execution.blocked",
      "execution_space_id" => execution_space_id_for_task(task_id),
      "payload" =>
        Map.merge(extra_payload, %{
          "stage_id" => nil,
          "description" => description,
          "needs_human" => true,
          "reported_by" => "stack_deployer"
        })
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[StackDeployer] failed to record rollup-merge blocker for task #{task_id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp execution_space_id_for_task(task_id) do
    case Platform.Orchestration.ExecutionSpace.find_by_task_id(task_id) do
      %{id: id} -> id
      _ -> nil
    end
  end

  # ── merge_member_into_rollup ────────────────────────────────────────────

  @type merge_result :: %{
          required(:status) => :merged,
          required(:merge_sha) => String.t(),
          required(:merged_at) => DateTime.t()
        }

  @doc """
  Merge a stack member's branch into the stack's rollup branch.

  Preconditions (each returns a tagged tuple, not an exception):

    * Task must be a stack member (`stack_id` non-nil) — otherwise
      `{:error, :not_in_stack}`.
    * The owning stack must exist — otherwise `{:error, :stack_not_found}`.
    * The owning project must exist with a `repo_url` — otherwise
      `{:error, :project_not_found}` / `{:error, :no_repo_url}`.
    * Task status must be `in_review` AND every validation in the
      task's review-stage(s) must be `passed` — otherwise
      `{:ok, {:not_ready, reason}}`. (`:not_ready` is intentionally an
      `:ok` result: the engine fires this hook eagerly on transition; if
      review validations haven't all passed yet, this is the expected
      no-op outcome.) The reason is one of:

      * `{:stages_pending, passed, total}` — ROUTINE. The current plan's
        review-stage validations aren't all `passed` yet. Logged at
        debug; this fires on every eager transition.
      * `:member_not_in_review` — ROUTINE. The member hasn't reached
        `in_review` yet (the hook also runs from the retry sweep).
      * `:member_past_review` — ANOMALY. The member is at `deploying` /
        `done` with no stamp, which no sanctioned path can produce
        (`stamp_merged/2` drives the transition off the stamp). Logged
        at warning.

      Task 019fa3e0: the reason exists because a bare `{:ok, :not_ready}`
      made a PERMANENT block (a superseded plan's validations gating the
      merge forever) indistinguishable from "not finished yet". A failure
      mode that reports success is the expensive kind.

  Idempotency:

    * If the task already carries `metadata["merged_into_rollup_at"]`,
      returns `{:ok, :already_merged}` without invoking the runner.

  On a clean merge:

    * Stamps `task.metadata["merged_into_rollup_at"] = %{"sha" => sha,
      "at" => iso8601}` via `Tasks.update_task/2`. This indirectly
      triggers the in-stack `stack_pending` sweep through
      `Tasks.maybe_sweep_stack_after_update/2` (the same hook T4 wired).
    * Returns `{:ok, %{status: :merged, merge_sha: sha, merged_at: dt}}`.

  On non-fast-forward divergence (ADR-0042 Decision 2):

    * The runner emits `{:error, :not_fast_forwardable, %{member_sha,
      rollup_sha, output}}`. The deployer stamps
      `task.metadata["paused_reason"] = %{kind: "rollup_diverged", …}`,
      logs `Logger.error(...)`, emits a
      `[:platform, :stack_deployer, :not_fast_forwardable]` telemetry
      event, and returns `{:error, :not_fast_forwardable, %{member_sha,
      rollup_sha}}`. The stack status is UNCHANGED — other members
      can keep merging while this one waits for a human rebase.

  On conflict (practically unreachable under `--ff-only`):

    * The runner emits `{:error, :conflict, %{files: [...]}}`. The
      deployer flips the stack to `status: "blocked"` and writes
      `metadata.conflict = %{member_task_id, files, at}`. Logs a
      warning and emits a `[:platform, :stack_deployer, :conflict]`
      telemetry event.
    * Returns `{:error, :conflict, files}`. NO auto-resolve.

  On any other runner error:

    * Logs a warning and returns `{:error, reason}`. The stack is NOT
      flipped to blocked — runner failures other than conflict
      (network blips, auth misconfig, etc.) are likely retryable and
      shouldn't halt the whole stack.
  """
  @typedoc """
  Why the per-member rollup-merge gate declined.

  `{:stages_pending, passed, total}` counts ONLY the current plan's
  review-stage validations — superseded plan versions are out of scope
  (task 019fa3e0), so the counts double as a witness that the lookup is
  current-plan-scoped.
  """
  @type not_ready_reason ::
          :member_not_in_review
          | :member_past_review
          | {:stages_pending, non_neg_integer(), non_neg_integer()}

  @spec merge_member_into_rollup(TaskRecord.t() | binary()) ::
          {:ok, merge_result()}
          | {:ok, :already_merged}
          | {:ok, {:not_ready, not_ready_reason()}}
          | {:error, :not_fast_forwardable, %{member_sha: String.t(), rollup_sha: String.t()}}
          | {:error, :conflict, [String.t()]}
          | {:error,
             :not_in_stack
             | :stack_not_found
             | :project_not_found
             | :no_repo_url
             | :task_not_found
             | term()}
  def merge_member_into_rollup(task_id) when is_binary(task_id) do
    case Tasks.get_task_record(task_id) do
      %TaskRecord{} = task -> merge_member_into_rollup(task)
      nil -> {:error, :task_not_found}
    end
  end

  def merge_member_into_rollup(%TaskRecord{stack_id: nil}), do: {:error, :not_in_stack}

  def merge_member_into_rollup(%TaskRecord{stack_id: stack_id} = task) when is_binary(stack_id) do
    # `already_merged?/1` is deliberately consulted BEFORE readiness: a
    # stamped member at `deploying` must short-circuit as `:already_merged`
    # and never reach the `:member_past_review` alarm below.
    if already_merged?(task) do
      {:ok, :already_merged}
    else
      case review_readiness(task) do
        {:ready, ready_reason} ->
          report_merge_ready(task, ready_reason)

          with {:ok, %Stack{} = stack} <- load_stack(stack_id),
               {:ok, project} <- load_project(stack.project_id),
               :ok <- ensure_repo_url(project) do
            do_merge_member(task, stack, project.repo_url)
          end

        {:not_ready, reason} ->
          report_merge_not_ready(task, reason)
          {:ok, {:not_ready, reason}}
      end
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp do_create_rollup_branch(%Stack{} = stack, repo_url) do
    runner = git_runner()

    args = %{
      repo_url: repo_url,
      base_branch: stack.base_branch,
      rollup_branch: stack.rollup_branch,
      stack_id: stack.id,
      project_id: stack.project_id
    }

    Logger.info(
      "[StackDeployer] ensuring rollup branch #{stack.rollup_branch} from " <>
        "#{stack.base_branch} for stack #{stack.id} (#{repo_url})"
    )

    start_time = System.monotonic_time()

    # ADR-0042 Decision 2: serialize concurrent invocations for the SAME
    # stack via a per-stack `pg_advisory_xact_lock`. The collision
    # surface is parallel MCP `stack_create` + `stack_start`
    # fire-and-forget hooks both racing to `runner.ensure_rollup_branch/1`.
    # Different stacks hash to different keys (see :erlang.phash2 below)
    # so unrelated stacks do NOT block each other. Transaction-level
    # locks release on commit/rollback — no leak risk. Under the test
    # sandbox all callers share one connection so the lock is
    # re-entrant, but the runner Agent queue serializes responses
    # FIFO-style which preserves the observable contract.
    txn_result =
      Repo.transaction(fn ->
        lock_key = :erlang.phash2(stack.id, 2_147_483_647)
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

        case runner.ensure_rollup_branch(args) do
          {:ok, %{status: status, base_sha: base_sha}}
          when status in [:created, :already_exists] ->
            case status do
              :created ->
                Logger.info(
                  "[StackDeployer] created #{stack.rollup_branch} on #{repo_url}" <>
                    if(base_sha, do: " at #{base_sha}", else: "")
                )

              :already_exists ->
                Logger.info(
                  "[StackDeployer] rollup branch #{stack.rollup_branch} already exists on " <>
                    "#{repo_url} — treating as success"
                )
            end

            stamp_rollup_branch_ready(stack, base_sha)

            {status, base_sha}

          {:error, reason} ->
            Logger.warning(
              "[StackDeployer] failed to create rollup branch #{stack.rollup_branch} on " <>
                "#{repo_url}: #{inspect(reason)}"
            )

            Repo.rollback(reason)
        end
      end)

    case txn_result do
      {:ok, {status, base_sha}} ->
        result = %{
          branch: stack.rollup_branch,
          base_sha: base_sha,
          status: status,
          created_at: DateTime.utc_now()
        }

        emit_branch_created_telemetry(stack, base_sha, status, start_time)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ADR-0042 rollup-lifecycle telemetry. Fires on both `:created` and
  # `:already_exists` — the `status` metadata field distinguishes them.
  # Sits next to the existing `[:platform, :stack_deployer, ...]` events
  # so downstream consumers can subscribe to either taxonomy.
  defp emit_branch_created_telemetry(%Stack{} = stack, base_sha, status, start_time) do
    duration_us =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond)

    :telemetry.execute(
      [:platform, :stacks, :rollup, :branch_created],
      %{duration_us: duration_us},
      %{
        stack_id: stack.id,
        rollup_branch: stack.rollup_branch,
        base_branch: stack.base_branch,
        base_sha: base_sha,
        status: status
      }
    )

    :ok
  end

  # ADR-0042 Decision 2: after the rollup branch is confirmed live on origin
  # (either freshly created or already present), stamp
  # `stack.metadata["rollup_branch_ready"]` so the HeartbeatScheduler's
  # git-workflow prompt can safely retarget member branches from
  # `origin/#{rollup_branch}` instead of `origin/#{default_branch}`.
  #
  # The stamp is best-effort: if the metadata write fails we log a warning
  # and let the caller succeed anyway. The absence of the stamp simply keeps
  # members branching from `default_branch` (the existing ADR-0041 behaviour)
  # so members never dispatch against a non-existent rollup ref.
  defp stamp_rollup_branch_ready(%Stack{} = stack, base_sha) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    ready = %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "base_sha" => base_sha
    }

    new_meta = Map.put(base_meta, "rollup_branch_ready", ready)

    case Stacks.update_stack(stack, %{metadata: new_meta}) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] failed to stamp rollup_branch_ready on stack #{stack.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp log_create_result(%Stack{id: id}, {:ok, %{status: status, branch: branch}}) do
    Logger.info("[StackDeployer] stack #{id} rollup branch #{branch} ready (#{status})")
    :ok
  end

  defp log_create_result(%Stack{id: id}, {:error, reason}) do
    Logger.warning(
      "[StackDeployer] stack #{id} rollup branch creation failed: #{inspect(reason)}"
    )

    :ok
  end

  # ── merge_member_into_rollup internals ──────────────────────────────────

  defp already_merged?(%TaskRecord{metadata: %{} = metadata}) do
    case Map.get(metadata, "merged_into_rollup_at") do
      nil -> false
      "" -> false
      _value -> true
    end
  end

  defp already_merged?(_task), do: false

  # A task is "review ready" iff it is at `in_review` AND every
  # validation in any of its review-stage(s) is `passed`. A task with
  # no review-stage validations (no review stage at all, or one with
  # zero validations) is vacuously ready — the precondition is "no
  # blocking validations remain".
  #
  # Task 019fa3e0: this used to be a bare `review_ready?/1` boolean, and
  # the caller turned `false` into an unqualified `{:ok, :not_ready}`. That
  # collapsed four distinct situations — three routine, one an invariant
  # violation — into a single term that reads as "not finished yet". It is
  # why a permanent block presented exactly like the ordinary eager-fire
  # no-op. Both halves of the answer are now named: whether the gate
  # opened, and why.
  #
  # `{:ready, _}` reasons are as load-bearing as the not-ready ones:
  # `:no_current_plan` merges by default (see below) but is anomalous
  # enough to warrant a warning at the call site.
  #
  # PUBLIC-BUT-UNDOCUMENTED (task 019fa3e0 stage 5). Exposed with `@doc
  # false` — same treatment as `member_slug_for/1` — so the integration
  # tests can assert this gate's verdict DIRECTLY against the adjacent
  # `Stacks.member_review_validations_all_passed?/1`. Going through
  # `merge_member_into_rollup/1` would only observe the verdict through
  # the git-runner machinery, which is precisely the indirection that let
  # the two predicates drift apart unnoticed. Not part of the module's
  # supported surface; callers should use `merge_member_into_rollup/1`.
  @doc false
  @spec review_readiness(TaskRecord.t()) ::
          {:ready, :validations_passed | :no_review_stages | :no_current_plan}
          | {:not_ready, not_ready_reason()}
  def review_readiness(%TaskRecord{status: "in_review", id: task_id}) do
    case review_stage_ids_for_task(task_id) do
      # No current plan at all → ready-by-default, preserving the
      # behaviour that existed before this query was scoped. Making it
      # not-ready would strand every plan-less member permanently, which
      # is precisely the symptom this task exists to remove — so the
      # anomaly is made LOUD (see `report_merge_ready/2`) rather than
      # blocking.
      :no_current_plan ->
        {:ready, :no_current_plan}

      {:ok, []} ->
        {:ready, :no_review_stages}

      {:ok, ids} ->
        validations =
          Validation
          |> where([v], v.stage_id in ^ids)
          |> Repo.all()

        total = length(validations)
        passed = Enum.count(validations, &(&1.status == "passed"))

        if passed == total do
          {:ready, :validations_passed}
        else
          {:not_ready, {:stages_pending, passed, total}}
        end
    end
  end

  # ANOMALY. A member at `deploying`/`done` with no `merged_into_rollup_at`
  # stamp cannot be produced by any sanctioned path: `stamp_merged/2`
  # drives `Stacks.advance_member_to_deploying/1` off the stamp it just
  # wrote, and `member_deploy_transition_ready?/1` (stacks.ex) refuses an
  # unstamped member. Reaching here means that invariant broke. The gate
  # still declines — the repair stays a deliberate, human-authorised act —
  # but it now says so out loud instead of returning a bare `:not_ready`.
  def review_readiness(%TaskRecord{status: status}) when status in ["deploying", "done"] do
    {:not_ready, :member_past_review}
  end

  # ROUTINE. The member simply hasn't reached `in_review` yet; the hook
  # fires eagerly on transition and the retry sweep re-runs it.
  def review_readiness(_task), do: {:not_ready, :member_not_in_review}

  # LOG LEVEL IS THE WHOLE POINT (task 019fa3e0). The pre-existing line
  # was `Logger.debug`, so even a perfect reason string would have been
  # invisible at production log levels — the reason the ADR-0046 stall had
  # to be found by hand. But promoting the WHOLE family to warning would
  # be just as bad: `{:stages_pending, _, _}` fires on every eager
  # transition, and an alarm that cries wolf on every no-op is one
  # operators learn to filter, which reproduces the original blindness in
  # a new form. So the split is by KIND, not by severity of consequence:
  # "too early" is routine and stays at debug; "past the gate, unstamped"
  # is an invariant violation and warns.
  #
  # Telemetry is emitted for EVERY reason, including the routine ones —
  # unlike a log line, a counter tagged with `reason` is aggregated rather
  # than read, so consumers filter by reason and the routine rate is
  # itself useful (a sudden flat-line in `:stages_pending` means the hook
  # stopped firing).
  #
  # Emitted HERE rather than in `log_merge_result/2` on purpose:
  # `log_merge_result/2` only runs on the `handle_member_transition/3`
  # path, so an operator calling `merge_member_into_rollup/1` directly at
  # an iex prompt — exactly the 2026-07-27 investigation — would have seen
  # neither the log nor the event.
  defp report_merge_not_ready(%TaskRecord{id: id, status: status}, reason) do
    case reason do
      :member_past_review ->
        Logger.warning(
          "[StackDeployer] task #{id} is at #{status} with NO merged_into_rollup_at " <>
            "stamp; refusing rollup merge (reason=:member_past_review). This is an " <>
            "invariant violation — the stamp must precede the transition out of " <>
            "in_review. Investigate before re-stamping by hand."
        )

      {:stages_pending, passed, total} ->
        Logger.debug(
          "[StackDeployer] task #{id} not yet review-ready " <>
            "(#{passed}/#{total} current-plan review validations passed); " <>
            "deferring rollup merge"
        )

      :member_not_in_review ->
        Logger.debug(
          "[StackDeployer] task #{id} is at #{status}, not in_review; " <>
            "deferring rollup merge"
        )
    end

    :telemetry.execute(
      [:platform, :stack_deployer, :merge_not_ready],
      %{count: 1},
      %{task_id: id, status: status, reason: reason}
    )

    :ok
  end

  # The gate OPENED, but not always for a reassuring reason. A member with
  # no current plan is ready-by-default (preserving pre-019fa3e0
  # behaviour), yet "merged without any plan to gate on" is worth a
  # warning: it is the one ready-path that skips validation entirely.
  defp report_merge_ready(%TaskRecord{id: id}, :no_current_plan) do
    Logger.warning(
      "[StackDeployer] task #{id} has no current plan (Tasks.current_plan/1 " <>
        "returned nil); proceeding with rollup merge ready-by-default — no " <>
        "review validations were consulted"
    )

    :telemetry.execute(
      [:platform, :stack_deployer, :merge_ready_without_plan],
      %{count: 1},
      %{task_id: id}
    )

    :ok
  end

  defp report_merge_ready(%TaskRecord{}, _ready_reason), do: :ok

  # A task's review stages are the stages that HOST at least one
  # `e2e_behavior` validation — a structural fact, not a name match.
  # (Task 019fe383 stage 2; stage 1 made the equivalent change in
  # `PlanEngine`.) `PlanEngine.route_e2e_behavior_validations/1` routes
  # every e2e_behavior case in a plan onto exactly one stage (a
  # single-host invariant), so "hosts an e2e_behavior validation" is
  # both necessary and sufficient to identify that stage — no name
  # substring involved.
  #
  # NOT `stages.origin == "synthesized"`. That column also marks the
  # engine's OTHER synthesized stage — the remediation stage inserted by
  # `PlanEngine.insert_remediation_stage/3` after a failed behavioral
  # gate ("Address the failed behavioural gate") — which only ever
  # carries `test_pass`/`lint_pass` validations, never `e2e_behavior`.
  # Gating on `origin == "synthesized"` would silently start requiring
  # THAT stage's own validations too whenever it sits at a non-`passed`
  # status while the task is back at `in_review` — a behavior change the
  # old name-based code never exhibited (the remediation stage's name
  # contains neither "review" nor "validation"). Checking for a hosted
  # e2e_behavior validation instead stays exclusive to the true gate
  # stage by construction.
  #
  # NO BACKFILL / NO FALLBACK NEEDED: this reads validations that
  # already exist on every plan, old or new — a pre-existing in-flight
  # plan whose gate stage was adopted by the OLD name-match logic still
  # carries its `e2e_behavior` validations on that stage right now, so
  # this query recognizes it immediately with zero data migration.
  # Mirrors the precedent set by `20260908230000_add_origin_to_stages.exs`'s
  # moduledoc, which rejected a retroactive name-based reclassification
  # pass over old rows as "exactly the failure mode this column exists
  # to make impossible" — don't re-derive a structural fact from a name
  # here either.
  #
  # SCOPING (task 019fa3e0): the lookup is restricted to the task's
  # CURRENT plan via `Tasks.current_plan/1`. An unscoped join across
  # every plan version harvested review stages from superseded plans
  # too, whose validations stay `pending` forever because nothing will
  # ever run them — so any member that ever needed a plan v2 could
  # never satisfy the gate, and one such member blocks its whole
  # stack's rollup. `Stacks.member_review_validations_all_passed?/1`
  # already resolves through `current_plan/1`; this mirrors it rather
  # than hand-rolling a `status == "approved"` filter, which would
  # mis-handle a task whose latest plan sits at `pending_review`.
  #
  # Returns `:no_current_plan` rather than a bare `[]` so the caller can
  # distinguish "no plan to gate on" from "current plan has no review
  # stage" — two cases an empty list conflates.
  defp review_stage_ids_for_task(task_id) when is_binary(task_id) do
    case Tasks.current_plan(task_id) do
      nil ->
        :no_current_plan

      %{id: plan_id} ->
        ids =
          PlanStage
          |> where([s], s.plan_id == ^plan_id)
          |> join(:inner, [s], v in Validation, on: v.stage_id == s.id)
          |> where([_s, v], v.kind == "e2e_behavior")
          |> distinct([s], s.id)
          |> select([s], s.id)
          |> Repo.all()

        {:ok, ids}
    end
  end

  defp load_stack(stack_id) when is_binary(stack_id) do
    case Stacks.get_stack(stack_id) do
      %Stack{} = stack -> {:ok, stack}
      nil -> {:error, :stack_not_found}
    end
  end

  defp load_project(project_id) when is_binary(project_id) do
    case Tasks.get_project(project_id) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  defp ensure_repo_url(%{repo_url: url}) when is_binary(url) and url != "", do: :ok
  defp ensure_repo_url(_project), do: {:error, :no_repo_url}

  defp do_merge_member(%TaskRecord{} = task, %Stack{} = stack, repo_url) do
    runner = git_runner()
    member_branch = member_branch_for(task)
    member_slug = member_slug_for(task)

    args = %{
      repo_url: repo_url,
      rollup_branch: stack.rollup_branch,
      member_branch: member_branch,
      member_slug: member_slug,
      project_id: stack.project_id,
      stack_id: stack.id,
      member_task_id: task.id
    }

    Logger.info(
      "[StackDeployer] merging member #{task.id} branch #{member_branch} into " <>
        "#{stack.rollup_branch} for stack #{stack.id} (#{repo_url})"
    )

    # Gap 1 FIX 1 (task 019f921d): guarantee the rollup branch exists on
    # origin BEFORE the merge shell-out. A silently-lost async
    # `create_rollup_branch/1` (fired fire-and-forget from
    # `handle_stack_transition/3` / `handle_stack_created/1`) would
    # otherwise leave us merging into a non-existent ref, failing every
    # member merge and stranding the whole stack. `ensure_rollup_branch/1`
    # is idempotent (short-circuits on `:already_exists`). If the branch
    # cannot be made to exist, escalate rather than attempt the merge.
    case ensure_rollup_branch(stack) do
      {:ok, _ensure_result} ->
        do_merge_member_after_ensure(runner, task, stack, repo_url, member_branch, args)

      {:error, reason} ->
        Logger.error(
          "[StackDeployer] cannot merge member #{task.id}: rollup branch " <>
            "#{stack.rollup_branch} unavailable for stack #{stack.id}: #{inspect(reason)}"
        )

        {:error, {:rollup_branch_unavailable, reason}}
    end
  end

  defp do_merge_member_after_ensure(
         runner,
         %TaskRecord{} = task,
         %Stack{} = stack,
         repo_url,
         member_branch,
         args
       ) do
    # Stage 4 backstop (task 019f7b7e): last chance to notice that this
    # member is about to land a migration whose timestamp a sibling
    # already claimed. Advisory only — see `check_migration_collision/4`.
    check_migration_collision(runner, task, stack, repo_url)

    start_time = System.monotonic_time()

    case runner.merge_member_into_rollup(args) do
      {:ok, %{status: :merged, merge_sha: merge_sha}} ->
        emit_member_merged_telemetry(stack, task, member_branch, merge_sha, start_time)
        stamp_merged(task, merge_sha)

      {:error, :not_fast_forwardable, %{} = detail} ->
        record_divergence(stack, task, detail)

        {:error, :not_fast_forwardable,
         %{
           member_sha: Map.get(detail, :member_sha),
           rollup_sha: Map.get(detail, :rollup_sha)
         }}

      {:error, :conflict, %{files: files} = detail} ->
        record_conflict(stack, task, files, detail)
        {:error, :conflict, files}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] failed to merge member #{task.id} into #{stack.rollup_branch}: " <>
            "#{inspect(reason)}"
        )

        err
    end
  end

  # ── Rollup-time migration collision guard (task 019f7b7e stage 4) ───────
  #
  # Option 3 from the task description, implemented as a LOG-ONLY guard
  # rather than a rename. Compares the migration filenames this member
  # adds against those already merged onto the rollup branch by sibling
  # members, and reports any shared `YYYYMMDDHHMMSS` prefix.
  #
  # Deliberately does NOT halt the merge. By the time we get here the
  # reservation (stages 1-3) should already have prevented the
  # collision; if it didn't, a loud log plus a metadata stamp gives an
  # operator something to act on, whereas silently refusing to merge
  # would strand the whole stack. A rename here would mean mutating a
  # git tree mid-deploy — a much larger change, deliberately deferred
  # until this log is observed firing in practice.
  #
  # Every failure path is swallowed: a stale clone, a runner that
  # doesn't implement the callback, or an outright raise must never be
  # the reason a rollup merge fails.
  defp check_migration_collision(runner, %TaskRecord{} = task, %Stack{} = stack, repo_url) do
    if function_exported?(runner, :list_added_migrations, 1) do
      with {:ok, member_paths} <-
             runner.list_added_migrations(%{
               repo_url: repo_url,
               base_branch: stack.rollup_branch,
               head_branch: member_branch_for(task),
               project_id: stack.project_id
             }),
           {:ok, rollup_paths} <-
             runner.list_added_migrations(%{
               repo_url: repo_url,
               base_branch: stack.base_branch,
               head_branch: stack.rollup_branch,
               project_id: stack.project_id
             }) do
        case colliding_migrations(member_paths, rollup_paths) do
          [] -> :ok
          filenames -> record_migration_collision(stack, task, filenames)
        end
      else
        {:error, reason} ->
          Logger.debug(
            "[StackDeployer] migration collision pre-check skipped for member " <>
              "#{task.id}: #{inspect(reason)}"
          )

          :ok

        _other ->
          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "[StackDeployer] migration collision pre-check raised for member " <>
          "#{task.id}: #{inspect(error)}"
      )

      :ok
  end

  # A collision is two DIFFERENT migration filenames sharing the same
  # leading timestamp — that is precisely what makes Ecto skip one of
  # them. An identical filename on both sides just means the member's
  # branch already contains the sibling's merged migration (normal after
  # a rebase onto rollup), so it is explicitly not a collision.
  defp colliding_migrations(member_paths, rollup_paths) do
    rollup_by_ts =
      rollup_paths
      |> Enum.map(&Path.basename/1)
      |> Enum.group_by(&migration_timestamp/1)

    member_paths
    |> Enum.map(&Path.basename/1)
    |> Enum.flat_map(fn member_file ->
      case migration_timestamp(member_file) do
        nil ->
          []

        ts ->
          rollup_by_ts
          |> Map.get(ts, [])
          |> Enum.reject(&(&1 == member_file))
          |> Enum.map(&%{timestamp: ts, member_file: member_file, rollup_file: &1})
      end
    end)
  end

  defp migration_timestamp(filename) do
    case Regex.run(~r/^(\d{14})_/, filename) do
      [_, ts] -> ts
      _ -> nil
    end
  end

  defp record_migration_collision(%Stack{} = stack, %TaskRecord{} = task, collisions) do
    at_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    filenames =
      Enum.map(collisions, fn c ->
        %{
          "timestamp" => c.timestamp,
          "member_file" => c.member_file,
          "rollup_file" => c.rollup_file
        }
      end)

    payload = %{
      "at" => at_iso,
      "offender_task_id" => task.id,
      "filenames" => filenames
    }

    Logger.error(
      "[StackDeployer] migration filename collision at rollup-merge time: member " <>
        "#{task.id} adds #{inspect(Enum.map(collisions, & &1.member_file))} which shares a " <>
        "timestamp with already-merged #{inspect(Enum.map(collisions, & &1.rollup_file))} on " <>
        "#{stack.rollup_branch} (stack #{stack.id}). Merge is proceeding — Ecto will silently " <>
        "skip one of these migrations. Rename the member's migration and re-run."
    )

    case Stacks.update_stack(stack, %{
           metadata: Map.put(base_meta, "migration_collision", payload)
         }) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] migration collision detected for member #{task.id} but " <>
            "metadata stamp failed: #{inspect(reason)}"
        )

        :ok
    end

    :telemetry.execute(
      [:platform, :stack_deployer, :migration_collision],
      %{count: length(collisions)},
      %{stack_id: stack.id, member_task_id: task.id, filenames: filenames}
    )

    :ok
  end

  # ADR-0042 rollup-lifecycle telemetry. Fires exactly once per
  # successful per-member fast-forward merge into the rollup branch.
  # Sits next to `[:platform, :stack_deployer, :not_fast_forwardable]`
  # and `:conflict` — those cover the failure modes; this covers the
  # happy path.
  defp emit_member_merged_telemetry(
         %Stack{} = stack,
         %TaskRecord{} = task,
         member_branch,
         merge_sha,
         start_time
       ) do
    duration_us =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond)

    :telemetry.execute(
      [:platform, :stacks, :rollup, :member_merged],
      %{duration_us: duration_us},
      %{
        stack_id: stack.id,
        task_id: task.id,
        member_branch: member_branch,
        merge_sha: merge_sha
      }
    )

    :ok
  end

  @doc false
  # Member branch convention: `task/<slug>`, where `<slug>` comes from
  # `HeartbeatScheduler.member_slug/1` — the single chokepoint every
  # worktree/branch slug in the system routes through. That is the FULL task
  # uuid for every task, member or not (task 019fb949 removed the last
  # truncating branch; see `member_slug/1` for why 8 chars is ambiguous by
  # construction).
  #
  # This used to compute its own `short_id/1` (first hyphen-segment,
  # unconditionally) and a comment claimed it mirrored a since-deleted
  # `HeartbeatScheduler.short_task_id/1`. It mirrored the wrong
  # counterpart: dispatch creates member branches via `member_slug/1`, so
  # executors pushed `task/<full-uuid>` while the deployer fetched
  # `task/<8-char>` and got
  # `fatal: couldn't find remote ref task/019f9b27`. Worse, siblings minted
  # in one batch share a first hyphen-segment (four members of the live
  # ADR-0046 stack all collapsed to `task/019f9b28`), so the truncated form
  # is not merely wrong — it is ambiguous.
  #
  # `member_slug/1` reads nothing but `task.id` — not `tasks.stack_id`, not
  # the `:stack` association — so no preload is required here and the
  # full-uuid form is guaranteed regardless of what the caller loaded. (It
  # did consult `stack_membership/1` until task 019fb949; both call sites sit
  # under a `%TaskRecord{stack_id: stack_id} when is_binary(stack_id)` guard,
  # which is why the deployer was never exposed to the truncating branch.)
  #
  # The convention is documented in
  # 0045-task-stacks-v2.md § Branch model
  # and in the planner template. This citation previously named ADR 0041 in
  # the bare-number form, which resolved to nothing: ADR 0041 is the
  # org-memory wiki system, and no ADR in the tree carried a `Branch model`
  # heading at all. It survived because the bare form carries no filename, so
  # `adr_citation_audit_test.exs` — which resolves the anchored
  # `<file>.md § <heading>` form against the named ADR's real headings — had
  # nothing to latch onto. Task 019fb949 wrote the rule into ADR 0045 and
  # anchored the citation, so the heading is now pinned by that audit.
  #
  # Public (`@doc false`) so the regression test can pin the
  # sibling-collision case directly.
  def member_branch_for(%TaskRecord{id: id} = task) when is_binary(id) do
    "task/" <> member_slug_for(task)
  end

  @doc false
  def member_slug_for(%TaskRecord{id: id} = task) when is_binary(id) do
    HeartbeatScheduler.member_slug(task)
  end

  defp stamp_merged(%TaskRecord{metadata: metadata} = task, merge_sha) do
    base = if is_map(metadata), do: metadata, else: %{}
    merged_at = DateTime.utc_now()

    # Task 01a05392 stage 2: a member that merged is by definition no longer
    # diverged, so a stale `paused_reason` from an earlier
    # `:not_fast_forwardable` is cleared in the SAME write as the merge
    # stamp. One update, not two — no observer ever reads a task that is
    # both merged and paused.
    new_metadata =
      base
      |> Map.delete("paused_reason")
      |> Map.put("merged_into_rollup_at", %{
        "sha" => merge_sha,
        "at" => DateTime.to_iso8601(merged_at)
      })

    case Tasks.update_task(task, %{metadata: new_metadata}) do
      {:ok, updated} ->
        Logger.info(
          "[StackDeployer] stamped merged_into_rollup_at on task #{task.id} (sha=#{merge_sha})"
        )

        # Gap 2 (task 019f921d): advance this freshly-stamped member
        # `in_review -> deploying` CAUSALLY after its own merge stamp. The
        # deploy tail (`in_review -> deploying`) previously fired only on a
        # later validation-pass event (`maybe_retrigger_stack_member_merge`)
        # or the 5-min sweep — so a member whose async merge stamp landed
        # AFTER its validations passed got stranded at `in_review` (M2-M5),
        # while M6/M7 merely won that race. Driving the advance here, off
        # the stamp we just wrote, makes it deterministic and consistent for
        # EVERY member. `updated` carries the new stamp so
        # `member_deploy_transition_ready?/1` sees it. Idempotent +
        # log-and-swallow (advance self-guards on status/readiness, so the
        # redundant `maybe_retrigger_stack_member_merge` + periodic sweep
        # never double-transition).
        _ = Stacks.advance_member_to_deploying(updated)

        # Stage 4 hook: every successful per-member rollup merge fires
        # the stack-level PR-open gate. The gate is itself idempotent
        # and gates internally — it returns `:not_ready` while members
        # remain unmerged, and `:already_open` after the PR has been
        # created. We do this asynchronously so the merge return path
        # doesn't block on a `gh pr create` shell-out (or its retries).
        _ = trigger_maybe_open_stack_pr(task.stack_id)

        {:ok, %{status: :merged, merge_sha: merge_sha, merged_at: merged_at}}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] merged into rollup but failed to stamp metadata on task " <>
            "#{task.id}: #{inspect(reason)}"
        )

        err
    end
  end

  defp trigger_maybe_open_stack_pr(stack_id) when is_binary(stack_id) do
    if async?() do
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        log_pr_open_result(stack_id, maybe_open_stack_pr(stack_id))
      end)
    else
      log_pr_open_result(stack_id, maybe_open_stack_pr(stack_id))
      :ok
    end
  end

  defp trigger_maybe_open_stack_pr(_), do: :ok

  defp record_conflict(%Stack{} = stack, %TaskRecord{} = task, files, detail) do
    at_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    conflict_payload = %{
      "member_task_id" => task.id,
      "files" => files,
      "at" => at_iso
    }

    new_meta = Map.put(base_meta, "conflict", conflict_payload)

    case Stacks.update_stack(stack, %{status: "blocked", metadata: new_meta}) do
      {:ok, _updated_stack} ->
        Logger.warning(
          "[StackDeployer] CONFLICT merging member #{task.id} into " <>
            "#{stack.rollup_branch} (stack #{stack.id}); files=#{inspect(files)}; " <>
            "stack flipped to blocked"
        )

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] CONFLICT recorded but failed to flip stack #{stack.id} to " <>
            "blocked: #{inspect(reason)}; files=#{inspect(files)}"
        )
    end

    :telemetry.execute(
      [:platform, :stack_deployer, :conflict],
      %{file_count: length(files)},
      %{
        stack_id: stack.id,
        member_task_id: task.id,
        rollup_branch: stack.rollup_branch,
        files: files,
        output: Map.get(detail, :output)
      }
    )

    :ok
  end

  # ADR-0042 Decision 2 pause path. When `git merge --ff-only` refuses
  # because the member branch isn't a descendant of rollup HEAD, we do
  # NOT auto-rebase (that would silently rewrite an agent's commits —
  # see ADR-0042's atomic, human-legible-history requirement). Instead
  # we stamp the task with a `paused_reason` so ops can see WHY the
  # task is stuck and what SHAs to eyeball, and we leave the stack
  # status alone — other members can keep merging past this one.
  #
  # Task 01a05392 stage 2: the stamp alone was invisible to the agent that
  # owns the branch — nothing reads `paused_reason`, and the member sat in
  # `in_review` until a human noticed. So AFTER the stamp commits we file an
  # `execution.blocked` runtime event (needs_human, addressed to the
  # member's execution assignee) whose description carries the literal
  # rebase remediation and the retry call. Filed outside any Repo
  # transaction so no subscriber can read the task before the stamp lands.
  #
  # Double-file guard: a retry against an UNCHANGED rollup HEAD reproduces
  # the same fact, so an existing `rollup_diverged` stamp at the same
  # `rollup_sha` suppresses the second blocker. A different `rollup_sha`
  # means the rollup moved since — new information, filed again.
  defp record_divergence(%Stack{} = stack, %TaskRecord{} = task, %{} = detail) do
    member_sha = Map.get(detail, :member_sha)
    rollup_sha = Map.get(detail, :rollup_sha)
    output = Map.get(detail, :output)
    at_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    base_meta = if is_map(task.metadata), do: task.metadata, else: %{}

    already_filed? = divergence_already_filed?(base_meta, rollup_sha)

    paused_reason =
      %{
        "kind" => "rollup_diverged",
        "member_sha" => member_sha,
        "rollup_sha" => rollup_sha,
        "output" => output,
        "at" => at_iso
      }

    new_meta = Map.put(base_meta, "paused_reason", paused_reason)

    case Tasks.update_task(task, %{metadata: new_meta}) do
      {:ok, _updated} ->
        Logger.error(
          "[StackDeployer] task #{task.id} branch diverged from rollup " <>
            "#{stack.rollup_branch}; pausing task. Rebase task branch onto " <>
            "rollup HEAD to unstick."
        )

        if already_filed? do
          Logger.info(
            "[StackDeployer] task #{task.id} divergence at rollup #{rollup_sha} " <>
              "already has a blocker on file; not filing a second one"
          )
        else
          file_divergence_blocker(stack, task, member_sha, rollup_sha)
        end

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] task #{task.id} branch diverged from rollup " <>
            "#{stack.rollup_branch} but paused_reason stamp failed: #{inspect(reason)}"
        )
    end

    :telemetry.execute(
      [:platform, :stack_deployer, :not_fast_forwardable],
      %{count: 1},
      %{
        task_id: task.id,
        stack_id: stack.id,
        member_sha: member_sha,
        rollup_sha: rollup_sha
      }
    )

    :ok
  end

  defp divergence_already_filed?(%{"paused_reason" => %{} = paused}, rollup_sha)
       when is_binary(rollup_sha) do
    paused["kind"] == "rollup_diverged" and paused["rollup_sha"] == rollup_sha
  end

  defp divergence_already_filed?(_meta, _rollup_sha), do: false

  # The blocker must be actionable WITHOUT a further lookup: it names the
  # member, the rollup branch, both SHAs, the exact rebase, and the retry
  # call (`stack_retry_member_merge`, task 01a05392 stage 3). It is addressed
  # to the member's EXECUTION assignee — the agent whose branch it is —
  # falling back to the current-phase assignee.
  defp file_divergence_blocker(%Stack{} = stack, %TaskRecord{} = task, member_sha, rollup_sha) do
    assignee_id = execution_assignee_id(task)

    description =
      "Rollup merge for stack member #{task.id} is not fast-forwardable: branch " <>
        "#{member_branch_for(task)} (#{member_sha}) has diverged from rollup " <>
        "#{stack.rollup_branch} (#{rollup_sha}). Nothing retries this on its own. " <>
        "Remediation: `git fetch origin && git rebase origin/#{stack.rollup_branch} && " <>
        "git push --force-with-lease`, then call `stack_retry_member_merge` with " <>
        "task_id #{task.id}."

    record_merge_blocker(task, description, %{
      "kind" => "rollup_diverged",
      "assignee_id" => assignee_id,
      "member_task_id" => task.id,
      "stack_id" => stack.id,
      "rollup_branch" => stack.rollup_branch,
      "member_sha" => member_sha,
      "rollup_sha" => rollup_sha,
      "retry_tool" => "stack_retry_member_merge"
    })
  end

  defp execution_assignee_id(%TaskRecord{} = task) do
    phase_assignees = if is_map(task.phase_assignees), do: task.phase_assignees, else: %{}

    case get_in(phase_assignees, ["execution", "assignee_id"]) do
      id when is_binary(id) and id != "" -> id
      _ -> task.assignee_id
    end
  end

  defp log_merge_result(%TaskRecord{id: id}, {:ok, :already_merged}) do
    Logger.debug("[StackDeployer] task #{id} already merged into rollup; no-op")
    :ok
  end

  # Intentionally silent: `report_merge_not_ready/2` already logged this
  # outcome WITH its reason, at the level that reason deserves, from
  # inside `merge_member_into_rollup/1`. Logging again here would double
  # every line on the transition-hook path and would still leave the
  # direct-call path (iex, sweeps) silent. Kept as an explicit clause so
  # the catch-all `{:error, reason}` clause below can't swallow it.
  defp log_merge_result(%TaskRecord{}, {:ok, {:not_ready, _reason}}), do: :ok

  defp log_merge_result(%TaskRecord{id: id}, {:ok, %{status: :merged, merge_sha: sha}}) do
    Logger.info("[StackDeployer] task #{id} merged into rollup at #{sha}")
    :ok
  end

  defp log_merge_result(%TaskRecord{id: id}, {:error, :conflict, files}) do
    Logger.warning(
      "[StackDeployer] task #{id} rollup merge halted by conflict; files=#{inspect(files)}"
    )

    :ok
  end

  defp log_merge_result(%TaskRecord{id: id}, {:error, :not_fast_forwardable, %{} = shas}) do
    Logger.warning(
      "[StackDeployer] task #{id} rollup merge paused: branch diverged " <>
        "(member_sha=#{Map.get(shas, :member_sha)}, rollup_sha=#{Map.get(shas, :rollup_sha)})"
    )

    :ok
  end

  defp log_merge_result(%TaskRecord{id: id}, {:error, reason}) do
    Logger.warning("[StackDeployer] task #{id} rollup merge failed: #{inspect(reason)}")
    :ok
  end

  # ── maybe_open_stack_pr (stage 4) ───────────────────────────────────────

  @typedoc "Successful stack-level PR open result."
  @type pr_open_result :: %{
          required(:status) => :opened,
          required(:number) => pos_integer(),
          required(:url) => String.t()
        }

  @doc """
  Open the stack-level rollup PR if every member has merged into the
  rollup branch and the stack hasn't already opened one.

  Behavior:

    1. Loads the stack and its members.
    2. **Gate**: every member must have `metadata["merged_into_rollup_at"]`
       set AND `status in ["in_review", "deploying"]`. Otherwise returns
       `{:ok, :not_ready}` (no shell-out, no metadata churn).
    3. **Idempotency**: if `stack.metadata["rollup_pr"]` is already
       populated, returns `{:ok, :already_open}`.
    4. Persists `metadata["rollup_pr"] = %{status: "opening", at: iso}`
       and transitions the stack to `deploying` BEFORE the gh shell-out
       — this is the race-prevention measure: a concurrent caller (a
       parallel member-merge that fires this gate at the same time)
       sees `metadata["rollup_pr"]` already set and short-circuits to
       `:already_open`.
    5. Composes a PR title (`stack.name`) and body (member list with
       title + task URL + merge SHA, plus a `git diff --stat` summary
       from the runner). Body generation is best-effort — failures in
       the diff-stat helper degrade gracefully (the section is
       omitted).
    6. Calls `runner.open_stack_pr/1` to shell out to `gh pr create`.
    7. On success: persists the returned `number` + `url` on
       `metadata["rollup_pr"]` and returns
       `{:ok, %{status: :opened, number: n, url: url}}`.
    8. On failure: rolls back the placeholder metadata + status flip
       to avoid leaving the stack in a half-deployed state, then
       returns `{:error, reason}`.
  """
  @spec maybe_open_stack_pr(Stack.t() | binary()) ::
          {:ok, pr_open_result()}
          | {:ok, :not_ready}
          | {:ok, :already_open}
          | {:error,
             :stack_not_found
             | :project_not_found
             | :no_repo_url
             | term()}
  def maybe_open_stack_pr(stack_id) when is_binary(stack_id) do
    case load_stack(stack_id) do
      {:ok, %Stack{} = stack} -> maybe_open_stack_pr(stack)
      err -> err
    end
  end

  def maybe_open_stack_pr(%Stack{} = stack) do
    cond do
      pr_already_opened?(stack) ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} rollup PR already open " <>
            "(#{rollup_pr_url(stack) || "url unknown"}); skipping"
        )

        {:ok, :already_open}

      true ->
        members = Stacks.members(stack)

        cond do
          not all_members_ready?(members, stack) ->
            {:ok, :not_ready}

          not deploy_validations_ready?(stack) ->
            # Task 019f487d stage 3: opening the rollup PR requires
            # BOTH gates — every member branch merged into rollup
            # (`all_members_ready?/1`, the rollup-merge downstream
            # signal) AND every member's non-deploy validations
            # `passed` (`Stacks.deploy_ready?/1`, the upstream
            # validation-pass signal). This guards against opening a
            # PR before the validation set is complete even if the
            # rollup merges somehow raced ahead. Once the stack has
            # been transitioned to `"deploying"` via
            # `Stacks.dispatch_stack_deploy/1`, the validation gate
            # was, by construction, satisfied at dispatch time — so
            # the `"deploying"` status is itself a valid pass-through.
            {:ok, :not_ready}

          true ->
            do_open_stack_pr(stack, members)
        end
    end
  end

  # Validation-side readiness for opening the rollup PR.
  #
  # Either the stack has already been dispatched (status = `"deploying"`,
  # which encodes "validations were all passed at dispatch time"), OR the
  # pure `Stacks.deploy_ready?/1` predicate still reports `true`
  # (pre-dispatch happy path). Both branches guarantee the underlying
  # invariant: no validation on any live member's plan is still pending.
  defp deploy_validations_ready?(%Stack{status: "deploying"}), do: true
  defp deploy_validations_ready?(%Stack{} = stack), do: Stacks.deploy_ready?(stack)

  @doc """
  Success-path handler for the stack-level rollup PR being merged.

  Called by T6's webhook routing when GitHub fires
  `pull_request.closed` with `merged: true` for the stack's
  `rollup_branch`. Transitions the stack to `done` via
  `Stacks.update_stack/2`, cascades any not-yet-done members to
  `done` via `Stacks.cascade_members_to_done/1` (the T6 webhook
  fan-out normally handles this, but stack members without a
  `pr_merged` validation need the direct cascade), kicks off rollup
  branch cleanup, and emits deploy telemetry.

  Stage 5 (Stack v2) hardening:

    * Optional `merge_commit_sha` is threaded through to the
      `[:platform, :stacks, :deploy, :pr_merged]` telemetry event so
      dashboards can correlate the merged SHA back to the git-side
      artifact. `nil` is legal (the caller has none to hand in).
    * Duration is computed from `metadata["rollup_pr"]["opened_at"]`
      when present; `nil` when the stack skipped the `dispatch` path
      (e.g. a directly-invoked test seam).
    * Idempotency: keyed on `metadata["rollup_pr"]["merged_at"]`. Once
      this handler has stamped `merged_at`, replays short-circuit —
      no double telemetry, no double branch delete. A stack manually
      flipped to `done` via `Stacks.update_stack/2` (no rollup_pr
      metadata at all) is treated as "already done" and short-circuits
      too, preserving pre-stage-5 semantics for that seam.

  Returns `{:ok, stack}` on success or `{:error, reason}` on failure.
  """
  @spec handle_rollup_pr_merged(Stack.t() | binary()) ::
          {:ok, Stack.t()} | {:error, :stack_not_found | term()}
  def handle_rollup_pr_merged(stack_or_id) do
    handle_rollup_pr_merged(stack_or_id, nil)
  end

  @doc """
  Two-arity variant of `handle_rollup_pr_merged/1` that threads the
  rollup PR's `merge_commit_sha` into the deploy telemetry event.

  See `handle_rollup_pr_merged/1` for behavior. Preferred call site for
  the webhook path, which has the SHA in hand from the GitHub payload.
  """
  @spec handle_rollup_pr_merged(Stack.t() | binary(), String.t() | nil) ::
          {:ok, Stack.t()} | {:error, :stack_not_found | term()}
  def handle_rollup_pr_merged(stack_id, merge_commit_sha) when is_binary(stack_id) do
    case load_stack(stack_id) do
      {:ok, stack} -> handle_rollup_pr_merged(stack, merge_commit_sha)
      err -> err
    end
  end

  def handle_rollup_pr_merged(%Stack{status: "done"} = stack, merge_commit_sha) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}
    rollup_pr = Map.get(base_meta, "rollup_pr")

    cond do
      is_map(rollup_pr) and is_binary(Map.get(rollup_pr, "merged_at")) ->
        # Webhook replay: this stack already completed its rollup-merge
        # transition on a prior delivery (`metadata.rollup_pr.merged_at`
        # stamped). Task 019f5bc4-3521 (Case B fix) — every real webhook
        # delivery must still route through `cascade_members_to_done/2`
        # so the `[:platform, :stacks, :deploy, :cascade_completed]`
        # telemetry event fires with one-per-delivery parity. The
        # cascade helper's own idempotency (`reject(&(&1.status == "done"))`)
        # means member rows stay untouched and the event carries
        # `cascaded_count: 0`.
        #
        # We deliberately do NOT re-stamp `metadata.rollup_pr.merged_at`,
        # re-emit the legacy `:rollup_pr_merged` / uniform `:pr_merged`
        # telemetry, or re-kick the rollup-branch delete. Those all
        # represent "the stack just entered done" side-effects; the
        # cascade telemetry represents "the webhook was delivered".
        Logger.info(
          "[StackDeployer] stack #{stack.id} rollup-merge webhook replay " <>
            "(rollup_pr.merged_at already stamped); emitting :cascade_completed " <>
            "telemetry no-op, skipping merged_at re-stamp, :pr_merged re-emit, " <>
            "and branch-delete re-kick"
        )

        _ = Stacks.cascade_members_to_done(stack, :webhook)

        # TAIL-stall fix (2026-07-22): belt-and-braces sweep of any
        # `no_op_wait_for_rollup` member that reached `deploying` after the
        # first delivery already stamped `merged_at`. `cascade_members_to_done/2`
        # above is a one-shot fan-out; a member flipped to `deploying` late
        # (e.g. by the in_review stall sweep) needs this idempotent sweep to
        # reach `done`.
        _ = Stacks.sweep_deploying_members_to_done(stack)
        {:ok, stack}

      is_nil(rollup_pr) ->
        # Pre-stage-5 semantic (test seam): a stack manually flipped to
        # `done` with NO rollup_pr metadata is treated as "already done"
        # and short-circuits — this isn't a real webhook delivery for a
        # rollup PR (there's no rollup PR to speak of), so the per-webhook
        # cascade telemetry contract doesn't apply. Existing tests in
        # `stack_deployer_test.exs` rely on this shape (see
        # "idempotent on already-done stack" and "already-done stack does
        # NOT invoke delete") — a full route through
        # `cascade_members_to_done/2` here would either fire spurious
        # telemetry or, for status="done" test seams with lingering
        # non-done members, over-cascade.
        Logger.info(
          "[StackDeployer] stack #{stack.id} already done (no rollup_pr metadata); " <>
            "rollup-merge handler is no-op"
        )

        # TAIL-stall fix (2026-07-22): even on this previously-leaking no-op
        # branch, sweep any `no_op_wait_for_rollup` member stranded at
        # `deploying` to `done`. Idempotent — a stack whose members are all
        # already `done` sweeps nothing.
        _ = Stacks.sweep_deploying_members_to_done(stack)
        {:ok, stack}

      true ->
        # Status is done but rollup_pr.merged_at is not stamped — a caller
        # (e.g. the webhook's `complete_rollup_merge/2`) flipped status to
        # done without running this handler. Stamp merged_at + emit
        # telemetry + cascade + branch delete for this "half-done" case.
        # This is the first-time happy-path branch on the webhook route
        # (`fan_out_rollup_merge` → `complete_rollup_merge` flips to done
        # without touching `rollup_pr.merged_at`, so we always land here
        # on real first-time deliveries).
        do_handle_rollup_pr_merged(stack, merge_commit_sha)
    end
  end

  def handle_rollup_pr_merged(%Stack{} = stack, merge_commit_sha) do
    do_handle_rollup_pr_merged(stack, merge_commit_sha)
  end

  defp do_handle_rollup_pr_merged(%Stack{} = stack, merge_commit_sha) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}
    now = DateTime.utc_now()
    now_iso = DateTime.to_iso8601(now)

    rollup_pr_meta =
      case Map.get(base_meta, "rollup_pr") do
        %{} = m -> Map.put(m, "merged_at", now_iso)
        _ -> %{"merged_at" => now_iso}
      end

    new_meta = Map.put(base_meta, "rollup_pr", rollup_pr_meta)

    case Stacks.update_stack(stack, %{status: "done", metadata: new_meta}) do
      {:ok, updated} ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} rollup PR merged; stack transitioned to done"
        )

        # Preserve the legacy telemetry event for existing dashboards.
        :telemetry.execute(
          [:platform, :stack_deployer, :rollup_pr_merged],
          %{count: 1},
          %{stack_id: stack.id, rollup_branch: stack.rollup_branch}
        )

        # Stage 5 (Stack v2): new namespaced `:stacks, :deploy, :pr_merged`
        # event with uniform metric shape %{stack_id, member_count,
        # duration_ms_in_deploying, merge_commit_sha} — matches the
        # :dispatched (stage 3) and :pr_rejected (stage 4) event shapes
        # so dashboards can build one uniform deploy-lifecycle panel.
        cascade = Stacks.cascade_members_to_done(updated, :webhook)

        # TAIL-stall fix (2026-07-22): after the one-shot fan-out, sweep any
        # `no_op_wait_for_rollup` member left at `deploying` to `done`. The
        # cascade above flips every not-done member, but a member that lands
        # at `deploying` on a later tick still needs this idempotent sweep.
        _ = Stacks.sweep_deploying_members_to_done(updated)

        member_count = length(Stacks.members(updated))
        duration_ms = deploy_duration_ms_in_deploying(base_meta, now)

        emit_pr_merged_telemetry(updated, member_count, duration_ms, merge_commit_sha)

        if cascade.skipped != [] do
          Logger.warning(
            "[StackDeployer] stack #{updated.id} rollup PR merged but " <>
              "#{length(cascade.skipped)} member(s) could not be cascaded to done: " <>
              inspect(cascade.skipped)
          )
        end

        # ADR 0045 rollup branch lifecycle ("On merge, `stack/<name>` is
        # deleted"): delete the rollup branch on merge. Best-effort — a failure here does NOT undo the `status
        # → done` transition. On async: false (tests) we run
        # synchronously so callers can observe the runner interaction.
        _ = kick_off_rollup_branch_delete(updated)

        {:ok, updated}

      {:error, _changeset} = err ->
        Logger.warning(
          "[StackDeployer] failed to flip stack #{stack.id} to done after rollup PR merge"
        )

        err
    end
  end

  # Compute `duration_ms_in_deploying` from the stack's pre-merge
  # `metadata["rollup_pr"]["opened_at"]` stamp. That timestamp is
  # written by `finalize_pr_opened/4` when the rollup PR opens, so it
  # is the canonical "stack entered deploy" marker. `nil` when the
  # stack never went through the dispatch path (e.g. tests that seed
  # `status: "deploying"` directly without an `opened_at` timestamp).
  defp deploy_duration_ms_in_deploying(base_meta, %DateTime{} = now) do
    with %{} = rollup_pr <- Map.get(base_meta, "rollup_pr"),
         opened_at when is_binary(opened_at) <- Map.get(rollup_pr, "opened_at"),
         {:ok, %DateTime{} = opened_dt, _} <- DateTime.from_iso8601(opened_at) do
      DateTime.diff(now, opened_dt, :millisecond)
    else
      _ -> nil
    end
  end

  defp emit_pr_merged_telemetry(
         %Stack{id: stack_id, rollup_branch: rollup_branch},
         member_count,
         duration_ms,
         merge_commit_sha
       ) do
    :telemetry.execute(
      [:platform, :stacks, :deploy, :pr_merged],
      %{count: 1, duration_ms_in_deploying: duration_ms},
      %{
        stack_id: stack_id,
        rollup_branch: rollup_branch,
        member_count: member_count,
        duration_ms_in_deploying: duration_ms,
        merge_commit_sha: merge_commit_sha
      }
    )

    :ok
  end

  # Fire-and-forget rollup-branch cleanup after the stack has flipped
  # to `done`. Loads the project inside the async task so the caller
  # of `handle_rollup_pr_merged/1` isn't blocked by a repo lookup.
  #
  # ADR 0045: `stack.abandon` deliberately leaves the rollup branch in
  # place for human-driven cleanup, so this helper is only invoked from
  # the merged-success path.
  defp kick_off_rollup_branch_delete(%Stack{} = stack) do
    if async?() do
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        do_delete_rollup_branch(stack)
      end)
    else
      do_delete_rollup_branch(stack)
      :ok
    end
  end

  defp do_delete_rollup_branch(%Stack{} = stack) do
    with {:ok, project} <- load_project(stack.project_id),
         :ok <- ensure_repo_url(project) do
      runner = git_runner()

      args = %{
        repo_url: project.repo_url,
        rollup_branch: stack.rollup_branch,
        project_id: stack.project_id,
        stack_id: stack.id
      }

      start_time = System.monotonic_time()

      case runner.delete_rollup_branch(args) do
        {:ok, :deleted} ->
          Logger.info(
            "[StackDeployer] deleted rollup branch #{stack.rollup_branch} for " <>
              "stack #{stack.id} on #{project.repo_url}"
          )

          :telemetry.execute(
            [:platform, :stack_deployer, :rollup_branch_deleted],
            %{count: 1},
            %{stack_id: stack.id, rollup_branch: stack.rollup_branch}
          )

          emit_branch_deleted_telemetry(stack, :deleted, start_time)

          :ok

        {:ok, :already_absent} ->
          Logger.info(
            "[StackDeployer] rollup branch #{stack.rollup_branch} for stack " <>
              "#{stack.id} already absent on #{project.repo_url}"
          )

          emit_branch_deleted_telemetry(stack, :already_absent, start_time)

          :ok

        {:error, reason} ->
          Logger.warning(
            "[StackDeployer] failed to delete rollup branch #{stack.rollup_branch} " <>
              "for stack #{stack.id}: #{inspect(reason)} — stack remains done; " <>
              "ops cleanup required"
          )

          :telemetry.execute(
            [:platform, :stack_deployer, :rollup_branch_delete_failed],
            %{count: 1},
            %{
              stack_id: stack.id,
              rollup_branch: stack.rollup_branch,
              reason: reason
            }
          )

          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] skipping rollup-branch delete for stack #{stack.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  # ADR-0042 rollup-lifecycle telemetry. Fires on both `:deleted` and
  # `:already_absent` — the `status` metadata field distinguishes them.
  # Does NOT fire on runner errors (those already emit
  # `[:platform, :stack_deployer, :rollup_branch_delete_failed]`).
  defp emit_branch_deleted_telemetry(%Stack{} = stack, status, start_time) do
    duration_us =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond)

    :telemetry.execute(
      [:platform, :stacks, :rollup, :branch_deleted],
      %{duration_us: duration_us},
      %{
        stack_id: stack.id,
        rollup_branch: stack.rollup_branch,
        status: status
      }
    )

    :ok
  end

  # ── handle_rollup_ci_failure (stage 5) ──────────────────────────────────

  @typedoc """
  Caller-supplied CI failure context. `:ci_run_url` is the canonical
  GitHub URL for the failing run (used for both idempotency keying
  and the metadata audit trail); `:head_sha` is the commit the failing
  CI run was triggered against (used by the attribution heuristic to
  bound the search window).
  """
  @type ci_failure_args :: %{
          required(:ci_run_url) => String.t(),
          required(:head_sha) => String.t()
        }

  @typedoc "Successful CI-failure bounce result."
  @type bounce_result :: %{
          required(:status) => :bounced,
          required(:bounced_task_ids) => [String.t()],
          required(:revert_sha) => String.t() | nil
        }

  @doc """
  Bounce EVERY stack member back to `in_progress` after the
  stack-level rollup PR's CI failed. This is the ship-or-no-ship
  guarantee: if the rollup PR fails, no member rides forward alone.

  See module-level docs for the ordering. Returns:

    * `{:ok, %{status: :bounced, bounced_task_ids, revert_sha}}` on a
      clean bounce. `bounced_task_ids` lists every member that was
      transitioned back to `in_progress`.
    * `{:ok, :already_bounced}` if every member with a merge stamp
      already carries `bounced_from_rollup[ci_run_url]` matching
      this run (replay-safe webhook handling).
    * `{:ok, :no_candidate}` if no member has a
      `merged_into_rollup_at` stamp (nothing was on the rollup —
      atomic bounce is a no-op).
    * `{:error, reason}` on any unrecoverable failure (project load,
      revert, transition).
  """
  @spec handle_rollup_ci_failure(Stack.t() | binary(), ci_failure_args()) ::
          {:ok, bounce_result()}
          | {:ok, :already_bounced}
          | {:ok, :no_candidate}
          | {:error,
             :stack_not_found
             | :project_not_found
             | :no_repo_url
             | term()}
  def handle_rollup_ci_failure(stack_id, %{} = args) when is_binary(stack_id) do
    case load_stack(stack_id) do
      {:ok, stack} -> handle_rollup_ci_failure(stack, args)
      err -> err
    end
  end

  def handle_rollup_ci_failure(%Stack{} = stack, %{ci_run_url: ci_run_url, head_sha: head_sha})
      when is_binary(ci_run_url) and is_binary(head_sha) do
    with {:ok, project} <- load_project(stack.project_id),
         :ok <- ensure_repo_url(project) do
      members = Stacks.members(stack)

      cond do
        # Idempotency guard runs FIRST so a replayed webhook after a
        # completed bounce (where every member has already lost its
        # `merged_into_rollup_at` stamp) still short-circuits to
        # `:already_bounced` rather than falling through to
        # `:no_candidate`.
        all_members_already_bounced?(members, ci_run_url) ->
          Logger.info(
            "[StackDeployer] stack #{stack.id} already fully bounced for " <>
              "ci_run_url=#{ci_run_url}; no-op"
          )

          {:ok, :already_bounced}

        true ->
          case pick_offender(members, head_sha, stack, project.repo_url) do
            {:ok, offender} ->
              do_atomic_bounce(stack, members, offender, project.repo_url, ci_run_url, head_sha)

            {:error, :no_candidate} ->
              Logger.warning(
                "[StackDeployer] stack #{stack.id} CI failure (#{ci_run_url}) but no merged " <>
                  "member found; no-op"
              )

              {:ok, :no_candidate}
          end
      end
    end
  end

  # ── handle_rollup_ci_failure internals ─────────────────────────────────

  # Pick the most-recently-merged member whose merge landed before
  # (or at) the failing run's head_sha. Heuristic: we use the
  # `merged_into_rollup_at.at` timestamp ordering as a proxy for
  # reachability — every member with a stamp was merged into the
  # rollup branch chronologically, so the merge SHAs are linearly
  # ordered along the branch. Anything stamped is a candidate; we
  # log when there's ambiguity (>1 candidate).
  defp pick_offender([], _head_sha, _stack, _repo_url), do: {:error, :no_candidate}

  defp pick_offender(members, head_sha, %Stack{} = stack, repo_url) when is_list(members) do
    candidates =
      members
      |> Enum.filter(&has_merged_stamp?/1)
      |> Enum.sort_by(&merged_at_iso/1, :desc)

    case candidates do
      [] ->
        {:error, :no_candidate}

      [only] ->
        maybe_log_pick_offender_unreachable(only, stack, repo_url)
        {:ok, only}

      [first | rest] ->
        Logger.warning(
          "[StackDeployer] CI attribution heuristic: bouncing #{first.id} as " <>
            "last-merged-before-failure (head_sha=#{head_sha}); review may be required " <>
            "(#{length(rest)} other candidate(s): #{Enum.map_join(rest, ",", & &1.id)})"
        )

        maybe_log_pick_offender_unreachable(first, stack, repo_url)
        {:ok, first}
    end
  end

  # Bug #2 (task 019f708f): `pick_offender` is a CI-failure heuristic
  # where the stamp is the only ordering signal — leave it, but log a
  # warning if the picked offender's stamp isn't actually reachable
  # from the rollup tip. This preserves the bounce (ops still needs
  # SOMETHING to revert) while surfacing the fabricated-stamp condition
  # in the log stream for post-mortem review.
  defp maybe_log_pick_offender_unreachable(
         %TaskRecord{
           id: task_id,
           metadata: %{"merged_into_rollup_at" => %{"sha" => sha}}
         },
         %Stack{rollup_branch: rollup_branch, project_id: project_id},
         repo_url
       )
       when is_binary(sha) and sha != "" and is_binary(rollup_branch) and rollup_branch != "" and
              is_binary(repo_url) and repo_url != "" do
    args = %{
      repo_url: repo_url,
      rollup_branch: rollup_branch,
      sha: sha,
      project_id: project_id
    }

    case git_runner().sha_reachable?(args) do
      {:ok, false} ->
        Logger.warning(
          "[StackDeployer] pick_offender: picked task #{task_id} but its stamp sha " <>
            "#{sha} is NOT reachable from #{rollup_branch}; proceeding with bounce " <>
            "on stamp-order heuristic — review revert target manually"
        )

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] pick_offender: reachability check failed for #{task_id} " <>
            "(sha=#{sha}, rollup=#{rollup_branch}): #{inspect(reason)}"
        )

      _ ->
        :ok
    end

    :ok
  end

  defp maybe_log_pick_offender_unreachable(_task, _stack, _repo_url), do: :ok

  defp has_merged_stamp?(%TaskRecord{metadata: %{"merged_into_rollup_at" => %{"sha" => sha}}})
       when is_binary(sha) and sha != "",
       do: true

  defp has_merged_stamp?(_), do: false

  defp merged_at_iso(%TaskRecord{metadata: %{"merged_into_rollup_at" => %{"at" => at}}})
       when is_binary(at),
       do: at

  defp merged_at_iso(_), do: ""

  defp already_bounced?(%TaskRecord{metadata: meta}, ci_run_url) when is_map(meta) do
    case Map.get(meta, "bounced_from_rollup") do
      %{"ci_run_url" => ^ci_run_url} -> true
      _ -> false
    end
  end

  defp already_bounced?(_task, _ci_run_url), do: false

  # Idempotency guard: the atomic bounce is considered "already done"
  # when every member of the stack carries the matching `ci_run_url`
  # bounce stamp. Since the atomic bounce stamps EVERY member (merged
  # or not), replaying the same webhook finds every member stamped
  # and short-circuits.
  defp all_members_already_bounced?([], _ci_run_url), do: false

  defp all_members_already_bounced?(members, ci_run_url) do
    Enum.all?(members, &already_bounced?(&1, ci_run_url))
  end

  defp do_atomic_bounce(
         %Stack{} = stack,
         members,
         %TaskRecord{} = offender,
         repo_url,
         ci_run_url,
         head_sha
       ) do
    offender_merge_sha = offender.metadata["merged_into_rollup_at"]["sha"]

    Logger.info(
      "[StackDeployer] atomic-bouncing stack #{stack.id} (#{length(members)} member(s)) after " <>
        "rollup CI failure (offender=#{offender.id} merge_sha=#{offender_merge_sha}, " <>
        "ci_run_url=#{ci_run_url}); reverting only the most-recently-merged commit — earlier " <>
        "merges are cleared via stack-level PR close + rollup rebuild on the next cycle."
    )

    with {:ok, revert_sha} <- revert_offender_merge(stack, offender, repo_url, offender_merge_sha),
         {:ok, bounced_ids} <- bounce_all_members(members, ci_run_url, head_sha),
         _ = close_rollup_pr(stack, repo_url, offender, ci_run_url),
         {:ok, _updated_stack} <- flip_stack_to_in_progress_for_bounce(stack) do
      :telemetry.execute(
        [:platform, :stacks, :deploy, :pr_rejected],
        %{count: 1, member_count: length(members)},
        %{
          stack_id: stack.id,
          member_count: length(members),
          ci_run_url: ci_run_url,
          revert_sha: revert_sha
        }
      )

      # Preserve the legacy telemetry name for existing dashboards.
      :telemetry.execute(
        [:platform, :stack_deployer, :ci_failure_bounce],
        %{count: 1},
        %{
          stack_id: stack.id,
          bounced_task_ids: bounced_ids,
          ci_run_url: ci_run_url,
          merge_sha: offender_merge_sha,
          revert_sha: revert_sha
        }
      )

      {:ok,
       %{
         status: :bounced,
         bounced_task_ids: bounced_ids,
         revert_sha: revert_sha
       }}
    end
  end

  # Stamp `bounced_from_rollup` on every member, clear
  # `merged_into_rollup_at`, and transition each back to
  # `"in_progress"`. Returns the list of task ids that were touched.
  # Failure to stamp or transition any single member is fatal to the
  # bounce so we surface the error to the caller.
  defp bounce_all_members(members, ci_run_url, head_sha) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, acc} ->
      merge_sha = get_in(member.metadata || %{}, ["merged_into_rollup_at", "sha"])

      with {:ok, stamped} <-
             stamp_bounce_and_clear_merge(member, ci_run_url, head_sha, merge_sha),
           {:ok, _transitioned} <- bounce_member_to_in_progress(stamped) do
        {:cont, {:ok, [member.id | acc]}}
      else
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      err -> err
    end
  end

  defp revert_offender_merge(%Stack{} = stack, %TaskRecord{} = offender, repo_url, merge_sha)
       when is_binary(merge_sha) and merge_sha != "" do
    runner = git_runner()

    args = %{
      repo_url: repo_url,
      rollup_branch: stack.rollup_branch,
      merge_sha: merge_sha,
      project_id: stack.project_id,
      stack_id: stack.id,
      member_task_id: offender.id
    }

    cond do
      not function_exported?(runner, :revert_member_merge, 1) ->
        {:error, {:runner_missing_callback, :revert_member_merge}}

      true ->
        case runner.revert_member_merge(args) do
          {:ok, %{status: :reverted, revert_sha: revert_sha}} when is_binary(revert_sha) ->
            Logger.info(
              "[StackDeployer] reverted merge #{merge_sha} on #{stack.rollup_branch} " <>
                "(revert_sha=#{revert_sha})"
            )

            {:ok, revert_sha}

          {:error, reason} = err ->
            Logger.warning(
              "[StackDeployer] failed to revert merge #{merge_sha} on " <>
                "#{stack.rollup_branch} for stack #{stack.id}: #{inspect(reason)}"
            )

            err
        end
    end
  end

  defp revert_offender_merge(_stack, _offender, _repo_url, _sha),
    do: {:error, :missing_merge_sha}

  defp stamp_bounce_and_clear_merge(
         %TaskRecord{metadata: metadata} = task,
         ci_run_url,
         head_sha,
         merge_sha
       ) do
    base = if is_map(metadata), do: metadata, else: %{}

    new_meta =
      base
      |> Map.delete("merged_into_rollup_at")
      |> Map.put("bounced_from_rollup", %{
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "ci_run_url" => ci_run_url,
        "head_sha" => head_sha,
        "sha" => merge_sha
      })

    case Tasks.update_task(task, %{metadata: new_meta}) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] failed to stamp bounce metadata on task #{task.id}: #{inspect(reason)}"
        )

        err
    end
  end

  defp bounce_member_to_in_progress(%TaskRecord{status: "in_progress"} = task) do
    # Already there (unmerged member OR a prior partial bounce). No-op.
    {:ok, task}
  end

  defp bounce_member_to_in_progress(%TaskRecord{} = task) do
    case Tasks.transition_task(task, "in_progress") do
      {:ok, transitioned} ->
        {:ok, transitioned}

      {:error, :invalid_transition} ->
        # `in_review -> in_progress` and `deploying -> in_progress`
        # are both allowed (see @valid_task_transitions). This
        # branch is reached only if the task has been transitioned
        # to a terminal state (done / cancelled). Log and treat as a
        # soft success — the task isn't where we expected but we
        # don't want to crash the atomic bounce over one member's
        # concurrent transition.
        Logger.warning(
          "[StackDeployer] atomic-bounce: task #{task.id} not at a status allowing return to " <>
            "in_progress (current=#{task.status}); leaving as-is"
        )

        {:ok, task}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] atomic-bounce: failed to transition task #{task.id} to in_progress: " <>
            "#{inspect(reason)}"
        )

        err
    end
  end

  defp close_rollup_pr(%Stack{} = stack, repo_url, %TaskRecord{} = offender, ci_run_url) do
    case stack.metadata do
      %{"rollup_pr" => %{"number" => number}} when is_integer(number) and number > 0 ->
        runner = git_runner()

        if function_exported?(runner, :close_stack_pr, 1) do
          args = %{
            repo_url: repo_url,
            pr_number: number,
            project_id: stack.project_id,
            stack_id: stack.id,
            comment:
              "Closing rollup PR: CI failed (#{ci_run_url}); bouncing member " <>
                "#{offender.id} back to in_progress. Stack deployer will reopen the " <>
                "PR once the bounced member re-merges."
          }

          case runner.close_stack_pr(args) do
            {:ok, :closed} ->
              Logger.info(
                "[StackDeployer] closed rollup PR ##{number} for stack #{stack.id} " <>
                  "(post-CI-failure bounce)"
              )

              :ok

            {:error, reason} ->
              Logger.warning(
                "[StackDeployer] failed to close rollup PR ##{number} for stack " <>
                  "#{stack.id}: #{inspect(reason)} (continuing — bounce is non-fatal)"
              )

              :ok
          end
        else
          Logger.warning(
            "[StackDeployer] runner missing close_stack_pr callback; skipping PR close " <>
              "for stack #{stack.id}"
          )

          :ok
        end

      _ ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} has no rollup_pr.number on metadata; skipping " <>
            "PR close"
        )

        :ok
    end
  end

  # Flip the stack from `deploying` back to `in_progress` (NOT
  # `in_review`) AND clear the `rollup_pr` metadata. The atomic
  # bounce puts every member back to `in_progress`, so the stack
  # regresses in lockstep — the next `maybe_open_stack_pr/1` cycle
  # opens a fresh PR after fixes land. Preserves the rest of the
  # metadata (any conflict record from earlier, etc.).
  defp flip_stack_to_in_progress_for_bounce(%Stack{} = stack) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}
    cleared = Map.delete(base_meta, "rollup_pr")

    case Stacks.update_stack(stack, %{status: "in_progress", metadata: cleared}) do
      {:ok, updated} ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} flipped #{stack.status} -> in_progress " <>
            "(post-CI-failure atomic bounce)"
        )

        {:ok, updated}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] failed to flip stack #{stack.id} to in_progress post-bounce: " <>
            "#{inspect(reason)}"
        )

        err
    end
  end

  # ── maybe_open_stack_pr internals ───────────────────────────────────────

  defp pr_already_opened?(%Stack{metadata: meta}) when is_map(meta) do
    case Map.get(meta, "rollup_pr") do
      %{} = pr -> Map.has_key?(pr, "number") or Map.get(pr, "status") == "opening"
      _ -> false
    end
  end

  defp pr_already_opened?(_stack), do: false

  defp rollup_pr_url(%Stack{metadata: %{"rollup_pr" => %{"url" => url}}}) when is_binary(url),
    do: url

  defp rollup_pr_url(_), do: nil

  defp all_members_ready?([], _stack), do: false

  defp all_members_ready?(members, %Stack{} = stack) when is_list(members) do
    Enum.all?(members, &member_ready_for_pr?/1) and
      Enum.all?(members, &member_sha_reachable?(&1, stack))
  end

  # Gap 4 (task 019f921d): the stack-PR-open readiness gate now delegates to
  # the SHARED `Stacks.member_landed_on_rollup?/1` predicate so it can never
  # drift from the dep-clearance gate (`Stacks.threshold_cleared?/1`) again.
  # This widens acceptance to a `done` member (previously only
  # `in_review`/`deploying`) and to a bare-string `merged_into_rollup_at`
  # stamp (previously only a `%{"sha" => _}` map) — the exact
  # genuinely-finished shape that was being rejected, leaving the stack
  # stuck at `deploying` with no rollup PR. The sha git-reachability check
  # for MAP-shaped stamps is preserved separately in `member_sha_reachable?/2`
  # (a bare-string stamp skips it, matching `dep_sha_reachable?/5`).
  defp member_ready_for_pr?(%TaskRecord{} = member), do: Stacks.member_landed_on_rollup?(member)

  defp member_ready_for_pr?(_member), do: false

  # Bug #2 (task 019f708f): gate the stack-PR-open path on ground-truth
  # sha reachability. A fabricated `merged_into_rollup_at` stamp
  # otherwise trips `all_members_ready?/2` and opens a PR that omits
  # the member's actual code. Only stamps with an extractable SHA are
  # verified — that's guaranteed because `member_ready_for_pr?/1`
  # requires a map-shaped stamp for the base case to return true.
  defp member_sha_reachable?(
         %TaskRecord{
           id: task_id,
           metadata: %{"merged_into_rollup_at" => %{"sha" => sha}}
         },
         %Stack{rollup_branch: rollup_branch, project_id: project_id} = _stack
       )
       when is_binary(sha) and sha != "" and is_binary(rollup_branch) and rollup_branch != "" do
    case load_project(project_id) do
      {:ok, %{repo_url: repo_url}} when is_binary(repo_url) and repo_url != "" ->
        check_member_sha_reachable(task_id, sha, repo_url, rollup_branch, project_id)

      _ ->
        # No repo_url configured for the project — reachability check
        # is not meaningful. Fall through to the stamp-presence check
        # already done by `member_ready_for_pr?/1`.
        true
    end
  end

  # No SHA extractable from the stamp — `member_ready_for_pr?/1` will
  # have already returned false, so this branch is defensive.
  defp member_sha_reachable?(_task, _stack), do: true

  defp check_member_sha_reachable(task_id, sha, repo_url, rollup_branch, project_id) do
    args = %{
      repo_url: repo_url,
      rollup_branch: rollup_branch,
      sha: sha,
      project_id: project_id
    }

    case git_runner().sha_reachable?(args) do
      {:ok, true} ->
        true

      {:ok, false} ->
        Logger.warning(
          "[StackDeployer] all_members_ready?: task #{task_id} stamp sha #{sha} " <>
            "not reachable from #{rollup_branch}; treating as unmerged"
        )

        false

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] all_members_ready?: reachability check failed for task " <>
            "#{task_id} (sha=#{sha}, rollup=#{rollup_branch}): #{inspect(reason)} — " <>
            "treating as unmerged"
        )

        false
    end
  end

  defp do_open_stack_pr(%Stack{} = stack, members) do
    with {:ok, project} <- load_project(stack.project_id),
         :ok <- ensure_repo_url(project),
         {:ok, locked_stack} <- lock_stack_for_pr(stack),
         body = build_pr_body(locked_stack, members, project.repo_url),
         {:ok, %{number: number, url: url}} <-
           call_open_pr(locked_stack, project.repo_url, body) do
      finalize_pr_opened(locked_stack, project, number, url)
    else
      {:error, :already_locked} ->
        # Task 01a05394 stage 4: a concurrent caller won the CAS in
        # `lock_stack_for_pr/1`. Its `open_stack_pr` is in flight or
        # already finalized — do NOT roll back; that would clear the
        # winner's placeholder and drop the stack to `in_review` under
        # a live PR. Short-circuit to the same result a fresh read
        # would have produced.
        Logger.info("[StackDeployer] stack #{stack.id} rollup PR lock already held; skipping")

        {:ok, :already_open}

      {:error, reason} = err ->
        # Best-effort rollback of the placeholder metadata + status
        # flip so a transient gh failure doesn't strand the stack
        # mid-deploy. We re-load the stack to avoid clobbering any
        # concurrent updates.
        rollback_pr_lock(stack.id)

        Logger.warning(
          "[StackDeployer] failed to open stack PR for #{stack.id} (#{stack.rollup_branch}): " <>
            "#{inspect(reason)}"
        )

        err

      {:error, _, _} = conflict_err ->
        rollback_pr_lock(stack.id)

        Logger.warning(
          "[StackDeployer] open_stack_pr unexpected conflict: #{inspect(conflict_err)}"
        )

        conflict_err
    end
  end

  # Persist a placeholder `metadata.rollup_pr = %{status: "opening"}`
  # and flip status -> "deploying" BEFORE the gh shell-out. This is
  # the race-prevention guard: two concurrent invocations both pass
  # the gate, but only one wins this update; the other re-loads,
  # sees status == "deploying" + rollup_pr present, and bails via
  # the `:already_open` short-circuit.
  #
  # Task 01a05394 stage 4: this is a compare-and-swap, not a
  # read-then-update. The WHERE carries the guard (`metadata ->
  # 'rollup_pr' IS NULL`) so two callers holding the same stale
  # struct — both of which passed `pr_already_opened?/1` — cannot
  # both write the placeholder. The row is the arbiter, not the
  # struct. Mirrors the status CAS in `Stacks.dispatch_stack_deploy/1`.
  # The loser gets `{:error, :already_locked}`, which the caller maps
  # to `:already_open` WITHOUT touching `rollback_pr_lock/1`.
  defp lock_stack_for_pr(%Stack{} = stack) do
    now = DateTime.utc_now()

    placeholder = %{
      "rollup_pr" => %{
        "status" => "opening",
        "at" => DateTime.to_iso8601(now)
      }
    }

    {count, _} =
      from(s in Stack,
        where:
          s.id == ^stack.id and
            fragment("(? -> 'rollup_pr') IS NULL", s.metadata),
        update: [
          set: [
            status: "deploying",
            metadata:
              fragment(
                "COALESCE(?, '{}'::jsonb) || ?",
                s.metadata,
                type(^placeholder, :map)
              ),
            updated_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])

    case count do
      1 ->
        case Stacks.get_stack(stack.id) do
          %Stack{} = locked -> {:ok, locked}
          nil -> {:error, :stack_not_found}
        end

      0 ->
        {:error, :already_locked}
    end
  end

  defp call_open_pr(%Stack{} = stack, repo_url, body) do
    runner = git_runner()

    args = %{
      repo_url: repo_url,
      base_branch: stack.base_branch,
      rollup_branch: stack.rollup_branch,
      title: stack.name,
      body: body,
      project_id: stack.project_id,
      stack_id: stack.id
    }

    if function_exported?(runner, :open_stack_pr, 1) do
      runner.open_stack_pr(args)
    else
      {:error, {:runner_missing_callback, :open_stack_pr}}
    end
  end

  # Task 01a05394 stage 5: auto-merge is NOT armed for rollup PRs.
  # `GitRunner.open_stack_pr/1` runs `gh pr create` only; nothing on
  # this path ever runs `gh pr merge --auto`. Whether `--auto` is even
  # armable depends on the target repo's branch protection (absent on
  # some repos, present on core since 2026-08), and this path does not
  # probe it. A project whose deploy config sets `auto_merge: true`
  # gets task-level auto-merge (`Platform.Tasks.AutoMerger`, unaffected
  # here) and nothing at the rollup level: a human or the merge webhook
  # / `Stacks.reconcile_merged_rollups/0` poll has to land the PR. The
  # `auto_merge_armed: false` stamp and the warning below exist so that
  # belief cannot be held quietly. Arming here is a separate decision.
  defp finalize_pr_opened(%Stack{} = stack, project, number, url)
       when is_integer(number) and is_binary(url) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    pr_meta = %{
      "number" => number,
      "url" => url,
      "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "auto_merge_armed" => false
    }

    new_meta = Map.put(base_meta, "rollup_pr", pr_meta)

    case Stacks.update_stack(stack, %{metadata: new_meta}) do
      {:ok, updated} ->
        Logger.info("[StackDeployer] stack #{stack.id} rollup PR opened: ##{number} #{url}")

        if auto_merge_configured?(project) do
          Logger.warning(
            "[StackDeployer] stack #{stack.id} rollup PR ##{number}: project deploy " <>
              "config sets auto_merge: true, but stack rollup PRs do not arm auto-merge " <>
              "(this path never runs `gh pr merge --auto`; task-level AutoMerger is " <>
              "unaffected). The PR requires a human or webhook-driven merge."
          )
        end

        :telemetry.execute(
          [:platform, :stack_deployer, :pr_opened],
          %{count: 1},
          %{stack_id: stack.id, rollup_branch: stack.rollup_branch, pr_number: number, url: url}
        )

        {:ok, %{status: :opened, number: number, url: url, stack: updated}}

      {:error, reason} ->
        Logger.warning(
          "[StackDeployer] PR ##{number} opened but failed to persist metadata on stack " <>
            "#{stack.id}: #{inspect(reason)}"
        )

        {:error, {:metadata_persist_failed, reason}}
    end
  end

  # Reads `auto_merge` the same way `DispatchPhase.agent_unpassable?/2`
  # and `HeartbeatScheduler` do (`config` first, falling back to the
  # strategy itself) so the three never disagree about where the key
  # lives. The stack has no single task to resolve a strategy through,
  # so the project-wide `deploy_config["default_strategy"]` is the
  # resolved config here.
  defp auto_merge_configured?(project) do
    deploy_config = Map.get(project, :deploy_config) || %{}

    case Map.get(deploy_config, "default_strategy") do
      %{} = strategy ->
        config = Map.get(strategy, "config")
        Map.get(config || strategy, "auto_merge", false) == true

      _ ->
        false
    end
  end

  # Task 01a05394 stage 4: a no-op unless the CURRENT `rollup_pr` is
  # still the `%{"status" => "opening"}` placeholder this module wrote
  # in `lock_stack_for_pr/1`. A stack carrying a real `rollup_pr.number`
  # is never moved — the pre-read check is kept, and the write itself
  # re-checks the same predicate in its WHERE so a `finalize_pr_opened/4`
  # that lands between the read and the write cannot be clobbered.
  # Public (`@doc false`) so the invariant is directly testable.
  @doc false
  def rollback_pr_lock(stack_id) when is_binary(stack_id) do
    case Stacks.get_stack(stack_id) do
      %Stack{metadata: meta} when is_map(meta) ->
        case Map.get(meta, "rollup_pr") do
          %{"status" => "opening"} = placeholder when not is_map_key(placeholder, "number") ->
            # Roll status back to in_review (the most-conservative
            # rollup state given members are merged but PR didn't
            # open). NOT back to in_progress: the merge already
            # happened, members are at in_review.
            _ =
              from(s in Stack,
                where:
                  s.id == ^stack_id and
                    fragment("(? -> 'rollup_pr' ->> 'status') = 'opening'", s.metadata) and
                    fragment("(? -> 'rollup_pr' -> 'number') IS NULL", s.metadata),
                update: [
                  set: [
                    status: "in_review",
                    metadata: fragment("? - 'rollup_pr'", s.metadata),
                    updated_at: ^DateTime.utc_now()
                  ]
                ]
              )
              |> Repo.update_all([])

            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp build_pr_body(%Stack{} = stack, members, repo_url) do
    member_lines = Enum.map(members, &member_line/1)

    member_section =
      case member_lines do
        [] -> "_no members_"
        lines -> Enum.join(lines, "\n")
      end

    diff_section =
      case fetch_diff_stat(stack, repo_url) do
        {:ok, ""} -> ""
        {:ok, summary} -> "\n\n## Diff stat\n\n```\n#{summary}\n```"
        {:error, _} -> ""
      end

    """
    Rollup PR for stack **#{stack.name}** (`#{stack.rollup_branch}` → `#{stack.base_branch}`).

    #{planning_gate_section(members)}## Members

    #{member_section}#{diff_section}

    ---
    _Opened by Startup Suite stack deployer._
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # ADR-0046 member 4, stage 4 — WRITER 1.
  #
  # The rollup PR body is composed here, server-side, and handed
  # pre-formatted to `GitRunner.open_stack_pr/1` (see `git_runner.ex`:
  # the runner generates neither title nor body). That makes it the one
  # PR surface no agent in the loop can quietly drop — which is the
  # whole point: a `Logger.warning` at merge time is read by nobody.
  #
  # ONLY `"failed"` renders. `"not_applicable"` is the progressive-
  # enhancement path (nobody holds the responsibility) and must never be
  # conflated with a gate that was expected to run and didn't
  # (`0046-design-and-architecture-phases-in-planning.md § Per-step outcome`).
  # The distinction is not re-derived from
  # `planning_step_outcomes` here — `Tasks.failed_planning_steps/1` is
  # the single definition, so this renderer cannot drift from the
  # auto-merge guard in `AutoMerger.execute_merge/4`.
  #
  # When no member has a failed gate this returns `""` — no empty
  # heading, so a clean stack's body is byte-identical to the pre-ADR
  # body.
  defp planning_gate_section(members) do
    case Enum.flat_map(members, &planning_gate_lines/1) do
      [] ->
        ""

      lines ->
        "## ⚠️ Gates that did not run\n\n" <>
          Enum.join(lines, "\n") <>
          "\n\nThese planning steps were expected to run and failed to dispatch. " <>
          "They are dispatch failures, NOT skips — a step nobody holds is recorded " <>
          "as `not_applicable` and is deliberately not listed here. Review the " <>
          "corresponding change by hand before merging.\n\n"
    end
  end

  defp planning_gate_lines(%TaskRecord{} = task) do
    title = task.title || "(untitled)"

    Enum.map(Tasks.failed_planning_steps(task), fn %{step: step, detail: detail} ->
      "- **#{title}** — `#{step}` — #{detail || "no detail recorded"}"
    end)
  end

  defp member_line(%TaskRecord{} = task) do
    sha =
      case task.metadata do
        %{"merged_into_rollup_at" => %{"sha" => sha}} when is_binary(sha) -> sha
        _ -> "unknown"
      end

    title = task.title || "(untitled)"
    url = task_url(task)
    "- [#{title}](#{url}) — sha #{sha}#{planning_gate_marker(task)}"
  end

  # Names the step(s) rather than hardcoding "ARCHITECTURE": the design
  # gate lands with ADR-0046 member 7 and this marker must not lie about
  # which gate went missing when it does.
  defp planning_gate_marker(%TaskRecord{} = task) do
    case Tasks.failed_planning_steps(task) do
      [] ->
        ""

      steps ->
        names = Enum.map_join(steps, " + ", &String.upcase(&1.step))
        noun = if length(steps) > 1, do: "GATES DID NOT RUN", else: "GATE DID NOT RUN"
        " — ⚠️ #{names} #{noun}"
    end
  end

  defp task_url(%TaskRecord{id: id}) when is_binary(id) do
    "#{endpoint_url()}/tasks/#{id}"
  end

  defp endpoint_url do
    if Code.ensure_loaded?(PlatformWeb.Endpoint) and
         function_exported?(PlatformWeb.Endpoint, :url, 0) do
      try do
        PlatformWeb.Endpoint.url()
      rescue
        _ -> ""
      end
    else
      ""
    end
  end

  defp fetch_diff_stat(%Stack{} = stack, repo_url) do
    runner = git_runner()

    args = %{
      repo_url: repo_url,
      base_branch: stack.base_branch,
      rollup_branch: stack.rollup_branch,
      project_id: stack.project_id
    }

    if function_exported?(runner, :diff_stat, 1) do
      try do
        runner.diff_stat(args)
      rescue
        e ->
          Logger.warning("[StackDeployer] diff_stat raised for stack #{stack.id}: #{inspect(e)}")

          {:error, :diff_stat_raised}
      end
    else
      {:error, :runner_missing_diff_stat}
    end
  end

  defp log_pr_open_result(stack_id, {:ok, %{status: :opened, number: n, url: url}}) do
    Logger.info("[StackDeployer] async stack PR open succeeded for #{stack_id}: ##{n} #{url}")

    :ok
  end

  defp log_pr_open_result(stack_id, {:ok, :not_ready}) do
    Logger.debug("[StackDeployer] stack #{stack_id} not all members merged yet; PR open deferred")
    :ok
  end

  defp log_pr_open_result(stack_id, {:ok, :already_open}) do
    Logger.debug("[StackDeployer] stack #{stack_id} rollup PR already open; skipping")
    :ok
  end

  defp log_pr_open_result(stack_id, {:error, reason}) do
    Logger.warning(
      "[StackDeployer] async stack PR open failed for #{stack_id}: #{inspect(reason)}"
    )

    :ok
  end

  defp log_pr_open_result(_stack_id, _other), do: :ok

  @doc """
  Public accessor for the configured git runner module.

  Exposed so sibling modules (e.g. `Platform.Tasks.Stacks` for the
  bug-#2 reachability gate in `unblocked_in_stack?/1`) can invoke
  runner callbacks without duplicating the config lookup.
  """
  @spec git_runner() :: module()
  def git_runner do
    config()
    |> Keyword.get(:git_runner, @default_runner)
  end

  defp async? do
    config()
    |> Keyword.get(:async, true)
  end

  defp task_supervisor do
    config()
    |> Keyword.get(:task_supervisor, Platform.TaskSupervisor)
  end

  defp config do
    Application.get_env(:platform, :stack_deployer, [])
  end
end
