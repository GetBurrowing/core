defmodule Platform.Tasks.BranchProvisioner.Runner do
  @moduledoc """
  The GitHub seam `Platform.Tasks.BranchProvisioner` calls.

  Three operations, all scoped to git refs on ONE repository:

    * `default_branch_sha/1` — the head commit of the repository's default
      branch, the base a new task branch is cut from.
    * `list_matching_refs/1` — does a ref with this exact name already
      exist?
    * `create_ref/1` — create it.

  There is deliberately NO update/force operation in this behaviour.
  Moving a branch an executor has already committed to would destroy
  work, so the capability does not exist to be reached for by mistake.

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
end
