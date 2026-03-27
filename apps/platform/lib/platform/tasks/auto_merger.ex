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
  """

  alias Platform.Tasks.PlanEngine

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
  Execute a PR merge via `gh pr merge`.

  Shells out to the GitHub CLI to merge the specified PR.

  Returns `{:ok, merge_sha}` on success or
  `{:error, error_type, details}` on failure.

  Error types:
  - `:conflict` — merge conflict
  - `:branch_protection` — branch protection rules prevent merge
  - `:ci_required` — required status checks have not passed
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

    case System.cmd("gh", args, stderr_to_stdout: true) do
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
  @spec record_merge_result(String.t(), {:ok, String.t()} | {:error, atom(), String.t()}) ::
          {:ok, term()} | {:error, term()}
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
