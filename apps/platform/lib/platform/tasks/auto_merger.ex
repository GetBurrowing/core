defmodule Platform.Tasks.AutoMerger do
  @moduledoc """
  Encapsulates the auto-merge decision and execution for PR-based deploy strategies.

  When `auto_merge: true` is configured in a project's deploy strategy, this module:
  1. Detects whether auto-merge should fire (`should_auto_merge?/1`)
  2. Determines the merge method (`merge_method/1`)
  3. Executes the merge via `gh pr merge` (`execute_merge/3`)
  4. Records the result on the `pr_merged` validation (`record_merge_result/3`)

  ## Integration

  Called by `GithubWebhookController` after `ci_passed` validation passes.
  If auto-merge is enabled, the controller spawns an async task to merge
  and evaluate the `pr_merged` validation.

  ## Stack-member guard (T5 stage 3)

  Stack members never open their own PRs — the stack rollup PR (T6)
  carries the deploy. Per ADR 0041, the per-task auto-merger MUST defer
  for any task with a non-nil `stack_id`. Two guards live in this module
  and `GithubWebhookController`:

    1. `defer_for_stack?/1` — predicate the webhook checks before
       spawning the merge task.
    2. `execute_merge/4` — task-aware overload that returns
       `{:ok, :deferred}` for stack members and never shells out.

  Defense-in-depth: even if a caller forgets the predicate, the
  task-aware `execute_merge/4` short-circuits the shell-out.

  ## Planning-gate guard (ADR-0046 member 4, stage 4)

  Auto-merge means, by definition, that no human approves the merge. So
  "a failed planning gate surfaces to whoever approves the merge" is
  unsatisfiable on this path unless auto-merge yields. `execute_merge/4`
  therefore refuses — AHEAD of the stack-member guard — when
  `Tasks.planning_gate_failed?/1` is true, returning
  `{:error, :planning_gate_failed, detail}` without shelling out.

  `record_merge_result/2`'s existing 3-tuple clause routes that to a
  FAILED `pr_merged` validation carrying `"error_type" =>
  "planning_gate_failed"`, so the refusal is durable and visible in the
  UI rather than a log line nobody reads at merge time.

  This is narrower than it looks and stays consistent with ADR-0046
  decision 7 ("failure falls open, visibly"): the branch is still
  pushed, the PR is still opened, no executor is ever blocked. The only
  thing withheld is the MACHINE merge.

  `"not_applicable"` never trips this guard. Nobody holding the
  responsibility is progressive enhancement, not a missing gate
  (ADR-0046:83); the predicate is `Tasks.failed_planning_steps/1`, which
  reports `"failed"` only.
  """

  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Task, as: TaskRecord

  require Logger

  @doc """
  Returns true if the deploy strategy has auto_merge enabled.

  Reads `deploy_strategy.config.auto_merge` from the strategy map.
  """
  @spec should_auto_merge?(map()) :: boolean()
  def should_auto_merge?(%{"type" => "pr_merge", "config" => config}) do
    Map.get(config, "auto_merge", false) == true
  end

  def should_auto_merge?(_strategy), do: false

  @doc """
  Returns the configured merge method for the strategy.

  Defaults to `"squash"` if not specified.
  """
  @spec merge_method(map()) :: String.t()
  def merge_method(%{"config" => config}) do
    Map.get(config, "merge_method", "squash")
  end

  def merge_method(_), do: "squash"

  @doc """
  Returns true when the given task is a stack member and the per-task
  auto-merger MUST defer to the stack-level rollup deploy.

  Delegates to the canonical `Platform.Tasks.dispatch_deploy_for_task/1`
  seam so every caller that asks "is this task allowed to deploy on its
  own?" goes through one guard. Preserved as a boolean predicate for
  backward compatibility with `GithubWebhookController.maybe_trigger_auto_merge/2`
  and existing tests; the underlying decision (and telemetry) lives in
  `Tasks.dispatch_deploy_for_task/1`.

  Accepts a `%Task{}` struct, a task id (binary), or `nil` (returns
  `false` — no task context, can't be a stack member).
  """
  @spec defer_for_stack?(TaskRecord.t() | binary() | nil) :: boolean()
  def defer_for_stack?(task) do
    Tasks.dispatch_deploy_for_task(task) == {:error, :stack_ships_atomically}
  end

  @doc """
  Task-aware overload of `execute_merge/3` that short-circuits for
  stack-member tasks per ADR 0041 (T5 stage 3).

  Behavior:

    * Failed planning gate (`Tasks.planning_gate_failed?/1`) — returns
      `{:error, :planning_gate_failed, detail}` WITHOUT shelling out.
      Checked FIRST, ahead of the stack-member guard: a gate that was
      expected to run and didn't is a stronger refusal than "someone
      else merges this", and a stack member in that state should not
      have its own deploy stage self-satisfy either. It does not strand
      the stack — rollup fan-out runs through
      `Stacks.cascade_members_to_done/2`, a status flip, not a
      validation evaluation.
    * Stack member (`Tasks.dispatch_deploy_for_task/1` returns
      `{:error, :stack_ships_atomically}`) — returns
      `{:ok, :deferred}` WITHOUT shelling out. The stack rollup PR
      owns the deploy; per-task PR-merge is forbidden.
    * Non-stack task — delegates to `execute_merge/3`.

  This is the entry point used by `GithubWebhookController` so the
  guard runs uniformly across the auto-merge code path. The guard
  emits `[:platform, :tasks, :deploy_dispatch, :rejected_stack_member]`
  telemetry on the blocked path, so operators can detect any caller
  that repeatedly tries to deploy a stack member individually.
  """
  @spec execute_merge(TaskRecord.t() | nil, String.t(), pos_integer(), String.t()) ::
          {:ok, String.t() | :deferred} | {:error, atom(), String.t()}
  def execute_merge(%TaskRecord{} = task, repo_url, pr_number, method) do
    if Tasks.planning_gate_failed?(task) do
      detail = planning_gate_detail(task)

      Logger.warning(
        "[AutoMerger] task #{task.id} has a failed planning gate; refusing to auto-merge " <>
          "PR ##{pr_number} on #{repo_url} — #{detail}"
      )

      {:error, :planning_gate_failed, detail}
    else
      execute_merge_after_planning_gate(task, repo_url, pr_number, method)
    end
  end

  def execute_merge(nil, repo_url, pr_number, method) do
    execute_merge(repo_url, pr_number, method)
  end

  defp execute_merge_after_planning_gate(%TaskRecord{} = task, repo_url, pr_number, method) do
    case Tasks.dispatch_deploy_for_task(task) do
      :ok ->
        execute_merge(repo_url, pr_number, method)

      {:error, :stack_ships_atomically} ->
        Logger.info(
          "[StackDeployer] task #{task.id} is a stack member; deferring to stack deployer " <>
            "(skipping per-task auto-merge of PR ##{pr_number})"
        )

        {:ok, :deferred}
    end
  end

  # Names the step AND carries the recorded `detail` so the failed
  # `pr_merged` validation's evidence says WHY the gate did not run, not
  # merely THAT it didn't. Built from `Tasks.failed_planning_steps/1`,
  # the same single definition the PR-body renderer reads.
  defp planning_gate_detail(%TaskRecord{} = task) do
    steps =
      task
      |> Tasks.failed_planning_steps()
      |> Enum.map_join("; ", fn %{step: step, detail: detail} ->
        "#{step} — #{detail || "no detail recorded"}"
      end)

    "Auto-merge refused: a planning gate was expected to run and failed to dispatch " <>
      "(#{steps}). This is a dispatch failure, not a skip — a step nobody holds is " <>
      "recorded as not_applicable and does not block. Review the change and merge by hand."
  end

  @doc """
  Execute a PR merge via `gh pr merge`.

  Shells out to the GitHub CLI to merge the specified PR.

  Returns `{:ok, merge_sha}` on success or
  `{:error, error_type, details}` on failure.

  Error types:
  - `:conflict` — merge conflict
  - `:branch_protection` — branch protection rules prevent merge
  - `:ci_required` — required status checks have not passed
  - `:gh_unavailable` — the `gh` binary is not installed / not on `PATH`
  - `:unknown` — unexpected error
  """
  @spec execute_merge(String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def execute_merge(repo_url, pr_number, method \\ "squash") do
    gh_method_flag = "--#{method}"

    args = [
      "pr",
      "merge",
      to_string(pr_number),
      gh_method_flag,
      "--auto",
      "-R",
      repo_url
    ]

    Logger.info("[AutoMerger] executing merge: gh #{Enum.join(args, " ")}")

    # `System.cmd("gh", …)` raises `ErlangError: :enoent` when the GitHub
    # CLI is absent — an opaque crash indistinguishable from a git failure.
    # The prod image shipped without `gh`, and this is one of the sites
    # that made that hard to see. Fail with a named, greppable reason
    # instead. Mirrors the `System.find_executable("gh")` guard in
    # `Platform.Responsibilities.Handlers.ArchitectureCronSweep`.
    case System.find_executable("gh") do
      nil ->
        message =
          "`gh` (GitHub CLI) not found on PATH; cannot run `gh pr merge` for PR ##{pr_number}"

        Logger.error("[AutoMerger] #{message}")
        {:error, :gh_unavailable, message}

      gh ->
        do_execute_merge(gh, args, repo_url, pr_number)
    end
  end

  defp do_execute_merge(gh, args, repo_url, pr_number) do
    case System.cmd(gh, args, stderr_to_stdout: true) do
      {output, 0} ->
        merge_sha = extract_merge_sha(output)

        Logger.info(
          "[AutoMerger] PR ##{pr_number} merged successfully on #{repo_url}" <>
            if(merge_sha, do: " (SHA: #{merge_sha})", else: "")
        )

        {:ok, merge_sha || "unknown"}

      {output, _exit_code} ->
        error_type = classify_merge_error(output)

        Logger.warning(
          "[AutoMerger] PR ##{pr_number} merge failed on #{repo_url}: #{error_type} — #{String.slice(output, 0, 500)}"
        )

        {:error, error_type, String.trim(output)}
    end
  end

  @doc """
  Record the merge result on a pr_merged validation.

  On success, evaluates the validation as passed with the merge SHA.
  On failure, evaluates as failed with the error details.
  """
  @spec record_merge_result(
          String.t(),
          {:ok, String.t() | :deferred} | {:error, atom(), String.t()}
        ) ::
          {:ok, term()} | {:error, term()}
  def record_merge_result(_validation_id, {:ok, :deferred}) do
    # Stack-member deferred path — the per-task pr_merged validation
    # stays pending; the stack rollup PR's merge will fan out via T6.
    {:ok, :deferred}
  end

  def record_merge_result(validation_id, {:ok, merge_sha}) do
    PlanEngine.evaluate_validation(validation_id, %{
      status: "passed",
      evidence: %{
        "merge_sha" => merge_sha,
        "merged_by" => "auto_merger",
        "merged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      evaluated_by: "auto_merger"
    })
  end

  def record_merge_result(validation_id, {:error, error_type, details}) do
    PlanEngine.evaluate_validation(validation_id, %{
      status: "failed",
      evidence: %{
        "error_type" => to_string(error_type),
        "details" => details,
        "attempted_by" => "auto_merger",
        "attempted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      evaluated_by: "auto_merger"
    })
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp extract_merge_sha(output) do
    # gh pr merge may output the merge commit SHA
    case Regex.run(~r/([0-9a-f]{40})/, output) do
      [_, sha] -> sha
      _ -> nil
    end
  end

  defp classify_merge_error(output) do
    output_lower = String.downcase(output)

    cond do
      String.contains?(output_lower, "merge conflict") or
          String.contains?(output_lower, "could not merge") ->
        :conflict

      String.contains?(output_lower, "branch protection") or
        String.contains?(output_lower, "required review") or
          String.contains?(output_lower, "dismissed review") ->
        :branch_protection

      String.contains?(output_lower, "required status check") or
          String.contains?(output_lower, "check failed") ->
        :ci_required

      String.contains?(output_lower, "not found") ->
        :not_found

      true ->
        :unknown
    end
  end
end
