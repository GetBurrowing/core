defmodule Platform.Tasks.MergeControl.Runner do
  @moduledoc """
  The one seam through which `Platform.Tasks.MergeControl` reaches GitHub.

  A single callback, `pr_state/1`, because the panel needs the PR number,
  its URL, its base ref and its check rollup at the same instant and from
  the same answer. Splitting them into separate callbacks would let the
  band describe checks on one PR while `Open PR` linked to another.

  ## Why the PR is resolved on demand rather than persisted

  Nothing in this codebase persists a PR URL at open time —
  `PlatformWeb.GithubWebhookController` handles `pull_request` only on
  `action: "closed"`, and `Platform.Tasks.DeployMergeReconciler` writes
  `pr_url` only after a merge is observed. Adding a persist path would
  buy the WORSE failure: a stale URL opens the wrong PR or a 404 while
  nothing on screen is wrong. An on-demand resolve that fails is loud and
  nameable, and the state band already exists to name it.
  """

  @typedoc """
  A resolved open PR for a branch.

  `checks` is the flattened status-check rollup: one entry per check with
  a `:passed?` boolean. An EMPTY list means the PR has zero configured
  checks, which is a different fact from a failing check and must never
  render as one — see `Platform.Tasks.MergeControl.band/1`.
  """
  @type pr :: %{
          number: pos_integer(),
          url: String.t(),
          base_ref: String.t(),
          checks: [%{name: String.t(), passed?: boolean()}]
        }

  @doc """
  Resolve the open PR for `%{repo: repo_url, branch: branch}`.

  `{:ok, nil}` means the branch has no open PR — a state to render, not
  an error. `{:error, :gh_unavailable, message}` names the missing binary
  rather than raising `ErlangError: :enoent`, which is what
  `System.cmd("gh", …)` does when the CLI is absent and which the prod
  image has already produced once.
  """
  @callback pr_state(%{repo: String.t(), branch: String.t()}) ::
              {:ok, pr() | nil} | {:error, :gh_unavailable, String.t()} | {:error, term()}
end
