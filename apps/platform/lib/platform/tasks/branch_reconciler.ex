defmodule Platform.Tasks.BranchReconciler do
  @moduledoc """
  Tell a WRONG merge-control state apart from an ORDINARY one.

  `MergeControl.build/1` asks GitHub about the branch recorded on the
  `pr_merged` gate. When the executor pushed somewhere else, GitHub is
  asked about a branch that does not exist and truthfully answers
  nothing, so the panel renders "This branch has no open pull request to
  merge." That sentence is ALSO the correct answer for an ordinary task
  whose PR simply is not open yet — a wrong state and an ordinary state
  are character-for-character identical, which is the whole defect.

  This module looks for a sibling ref under the same 8-hex task prefix —
  the same `task/<first-8-hex>*` glob shape the deploy prompt already
  renders (`heartbeat_scheduler.ex`'s legacy-branch recovery step) — and
  answers:

    * `:match` — a ref with the recorded name exists.
    * `{:mismatch, [found]}` — the recorded name is absent while another
      `task/<8hex>…` ref exists. The caller names BOTH.
    * `:unknown` — anything else.

  ## A failed probe is never a mismatch

  `:unknown` covers an unresolvable repo, an unparseable branch name, a
  runner error, a missing `gh`, AND an empty ref list. Reporting a probe
  that could not run as a mismatch would put a red "Recorded branch not
  found" band in front of a human every time GitHub was briefly
  unreachable, which teaches them to click past the one band that is
  supposed to stop them.

  ## Block, do not adopt

  The answer is a REPORT. There is deliberately no path where the found
  branch is adopted onto the gate: a confused agent that pushed to the
  wrong branch would get Suite to merge that branch. The control refuses
  and says both names. Silence is what is forbidden, not refusal.

  Uses `Platform.Tasks.BranchProvisioner`'s runner so there is ONE GitHub
  ref seam in the system rather than a second spelling of `matching-refs`.
  """

  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.RepoRef

  @type outcome :: :match | {:mismatch, [String.t()]} | :unknown

  @prefix_re ~r/^task\/(?<prefix>[0-9a-f]{8})/

  @doc """
  Reconcile `recorded_branch` against the refs actually on `repo_url`.

  Options:

    * `:runner` — override the configured
      `Platform.Tasks.BranchProvisioner.Runner`.
  """
  @spec reconcile(term(), term(), keyword()) :: outcome()
  def reconcile(repo_url, recorded_branch, opts \\ [])

  def reconcile(repo_url, recorded_branch, opts) when is_binary(recorded_branch) do
    runner = Keyword.get(opts, :runner, BranchProvisioner.runner())

    with {:ok, repo} <- normalize_repo(repo_url),
         {:ok, prefix} <- prefix_of(recorded_branch),
         {:ok, refs} <- list_refs(runner, repo, prefix) do
      classify(recorded_branch, refs)
    else
      _ -> :unknown
    end
  end

  def reconcile(_repo_url, _recorded_branch, _opts), do: :unknown

  # ── Internals ───────────────────────────────────────────────────────────

  defp normalize_repo(repo_url) do
    case RepoRef.normalize(repo_url) do
      {:ok, repo} -> {:ok, repo}
      _ -> :error
    end
  end

  # `task/<first-8-hex>` — the glob shape the deploy prompt's legacy
  # recovery step already renders. Not a slug helper: nothing else may
  # truncate a task id (see `heartbeat_scheduler.ex`).
  defp prefix_of(branch) do
    case Regex.named_captures(@prefix_re, branch) do
      %{"prefix" => prefix} -> {:ok, "task/" <> prefix}
      _ -> :error
    end
  end

  defp list_refs(runner, repo, prefix) do
    case runner.list_matching_refs(%{repo: repo, ref: "heads/" <> prefix}) do
      {:ok, refs} when is_list(refs) -> {:ok, refs}
      _ -> :error
    end
  end

  defp classify(recorded, refs) do
    names =
      refs
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.replace_prefix(&1, "refs/heads/", ""))

    cond do
      recorded in names -> :match
      names == [] -> :unknown
      true -> {:mismatch, names}
    end
  end
end
