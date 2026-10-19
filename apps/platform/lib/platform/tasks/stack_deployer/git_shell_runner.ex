defmodule Platform.Tasks.StackDeployer.GitShellRunner do
  @moduledoc """
  Default git runner for `Platform.Tasks.StackDeployer`.

  Shells out to `git` to ensure a stack's rollup branch exists on
  origin at `base_branch` HEAD. Maintains a per-project working clone
  under `tmp/stack_deployer/<project_id>` (configurable via
  `:platform, :stack_deployer, repo_root: <path>`); the clone is reused
  across stacks so we don't pay clone cost on every start.

  ## Operation sequence

  1. Ensure a local clone exists at `<repo_root>/<project_id>` (clone
     if missing).
  2. `git fetch origin --prune` to refresh remote refs.
  3. `git ls-remote origin refs/heads/<rollup_branch>` to check
     idempotency. If the branch already exists on origin, return
     `{:ok, %{status: :already_exists, base_sha: <existing_sha>}}`.
  4. Resolve `base_branch` HEAD via `git rev-parse origin/<base_branch>`.
  5. Push: `git push origin <base_sha>:refs/heads/<rollup_branch>`. We
     push the SHA explicitly (not `origin/<base>:refs/heads/<rollup>`)
     so the push is deterministic against the SHA we just resolved.
  6. Return `{:ok, %{status: :created, base_sha: <base_sha>}}`.

  Errors are returned as `{:error, {atom, details}}` tuples. The caller
  (`StackDeployer.create_rollup_branch/1`) logs them.

  ## Why a working clone (vs. shallow / `gh api`)

  The plan for T5 specifies `git fetch + git push origin base:rollup`
  shell-out (per stage 1's plan description), and stages 2 onward will
  do real merges into this same clone. Sharing one clone per project
  means stage 2's merge work has the refs it needs without re-cloning.

  ## Authentication

  Push auth is read from `GITHUB_TOKEN` via the same git credential
  helper used by `Platform.Execution.LocalWorkspace.prepare_git_push_auth/2`.
  The helper string is defined once, in `LocalWorkspace`, and installed on
  the shared clone by `ensure_clone/2` — on the fresh-clone path via
  `git -c` (which also authenticates the clone itself) plus a
  `git config --local` write, and on the already-exists path via
  `git config --local`, so a clone made before the helper existed still
  picks it up.

  The token is never written to disk and never embedded in `repo_url`; the
  helper reads `$GITHUB_TOKEN` from the process environment at push time.
  If `GITHUB_TOKEN` is unset the helper exits non-zero rather than pushing
  with an empty password.

  ## `gh` availability

  The PR-facing callbacks (`open_stack_pr/1`, `close_stack_pr/1`) shell out
  to the GitHub CLI. When `gh` is not on `PATH` they return
  `{:error, {:gh_unavailable, message}}` rather than raising an `:enoent`
  `ErlangError` that is indistinguishable from a git failure.
  """

  @behaviour Platform.Tasks.StackDeployer.GitRunner

  alias Platform.Execution.LocalWorkspace

  require Logger

  # Default repo-root subdirectory name. The full path is composed at
  # runtime by `default_repo_root/0` off `System.tmp_dir!/0` — this
  # avoids the historical hardcoded `"tmp/stack_deployer"` that
  # `Path.expand/1` resolved to `<CWD>/tmp/stack_deployer` (i.e. under
  # the release's `/app` in the production container, which is owned by
  # `root:root` while the beam runs as UID 1000 — a `File.mkdir_p!/1`
  # crash there stalled the meeting-to-tasks pipeline rollup on
  # 2026-07-17). Override via `config :platform, :stack_deployer,
  # repo_root: <path>` when you want a persistent location.
  @default_repo_root_subdir "stack_deployer"

  @impl true
  def ensure_rollup_branch(%{
        repo_url: repo_url,
        base_branch: base_branch,
        rollup_branch: rollup_branch,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(base_branch) and is_binary(rollup_branch) and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <- git(["fetch", "origin", "--prune"], cd: clone_path),
         {:ok, remote_check} <-
           git(["ls-remote", "origin", "refs/heads/#{rollup_branch}"], cd: clone_path) do
      case parse_ls_remote_sha(remote_check) do
        {:ok, existing_sha} ->
          {:ok, %{status: :already_exists, base_sha: existing_sha}}

        :empty ->
          create_branch(clone_path, base_branch, rollup_branch)
      end
    end
  end

  @impl true
  def ensure_rollup_branch(_args), do: {:error, {:invalid_args, "missing required keys"}}

  @impl true
  def merge_member_into_rollup(%{
        repo_url: repo_url,
        rollup_branch: rollup_branch,
        member_branch: member_branch,
        member_slug: _member_slug,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(rollup_branch) and is_binary(member_branch) and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <-
           git(["fetch", "origin", member_branch, rollup_branch], cd: clone_path),
         # Force-update local refs to match origin so a stale clone doesn't
         # produce a non-fast-forward checkout/merge.
         {:ok, _} <-
           git(["checkout", "-B", rollup_branch, "origin/#{rollup_branch}"], cd: clone_path),
         {:ok, member_sha_out} <-
           git(["rev-parse", "origin/#{member_branch}"], cd: clone_path),
         member_sha = String.trim(member_sha_out),
         :merge_attempt <-
           attempt_merge(clone_path, member_sha),
         {:ok, merge_sha_out} <-
           git(["rev-parse", "HEAD"], cd: clone_path),
         {:ok, _} <-
           git(["push", "origin", "#{rollup_branch}:refs/heads/#{rollup_branch}"],
             cd: clone_path
           ) do
      {:ok, %{status: :merged, merge_sha: String.trim(merge_sha_out)}}
    else
      {:not_fast_forwardable, detail} ->
        # `git merge --ff-only` fails cleanly — no in-progress merge to
        # abort — so we do not need to reset the working tree here.
        {:error, :not_fast_forwardable, detail}

      {:conflict, output} ->
        files = collect_conflict_files(clone_path)
        _ = git(["merge", "--abort"], cd: clone_path)
        {:error, :conflict, %{files: files, output: output}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def merge_member_into_rollup(_args),
    do: {:error, {:invalid_args, "missing required keys"}}

  # ── open_stack_pr / diff_stat (stage 4) ─────────────────────────────────

  @impl true
  def open_stack_pr(%{
        repo_url: repo_url,
        base_branch: base_branch,
        rollup_branch: rollup_branch,
        title: title,
        body: body
      })
      when is_binary(repo_url) and is_binary(base_branch) and is_binary(rollup_branch) and
             is_binary(title) and is_binary(body) do
    args = [
      "pr",
      "create",
      "-R",
      repo_url,
      "--base",
      base_branch,
      "--head",
      rollup_branch,
      "--title",
      title,
      "--body",
      body
    ]

    Logger.info(
      "[StackDeployer] opening stack PR: gh pr create -R #{repo_url} " <>
        "--base #{base_branch} --head #{rollup_branch}"
    )

    with {:ok, gh} <- gh_executable(["pr", "create"]) do
      case System.cmd(gh, args,
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {output, 0} ->
          case parse_pr_url(output) do
            {:ok, url, number} ->
              {:ok, %{number: number, url: url}}

            :error ->
              {:error, {:pr_create_no_url, String.trim(output)}}
          end

        {output, code} ->
          {:error, {:gh_failed, ["pr", "create"], code, String.trim(output)}}
      end
    end
  end

  @impl true
  def open_stack_pr(_args), do: {:error, {:invalid_args, "missing required keys"}}

  @impl true
  def diff_stat(%{
        repo_url: repo_url,
        base_branch: base_branch,
        rollup_branch: rollup_branch,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(base_branch) and is_binary(rollup_branch) and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <- git(["fetch", "origin", base_branch, rollup_branch], cd: clone_path),
         {:ok, out} <-
           git(
             ["diff", "--stat", "origin/#{base_branch}..origin/#{rollup_branch}"],
             cd: clone_path
           ) do
      {:ok, String.trim(out)}
    end
  end

  @impl true
  def diff_stat(_args), do: {:error, {:invalid_args, "missing required keys"}}

  # ── list_added_migrations (task 019f7b7e stage 4) ───────────────────────

  @migrations_path "apps/platform/priv/repo/migrations/"

  @impl true
  def list_added_migrations(%{
        repo_url: repo_url,
        base_branch: base_branch,
        head_branch: head_branch,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(base_branch) and is_binary(head_branch) and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <- git(["fetch", "origin", base_branch, head_branch], cd: clone_path),
         {:ok, out} <-
           git(
             [
               "diff",
               "--name-only",
               "origin/#{base_branch}...origin/#{head_branch}",
               "--",
               @migrations_path
             ],
             cd: clone_path
           ) do
      paths =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, paths}
    end
  end

  @impl true
  def list_added_migrations(_args), do: {:error, {:invalid_args, "missing required keys"}}

  # ── pr_merge_state (task 01a05394 stage 1) ──────────────────────────────

  @impl true
  def pr_merge_state(%{repo_url: repo_url, pr_number: pr_number})
      when is_binary(repo_url) and is_integer(pr_number) and pr_number > 0 do
    args = [
      "pr",
      "view",
      Integer.to_string(pr_number),
      "-R",
      repo_url,
      "--json",
      "merged,mergedAt,mergeCommit,url"
    ]

    with {:ok, gh} <- gh_executable(["pr", "view"]) do
      case System.cmd(gh, args,
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {output, 0} ->
          parse_pr_merge_state(output)

        {output, code} ->
          {:error, {:gh_failed, ["pr", "view"], code, String.trim(output)}}
      end
    end
  end

  @impl true
  def pr_merge_state(_args), do: {:error, {:invalid_args, "missing required keys"}}

  @doc false
  # Parse the `gh pr view --json merged,mergedAt,mergeCommit,url` payload.
  #
  # Exposed (doc-hidden) so the suite can drive the parse directly against
  # merged / unmerged / malformed payloads without a real `gh` on PATH — an
  # uninstalled binary prints nothing, so a shell-out test would fail
  # silently on host state rather than on the code.
  #
  # Unparseable output is an ERROR, never `merged: false`: a parse failure
  # read as "not merged" is indistinguishable from a genuinely open PR.
  def parse_pr_merge_state(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"merged" => merged} = json} when is_boolean(merged) ->
        {:ok,
         %{
           merged: merged,
           merged_at: json["mergedAt"],
           merge_commit_sha: get_in(json, ["mergeCommit", "oid"]),
           url: json["url"]
         }}

      _ ->
        {:error, {:pr_view_unparseable, output}}
    end
  end

  # ── revert_member_merge / close_stack_pr (stage 5) ──────────────────────

  @impl true
  def revert_member_merge(%{
        repo_url: repo_url,
        rollup_branch: rollup_branch,
        merge_sha: merge_sha,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(rollup_branch) and is_binary(merge_sha) and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <- git(["fetch", "origin", rollup_branch], cd: clone_path),
         {:ok, _} <-
           git(["checkout", "-B", rollup_branch, "origin/#{rollup_branch}"], cd: clone_path),
         :revert_attempt <- attempt_revert(clone_path, merge_sha),
         {:ok, revert_sha_out} <- git(["rev-parse", "HEAD"], cd: clone_path),
         {:ok, _} <-
           git(["push", "origin", "#{rollup_branch}:refs/heads/#{rollup_branch}"],
             cd: clone_path
           ) do
      {:ok, %{status: :reverted, revert_sha: String.trim(revert_sha_out)}}
    else
      {:revert_failed, output} ->
        _ = git(["revert", "--abort"], cd: clone_path)
        {:error, {:revert_failed, String.trim(output)}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def revert_member_merge(_args), do: {:error, {:invalid_args, "missing required keys"}}

  @impl true
  def close_stack_pr(%{repo_url: repo_url, pr_number: pr_number} = args)
      when is_binary(repo_url) and is_integer(pr_number) and pr_number > 0 do
    base_args = ["pr", "close", "-R", repo_url, Integer.to_string(pr_number)]

    args_list =
      case Map.get(args, :comment) do
        comment when is_binary(comment) and comment != "" ->
          base_args ++ ["--comment", comment]

        _ ->
          base_args
      end

    Logger.info(
      "[StackDeployer] closing stack PR ##{pr_number} on #{repo_url} (post-CI-failure bounce)"
    )

    with {:ok, gh} <- gh_executable(["pr", "close"]) do
      case System.cmd(gh, args_list,
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {_out, 0} ->
          {:ok, :closed}

        {output, code} ->
          {:error, {:gh_failed, ["pr", "close"], code, String.trim(output)}}
      end
    end
  end

  @impl true
  def close_stack_pr(_args), do: {:error, {:invalid_args, "missing required keys"}}

  # ── delete_rollup_branch (stage 3) ──────────────────────────────────────

  @impl true
  def delete_rollup_branch(%{
        repo_url: repo_url,
        rollup_branch: rollup_branch,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(rollup_branch) and is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, ls_out} <-
           git(["ls-remote", "--heads", "origin", "refs/heads/#{rollup_branch}"], cd: clone_path) do
      case parse_ls_remote_sha(ls_out) do
        :empty ->
          Logger.info(
            "[StackDeployer] rollup branch #{rollup_branch} already absent on #{repo_url}"
          )

          {:ok, :already_absent}

        {:ok, _sha} ->
          push_delete(clone_path, rollup_branch)
      end
    end
  end

  @impl true
  def delete_rollup_branch(_args),
    do: {:error, {:invalid_args, "missing required keys"}}

  # ── sha_reachable? (bug #2, task 019f708f) ──────────────────────────────

  # Ask git whether `sha` is an ancestor of the rollup branch tip on
  # origin. Used by `Stacks.unblocked_in_stack?/1` and
  # `StackDeployer.all_members_ready?/2` so a fabricated
  # `merged_into_rollup_at` stamp can't promote a dependent or open a
  # rollup PR that omits the member's actual code.
  @impl true
  def sha_reachable?(%{
        repo_url: repo_url,
        rollup_branch: rollup_branch,
        sha: sha,
        project_id: project_id
      })
      when is_binary(repo_url) and is_binary(rollup_branch) and is_binary(sha) and sha != "" and
             is_binary(project_id) do
    clone_path = clone_path_for(project_id)

    with {:ok, _} <- ensure_clone(clone_path, repo_url),
         {:ok, _} <- git(["fetch", "origin", rollup_branch], cd: clone_path) do
      # `merge-base --is-ancestor` exits 0 when `sha` IS an ancestor of
      # `origin/<rollup>` and 1 when it is NOT. Any other exit code
      # means the check itself failed (unknown SHA, permission
      # denied, etc) — surface as `{:error, ...}` so callers can be
      # conservative.
      case System.cmd(
             "git",
             ["merge-base", "--is-ancestor", sha, "origin/#{rollup_branch}"],
             cd: clone_path,
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {_, 0} -> {:ok, true}
        {_, 1} -> {:ok, false}
        {output, code} -> {:error, {:git_failed, ["merge-base"], code, String.trim(output)}}
      end
    end
  end

  @impl true
  def sha_reachable?(_args), do: {:error, {:invalid_args, "missing required keys"}}

  defp push_delete(clone_path, rollup_branch) do
    args = ["push", "origin", "--delete", rollup_branch]

    Logger.info("[StackDeployer] deleting rollup branch #{rollup_branch} on origin")

    case System.cmd("git", args,
           cd: clone_path,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {_out, 0} ->
        {:ok, :deleted}

      {output, code} ->
        trimmed = String.trim(output)

        if branch_protected?(output) do
          {:error, {:branch_protected, trimmed}}
        else
          {:error, {:git_failed, args, code, trimmed}}
        end
    end
  end

  defp branch_protected?(output) do
    out = String.downcase(output)

    String.contains?(out, "protected branch") or
      String.contains?(out, "refusing to delete the current branch")
  end

  # Returns `:revert_attempt` on a clean revert, `{:revert_failed, output}`
  # otherwise (typically a conflict — revert merges can hit the same
  # class of conflicts merges can).
  defp attempt_revert(clone_path, merge_sha) do
    case System.cmd(
           "git",
           ["revert", "--no-edit", "-m", "1", merge_sha],
           cd: clone_path,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {_out, 0} -> :revert_attempt
      {output, _code} -> {:revert_failed, output}
    end
  end

  # Pull a GitHub PR URL out of `gh pr create` stdout. `gh pr create`
  # prints the URL on success (typically as the last non-empty line);
  # we extract the number from the trailing `/pull/<n>` segment.
  defp parse_pr_url(output) do
    case Regex.run(
           ~r{(https?://[^\s]+/pull/(\d+))},
           output
         ) do
      [_, url, number_str] ->
        case Integer.parse(number_str) do
          {n, _} when n > 0 -> {:ok, url, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # ── Internals (stage 2) ─────────────────────────────────────────────────

  # ADR-0042 Decision 2: rollup merges are fast-forward-only. Every
  # `task/<uuid>` member branch is cut from rollup HEAD (see stage 1),
  # so a validated pass fast-forwards trivially. If the member branch
  # somehow diverged (someone rebased manually, a sibling landed while
  # this member was in review and wasn't picked up by the "cut from
  # rollup HEAD" retarget, etc.) we halt with `:not_fast_forwardable`
  # so the task can be paused for human rebase — we do NOT auto-rebase
  # because that would silently rewrite an agent's commits.
  #
  # Returns:
  #   * `:merge_attempt` — clean fast-forward. Caller continues to push.
  #   * `{:not_fast_forwardable, %{member_sha, rollup_sha, output}}` —
  #     git rejected the FF. Caller returns `{:error, :not_fast_forwardable, detail}`.
  #   * `{:conflict, output}` — technically unreachable with `--ff-only`
  #     (git would report non-FF first), left as defence-in-depth.
  #   * `{:error, {:git_failed, ...}}` — any other failure.
  defp attempt_merge(clone_path, member_sha) do
    rollup_sha =
      case git(["rev-parse", "HEAD"], cd: clone_path) do
        {:ok, out} -> String.trim(out)
        _ -> ""
      end

    case System.cmd(
           "git",
           ["merge", "--ff-only", member_sha],
           cd: clone_path,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {_out, 0} ->
        :merge_attempt

      {output, _code} ->
        trimmed = String.trim(output)

        cond do
          not_fast_forwardable?(output) ->
            {:not_fast_forwardable,
             %{member_sha: member_sha, rollup_sha: rollup_sha, output: trimmed}}

          conflict?(output) ->
            {:conflict, trimmed}

          true ->
            {:error, {:git_failed, ["merge", "--ff-only", member_sha], 1, trimmed}}
        end
    end
  end

  defp not_fast_forwardable?(output) do
    out = String.downcase(output)

    String.contains?(out, "not possible to fast-forward") or
      String.contains?(out, "non-fast-forward") or
      String.contains?(out, "not a fast-forward")
  end

  defp conflict?(output) do
    out = String.downcase(output)

    String.contains?(out, "conflict") or
      String.contains?(out, "automatic merge failed")
  end

  defp collect_conflict_files(clone_path) do
    case System.cmd("git", ["diff", "--name-only", "--diff-filter=U"],
           cd: clone_path,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)

      _ ->
        []
    end
  end

  defp create_branch(clone_path, base_branch, rollup_branch) do
    with {:ok, base_sha_out} <-
           git(["rev-parse", "origin/#{base_branch}"], cd: clone_path),
         base_sha = String.trim(base_sha_out),
         true <- base_sha != "" or {:error, {:base_branch_not_found, base_branch}},
         {:ok, _} <-
           git(
             ["push", "origin", "#{base_sha}:refs/heads/#{rollup_branch}"],
             cd: clone_path
           ) do
      {:ok, %{status: :created, base_sha: base_sha}}
    else
      # The `or` above yields `true` or this tuple, never `false`. The clause
      # used to read `false ->`, so an empty rev-parse fell through every
      # `else` clause and raised WithClauseError (found by the Elixir 1.20
      # type checker).
      {:error, {:base_branch_not_found, _base_branch}} = err ->
        err

      {:error, {:git_failed, _args, _code, output}} = err ->
        # `git push` against an existing branch races us; treat the
        # "already exists" / "non-fast-forward" message as idempotent
        # success so concurrent invocations don't double-error.
        if push_already_exists?(output) do
          case git(["ls-remote", "origin", "refs/heads/#{rollup_branch}"], cd: clone_path) do
            {:ok, out} ->
              case parse_ls_remote_sha(out) do
                {:ok, sha} -> {:ok, %{status: :already_exists, base_sha: sha}}
                :empty -> err
              end

            _ ->
              err
          end
        else
          err
        end
    end
  end

  # Ensure the shared per-project clone exists AND carries the
  # `GITHUB_TOKEN` credential helper.
  #
  # The credential helper is the piece this runner's moduledoc deferred to
  # "a follow-up" that never happened: the prod container has no gitconfig,
  # no `.git-credentials` and no helper, so `GITHUB_TOKEN` in the
  # environment had nothing to consume it and every rollup push failed with
  # a generic non-zero git exit.
  #
  # Configured on BOTH paths deliberately, because this function
  # short-circuits on an existing clone and every clone made before this
  # change is in exactly that state — it would otherwise never acquire the
  # helper and the deploy would stay broken until someone deleted the clone
  # by hand.
  #
  # On the fresh-clone path the `-c` flags precede the subcommand so they
  # apply to the clone ITSELF (a private remote needs auth to clone at
  # all). Git-level `-c` does NOT persist into the new repository, so the
  # same settings are written to the clone's local config immediately
  # after — verified, not assumed: an earlier revision of this fix relied
  # on `-c` persistence and the regression test caught the empty config.
  #
  # The helper string lives in `LocalWorkspace` and is referenced, never
  # copied. The token itself is never written to disk and never embedded in
  # `repo_url` — the helper reads `$GITHUB_TOKEN` from the environment at
  # push time.
  defp ensure_clone(clone_path, repo_url) do
    if File.dir?(Path.join(clone_path, ".git")) do
      with :ok <- configure_push_auth(clone_path), do: {:ok, :exists}
    else
      :ok = File.mkdir_p!(Path.dirname(clone_path))

      args = LocalWorkspace.git_push_auth_cli_args() ++ ["clone", "--quiet", repo_url, clone_path]

      case System.cmd("git", args,
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {_out, 0} ->
          with :ok <- configure_push_auth(clone_path), do: {:ok, :cloned}

        {output, code} ->
          {:error, {:git_clone_failed, code, String.trim(output)}}
      end
    end
  end

  defp configure_push_auth(clone_path) do
    case LocalWorkspace.configure_git_push_auth(clone_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:git_credential_helper_failed, reason}}
    end
  end

  # Resolve the `gh` binary before shelling out.
  #
  # `System.cmd("gh", …)` on a host without the GitHub CLI raises
  # `ErlangError: :enoent`, which surfaces through the deployer's
  # try/rescue as a generic "rollup merge raised" blocker — visually
  # indistinguishable from a git failure, and the reason the missing binary
  # in `ghcr.io/getburrowing/core` took a separate investigation to find.
  #
  # Returning a distinct, greppable `:gh_unavailable` that names the binary
  # turns the next occurrence into a one-line diagnosis. Mirrors the
  # `System.find_executable("gh")` guard in
  # `Platform.Responsibilities.Handlers.ArchitectureCronSweep`.
  defp gh_executable(subcommand) do
    case System.find_executable("gh") do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        Logger.error(
          "[StackDeployer] `gh` (GitHub CLI) is not installed or not on PATH — " <>
            "cannot run `gh #{Enum.join(subcommand, " ")}`"
        )

        {:error,
         {:gh_unavailable,
          "`gh` (GitHub CLI) not found on PATH; cannot run `gh #{Enum.join(subcommand, " ")}`"}}
    end
  end

  defp git(args, opts) do
    cd = Keyword.fetch!(opts, :cd)

    case System.cmd("git", args,
           cd: cd,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:git_failed, args, code, String.trim(output)}}
    end
  end

  defp parse_ls_remote_sha(""), do: :empty

  defp parse_ls_remote_sha(output) do
    case output |> String.trim() |> String.split() do
      [sha | _] when byte_size(sha) >= 7 -> {:ok, sha}
      _ -> :empty
    end
  end

  defp push_already_exists?(output) do
    out = String.downcase(output)

    String.contains?(out, "already exists") or
      String.contains?(out, "non-fast-forward") or
      String.contains?(out, "rejected")
  end

  defp clone_path_for(project_id) when is_binary(project_id) do
    safe = String.replace(project_id, ~r/[^A-Za-z0-9._-]/u, "_")
    Path.join(repo_root(), safe)
  end

  defp repo_root do
    Application.get_env(:platform, :stack_deployer, [])
    |> Keyword.get(:repo_root, default_repo_root())
    |> Path.expand()
  end

  # Runtime-resolved default so we land in a writable dir regardless of
  # CWD. `System.tmp_dir!/0` picks `TMPDIR` / `TEMP` / `TMP` / `/tmp` in
  # that order — every container image we ship has one of those writable
  # by the release user. See the module attribute doc above for the
  # historical /app permission-denied failure this replaces.
  defp default_repo_root, do: Path.join(System.tmp_dir!(), @default_repo_root_subdir)
end
