defmodule Platform.Tasks.BranchProvisioner.Runner do
  @moduledoc """
  The GitHub seam `Platform.Tasks.BranchProvisioner` calls.

  Five operations, all scoped to git refs on ONE repository:

    * `default_branch_sha/1` — the head commit of the repository's default
      branch, the base a new task branch is cut from.
    * `branch_head_sha/1` — the head commit of ONE named branch.
    * `list_matching_refs/1` — does a ref with this exact name already
      exist?
    * `create_ref/1` — create it.
    * `compare_refs/1` — how does one ref stand against another?

  There is deliberately NO update/force operation in this behaviour.
  Moving a branch an executor has already committed to would destroy
  work, so the capability does not exist to be reached for by mistake.
  `compare_refs/1` is a READ: it reports the divergence, and reporting
  is the whole point — a caller that learns a branch is stale still has
  no way, through this seam, to move it.

  Same seam shape as `Platform.Tasks.MergeControl.Runner`: a behaviour
  with a `gh`-backed default, so tests pin a stub through
  `BranchProvisioner.runner/0` instead of shelling out.
  """

  @typedoc "Canonical `owner/name` slug — see `Platform.Tasks.RepoRef`."
  @type repo :: String.t()

  @doc """
  The sha at the head of `repo`'s default branch.
  """
  @callback default_branch_sha(%{repo: repo()}) ::
              {:ok, String.t()} | {:error, atom(), String.t()} | {:error, term()}

  @doc """
  The sha at the head of `branch` on `repo`.

  `{:error, :ref_not_found}` when the branch does not exist — a normal
  answer for a task whose executor never pushed, not a failure of the
  question. Distinct from `{:error, term()}` so a caller can tell "there
  is no such branch" from "we could not ask".

  Separate from `default_branch_sha/1` rather than a `ref` argument on it
  because the two answer different questions and one call site must not be
  able to drift into the other by passing a different string: the default
  branch is the BASE a task branch is cut from, this is the TIP of the task
  branch itself, and `Platform.Tasks.DeployStageBuilder` records the second
  onto deploy gates as the commit under review. Handing the base sha to
  that recorder would mint a gate that can only ever match a PR merging
  main into itself.
  """
  @callback branch_head_sha(%{repo: repo(), branch: String.t()}) ::
              {:ok, String.t()}
              | {:error, :ref_not_found}
              | {:error, atom(), String.t()}
              | {:error, term()}

  @doc """
  Refs under `ref` (a `heads/...` prefix, GitHub's `matching-refs` shape).

  Returns the list of full ref names (`"refs/heads/task/<uuid>"`), which
  may be empty. A prefix match is NOT an existence answer: the caller
  compares names exactly.
  """
  @callback list_matching_refs(%{repo: repo(), ref: String.t()}) ::
              {:ok, [String.t()]} | {:error, atom(), String.t()} | {:error, term()}

  @doc """
  Create `ref` (`"refs/heads/..."`) at `sha`.

  `{:error, :ref_exists}` when GitHub answers 422 `Reference already
  exists` — a normal outcome on redispatch, not a failure.
  """
  @callback create_ref(%{repo: repo(), ref: String.t(), sha: String.t()}) ::
              {:ok, String.t()}
              | {:error, :ref_exists}
              | {:error, atom(), String.t()}
              | {:error, term()}

  @doc """
  Compare `head` against `base` on `repo`.

  Answers GitHub's `compare` shape: `ahead_by` is how many commits
  `head` carries that `base` does not, `behind_by` how many `base`
  carries that `head` does not. Both are needed and neither is
  derivable from the other — `ahead_by` alone cannot tell a branch that
  has never been pushed to apart from one whose work has already
  landed, and `behind_by` alone is true of essentially every task
  branch and so distinguishes nothing.
  """
  @callback compare_refs(%{repo: repo(), base: String.t(), head: String.t()}) ::
              {:ok, %{ahead_by: non_neg_integer(), behind_by: non_neg_integer()}}
              | {:error, atom(), String.t()}
              | {:error, term()}
end
