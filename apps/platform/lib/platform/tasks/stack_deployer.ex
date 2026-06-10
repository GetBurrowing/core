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

  On conflict the runner reports `{:error, :conflict, %{files}}` and
  the deployer halts the stack: stack `status -> "blocked"` and
  `metadata.conflict` records the offending member, file list, and
  timestamp. No auto-resolve is attempted.

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

  ## Stage 5 (this module's added surface)

  `handle_rollup_ci_failure/2` is the failure path T6 will call when
  the GitHub `check_run` / `check_suite` webhook (or the `ci_passed`
  validation evaluation pipeline) reports a failing CI run for a PR
  whose head is the stack's `rollup_branch`.

  The heuristic attribution + bounce protocol:

    1. **Identify offender** — load all stack members ordered by
       `metadata["merged_into_rollup_at"]["at"]` descending. The
       offender is the most-recently-merged member whose merge SHA
       was already on the rollup branch when the failing CI run
       fired (we approximate "reachable from head_sha" by including
       any merge whose timestamp is at-or-before the run). If
       multiple merges fit the window the most-recent is picked and
       an `[StackDeployer] CI attribution heuristic: ...` warning is
       logged.
    2. **Bounce** — clear the offender's
       `metadata["merged_into_rollup_at"]`; revert the offender's
       merge commit on `rollup_branch` via the runner; transition
       the offender back to `in_progress`; stamp
       `metadata["bounced_from_rollup"] = %{at, ci_run_url, sha}`.
    3. **Close the rollup PR** so the next
       `maybe_open_stack_pr/1` cycle opens a fresh PR after the
       bounced member re-merges.
    4. **Flip the stack** back to `in_review`.

  Other members KEEP their `merged_into_rollup_at` stamps and remain
  `in_review`. There is no retry loop — the bounced member is picked
  up by the normal dispatcher.

  Idempotent: if the offender already carries
  `metadata["bounced_from_rollup"]["ci_run_url"]` matching the
  invocation's `ci_run_url`, the function no-ops.

  ## Test injection

  Git operations are dispatched through a runner module configurable
  via `:platform, :stack_deployer, git_runner: Module`. The default
  runner is `Platform.Tasks.StackDeployer.GitShellRunner`, which
  shells out to `git`. Tests substitute an in-memory runner.
  """

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks}
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
        log_merge_result(task, merge_member_into_rollup(task))
      end)
    else
      log_merge_result(task, merge_member_into_rollup(task))
      :ok
    end
  end

  def handle_member_transition(%TaskRecord{}, _from, _to), do: :ok

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
      `{:ok, :not_ready}`. (`:not_ready` is intentionally an `:ok`
      result: the engine fires this hook eagerly on transition; if
      review validations haven't all passed yet, this is the expected
      no-op outcome.)

  Idempotency:

    * If the task already carries `metadata["merged_into_rollup_at"]`,
      returns `{:ok, :already_merged}` without invoking the runner.

  On a clean merge:

    * Stamps `task.metadata["merged_into_rollup_at"] = %{"sha" => sha,
      "at" => iso8601}` via `Tasks.update_task/2`. This indirectly
      triggers the in-stack `stack_pending` sweep through
      `Tasks.maybe_sweep_stack_after_update/2` (the same hook T4 wired).
    * Returns `{:ok, %{status: :merged, merge_sha: sha, merged_at: dt}}`.

  On conflict:

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
  @spec merge_member_into_rollup(TaskRecord.t() | binary()) ::
          {:ok, merge_result()}
          | {:ok, :already_merged}
          | {:ok, :not_ready}
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
    cond do
      already_merged?(task) ->
        {:ok, :already_merged}

      not review_ready?(task) ->
        {:ok, :not_ready}

      true ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_id),
             {:ok, project} <- load_project(stack.project_id),
             :ok <- ensure_repo_url(project) do
          do_merge_member(task, stack, project.repo_url)
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

    case runner.ensure_rollup_branch(args) do
      {:ok, %{status: status, base_sha: base_sha}} when status in [:created, :already_exists] ->
        result = %{
          branch: stack.rollup_branch,
          base_sha: base_sha,
          status: status,
          created_at: DateTime.utc_now()
        }

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

        {:ok, result}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] failed to create rollup branch #{stack.rollup_branch} on " <>
            "#{repo_url}: #{inspect(reason)}"
        )

        err
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
  defp review_ready?(%TaskRecord{status: "in_review", id: task_id}) do
    review_stage_ids = review_stage_ids_for_task(task_id)

    case review_stage_ids do
      [] ->
        true

      ids ->
        validations =
          Validation
          |> where([v], v.stage_id in ^ids)
          |> Repo.all()

        Enum.all?(validations, &(&1.status == "passed"))
    end
  end

  defp review_ready?(_task), do: false

  # A task's review stages are the stages whose name marks them as a
  # review/validation stage in the plan. Mirrors the heuristic used
  # elsewhere (e.g. `PlanEngine.attach_e2e_validations_to_review_stage/2`):
  # name contains "review" or "validation", and is NOT a "Deploy:"
  # stage. Stack members never reach a Deploy stage in the per-member
  # path anyway, but the filter is kept conservative.
  defp review_stage_ids_for_task(task_id) when is_binary(task_id) do
    PlanStage
    |> join(:inner, [s], p in Platform.Tasks.Plan, on: p.id == s.plan_id)
    |> where([s, p], p.task_id == ^task_id)
    |> select([s, _p], %{id: s.id, name: s.name})
    |> Repo.all()
    |> Enum.filter(&review_stage?/1)
    |> Enum.map(& &1.id)
  end

  defp review_stage?(%{name: nil}), do: false

  defp review_stage?(%{name: name}) when is_binary(name) do
    lower = String.downcase(name)

    not String.starts_with?(lower, "deploy:") and
      (String.contains?(lower, "review") or String.contains?(lower, "validation"))
  end

  defp review_stage?(_), do: false

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

    case runner.merge_member_into_rollup(args) do
      {:ok, %{status: :merged, merge_sha: merge_sha}} ->
        stamp_merged(task, merge_sha)

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

  # Member branch convention: `task/<short_id>` where `<short_id>` is
  # the first hyphen-segment of the task uuid. Mirrors
  # `Platform.Orchestration.HeartbeatScheduler.short_task_id/1`. The
  # convention is documented in ADR 0041 §"Branch model" and in the
  # planner template.
  defp member_branch_for(%TaskRecord{id: id}) when is_binary(id) do
    "task/" <> short_id(id)
  end

  defp member_slug_for(%TaskRecord{id: id}) when is_binary(id), do: short_id(id)

  defp short_id(id) when is_binary(id) do
    id |> String.split("-") |> List.first()
  end

  defp stamp_merged(%TaskRecord{metadata: metadata} = task, merge_sha) do
    base = if is_map(metadata), do: metadata, else: %{}
    merged_at = DateTime.utc_now()

    new_metadata =
      Map.put(base, "merged_into_rollup_at", %{
        "sha" => merge_sha,
        "at" => DateTime.to_iso8601(merged_at)
      })

    case Tasks.update_task(task, %{metadata: new_metadata}) do
      {:ok, _updated} ->
        Logger.info(
          "[StackDeployer] stamped merged_into_rollup_at on task #{task.id} (sha=#{merge_sha})"
        )

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

  defp log_merge_result(%TaskRecord{id: id}, {:ok, :already_merged}) do
    Logger.debug("[StackDeployer] task #{id} already merged into rollup; no-op")
    :ok
  end

  defp log_merge_result(%TaskRecord{id: id}, {:ok, :not_ready}) do
    Logger.debug("[StackDeployer] task #{id} not yet review-ready; deferring rollup merge")

    :ok
  end

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

        if all_members_ready?(members) do
          do_open_stack_pr(stack, members)
        else
          {:ok, :not_ready}
        end
    end
  end

  @doc """
  Success-path handler for the stack-level rollup PR being merged.

  Called by T6's webhook routing when GitHub fires
  `pull_request.closed` with `merged: true` for the stack's
  `rollup_branch`. Transitions the stack to `done` via
  `Stacks.update_stack/2`. Member-status fan-out is owned by T6
  (each member's per-task `pr_merged` validation auto-passes off the
  same webhook), not by this function.

  Returns `{:ok, stack}` on success or `{:error, reason}` on failure.
  Idempotent: if the stack is already `done`, returns `{:ok, stack}`.
  """
  @spec handle_rollup_pr_merged(Stack.t() | binary()) ::
          {:ok, Stack.t()} | {:error, :stack_not_found | term()}
  def handle_rollup_pr_merged(stack_id) when is_binary(stack_id) do
    case load_stack(stack_id) do
      {:ok, stack} -> handle_rollup_pr_merged(stack)
      err -> err
    end
  end

  def handle_rollup_pr_merged(%Stack{status: "done"} = stack) do
    Logger.info("[StackDeployer] stack #{stack.id} already done; rollup-merge handler is no-op")
    {:ok, stack}
  end

  def handle_rollup_pr_merged(%Stack{} = stack) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    rollup_pr_meta =
      case Map.get(base_meta, "rollup_pr") do
        %{} = m -> Map.put(m, "merged_at", DateTime.utc_now() |> DateTime.to_iso8601())
        _ -> %{"merged_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
      end

    new_meta = Map.put(base_meta, "rollup_pr", rollup_pr_meta)

    case Stacks.update_stack(stack, %{status: "done", metadata: new_meta}) do
      {:ok, updated} ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} rollup PR merged; stack transitioned to done"
        )

        :telemetry.execute(
          [:platform, :stack_deployer, :rollup_pr_merged],
          %{count: 1},
          %{stack_id: stack.id, rollup_branch: stack.rollup_branch}
        )

        {:ok, updated}

      {:error, _changeset} = err ->
        Logger.warning(
          "[StackDeployer] failed to flip stack #{stack.id} to done after rollup PR merge"
        )

        err
    end
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
          required(:bounced_task_id) => String.t(),
          required(:revert_sha) => String.t() | nil
        }

  @doc """
  Bounce the offending member back to `in_progress` after the
  stack-level rollup PR's CI failed.

  See module-level docs for the heuristic and ordering. Returns:

    * `{:ok, %{status: :bounced, bounced_task_id, revert_sha}}` on a
      clean bounce.
    * `{:ok, :already_bounced}` if the most-recently-merged member is
      already stamped with this `ci_run_url`.
    * `{:ok, :no_candidate}` if no member has a
      `merged_into_rollup_at` stamp (nothing to bounce).
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
         :ok <- ensure_repo_url(project),
         members = Stacks.members(stack),
         {:ok, offender} <- pick_offender(members, head_sha) do
      if already_bounced?(offender, ci_run_url) do
        Logger.info(
          "[StackDeployer] stack #{stack.id} member #{offender.id} already bounced for " <>
            "ci_run_url=#{ci_run_url}; no-op"
        )

        {:ok, :already_bounced}
      else
        do_bounce_offender(stack, offender, project.repo_url, ci_run_url, head_sha)
      end
    else
      {:error, :no_candidate} ->
        Logger.warning(
          "[StackDeployer] stack #{stack.id} CI failure (#{ci_run_url}) but no merged " <>
            "member found to bounce; no-op"
        )

        {:ok, :no_candidate}

      {:error, _reason} = err ->
        err
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
  defp pick_offender([], _head_sha), do: {:error, :no_candidate}

  defp pick_offender(members, head_sha) when is_list(members) do
    candidates =
      members
      |> Enum.filter(&has_merged_stamp?/1)
      |> Enum.sort_by(&merged_at_iso/1, :desc)

    case candidates do
      [] ->
        {:error, :no_candidate}

      [only] ->
        {:ok, only}

      [first | rest] ->
        Logger.warning(
          "[StackDeployer] CI attribution heuristic: bouncing #{first.id} as " <>
            "last-merged-before-failure (head_sha=#{head_sha}); review may be required " <>
            "(#{length(rest)} other candidate(s): #{Enum.map_join(rest, ",", & &1.id)})"
        )

        {:ok, first}
    end
  end

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

  defp do_bounce_offender(
         %Stack{} = stack,
         %TaskRecord{} = offender,
         repo_url,
         ci_run_url,
         head_sha
       ) do
    merge_sha = offender.metadata["merged_into_rollup_at"]["sha"]

    Logger.info(
      "[StackDeployer] bouncing member #{offender.id} from stack #{stack.id} rollup " <>
        "(merge_sha=#{merge_sha}, ci_run_url=#{ci_run_url})"
    )

    with {:ok, revert_sha} <- revert_offender_merge(stack, offender, repo_url, merge_sha),
         {:ok, bounced_task} <-
           stamp_bounce_and_clear_merge(offender, ci_run_url, head_sha, merge_sha),
         {:ok, _transitioned} <-
           bounce_member_to_in_progress(bounced_task),
         _ = close_rollup_pr(stack, repo_url, offender, ci_run_url),
         {:ok, _updated_stack} <- flip_stack_to_in_review_for_bounce(stack) do
      :telemetry.execute(
        [:platform, :stack_deployer, :ci_failure_bounce],
        %{count: 1},
        %{
          stack_id: stack.id,
          bounced_task_id: offender.id,
          ci_run_url: ci_run_url,
          merge_sha: merge_sha,
          revert_sha: revert_sha
        }
      )

      {:ok,
       %{
         status: :bounced,
         bounced_task_id: offender.id,
         revert_sha: revert_sha
       }}
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
    # Already there (manual transition raced us, or the dispatcher
    # already grabbed it). Treat as success.
    {:ok, task}
  end

  defp bounce_member_to_in_progress(%TaskRecord{} = task) do
    case Tasks.transition_task(task, "in_progress") do
      {:ok, transitioned} ->
        {:ok, transitioned}

      {:error, :invalid_transition} ->
        # `in_review -> in_progress` IS allowed (see @valid_task_transitions),
        # so this branch is reached only if the task has already been
        # transitioned elsewhere (e.g., to deploying / done). Log and
        # treat as a soft success — the task isn't where we expected
        # but we don't want to crash the bounce.
        Logger.warning(
          "[StackDeployer] bounce: task #{task.id} not at a status allowing return to " <>
            "in_progress (current=#{task.status}); leaving as-is"
        )

        {:ok, task}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] bounce: failed to transition task #{task.id} to in_progress: " <>
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

  # Flip the stack from `deploying` back to `in_review` AND clear
  # the `rollup_pr` metadata so the next `maybe_open_stack_pr/1`
  # cycle opens a fresh PR after the bounced member re-merges. We
  # preserve the rest of the metadata (any conflict record from
  # earlier, etc.).
  defp flip_stack_to_in_review_for_bounce(%Stack{} = stack) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}
    cleared = Map.delete(base_meta, "rollup_pr")

    case Stacks.update_stack(stack, %{status: "in_review", metadata: cleared}) do
      {:ok, updated} ->
        Logger.info(
          "[StackDeployer] stack #{stack.id} flipped #{stack.status} -> in_review " <>
            "(post-CI-failure bounce)"
        )

        {:ok, updated}

      {:error, reason} = err ->
        Logger.warning(
          "[StackDeployer] failed to flip stack #{stack.id} to in_review post-bounce: " <>
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

  defp all_members_ready?([]), do: false

  defp all_members_ready?(members) when is_list(members) do
    Enum.all?(members, &member_ready_for_pr?/1)
  end

  defp member_ready_for_pr?(%TaskRecord{status: status, metadata: meta})
       when status in ["in_review", "deploying"] and is_map(meta) do
    case Map.get(meta, "merged_into_rollup_at") do
      %{"sha" => sha} when is_binary(sha) and sha != "" -> true
      _ -> false
    end
  end

  defp member_ready_for_pr?(_member), do: false

  defp do_open_stack_pr(%Stack{} = stack, members) do
    with {:ok, project} <- load_project(stack.project_id),
         :ok <- ensure_repo_url(project),
         {:ok, locked_stack} <- lock_stack_for_pr(stack),
         body = build_pr_body(locked_stack, members, project.repo_url),
         {:ok, %{number: number, url: url}} <-
           call_open_pr(locked_stack, project.repo_url, body) do
      finalize_pr_opened(locked_stack, number, url)
    else
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
  defp lock_stack_for_pr(%Stack{} = stack) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    placeholder = %{
      "status" => "opening",
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Stacks.update_stack(stack, %{
      status: "deploying",
      metadata: Map.put(base_meta, "rollup_pr", placeholder)
    })
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

  defp finalize_pr_opened(%Stack{} = stack, number, url)
       when is_integer(number) and is_binary(url) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    pr_meta = %{
      "number" => number,
      "url" => url,
      "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_meta = Map.put(base_meta, "rollup_pr", pr_meta)

    case Stacks.update_stack(stack, %{metadata: new_meta}) do
      {:ok, updated} ->
        Logger.info("[StackDeployer] stack #{stack.id} rollup PR opened: ##{number} #{url}")

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

  defp rollback_pr_lock(stack_id) when is_binary(stack_id) do
    case Stacks.get_stack(stack_id) do
      %Stack{metadata: meta} = current when is_map(meta) ->
        case Map.get(meta, "rollup_pr") do
          %{"status" => "opening"} ->
            cleared = Map.delete(meta, "rollup_pr")

            # Roll status back to in_review (the most-conservative
            # rollup state given members are merged but PR didn't
            # open). NOT back to in_progress: the merge already
            # happened, members are at in_review.
            _ = Stacks.update_stack(current, %{status: "in_review", metadata: cleared})
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

    ## Members

    #{member_section}#{diff_section}

    ---
    _Opened by Startup Suite stack deployer._
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp member_line(%TaskRecord{} = task) do
    sha =
      case task.metadata do
        %{"merged_into_rollup_at" => %{"sha" => sha}} when is_binary(sha) -> sha
        _ -> "unknown"
      end

    title = task.title || "(untitled)"
    url = task_url(task)
    "- [#{title}](#{url}) — sha #{sha}"
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

  defp git_runner do
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
