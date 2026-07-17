defmodule Platform.Tasks.StackDeployer.GitRunner do
  @moduledoc """
  Behaviour for git operations needed by `Platform.Tasks.StackDeployer`.

  The default implementation is `Platform.Tasks.StackDeployer.GitShellRunner`,
  which shells out to the system `git` binary. Tests substitute an
  in-memory implementation to exercise the deployer without hitting a
  real remote.

  Stage 1 of T5 added `ensure_rollup_branch/1`; stage 2 adds
  `merge_member_into_rollup/1`; stage 4 adds `open_stack_pr/1` (and
  `diff_stat/1` for summarising the rollup vs base in PR body text);
  stage 5 adds `revert_member_merge/1` and `close_stack_pr/1` to
  support CI-failure bounce of an offending member.
  """

  @typedoc """
  Result of a successful rollup-branch creation.

    * `:status` is `:created` when the runner pushed a new branch, or
      `:already_exists` when the branch was already on origin (idempotent
      success — no push performed).
    * `:base_sha` is the SHA the rollup branch points at on origin
      (always populated on success — for `:already_exists` it's the
      branch's current SHA, which may differ from the current
      `base_branch` HEAD if the rollup has already moved).
  """
  @type ensure_result :: %{
          required(:status) => :created | :already_exists,
          required(:base_sha) => String.t() | nil
        }

  @typedoc """
  Arguments for `ensure_rollup_branch/1`.

  All keys are required. The runner is project-agnostic: it takes a
  `repo_url` and `project_id` (used for working-clone path scoping)
  rather than a `Stack` struct so the behaviour stays usable from
  testing fixtures without depending on the schema.
  """
  @type ensure_args :: %{
          required(:repo_url) => String.t(),
          required(:base_branch) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t()
        }

  @callback ensure_rollup_branch(ensure_args()) ::
              {:ok, ensure_result()} | {:error, term()}

  @typedoc """
  Result of a successful per-member rollup merge.

    * `:status` is always `:merged` for a real merge. (Idempotency —
      "already merged" — is short-circuited above the runner in
      `StackDeployer.merge_member_into_rollup/1`, so the runner is only
      invoked when an actual merge needs to happen.)
    * `:merge_sha` is the SHA of the new merge commit on the rollup
      branch (post-push).
  """
  @type merge_result :: %{
          required(:status) => :merged,
          required(:merge_sha) => String.t()
        }

  @typedoc """
  Conflict detail surfaced by the runner when `git merge` fails on
  conflicting hunks. `:files` is the list of paths reported by
  `git diff --name-only --diff-filter=U` after `git merge --abort`
  (best-effort — may be empty if abort already cleared the index).

  With the ADR-0042 Decision 2 switch to `merge --ff-only`, a merge
  conflict is effectively unreachable in practice — git rejects the
  merge as non-fast-forward before it can hit conflicting hunks — but
  the callback shape is preserved for defence-in-depth.
  """
  @type merge_conflict :: %{
          required(:files) => [String.t()],
          optional(:output) => String.t()
        }

  @typedoc """
  Divergence detail surfaced by the runner when `git merge --ff-only`
  fails because the member branch is not a descendant of the current
  rollup HEAD (ADR-0042 Decision 2).

    * `:member_sha` — the tip SHA of the member branch that failed to
      fast-forward (`origin/task/<uuid>` after fetch).
    * `:rollup_sha` — the current rollup HEAD the runner attempted to
      fast-forward FROM (`origin/<rollup_branch>` after fetch and
      checkout). May be `""` if the pre-merge `rev-parse HEAD` failed
      (best-effort — the divergence is still reported).
    * `:output` — the trimmed git stderr/stdout so callers can
      preserve the exact failure message on the paused task's audit
      trail.
  """
  @type merge_divergence :: %{
          required(:member_sha) => String.t(),
          required(:rollup_sha) => String.t(),
          optional(:output) => String.t()
        }

  @typedoc """
  Arguments for `merge_member_into_rollup/1`.

  Mirrors `ensure_args` plus the member branch to merge and a
  human-readable `:member_slug` used in the merge commit message so
  reviewers can see at a glance which member contributed each commit.
  """
  @type merge_args :: %{
          required(:repo_url) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:member_branch) => String.t(),
          required(:member_slug) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t(),
          optional(:member_task_id) => String.t()
        }

  @doc """
  Merge `member_branch` into `rollup_branch` on origin.

  ADR-0042 Decision 2: the merge is FAST-FORWARD-ONLY. Every member
  branch is cut from rollup HEAD (stage 1), so the validated-pass
  merge is a trivial fast-forward. If the FF isn't possible, the
  runner reports `:not_fast_forwardable` and the deployer pauses the
  offending task for human rebase — no auto-rebase (that would
  silently rewrite an agent's commits).

  Implementations must:

    1. Fetch both branches.
    2. Check out the rollup branch at `origin/<rollup_branch>`.
    3. `git merge --ff-only <member_sha>` (no `-m` — FF has no merge
       commit).
    4. On success: push the rollup branch and return
       `{:ok, %{status: :merged, merge_sha: <sha>}}`.
    5. On non-fast-forward: return
       `{:error, :not_fast_forwardable, %{member_sha, rollup_sha, output}}`.
       The runner does NOT need to abort — `merge --ff-only` fails
       cleanly with no working-tree changes.
    6. On conflict (defence-in-depth — practically unreachable under
       `--ff-only`): `git merge --abort`, parse
       `git diff --name-only --diff-filter=U` for the conflict file
       list, and return `{:error, :conflict, %{files: [...]}}`.
    7. On any other git failure: return `{:error, reason}` (do NOT
       leave the working tree mid-merge — abort first if needed).
  """
  @callback merge_member_into_rollup(merge_args()) ::
              {:ok, merge_result()}
              | {:error, :not_fast_forwardable, merge_divergence()}
              | {:error, :conflict, merge_conflict()}
              | {:error, term()}

  @typedoc """
  Result of a successful stack-level PR creation.

    * `:number` is the PR number returned by `gh pr create`.
    * `:url` is the canonical `https://github.com/owner/repo/pull/N` URL.
  """
  @type pr_result :: %{
          required(:number) => pos_integer(),
          required(:url) => String.t()
        }

  @typedoc """
  Arguments for `open_stack_pr/1`. The runner shells out to
  `gh pr create -R <repo_url> --base <base_branch> --head <rollup_branch>
  --title <title> --body <body>` and returns the parsed PR number/URL.

  The deployer is responsible for composing `:title` and `:body` and
  passing them in pre-formatted; the runner does not generate either.
  """
  @type pr_args :: %{
          required(:repo_url) => String.t(),
          required(:base_branch) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t()
        }

  @doc """
  Open ONE PR from `rollup_branch` against `base_branch` on origin.

  Implementations must:

    1. Shell out to `gh pr create -R <repo_url> --base <base_branch>
       --head <rollup_branch> --title <title> --body <body>`.
    2. Parse the stdout for a GitHub PR URL (and the trailing PR
       number). Return `{:ok, %{number: n, url: url}}` on success.
    3. On any failure: return `{:error, reason}`. Do NOT retry.
  """
  @callback open_stack_pr(pr_args()) ::
              {:ok, pr_result()} | {:error, term()}

  @typedoc """
  Arguments for `diff_stat/1`. Runs `git diff --stat
  <base_branch>..<rollup_branch>` against the project working clone
  and returns the trimmed stdout summary.
  """
  @type diff_stat_args :: %{
          required(:repo_url) => String.t(),
          required(:base_branch) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:project_id) => String.t()
        }

  @doc """
  Return a `git diff --stat <base_branch>..<rollup_branch>` summary
  suitable for inclusion in a PR body.

  Implementations must fetch both refs first (the clone may be stale)
  and return `{:ok, summary}` on success or `{:error, reason}` on
  failure. The caller (deployer) treats failure as non-fatal — the PR
  body simply omits the diff stat section.
  """
  @callback diff_stat(diff_stat_args()) ::
              {:ok, String.t()} | {:error, term()}

  # ── revert_member_merge / close_stack_pr (stage 5) ──────────────────────

  @typedoc """
  Result of a successful merge revert on the rollup branch.

  `:revert_sha` is the SHA of the revert commit pushed to
  `rollup_branch`.
  """
  @type revert_result :: %{
          required(:status) => :reverted,
          required(:revert_sha) => String.t()
        }

  @typedoc """
  Arguments for `revert_member_merge/1`. The deployer passes the
  rollup branch and the offending merge commit's SHA. The runner is
  expected to run `git revert -m 1 <merge_sha>` against the rollup
  working clone and push the result back to origin.
  """
  @type revert_args :: %{
          required(:repo_url) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:merge_sha) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t(),
          optional(:member_task_id) => String.t()
        }

  @doc """
  Revert a merge commit on `rollup_branch` so the rollup returns to a
  buildable state after a CI failure has been attributed to a single
  member.

  Implementations must:

    1. Fetch the rollup branch (the clone may be stale).
    2. Check out `rollup_branch` at `origin/<rollup_branch>`.
    3. Run `git revert -m 1 --no-edit <merge_sha>` to revert the
       (assumed `--no-ff`) merge commit. `-m 1` selects the first
       parent (the rollup branch line) as the mainline.
    4. Push the revert commit to origin.
    5. Return `{:ok, %{status: :reverted, revert_sha: <new_sha>}}` on
       success or `{:error, reason}` on failure. Do NOT leave the
       working tree in a mid-revert state — abort and clean up before
       erroring.
  """
  @callback revert_member_merge(revert_args()) ::
              {:ok, revert_result()} | {:error, term()}

  @typedoc """
  Arguments for `close_stack_pr/1`. The deployer passes the PR number
  and an optional comment (currently always present) to leave on the
  PR explaining the CI-failure bounce. The runner shells out to
  `gh pr close -R <repo_url> <pr_number> --comment <comment>`.
  """
  @type close_pr_args :: %{
          required(:repo_url) => String.t(),
          required(:pr_number) => pos_integer(),
          optional(:comment) => String.t(),
          optional(:project_id) => String.t(),
          optional(:stack_id) => String.t()
        }

  @doc """
  Close a stack-level rollup PR (no merge) after CI failure attribution
  bounced an offending member.

  Implementations must:

    1. Shell out to `gh pr close -R <repo_url> <pr_number>` (with
       `--comment <comment>` when supplied).
    2. Return `{:ok, :closed}` on success or `{:error, reason}` on
       failure. The deployer treats failure as non-fatal — the bounce
       still proceeds and a follow-up cycle can retry the close.
  """
  @callback close_stack_pr(close_pr_args()) ::
              {:ok, :closed} | {:error, term()}

  # ── delete_rollup_branch (stage 3) ──────────────────────────────────────

  @typedoc """
  Arguments for `delete_rollup_branch/1`.

  ADR-0042 Rollup branch lifecycle: on successful merge of the
  stack-level PR, the rollup branch is cleaned up. The runner is
  project-agnostic and receives `repo_url` + `rollup_branch` + a
  `project_id` used for working-clone path scoping (mirroring the
  other callbacks).
  """
  @type delete_args :: %{
          required(:repo_url) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t()
        }

  @doc """
  Delete `rollup_branch` from `origin`.

  Called by `StackDeployer.handle_rollup_pr_merged/1` after the stack
  flips to `done`. Best-effort: a failure here does NOT undo the
  status transition — ops cleans up manually if delete fails on
  branch protection or transient network issues.

  Implementations must:

    1. `git ls-remote --heads origin refs/heads/<rollup_branch>` for
       idempotency. If empty, return `{:ok, :already_absent}` (no
       push performed).
    2. Otherwise `git push origin --delete <rollup_branch>` (or the
       equivalent colon-prefix `:<rollup_branch>` refspec). On success
       return `{:ok, :deleted}`.
    3. On branch-protection failure (stderr contains
       `protected branch`): return
       `{:error, {:branch_protected, output}}` so the caller can log
       and telemetry-emit but not retry blindly.
    4. On any other git failure: return
       `{:error, {:git_failed, args, exit_code, output}}`.
  """
  @callback delete_rollup_branch(delete_args()) ::
              {:ok, :deleted} | {:ok, :already_absent} | {:error, term()}

  # ── sha_reachable? (bug #2, task 019f708f) ──────────────────────────────

  @typedoc """
  Arguments for `sha_reachable?/1`.

  Given a git SHA and the name of a rollup branch, ask the runner whether
  the SHA is an ancestor of the branch tip on origin. This is the
  ground-truth check backing `Stacks.unblocked_in_stack?/1` and
  `StackDeployer.all_members_ready?/2` — a `metadata["merged_into_rollup_at"]`
  stamp records the caller's claim, but the runner is the arbiter.
  """
  @type reachability_args :: %{
          required(:repo_url) => String.t(),
          required(:rollup_branch) => String.t(),
          required(:sha) => String.t(),
          required(:project_id) => String.t(),
          optional(:stack_id) => String.t()
        }

  @doc """
  Return `{:ok, true}` if `sha` is reachable from the current tip of
  `rollup_branch` on `origin`, `{:ok, false}` if not, or `{:error, reason}`
  if the runner can't answer (e.g. transient fetch failure).

  Implementations must:

    1. Fetch the rollup branch (`git fetch origin <rollup_branch>`) so
       the local ref is fresh — a stale clone would falsely report
       "unreachable" for a SHA that WAS just merged.
    2. Run `git merge-base --is-ancestor <sha> origin/<rollup_branch>`.
       Git exits 0 when `sha` IS an ancestor, 1 when it is NOT, and
       128 (or another non-{0,1}) when the SHA is unknown / the check
       could not be performed. Callers treat `{:ok, false}` as
       "fabricated stamp — treat as unmerged" and `{:error, reason}` as
       "check unknown — be conservative".

  Callers may pass a short (e.g. 7-char) SHA; the runner must handle
  git's abbreviated-SHA resolution the same way `git rev-parse` does.
  """
  @callback sha_reachable?(reachability_args()) ::
              {:ok, boolean()} | {:error, term()}

  @optional_callbacks [
    merge_member_into_rollup: 1,
    open_stack_pr: 1,
    diff_stat: 1,
    revert_member_merge: 1,
    close_stack_pr: 1,
    delete_rollup_branch: 1,
    sha_reachable?: 1
  ]
