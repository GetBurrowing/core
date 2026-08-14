defmodule Platform.Tasks.BranchProvisioner do
  @moduledoc """
  Create the task branch Suite's deploy gates already expect to exist.

  `DeployStageBuilder.repo_validation/2` writes
  `StackDeployer.member_branch_for/1` onto every `pr_merged` gate's
  `evaluation_payload["branch"]`, and `MergeControl.build/1` asks GitHub
  about exactly that string. So the branch name is DERIVED from the task
  id, and an executor that pushed to an invented name leaves Suite
  looking for a branch nobody created — the gate reads "no open PR" while
  the work sits on a branch Suite has never heard of.

  This module closes that gap from the Suite side: it creates
  `task/<uuid>` up front, off the repository's default branch, so the
  name the gate watches exists before an executor ever runs.

  ## Derive, never report

  There is deliberately NO path where an executor reports the branch it
  pushed and Suite overwrites the gate. That sounds like making reality
  authoritative; it is the dangerous option — a confused agent that
  pushed to the wrong branch would get Suite to merge the wrong branch.
  Deriving from the task id is the safer design. This module ENFORCES
  that derivation, it does not replace it: the name comes from
  `StackDeployer.member_branch_for/1` and nothing else, so no fourth
  spelling of the derivation enters the system (see the comment at
  `plan_engine.ex:615`).

  ## Idempotence

  A redispatch must not fail. An existing ref is `{:ok, :exists}`,
  including GitHub's 422 `Reference already exists` on a racing second
  create. A ref that exists but points somewhere else is ALSO
  `{:ok, :exists}` — this module never force-updates a ref, because
  moving a branch an executor has already committed to would destroy
  work.
  """

  alias Platform.Tasks
  alias Platform.Tasks.RepoRef
  alias Platform.Tasks.StackDeployer
  alias Platform.Tasks.Task, as: TaskRecord

  require Logger

  @default_runner Platform.Tasks.BranchProvisioner.GhRunner

  @type outcome :: {:ok, :created} | {:ok, :exists} | {:error, term()}

  @doc """
  The configured `Platform.Tasks.BranchProvisioner.Runner`.

  Public so tests can pin a stub without mutating application env from an
  async case — same reason as `Platform.Tasks.MergeControl.runner/0`.
  """
  @spec runner() :: module()
  def runner do
    :platform
    |> Application.get_env(:branch_provisioner, [])
    |> Keyword.get(:runner, @default_runner)
  end

  @doc """
  The branch name for a task — `StackDeployer.member_branch_for/1`.

  Exposed so callers (and tests) can name the branch without importing a
  second derivation.
  """
  @spec branch_for(TaskRecord.t()) :: String.t()
  def branch_for(%TaskRecord{} = task), do: StackDeployer.member_branch_for(task)

  @doc """
  Ensure `task`'s branch exists in one repository.

  Returns `{:ok, :created}`, `{:ok, :exists}`, or `{:error, reason}`.
  `reason` is `{:unresolvable_repo, value}` when `repo_url` does not
  normalize to an `owner/name` slug, and otherwise whatever the runner
  reported — including the three-element `{:error, :gh_unavailable,
  message}` when the CLI is missing.

  Options:

    * `:runner` — override the configured runner module.
  """
  @spec ensure_branch(TaskRecord.t(), term(), keyword()) :: outcome()
  def ensure_branch(%TaskRecord{} = task, repo_url, opts \\ []) do
    runner = Keyword.get(opts, :runner, runner())
    branch = branch_for(task)

    case RepoRef.normalize(repo_url) do
      {:ok, repo} -> do_ensure(runner, repo, branch)
      :error -> {:error, {:unresolvable_repo, repo_url}}
    end
  end

  @doc """
  Ensure `task`'s branch exists in EVERY repository the task deploys to.

  Resolves the repo set through
  `Platform.Tasks.resolve_deploy_strategy_with_repos/1` — the same
  resolution `DeployStageBuilder` builds gates from, so there is one ref
  per gate and every one of them carries the SAME branch name.

  Returns `{:ok, %{branch: branch, results: [...]}}` where each result is
  `%{repo_url: url, result: outcome}`, in repo-set order. The overall
  shape is `:ok` even when an individual repository failed: the caller
  decides what a partial provision means, rather than this function
  collapsing four answers into one.
  """
  @spec ensure_branches(TaskRecord.t(), keyword()) ::
          {:ok, %{branch: String.t(), results: [map()]}}
  def ensure_branches(%TaskRecord{} = task, opts \\ []) do
    branch = branch_for(task)

    results =
      task
      |> Tasks.resolve_deploy_strategy_with_repos()
      |> Map.get("repos", [])
      |> Enum.map(fn entry ->
        repo_url = repo_url_of(entry)
        %{repo_url: repo_url, result: ensure_branch(task, repo_url, opts)}
      end)

    {:ok, %{branch: branch, results: results}}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp do_ensure(runner, repo, branch) do
    ref = "refs/heads/" <> branch

    case runner.list_matching_refs(%{repo: repo, ref: "heads/" <> branch}) do
      {:ok, refs} ->
        # `matching-refs` is a PREFIX query: `heads/task/<uuid>` also
        # returns `heads/task/<uuid>-something`. Only an exact name is an
        # existence answer.
        if ref in refs, do: {:ok, :exists}, else: create(runner, repo, ref)

      error ->
        error
    end
  end

  defp create(runner, repo, ref) do
    case runner.default_branch_sha(%{repo: repo}) do
      {:ok, sha} -> post_ref(runner, repo, ref, sha)
      error -> error
    end
  end

  defp post_ref(runner, repo, ref, sha) do
    case runner.create_ref(%{repo: repo, ref: ref, sha: sha}) do
      {:ok, _created} ->
        {:ok, :created}

      # Lost a race with another provisioner. The branch exists, which is
      # what the caller asked for.
      {:error, :ref_exists} ->
        {:ok, :exists}

      error ->
        Logger.error("[branch_provisioner] failed to create #{ref} in #{repo}: #{inspect(error)}")
        error
    end
  end

  defp repo_url_of(%{"repo_url" => url}), do: url
  defp repo_url_of(%{repo_url: url}), do: url
  defp repo_url_of(other), do: other
end
