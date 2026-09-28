defmodule Platform.Tasks.DeployMergeReconciler.GhMergeRunner do
  @moduledoc """
  Default `MergeRunner` — asks the GitHub CLI whether a branch's PR merged.

      gh pr list -R <repo> --head <branch> --state merged \\
        --json number,mergedAt,mergeCommit,headRefOid,url,author --limit 1

  Read-only. This module runs exactly two `gh` subcommands, `pr list` and
  `api repos/<slug>/compare/<base>...<head>`; there is no code path here
  that mutates a repository.

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
      "number,mergedAt,mergeCommit,headRefOid,url,author",
      "--limit",
      "1"
    ]

    case System.find_executable("gh") do
      nil ->
        {:error, :gh_unavailable}

      gh ->
        run(gh, args, &decode/1)
    end
  end

  @doc """
  Every commit strictly between `base_sha` and `head_sha`:

      gh api repos/<owner>/<name>/compare/<base_sha>...<head_sha>

  `query.repo` arrives in whichever spelling the gate declared (a full URL
  or a bare slug, same as `merged_pr/1`'s `repo`), so it is normalized to
  the `owner/name` slug the REST path requires via
  `Platform.Tasks.RepoRef.normalize/1` rather than handed to `gh` raw —
  `gh api`'s path is a literal string, not `-R`, and does no normalization
  of its own.
  """
  @impl true
  def commits_between(%{repo: repo}, base_sha, head_sha) do
    case Platform.Tasks.RepoRef.normalize(repo) do
      {:ok, slug} ->
        args = ["api", "repos/#{slug}/compare/#{base_sha}...#{head_sha}"]

        case System.find_executable("gh") do
          nil -> {:error, :gh_unavailable}
          gh -> run(gh, args, &decode_compare/1)
        end

      :error ->
        {:error, {:invalid_repo, repo}}
    end
  end

  # Shared by `merged_pr/1` and `commits_between/3` — both shell out to `gh`
  # the same way and differ only in how they decode a `0`-exit response.
  # `decoder` is `&decode/1` or `&decode_compare/1`.
  defp run(gh, args, decoder) do
    case System.cmd(gh, args, stderr_to_stdout: true) do
      {output, 0} -> decoder.(output)
      {output, _exit_code} -> {:error, {:gh_error, String.trim(output)}}
    end
  end

  # `{:ok, []}` here must mean "the compare API says there are genuinely
  # zero commits between these shas" — the same discipline `decode/1` above
  # applies to `{:ok, nil}`. A response this shape does not recognize is a
  # parse error, never silently folded into an empty list.
  defp decode_compare(output) do
    case Jason.decode(output) do
      {:ok, %{"commits" => commits}} when is_list(commits) ->
        if Enum.all?(commits, &valid_commit?/1) do
          {:ok, Enum.map(commits, &decode_commit/1)}
        else
          {:error, {:parse_error, String.slice(output, 0, 500)}}
        end

      _ ->
        {:error, {:parse_error, String.slice(output, 0, 500)}}
    end
  end

  defp valid_commit?(%{"sha" => sha}), do: is_binary(sha)
  defp valid_commit?(_), do: false

  defp decode_commit(%{"sha" => sha} = commit) do
    %{
      sha: sha,
      committer_date: get_in(commit, ["commit", "committer", "date"]),
      author_login: get_in(commit, ["author", "login"])
    }
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
           head_sha: head_sha(pr["headRefOid"]),
           author_login: author_login(pr["author"])
         }}

      {:ok, []} ->
        {:ok, nil}

      _ ->
        {:error, {:parse_error, String.slice(output, 0, 500)}}
    end
  end

  # `author` is `%{"login" => …}` when `gh` answers it and `null` for a
  # deleted account or some bot identities. Same nil discipline as
  # `merge_commit_sha/1` and `head_sha/1`: record what GitHub actually said,
  # never a placeholder that would misattribute a fix-forward commit to the
  # wrong person.
  defp author_login(%{"login" => login}) when is_binary(login) do
    case String.trim(login) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp author_login(_), do: nil

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
