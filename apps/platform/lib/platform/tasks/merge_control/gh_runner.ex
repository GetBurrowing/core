defmodule Platform.Tasks.MergeControl.GhRunner do
  @moduledoc """
  Default `Platform.Tasks.MergeControl.Runner` — one read-only `gh`
  subcommand.

      gh pr list -R <repo> --head <branch> --state open \\
        --json number,url,baseRefName,statusCheckRollup --limit 1

  Reuses the shape already shipped in
  `PlatformWeb.GithubWebhookController.find_pr_number_for_branch/2` and
  `Platform.Tasks.DeployMergeReconciler.GhMergeRunner`, widened only by
  the extra `--json` fields the panel renders. It runs `pr list` and
  nothing else; there is no code path here that mutates a repository.

  ## Missing binary

  `System.cmd("gh", …)` raises `ErlangError: :enoent` when the CLI is
  absent — a crash whose stacktrace reads like anything except "the
  binary is missing", and the prod image shipped without `gh` once
  already. Mirrors the `System.find_executable("gh")` guards in
  `Platform.Tasks.AutoMerger.execute_merge/3`,
  `PlatformWeb.GithubWebhookController.find_pr_number_for_branch/2` and
  `Platform.Tasks.DeployMergeReconciler.GhMergeRunner`.
  """

  @behaviour Platform.Tasks.MergeControl.Runner

  require Logger

  @gh_missing_message "`gh` (GitHub CLI) not found on PATH; cannot run `gh pr list` to resolve the open PR for a task branch"

  @impl true
  def pr_state(%{repo: repo, branch: branch}) do
    args = [
      "pr",
      "list",
      "-R",
      repo,
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "number,url,baseRefName,statusCheckRollup",
      "--limit",
      "1"
    ]

    case System.find_executable("gh") do
      nil ->
        Logger.error("[merge_control] #{@gh_missing_message}")
        {:error, :gh_unavailable, @gh_missing_message}

      gh ->
        run(gh, args)
    end
  end

  defp run(gh, args) do
    case System.cmd(gh, args, stderr_to_stdout: true) do
      {output, 0} -> decode(output)
      {output, _exit_code} -> {:error, {:gh_error, String.trim(output)}}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, [%{"number" => number} = pr | _]} when is_integer(number) ->
        {:ok,
         %{
           number: number,
           url: pr["url"],
           base_ref: pr["baseRefName"],
           checks: checks(pr["statusCheckRollup"])
         }}

      {:ok, []} ->
        {:ok, nil}

      _ ->
        {:error, {:parse_error, String.slice(output, 0, 500)}}
    end
  end

  # `statusCheckRollup` is `null` on a PR with no checks and a list
  # otherwise. Both collapse to `[]`, which the band renders as "nothing
  # has verified this branch" — the whole point of this control.
  #
  # A check is `passed?` only on an explicit success. `SUCCESS` /
  # `NEUTRAL` / `SKIPPED` (checks) and `SUCCESS` (statuses) are the
  # non-failing terminal states; anything else — including a check still
  # in flight — is not a pass, because "still running" must not read as
  # verified.
  defp checks(rollup) when is_list(rollup) do
    Enum.map(rollup, fn entry ->
      %{
        name: entry["name"] || entry["context"] || "check",
        passed?: (entry["conclusion"] || entry["state"]) in ~w(SUCCESS NEUTRAL SKIPPED)
      }
    end)
  end

  defp checks(_), do: []
end
