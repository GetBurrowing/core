defmodule Platform.Tasks.DeployMergeReconciler.GhMergeRunner do
  @moduledoc """
  Default `MergeRunner` — asks the GitHub CLI whether a branch's PR merged.

      gh pr list -R <repo> --head <branch> --state merged \\
        --json number,mergedAt,mergeCommit,headRefOid,url --limit 1

  Read-only. This module runs exactly one `gh` subcommand and it is
  `pr list`; there is no code path here that mutates a repository.

  ## Why `--state merged` and not `--state all`

  Asking for merged PRs only means the empty result IS the answer "not
  merged yet", with no client-side interpretation of a `state` field. A
  closed-unmerged PR and an open PR are both absent from the result, and both
  correctly leave the gate pending.

  ## `--limit 1`

  A branch can carry more than one merged PR over its life (reopened,
  re-merged, or a second PR cut from the same head). `gh pr list` returns
  newest-first, so the first row is the most recent merge — which is the one
  that put the branch's current work on the base. Taking more would only give
  the reconciler a choice it has no basis to make.

  ## Missing binary

  `System.cmd("gh", …)` raises `ErlangError: :enoent` when the CLI is absent,
  a crash whose stacktrace reads like anything except "the binary is
  missing" — the prod image shipped without `gh` once already. `available?/0`
  answers that question up front for the whole sweep, and `merged_pr/1` keeps
  its own guard so a `gh` that vanishes mid-pass degrades to a named error
  rather than an exception. Mirrors the `System.find_executable("gh")` guards
  in `PlatformWeb.GithubWebhookController.find_pr_number_for_branch/2` and
  `Platform.Tasks.AutoMerger.execute_merge/3`.
  """

  @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

  require Logger

  @gh_missing_message "`gh` (GitHub CLI) not found on PATH; cannot poll `gh pr list` for merged deploy PRs"

  @impl true
  def available? do
    case System.find_executable("gh") do
      nil -> {:error, :gh_unavailable, @gh_missing_message}
      _path -> :ok
    end
  end

  @impl true
  def merged_pr(%{repo: repo, branch: branch}) do
    args = [
      "pr",
      "list",
      "-R",
      repo,
      "--head",
      branch,
      "--state",
      "merged",
      "--json",
      "number,mergedAt,mergeCommit,headRefOid,url",
      "--limit",
      "1"
    ]

    case System.find_executable("gh") do
      nil ->
        {:error, :gh_unavailable}

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
           merged_at: pr["mergedAt"],
           merge_commit_sha: merge_commit_sha(pr["mergeCommit"]),
           head_sha: head_sha(pr["headRefOid"])
         }}

      {:ok, []} ->
        {:ok, nil}

      _ ->
        {:error, {:parse_error, String.slice(output, 0, 500)}}
    end
  end

  # `mergeCommit` is `null` for some merge methods and `%{"oid" => sha}`
  # otherwise. Record `nil` rather than a placeholder string: a fabricated
  # SHA in deploy evidence is worse than an absent one.
  defp merge_commit_sha(%{"oid" => oid}) when is_binary(oid), do: oid
  defp merge_commit_sha(_), do: nil

  # `headRefOid` is a bare sha string, not the `%{"oid" => …}` object
  # `mergeCommit` uses — one extra field on the SAME `pr list` query, not a
  # second API call. Same nil discipline as `merge_commit_sha/1`, and here it
  # matters more: `DeployMergeReconciler.poll/7` compares this against the
  # tip the gate was minted for, so a placeholder string would not merely sit
  # in evidence, it would decide the comparison. A blank is a nil too — an
  # empty string would compare unequal to every recorded tip and hang every
  # gate on a repository whose merge method answers `""`.
  defp head_sha(oid) when is_binary(oid) do
    case String.trim(oid) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp head_sha(_), do: nil
end
