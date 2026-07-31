defmodule Platform.Tasks.DeployMergeReconciler.MergeRunner do
  @moduledoc """
  Behaviour for the one external observation `DeployMergeReconciler` makes:
  "has the PR for this branch, in this repository, merged?"

  The default implementation is
  `Platform.Tasks.DeployMergeReconciler.GhMergeRunner`, which shells out to
  the GitHub CLI. Tests substitute an in-memory implementation, mirroring the
  `Platform.Tasks.StackDeployer.GitRunner` / `GitShellRunner` split. Do NOT
  mock `System.cmd/3` — the seam is the behaviour.

  ## Read-only by construction

  There is deliberately no merge callback here. The reconciler OBSERVES a
  merge that already happened; it never causes one. Machine-merging stays
  with `Platform.Tasks.AutoMerger`, which since task 019fa63a stage 4 refuses
  any repository whose entry declares `ci: "none"`. Adding a `merge/1`
  callback to this behaviour would put a second merge path one keystroke away
  from a poller that runs every five minutes against every open deploy, on
  repositories specifically chosen because nothing gates them. The absence of
  the callback is the guard.

  ## `available?/0` is separate from `merged_pr/1` on purpose

  A missing `gh` binary is not a per-repository fact and must not be
  discovered once per gate: `DeployMergeReconciler.sweep/1` asks ONCE at the
  top of a pass, logs one ERROR naming the binary, and returns a count of
  zero without touching a single validation. A tool we could not run is
  never a merge and never a failure — it is a pass we did not perform.
  """

  @typedoc """
  The question. `repo` is whatever `gh -R` should be handed (the gate's
  declared `repo_url`, falling back to its canonical slug); `branch` is the
  task branch whose PR we are asking about, e.g. `"task/019fa63a"`.
  """
  @type query :: %{
          required(:repo) => String.t(),
          required(:branch) => String.t()
        }

  @typedoc """
  A merged pull request. Every field except `:number` may be `nil` — GitHub
  returns a null `mergeCommit` for some merge methods, and the reconciler
  records what it was given rather than inventing a SHA.
  """
  @type merged_pr :: %{
          required(:number) => pos_integer(),
          required(:url) => String.t() | nil,
          required(:merged_at) => String.t() | nil,
          required(:merge_commit_sha) => String.t() | nil
        }

  @doc """
  Whether the runner can run at all.

  `:ok` when it can. `{:error, :gh_unavailable, message}` when the underlying
  tool is missing — the message names the binary so the operator log says
  what to install rather than surfacing an `:enoent` stacktrace.
  """
  @callback available?() :: :ok | {:error, :gh_unavailable, String.t()}

  @doc """
  Look up the merged PR for `query.branch` in `query.repo`.

  * `{:ok, merged_pr}` — a PR from that branch merged.
  * `{:ok, nil}` — no merged PR from that branch. NOT an error: this is the
    routine answer for every open deploy on every tick.
  * `{:error, reason}` — the lookup itself failed. Emphatically distinct from
    `{:ok, nil}`; a failed question must never be recorded as a "no".
  """
  @callback merged_pr(query()) :: {:ok, merged_pr() | nil} | {:error, term()}
end
