defmodule Platform.Tasks.BranchProvisioner.GhRunner do
  @moduledoc """
  Default `Platform.Tasks.BranchProvisioner.Runner` — three `gh api` calls.

      gh api repos/<owner>/<name>                       # default_branch
      gh api repos/<owner>/<name>/git/ref/heads/<b>     # its head sha
      gh api repos/<owner>/<name>/git/matching-refs/... # existence
      gh api -X POST repos/<owner>/<name>/git/refs      # create

  ## Missing binary

  `System.cmd("gh", …)` raises `ErlangError: :enoent` when the CLI is
  absent — a crash whose stacktrace reads like anything except "the
  binary is missing", and the prod image shipped without `gh` once
  already. Guarded exactly like
  `Platform.Tasks.MergeControl.GhRunner.pr_state/1`.
  """

  @behaviour Platform.Tasks.BranchProvisioner.Runner

  require Logger

  @gh_missing_message "`gh` (GitHub CLI) not found on PATH; cannot create the task branch ref via `gh api`"

  @impl true
  def default_branch_sha(%{repo: repo}) do
    with {:ok, %{"default_branch" => default}} when is_binary(default) <-
           api(["api", "repos/#{repo}"]),
         {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) <-
           api(["api", "repos/#{repo}/git/ref/heads/#{default}"]) do
      {:ok, sha}
    else
      {:error, _, _} = err -> err
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def list_matching_refs(%{repo: repo, ref: ref}) do
    case api(["api", "repos/#{repo}/git/matching-refs/#{ref}"]) do
      {:ok, refs} when is_list(refs) ->
        {:ok, for(%{"ref" => name} <- refs, is_binary(name), do: name)}

      {:error, _, _} = err ->
        err

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def create_ref(%{repo: repo, ref: ref, sha: sha}) do
    args = ["api", "-X", "POST", "repos/#{repo}/git/refs", "-f", "ref=#{ref}", "-f", "sha=#{sha}"]

    case api(args) do
      {:ok, %{"ref" => created}} when is_binary(created) -> {:ok, created}
      {:error, {:gh_error, output}} -> classify_error(output)
      {:error, _, _} = err -> err
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  # GitHub answers 422 `Reference already exists` on a second create. That
  # is the idempotent outcome, not a failure — a redispatch must not fail.
  defp classify_error(output) do
    if String.contains?(output, "Reference already exists") do
      {:error, :ref_exists}
    else
      {:error, {:gh_error, output}}
    end
  end

  defp api(args) do
    case System.find_executable("gh") do
      nil ->
        Logger.error("[branch_provisioner] #{@gh_missing_message}")
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
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, {:parse_error, String.slice(output, 0, 500)}}
    end
  end
end
