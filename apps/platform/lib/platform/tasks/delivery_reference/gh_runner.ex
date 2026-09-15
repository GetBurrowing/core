defmodule Platform.Tasks.DeliveryReference.GhRunner do
  @moduledoc """
  Default `Platform.Tasks.DeliveryReference.Runner` — two read-only `gh`
  subcommands and nothing else:

      gh api repos/<slug>/commits/<sha>
      gh pr view <number> -R <slug> --json state,mergedAt,mergeCommit,url

  There is no code path here that mutates a repository.

  ## Missing binary

  `System.cmd("gh", …)` raises `ErlangError: :enoent` when the CLI is
  absent — a crash whose stacktrace reads like anything except "the
  binary is missing", and the prod image has shipped without `gh`
  before. Mirrors the `System.find_executable("gh")` guards in
  `Platform.Tasks.AutoMerger.execute_merge/3` and
  `Platform.Tasks.MergeControl.GhRunner.pr_state/1` — except that those
  return `{:error, :gh_unavailable, message}` and this returns
  `{:error, {:unavailable, message}}`, the two-tuple shape the
  `DeliveryReference.Runner` behaviour declares.

  ## Why a non-zero exit is not automatically `:not_found`

  `gh` exits non-zero for a 404 AND for a network failure, an expired
  token and a rate limit. Only the 404 wording means the object does not
  exist; everything else is `{:unavailable, _}`, because closing a task
  as delivered on "I could not check" is the failure this module exists
  to prevent.
  """

  @behaviour Platform.Tasks.DeliveryReference.Runner

  require Logger

  @gh_missing_message "`gh` (GitHub CLI) not found on PATH; cannot verify a delivery reference against GitHub"

  @impl true
  def commit(slug, sha) do
    case run(["api", "repos/#{slug}/commits/#{sha}"]) do
      {:ok, output} -> decode(output)
      other -> other
    end
  end

  @impl true
  def pull_request(slug, number) do
    args = [
      "pr",
      "view",
      Integer.to_string(number),
      "-R",
      slug,
      "--json",
      "state,mergedAt,mergeCommit,url"
    ]

    case run(args) do
      {:ok, output} -> decode(output)
      other -> other
    end
  end

  defp run(args) do
    case System.find_executable("gh") do
      nil ->
        Logger.error("[delivery_reference] #{@gh_missing_message}")
        {:error, {:unavailable, @gh_missing_message}}

      gh ->
        case System.cmd(gh, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _exit_code} -> classify_failure(String.trim(output))
        end
    end
  end

  # GitHub's 404 wording, across both `gh api` and `gh pr view`.
  defp classify_failure(output) do
    if output =~ ~r/404|[Nn]ot [Ff]ound|no pull requests found|could not resolve to a/i do
      {:error, :not_found}
    else
      {:error, {:unavailable, String.slice(output, 0, 500)}}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:unavailable, "unparseable `gh` output: " <> String.slice(output, 0, 500)}}
    end
  end
end
