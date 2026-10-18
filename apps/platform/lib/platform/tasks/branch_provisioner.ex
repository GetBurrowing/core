defmodule Platform.Tasks.BranchProvisioner do
  @moduledoc """
  Create the task branch Burrow's deploy gates already expect to exist.

  `DeployStageBuilder.repo_validation/3` writes
  `StackDeployer.member_branch_for/1` onto every `pr_merged` gate's
  `evaluation_payload["branch"]`, and `MergeControl.build/1` asks GitHub
  about exactly that string. So the branch name is DERIVED from the task
  id, and an executor that pushed to an invented name leaves Burrow
  looking for a branch nobody created — the gate reads "no open PR" while
  the work sits on a branch Burrow has never heard of.

  This module closes that gap from the Burrow side: it creates
  `task/<uuid>` up front, off the repository's default branch, so the
  name the gate watches exists before an executor ever runs.

  ## Derive, never report

  There is deliberately NO path where an executor reports the branch it
  pushed and Burrow overwrites the gate. That sounds like making reality
  authoritative; it is the dangerous option — a confused agent that
  pushed to the wrong branch would get Burrow to merge the wrong branch.
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

  @doc """
  The current tip sha of `branch` in every repository `strategy` deploys to,
  as `%{canonical_slug => sha}`.

  `strategy` is the map `Platform.Tasks.resolve_deploy_strategy_with_repos/1`
  returns — the SAME resolution `Platform.Tasks.DeployStageBuilder` builds
  gates from, so the keys here and the `"repo"` slugs on the gates are
  produced by one normalizer (`Platform.Tasks.RepoRef`) and cannot disagree
  about how a repository is named.

  ## Per repository, not once per stage

  One task pushes ONE branch name into N repositories, and those N branches
  are unrelated refs with unrelated tips. A single sha recorded onto all N
  gates would match at most one of them and hang the rest forever, which is
  the failure this map exists to avoid. The multi-repo deploy is the reason
  the return value is a map rather than a string.

  ## A repository that cannot be asked is ABSENT, not nil

  Every failure mode — no `gh`, a 404 for a branch nobody pushed, an
  unnormalizable url, a repository we lack a token for — omits that key. The
  caller writes `nil` for a missing key, and
  `Platform.Tasks.DeployMergeReconciler` reads a nil tip as "this gate cannot
  make the tree comparison" and falls through to its ordering check. That is
  deliberately fail-SOFT, and it is the one place in this feature that is:
  hanging every gate in a repository whose ref lookup flaked would strand
  live deploys, and the ordering check still stands. The `warning` below is
  what makes the degraded gate visible.
  """
  @spec branch_tip_shas(map(), String.t(), keyword()) :: %{String.t() => String.t()}
  def branch_tip_shas(strategy, branch, opts \\ [])

  def branch_tip_shas(strategy, branch, opts) when is_map(strategy) and is_binary(branch) do
    runner = Keyword.get(opts, :runner, runner())

    strategy
    |> Map.get("repos", [])
    |> List.wrap()
    |> Enum.map(&slug_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn slug, acc ->
      case runner.branch_head_sha(%{repo: slug, branch: branch}) do
        {:ok, sha} when is_binary(sha) ->
          Map.put(acc, slug, sha)

        # `NoopRunner`'s answer, and the ONE failure that is not a
        # degradation: it means an operator deliberately switched branch
        # provisioning off (`config/test.exs` does exactly this, so every
        # deploy-stage injection in the suite lands here). A `warning` for a
        # configured no-op is noise that trains people to ignore the real
        # one below, which fires when we tried and could not.
        {:error, :branch_provisioning_disabled} ->
          Logger.debug(
            "[branch_provisioner] branch provisioning is disabled; recording no " <>
              "branch_tip_sha for #{branch} in #{slug}"
          )

          acc

        other ->
          Logger.warning(
            "[branch_provisioner] could not resolve the tip of #{branch} in #{slug}: " <>
              "#{inspect(other)} — the deploy gate for this repository will record no " <>
              "branch_tip_sha and can only check merge ORDERING, not which tree merged"
          )

          acc
      end
    end)
  end

  def branch_tip_shas(_strategy, _branch, _opts), do: %{}

  # ── Internals ───────────────────────────────────────────────────────────

  # `RepoRef.slug/1` and not a second spelling: these keys are looked up by
  # `DeployStageBuilder.repo_validation/3` under the slug `repo_gate/2`
  # computed the same way, and two normalizers that agree today are two
  # normalizers that can stop agreeing.
  defp slug_of(entry) do
    case entry do
      %{"slug" => slug} when is_binary(slug) -> slug
      other -> other |> repo_url_of() |> RepoRef.slug()
    end
  end

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