end

defmodule Platform.Tasks.StackDeployer.NoopRunner do
  @moduledoc """
  No-op git runner used as the default in test env so existing
  `Stacks` test suites that don't care about the deployer can call
  `start_stack/1` without shelling out to git or hitting a real remote.

  Always returns `{:ok, %{status: :already_exists, base_sha: nil}}` so
  callers see a successful idempotent result.
  """

  @behaviour Platform.Tasks.StackDeployer.GitRunner

  @impl true
  def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: nil}}

  @impl true
  def merge_member_into_rollup(_args),
    do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

  @impl true
  def open_stack_pr(_args),
    do: {:ok, %{number: 0, url: "https://github.com/example/example/pull/0"}}

  @impl true
  def diff_stat(_args), do: {:ok, ""}

  @impl true
  def revert_member_merge(_args),
    do: {:ok, %{status: :reverted, revert_sha: "0000000000000000000000000000000000000000"}}

  @impl true
  def close_stack_pr(_args), do: {:ok, :closed}

  @impl true
  def delete_rollup_branch(_args), do: {:ok, :deleted}

  # Bug #2 (task 019f708f): default to "reachable" in the no-op runner so
  # existing Stacks tests that use plain-string `merged_into_rollup_at`
  # stamps or absent-runner setups keep passing. Tests exercising
  # unreachable-stamp behavior swap in a runner that returns `{:ok, false}`.
  @impl true
  def sha_reachable?(_args), do: {:ok, true}
end
