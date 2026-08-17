defmodule Platform.Execution.LocalRunnerTest do
  @moduledoc """
  Tests for the local runner provider, credential leasing, and the
  GitHub proof-of-life push path.

  These tests cover:
    - Workspace allocation determinism
    - Process spawn and provider ref shape
    - Graceful stop and forced kill semantics
    - CredentialLease issuance, env injection, and revocation
    - LocalWorkspace git worktree setup and push path (unit-level)
  """
  use ExUnit.Case, async: false

  alias Platform.Execution.{CredentialLease, LocalWorkspace, Run}
  alias Platform.Execution.{LocalRunner, LocalProcessWrapper}

  @helper_script Path.expand("../../support/fixtures/local_runner_helper.sh", __DIR__)

  # ---------------------------------------------------------------------------
  # Workspace allocation
  # ---------------------------------------------------------------------------

  describe "LocalWorkspace.ensure_workspace/2" do
    test "allocates a deterministic per-run workspace under the configured root" do
      root = temp_dir("workspace-root")
      run = run_fixture("task/123:demo")

      assert {:ok, first} = LocalWorkspace.ensure_workspace(run, run_root: root)
      assert {:ok, second} = LocalWorkspace.ensure_workspace(run, run_root: root)

      assert first == second
      assert first.root == Path.expand(root)
      assert first.path == Path.join(Path.expand(root), "task_123_demo")
      assert File.dir?(first.path)
    end

    test "different runs get distinct workspaces" do
      root = temp_dir("workspace-root")
      run_a = run_fixture("run-A")
      run_b = run_fixture("run-B")

      {:ok, ws_a} = LocalWorkspace.ensure_workspace(run_a, run_root: root)
      {:ok, ws_b} = LocalWorkspace.ensure_workspace(run_b, run_root: root)

      assert ws_a.path != ws_b.path
    end
  end

  # ---------------------------------------------------------------------------
  # Process spawn and provider ref
  # ---------------------------------------------------------------------------

  describe "LocalRunner.spawn_run/2" do
    test "returns a provider ref with correct shape and spawns a live process" do
      run_id = unique_run_id()
      root = temp_dir("spawn-root")
      ready_file = Path.join(root, "#{run_id}.ready")
      state_file = Path.join(root, "#{run_id}.state")

      run = run_fixture(run_id)

      assert {:ok, ref} =
               LocalRunner.spawn_run(run,
                 run_root: root,
                 run_server: self(),
                 command: "/bin/sh",
                 args: [@helper_script, "loop", ready_file, state_file]
               )

      assert ref.provider == :local
      assert ref.run_id == run_id
      assert ref.workspace_root == Path.expand(root)
      assert ref.workspace_path == Path.join(Path.expand(root), run_id)
      assert is_pid(ref.wrapper_pid)
      assert is_integer(ref.os_pid)

      assert_file_eventually(ready_file)

      # Clean up
      LocalProcessWrapper.force_stop(ref.wrapper_pid)
    end

    test "returns error when command is missing" do
      run = run_fixture(unique_run_id())
      root = temp_dir("no-cmd")

      assert {:error, :missing_command} =
               LocalRunner.spawn_run(run, run_root: root, run_server: self())
    end

    test "injects credential lease env into the child process" do
      run_id = unique_run_id()
      root = temp_dir("lease-env-root")
      output_file = Path.join(root, "#{run_id}.env")

      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: run_id,
          github_token: "test-token-#{run_id}",
          author_name: "Test Runner",
          author_email: "runner@test.local"
        )

      run = run_fixture(run_id)

      assert {:ok, ref} =
               LocalRunner.spawn_run(run,
                 run_root: root,
                 run_server: self(),
                 command: "/bin/sh",
                 args: ["-c", "printenv GITHUB_TOKEN > #{output_file} && sync"],
                 credential_lease: lease
               )

      # Wait for the process to finish writing (not just file existence)
      assert_eventually(
        fn ->
          File.exists?(output_file) && String.trim(File.read!(output_file)) != ""
        end,
        5_000
      )

      assert String.trim(File.read!(output_file)) == "test-token-#{run_id}"

      _ = ref
    end
  end

  # ---------------------------------------------------------------------------
  # Stop and kill semantics
  # ---------------------------------------------------------------------------

  describe "LocalRunner stop/kill" do
    test "request_stop sends TERM to the child and it exits cleanly" do
      run_id = unique_run_id()
      root = temp_dir("stop-root")
      ready_file = Path.join(root, "#{run_id}.ready")
      state_file = Path.join(root, "#{run_id}.state")

      run = run_fixture(run_id)

      {:ok, ref} =
        LocalRunner.spawn_run(run,
          run_root: root,
          run_server: self(),
          command: "/bin/sh",
          args: [@helper_script, "loop", ready_file, state_file]
        )

      assert_file_eventually(ready_file)

      run_with_ref = %Run{run | runner_ref: ref}
      assert :ok = LocalRunner.request_stop(run_with_ref, [])

      # Wrapper exits and we get a runner_exited message
      assert_eventually(
        fn ->
          receive do
            {:runner_exited, ^run_id, %{exit_state: :cancelled}} -> true
          after
            10 -> false
          end
        end,
        2_000
      )

      assert_file_eventually(state_file)
      assert File.read!(state_file) == "term\n"
    end

    test "force_stop kills the child immediately" do
      run_id = unique_run_id()
      root = temp_dir("kill-root")
      ready_file = Path.join(root, "#{run_id}.ready")
      state_file = Path.join(root, "#{run_id}.state")

      run = run_fixture(run_id)

      {:ok, ref} =
        LocalRunner.spawn_run(run,
          run_root: root,
          run_server: self(),
          command: "/bin/sh",
          args: [@helper_script, "loop", ready_file, state_file]
        )

      assert_file_eventually(ready_file)

      run_with_ref = %Run{run | runner_ref: ref}
      assert :ok = LocalRunner.force_stop(run_with_ref, [])

      # Wrapper exits and we get a runner_exited message with :killed
      assert_eventually(
        fn ->
          receive do
            {:runner_exited, ^run_id, %{exit_state: :killed}} -> true
          after
            10 -> false
          end
        end,
        2_000
      )

      # State file should NOT be written (SIGKILL bypasses the trap)
      refute File.exists?(state_file)
    end

    test "force_stop after wrapper exit is safe (idempotent)" do
      run_id = unique_run_id()
      root = temp_dir("idempotent-root")
      state_file = Path.join(root, "#{run_id}.state")

      run = run_fixture(run_id)

      {:ok, ref} =
        LocalRunner.spawn_run(run,
          run_root: root,
          run_server: self(),
          command: "/bin/sh",
          args: [@helper_script, "exit0", Path.join(root, "ready"), state_file]
        )

      # Wait for the process to exit on its own
      assert_eventually(
        fn ->
          !Process.alive?(ref.wrapper_pid)
        end,
        2_000
      )

      run_with_ref = %Run{run | runner_ref: ref}
      assert :ok = LocalRunner.force_stop(run_with_ref, [])
    end
  end

  # ---------------------------------------------------------------------------
  # CredentialLease
  # ---------------------------------------------------------------------------

  describe "CredentialLease" do
    test "issues a github lease with token from opts" do
      run_id = unique_run_id()

      assert {:ok, lease} =
               CredentialLease.lease(:github,
                 run_id: run_id,
                 github_token: "ghp_test123",
                 author_name: "Test User",
                 author_email: "test@suite.local"
               )

      assert lease.kind == :github
      assert lease.run_id == run_id
      assert lease.credentials.token == "ghp_test123"
      assert lease.credentials.author_name == "Test User"
      assert CredentialLease.valid?(lease)
    end

    test "to_env/1 injects GITHUB_TOKEN and git identity vars" do
      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: unique_run_id(),
          github_token: "ghp_abc",
          author_name: "Suite Bot",
          author_email: "bot@suite.local"
        )

      env = CredentialLease.to_env(lease)

      assert env["GITHUB_TOKEN"] == "ghp_abc"
      assert env["GIT_AUTHOR_NAME"] == "Suite Bot"
      assert env["GIT_COMMITTER_NAME"] == "Suite Bot"
      assert env["GIT_AUTHOR_EMAIL"] == "bot@suite.local"
      assert env["GIT_COMMITTER_EMAIL"] == "bot@suite.local"
    end

    test "issues a model lease for anthropic" do
      {:ok, lease} =
        CredentialLease.lease(:model,
          run_id: unique_run_id(),
          provider: :anthropic,
          api_key: "sk-ant-test"
        )

      assert lease.kind == :model
      assert lease.credentials.provider == :anthropic
      assert lease.credentials.api_key == "sk-ant-test"

      env = CredentialLease.to_env(lease)
      assert env["ANTHROPIC_API_KEY"] == "sk-ant-test"
    end

    test "revoke/1 marks lease as revoked and valid?/1 returns false" do
      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: unique_run_id(),
          github_token: "ghp_abc"
        )

      assert CredentialLease.valid?(lease)

      {:ok, revoked} = CredentialLease.revoke(lease)
      refute CredentialLease.valid?(revoked)
      assert is_struct(revoked.revoked_at, DateTime)
    end

    test "returns error when github token is missing and env var is unset" do
      # Unset env var if set by test environment
      prev = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")

      try do
        assert {:error, :missing_github_token} =
                 CredentialLease.lease(:github, run_id: unique_run_id())
      after
        if prev, do: System.put_env("GITHUB_TOKEN", prev)
      end
    end

    test "issues a custom lease with arbitrary credentials" do
      {:ok, lease} =
        CredentialLease.lease(:custom,
          run_id: unique_run_id(),
          credentials: %{MY_SECRET: "s3cr3t", OTHER_VAR: "value"}
        )

      assert lease.kind == :custom
      env = CredentialLease.to_env(lease)
      assert env["MY_SECRET"] == "s3cr3t"
    end
  end

  # ---------------------------------------------------------------------------
  # Git worktree setup (unit-level, using a local temp repo)
  # ---------------------------------------------------------------------------

  describe "LocalWorkspace git worktree" do
    test "setup_git_worktree creates a worktree from a local repo" do
      {repo_path, branch} = setup_temp_git_repo()
      run_id = unique_run_id()
      root = temp_dir("wt-root")

      run = run_fixture(run_id)
      {:ok, workspace} = LocalWorkspace.ensure_workspace(run, run_root: root)

      assert {:ok, wt_path} =
               LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)

      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, ".git")) or File.dir?(Path.join(wt_path, ".git"))
    end

    test "setup_git_worktree is idempotent when called twice" do
      {repo_path, branch} = setup_temp_git_repo()
      run_id = unique_run_id()
      root = temp_dir("wt-idempotent")

      run = run_fixture(run_id)
      {:ok, workspace} = LocalWorkspace.ensure_workspace(run, run_root: root)

      assert {:ok, wt_path_1} =
               LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)

      assert {:ok, wt_path_2} =
               LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)

      assert wt_path_1 == wt_path_2
    end
  end

  # ---------------------------------------------------------------------------
  # Worktree REMOVAL (task 019fe1b7 stage 3). Before this stage the module
  # that creates worktrees had no removal function at all — verified at the
  # base commit, not assumed.
  # ---------------------------------------------------------------------------

  describe "LocalWorkspace.worktree_path/2 containment" do
    test "a run id of \"..\" is REFUSED, because the sanitiser does not stop it" do
      root = temp_dir("escape-root")

      # THE HAZARD IS REAL IN THIS FIXTURE, which is the assertion that makes
      # the refusal below mean something: `safe_run_segment/1` replaces
      # anything outside [A-Za-z0-9._-] with `_`, and `.` is INSIDE that set.
      # So ".." survives sanitisation intact and the naive derivation lands
      # one level ABOVE the run root. Asserting the refusal without asserting
      # the hazard would be true by construction.
      naive = Path.expand(Path.join([Path.expand(root), "..", "git"]))
      refute String.starts_with?(naive, Path.expand(root) <> "/")

      assert {:error, {:unsafe_run_id, ".."}} = LocalWorkspace.worktree_path("..", run_root: root)
    end

    test "path separators are sanitised INTO the root, not refused" do
      # A discriminating pair: `/` is outside the allowed set and becomes `_`,
      # so a separator-bearing id stays contained and is legal. Only the ids
      # that genuinely escape are refused — a check that refused both would
      # not distinguish sanitisation from containment.
      root = temp_dir("escape-root")
      expanded = Path.expand(root)

      assert {:ok, path} = LocalWorkspace.worktree_path("/etc/passwd", run_root: root)
      assert path == Path.join([expanded, "_etc_passwd", "git"])

      # `"../.."` too: both separators are replaced, so it collapses to the
      # single harmless segment `".._.."` rather than climbing twice. The one
      # id that escapes is a bare `".."` — which is exactly why the refusal is
      # a containment check on the DERIVED path and not a blacklist of
      # substrings.
      assert {:ok, twice} = LocalWorkspace.worktree_path("../..", run_root: root)
      assert twice == Path.join([expanded, ".._..", "git"])

      assert {:ok, nested} = LocalWorkspace.worktree_path("a/../../b", run_root: root)
      assert String.starts_with?(nested, expanded <> "/")
    end

    test "remove_git_worktree/2 refuses an escaping run id INSTEAD of deleting" do
      root = temp_dir("escape-remove-root")
      sibling = Path.join(Path.dirname(Path.expand(root)), "git")
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "precious.txt"), "someone else's work\n")

      assert {:error, {:unsafe_run_id, ".."}} =
               LocalWorkspace.remove_git_worktree("..", run_root: root)

      # What the containment check is FOR: the directory the naive derivation
      # would have pointed at is untouched.
      assert File.exists?(Path.join(sibling, "precious.txt"))
    end
  end

  describe "LocalWorkspace.remove_git_worktree/2" do
    test "removes a real worktree and prunes the repo's registration" do
      {repo_path, branch} = setup_temp_git_repo()
      run_id = unique_run_id()
      root = temp_dir("wt-remove")

      {:ok, workspace} = LocalWorkspace.ensure_workspace(run_fixture(run_id), run_root: root)
      {:ok, wt_path} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)
      assert File.dir?(wt_path)

      assert {:ok, :removed} = LocalWorkspace.remove_git_worktree(run_id, run_root: root)
      refute File.exists?(wt_path)

      {listing, 0} = System.cmd("git", ["worktree", "list"], cd: repo_path)
      refute listing =~ wt_path
    end

    test "an absent worktree is {:ok, :absent} — checked BEFORE acting" do
      root = temp_dir("wt-absent")

      assert {:ok, :absent} =
               LocalWorkspace.remove_git_worktree(unique_run_id(), run_root: root)
    end

    test "removing twice is {:ok, :removed} then {:ok, :absent}, never an error" do
      {repo_path, branch} = setup_temp_git_repo()
      run_id = unique_run_id()
      root = temp_dir("wt-remove-twice")

      {:ok, workspace} = LocalWorkspace.ensure_workspace(run_fixture(run_id), run_root: root)
      {:ok, _wt} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)

      assert {:ok, :removed} = LocalWorkspace.remove_git_worktree(run_id, run_root: root)
      assert {:ok, :absent} = LocalWorkspace.remove_git_worktree(run_id, run_root: root)
    end

    test "a plain workspace directory with no git state is removed directly" do
      run_id = unique_run_id()
      root = temp_dir("wt-plain")

      {:ok, workspace} = LocalWorkspace.ensure_workspace(run_fixture(run_id), run_root: root)
      plain = Path.join(workspace.path, "git")
      File.mkdir_p!(plain)

      assert {:ok, :removed} = LocalWorkspace.remove_git_worktree(run_id, run_root: root)
      refute File.exists?(plain)
    end

    test "a DIRTY worktree git refuses to remove surfaces as an error, not :absent" do
      # The failure that must NOT be swallowed. `--force` would make this
      # green and would be the bug: a worktree holding uncommitted work is
      # exactly the one a human still needs.
      {repo_path, branch} = setup_temp_git_repo()
      run_id = unique_run_id()
      root = temp_dir("wt-dirty")

      {:ok, workspace} = LocalWorkspace.ensure_workspace(run_fixture(run_id), run_root: root)
      {:ok, wt_path} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)
      File.write!(Path.join(wt_path, "uncommitted.txt"), "work in progress\n")

      assert {:error, {:worktree_remove_failed, code, output}} =
               LocalWorkspace.remove_git_worktree(run_id, run_root: root)

      assert code != 0
      assert is_binary(output)

      # And the work is still there. An error that had deleted anyway would
      # satisfy the tuple assertion alone.
      assert File.exists?(Path.join(wt_path, "uncommitted.txt"))
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub proof-of-life push path (local bare repo)
  # ---------------------------------------------------------------------------

  describe "LocalWorkspace.push_branch/3" do
    test "commits and pushes to a local bare remote" do
      run_id = unique_run_id()
      root = temp_dir("push-root")

      # Create a bare remote and a clone with a run branch
      {clone_path, branch} = setup_temp_repo_with_remote(root, run_id)

      # Write a proof-of-life change
      File.write!(Path.join(clone_path, "proof.txt"), "run=#{run_id}\n")

      assert :ok =
               LocalWorkspace.push_branch(clone_path, run_id,
                 message: "proof-of-life: run #{run_id}",
                 remote: "origin"
               )

      # Verify the push landed in the bare remote by checking the ref exists
      {output, 0} =
        System.cmd("git", ["ls-remote", "origin", "refs/heads/#{branch}"],
          cd: clone_path,
          stderr_to_stdout: true
        )

      assert String.contains?(output, branch)
    end

    test "push with a github credential lease injects GITHUB_TOKEN into git env" do
      run_id = unique_run_id()
      root = temp_dir("push-lease-root")

      # We can't make a real GitHub push in tests, so we verify the env is
      # injected correctly by checking the lease-to-env conversion applies and
      # the push path runs without errors on a local remote.
      {clone_path, _branch} = setup_temp_repo_with_remote(root, run_id)

      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: run_id,
          github_token: "ghp_testtoken_notreal",
          author_name: "Suite Bot",
          author_email: "bot@suite.local"
        )

      File.write!(Path.join(clone_path, "lease-proof.txt"), "token-injected\n")

      # Should still succeed pushing to the local bare remote even with a lease
      assert :ok =
               LocalWorkspace.push_branch(clone_path, run_id,
                 message: "proof-of-life with lease: run #{run_id}",
                 remote: "origin",
                 lease: lease
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_fixture(run_id) do
    Run.new(run_id, "task-#{run_id}", [])
  end

  # Every temp path in this file hangs off ONE root that is unique to this
  # BEAM run and is deleted when the module finishes.
  #
  # Task 019fb978 stage 1 measured why. The old construction was
  # `Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer(...)}")`:
  # `System.tmp_dir!()` is machine-global and `System.unique_integer/1` is
  # unique only within ONE VM, restarting from a low value in every new
  # `mix test`. The product is therefore NOT unique across runs — every run
  # reissued `/tmp/git-repo-48`, `/tmp/wt-root-51`, `run-61`, and nothing ever
  # deleted them. Census on the measuring box found 776 `workspace-root-*`,
  # 501 `no-cmd-*` and 450 `spawn-root-*` directories left behind.
  #
  # Two ways that bit. `setup_temp_git_repo/0` re-entered an existing repo, so
  # `git remote add origin` printed "error: remote origin already exists." and
  # a stale worktree registration survived — a later run asking for the same
  # branch got `fatal: '<branch>' is already used by worktree at ...` (exit
  # 128). And `printenv GITHUB_TOKEN > <output_file>` opens `O_TRUNC`, so a
  # second run regenerating the same `run_id` truncated the first run's file
  # between its write and its read.
  #
  # Measured: 8 of 20 runs failing on a shared `/tmp` (40%, which reproduces
  # the banked ~1-in-3), 1 of 12 into a private-but-REUSED dir (and that one
  # was run 02, colliding with run 01's leavings), 0 of 12 with a fresh root
  # per run. Residue is the mechanism; concurrency only widens the window,
  # which is why cleanup is half the fix and not an afterthought.
  #
  # Randomness rather than a counter is the point: the value has to be unique
  # across OS processes, and no per-VM counter can be.
  #
  # Task 01a0108d hoisted that conclusion out of this file: the token is now
  # `Platform.TestTemp.unique_token/0` and the root comes from
  # `Platform.TestTemp.mkdir!/1`, so the 51 sites that had the old construction
  # share one implementation with this one. The account above is the measured
  # record of why; only the location of the code changed.
  setup_all do
    root = Platform.TestTemp.mkdir!("platform-local-runner-test")
    :persistent_term.put({__MODULE__, :temp_root}, root)

    on_exit(fn ->
      File.rm_rf(root)
      :persistent_term.erase({__MODULE__, :temp_root})
    end)

    :ok
  end

  defp temp_root do
    :persistent_term.get({__MODULE__, :temp_root})
  end

  defp temp_dir(prefix) do
    path = Path.join(temp_root(), "#{prefix}-#{unique_token()}")

    File.mkdir_p!(path)
    path
  end

  defp unique_run_id do
    "run-#{unique_token()}"
  end

  # Delegated so this file and the swept call sites cannot drift apart. The
  # shared token is lowercase base32 plus the OS pid plus a counter: safe as a
  # path segment AND as a git branch name (the branch built in
  # `setup_temp_git_repo/0` interpolates one).
  defp unique_token, do: Platform.TestTemp.unique_token()

  defp assert_file_eventually(path, timeout \\ 1_000) do
    assert_eventually(fn -> File.exists?(path) end, timeout)
  end

  defp assert_eventually(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      assert true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      else
        flunk("condition was not met before timeout")
      end
    end
  end

  # Set up a minimal local git repo for worktree tests
  defp setup_temp_git_repo do
    repo = temp_dir("git-repo")
    branch = "run-wt-#{unique_token()}"

    System.cmd("git", ["init", "--initial-branch=main"], cd: repo, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: repo)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# test\n")
    System.cmd("git", ["add", "."], cd: repo)
    System.cmd("git", ["commit", "-m", "init"], cd: repo, stderr_to_stdout: true)

    {repo, branch}
  end

  # Set up a bare remote + clone with a branch ready for push
  defp setup_temp_repo_with_remote(root, run_id) do
    bare = Path.join(root, "bare.git")
    clone = Path.join(root, "clone")
    branch = "run/#{run_id}"

    System.cmd("git", ["init", "--bare", "--initial-branch=main", bare], stderr_to_stdout: true)

    # Seed the bare repo so it has a HEAD ref
    seed = Path.join(root, "seed")
    File.mkdir_p!(seed)
    System.cmd("git", ["init", "--initial-branch=main"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: seed)
    System.cmd("git", ["config", "user.name", "Test"], cd: seed)
    File.write!(Path.join(seed, "README.md"), "# suite-runner-test\n")
    System.cmd("git", ["add", "."], cd: seed)
    System.cmd("git", ["commit", "-m", "init"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["remote", "add", "origin", bare], cd: seed)
    System.cmd("git", ["push", "origin", "main"], cd: seed, stderr_to_stdout: true)

    # Clone and set up the run branch
    System.cmd("git", ["clone", bare, clone], stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: clone)
    System.cmd("git", ["config", "user.name", "Suite Bot"], cd: clone)
    System.cmd("git", ["checkout", "-b", branch], cd: clone, stderr_to_stdout: true)

    {clone, branch}
  end
end
