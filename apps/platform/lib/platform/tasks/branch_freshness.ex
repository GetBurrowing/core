defmodule Platform.Tasks.BranchFreshness do
  @moduledoc """
  Tell a task branch that carries NOTHING apart from an ordinary one.

  `BranchProvisioner` cuts `task/<uuid>` off the default branch at the
  first dispatch and, by design, never moves it again — an existing ref
  is `{:ok, :exists}` even when it points somewhere else, because moving
  a branch an executor has already committed to would destroy work. That
  invariant is correct and this module does not touch it.

  What it leaves open is the case where the FIRST stage's work reached
  the default branch from some other branch. The task branch then still
  sits at the sha it was provisioned at, holding no commits at all, and
  the dispatch prompt sends stage 2 to `--track` it. The executor lands
  in a tree where its own predecessor's artefacts are simply not there.

  ## Why the failure is invisible

  Nothing errors. `git worktree add --track` succeeds, the files are
  absent, and absence is character-for-character identical to "this was
  never built" — so a stage told to "re-run stage 1's harness" reports
  that there is no harness, which reads as a true finding about the work
  rather than a false one about the tree.

  The stack path already refuses to have this problem: ADR-0042 retargets
  a member branch at the rollup head precisely "so a member sees its
  already-merged siblings" (`heartbeat_scheduler.ex`,
  `stack_member_git_workflow_section/2`). A non-stack task has no
  equivalent, and this module is the detection half of that gap.

  ## Ahead, not behind

  `behind_by > 0` is NOT the signal, and using it would be the whole bug
  in a new place. Every task branch is behind the default branch the
  moment anything else merges, so a check on `behind_by` fires on
  essentially every second-stage dispatch and would suppress or shout
  about all of them — the "silent strangulation" failure the router's
  dispatch guards are written to avoid.

  The signal is `ahead_by == 0`: the branch carries no commits of its
  own. That is exactly the observed shape, and it is also the only state
  in which a fast-forward is provably lossless, so the same predicate
  that finds the fault licenses the only safe recovery from it and
  withholds that licence the instant the branch has work on it.

    * `:fresh` — `ahead_by > 0` (the branch has its own commits), or the
      branch is identical to the base. Nothing to say.
    * `{:stale_stub, behind_by}` — `ahead_by == 0` and `behind_by > 0`.
    * `:unknown` — anything else.

  ## A failed probe is never a finding

  `:unknown` covers an unresolvable repo, a non-binary branch name, a
  runner error, a missing `gh`, any response that is not two integers,
  AND a runner that raises or exits. Same rule as
  `Platform.Tasks.BranchReconciler`: reporting a probe that could not
  run as a fault would put a warning the executor is meant to act on
  into prompts every time GitHub was briefly unreachable, which teaches
  it to read past the one warning that matters.

  The rescue is not defensive padding. `assess/4` is called during
  prompt rendering, inside the `TaskRouter` GenServer's dispatch — a
  raise here does not degrade the warning, it kills the dispatch, and a
  task whose router keeps crashing is worse off than one whose executor
  merely lacks a hint. This was not hypothetical: adding `compare_refs/1`
  to the runner behaviour left an existing test stub without the
  callback, and the `UndefinedFunctionError` took down
  `do_dispatch_resolved/6` rather than the prompt losing a paragraph.
  Same rule the router's own dispatch guards codify — failing open costs
  one less-informative prompt, failing closed costs a stalled task.

  Uses `Platform.Tasks.BranchProvisioner`'s runner so there is ONE GitHub
  ref seam in the system rather than a second spelling of `compare`.
  """

  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.RepoRef

  @type outcome :: :fresh | {:stale_stub, pos_integer()} | :unknown

  @doc """
  Assess `branch` against `base_branch` on `repo_url`.

  Options:

    * `:runner` — override the configured
      `Platform.Tasks.BranchProvisioner.Runner`.
  """
  @spec assess(term(), term(), term(), keyword()) :: outcome()
  def assess(repo_url, branch, base_branch, opts \\ [])

  def assess(repo_url, branch, base_branch, opts)
      when is_binary(branch) and is_binary(base_branch) do
    runner = Keyword.get(opts, :runner, BranchProvisioner.runner())

    with {:ok, repo} <- normalize_repo(repo_url),
         {:ok, ahead, behind} <- compare(runner, repo, base_branch, branch) do
      classify(ahead, behind)
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  def assess(_repo_url, _branch, _base_branch, _opts), do: :unknown

  # ── Internals ───────────────────────────────────────────────────────────

  defp normalize_repo(repo_url) do
    case RepoRef.normalize(repo_url) do
      {:ok, repo} -> {:ok, repo}
      _ -> :error
    end
  end

  defp compare(runner, repo, base, head) do
    case runner.compare_refs(%{repo: repo, base: base, head: head}) do
      {:ok, %{ahead_by: ahead, behind_by: behind}}
      when is_integer(ahead) and ahead >= 0 and is_integer(behind) and behind >= 0 ->
        {:ok, ahead, behind}

      _ ->
        :error
    end
  end

  # `ahead > 0` is `:fresh` REGARDLESS of how far behind the branch is.
  # A branch 300 commits behind that holds its own work is an ordinary
  # long-running branch, and it is the one case where fast-forwarding
  # would lose something — so it must never be reported as a stub.
  defp classify(ahead, _behind) when ahead > 0, do: :fresh
  defp classify(0, behind) when behind > 0, do: {:stale_stub, behind}
  defp classify(_ahead, _behind), do: :fresh
end
