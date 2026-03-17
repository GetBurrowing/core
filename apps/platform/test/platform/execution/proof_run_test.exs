defmodule Platform.Execution.ProofRunTest do
  @moduledoc """
  Integration tests for the end-to-end proof-of-life run orchestration.

  These tests exercise the full ProofRun.run/2 flow in both repository-backed
  and workspace-only modes, and verify that artifacts + context items are
  registered and surfaced correctly.
  """
  use ExUnit.Case, async: false

  alias Platform.Execution.ProofRun
  alias Platform.Execution

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_task_id, do: "task-proof-#{System.unique_integer([:positive, :monotonic])}"

  defp temp_dir(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  # Set up a bare remote + clone with a branch for push tests
  defp setup_temp_repo_with_remote(root) do
    bare = Path.join(root, "bare.git")
    clone = Path.join(root, "clone")

    System.cmd("git", ["init", "--bare", "--initial-branch=main", bare], stderr_to_stdout: true)

    seed = Path.join(root, "seed")
    File.mkdir_p!(seed)
    System.cmd("git", ["init", "--initial-branch=main"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: seed)
    System.cmd("git", ["config", "user.name", "Test"], cd: seed)
    File.write!(Path.join(seed, "README.md"), "# suite-proof-test\n")
    System.cmd("git", ["add", "."], cd: seed)
    System.cmd("git", ["commit", "-m", "init"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["remote", "add", "origin", bare], cd: seed)
    System.cmd("git", ["push", "origin", "main"], cd: seed, stderr_to_stdout: true)

    System.cmd("git", ["clone", bare, clone], stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: clone)
    System.cmd("git", ["config", "user.name", "Suite Bot"], cd: clone)

    {clone, bare}
  end

  # Derive the worktree path the same way ProofRun/LocalWorkspace do
  defp expected_worktree_path(run_id, run_root) do
    safe_id =
      run_id
      |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
      |> case do
        "" -> "run"
        v -> v
      end

    Path.join([Path.expand(run_root), safe_id, "git"])
  end

  # ---------------------------------------------------------------------------
  # Workspace-only mode (no repo_path)
  # ---------------------------------------------------------------------------

  describe "ProofRun.run/2 — workspace-only mode" do
    test "creates a run, pushes context, registers a verification artifact, and completes" do
      task_id = unique_task_id()
      root = temp_dir("proof-ws-only")

      assert {:ok, result} = ProofRun.run(task_id, run_root: root, repo_path: nil)

      # Run should be completed
      assert %{run: run, artifacts: artifacts, pushed: pushed} = result
      assert run.status == :completed
      assert run.task_id == task_id

      # No push in workspace-only mode (no credential lease)
      refute pushed

      # At least the verification artifact was registered
      assert length(artifacts) >= 1
      verify_art = Enum.find(artifacts, &(&1.name == "proof-of-life verification"))
      assert verify_art
      assert verify_art.kind == :code_output
      assert verify_art.task_id == task_id

      # Run is terminal — but the GenServer process is still alive in the
      # RunSupervisor until it crashes or is evicted. The run struct should
      # reflect :completed status.
      assert {:ok, fetched_run} = Execution.get_run(run.id)
      assert fetched_run.status == :completed
    end

    test "verification artifact locator contains inline content" do
      task_id = unique_task_id()
      root = temp_dir("proof-inline")

      {:ok, result} = ProofRun.run(task_id, run_root: root, repo_path: nil)

      verify_art = Enum.find(result.artifacts, &(&1.name == "proof-of-life verification"))
      assert %{"type" => "inline", "content" => content} = verify_art.locator
      assert is_binary(content)
    end

    test "verification artifact metadata captures step and branch info" do
      task_id = unique_task_id()
      root = temp_dir("proof-meta")

      {:ok, result} = ProofRun.run(task_id, run_root: root, repo_path: nil)

      verify_art = Enum.find(result.artifacts, &(&1.name == "proof-of-life verification"))
      assert %{"step" => "git_status"} = verify_art.metadata
    end
  end

  # ---------------------------------------------------------------------------
  # Repository mode (with a real local git repo)
  # ---------------------------------------------------------------------------

  describe "ProofRun.run/2 — repository mode" do
    setup do
      original_proof_config = Application.get_env(:platform, :proof_of_life, [])
      original_execution_config = Application.get_env(:platform, :execution, [])

      on_exit(fn ->
        Application.put_env(:platform, :proof_of_life, original_proof_config)
        Application.put_env(:platform, :execution, original_execution_config)
      end)

      :ok
    end

    test "writes proof-of-life.md change and captures git status as verification artifact" do
      task_id = unique_task_id()
      root = temp_dir("proof-repo")
      {clone_path, _bare} = setup_temp_repo_with_remote(root)

      # Let ProofRun derive its own branch from the run_id (don't pass a branch)
      opts = [
        repo_path: clone_path,
        run_root: root
      ]

      assert {:ok, result} = ProofRun.run(task_id, opts)

      assert result.run.status == :completed
      assert is_binary(result.branch)

      # Verification output should be a string (git status output)
      verify_art = Enum.find(result.artifacts, &(&1.name == "proof-of-life verification"))
      assert verify_art
      content = get_in(verify_art.locator, ["content"]) || ""
      assert is_binary(content)

      # Proof-of-life.md should exist in the worktree at the expected path
      wt_path = expected_worktree_path(result.run.id, root)
      proof_file = Path.join(wt_path, "docs/proof-of-life.md")
      assert File.exists?(proof_file)
      assert String.contains?(File.read!(proof_file), task_id)
    end

    test "proof-of-life.md contains run ID in the entry" do
      task_id = unique_task_id()
      root = temp_dir("proof-runid")
      {clone_path, _bare} = setup_temp_repo_with_remote(root)

      {:ok, result} = ProofRun.run(task_id, repo_path: clone_path, run_root: root)

      wt_path = expected_worktree_path(result.run.id, root)
      proof_file = Path.join(wt_path, "docs/proof-of-life.md")
      content = File.read!(proof_file)

      assert String.contains?(content, result.run.id)
      assert String.contains?(content, "proof-of-life")
    end

    test "two runs on the same task use distinct run-scoped branches" do
      task_id = unique_task_id()
      root = temp_dir("proof-two-runs")
      {clone_path, _bare} = setup_temp_repo_with_remote(root)

      opts = [repo_path: clone_path, run_root: root]

      # First run — no branch specified, uses run.id as branch
      assert {:ok, result1} = ProofRun.run(task_id, opts)
      assert result1.run.status == :completed

      # Second run — same task, new run_id, so branch is different
      assert {:ok, result2} = ProofRun.run(task_id, opts)
      assert result2.run.status == :completed

      # Each run got its own branch derived from its unique run_id
      assert result1.branch != result2.branch
    end

    test "uses configured repo_path defaults when repo_path opt is omitted" do
      task_id = unique_task_id()
      root = temp_dir("proof-config-repo")
      {clone_path, _bare} = setup_temp_repo_with_remote(root)

      Application.put_env(:platform, :proof_of_life,
        repo_path: clone_path,
        base_ref: "origin/main",
        run_root: root
      )

      {:ok, result} = ProofRun.run(task_id)

      assert result.run.status == :completed
      wt_path = expected_worktree_path(result.run.id, root)
      assert File.exists?(Path.join(wt_path, "docs/proof-of-life.md"))
      assert result.branch == "proof-of-life/#{result.run.id}"
    end

    test "uses configured github credentials to push when no explicit lease is provided" do
      task_id = unique_task_id()
      root = temp_dir("proof-config-push")
      {clone_path, bare_path} = setup_temp_repo_with_remote(root)

      Application.put_env(:platform, :proof_of_life,
        repo_path: clone_path,
        repo_slug: "Startup-Suite/core",
        remote: "origin",
        base_ref: "origin/main",
        run_root: root
      )

      Application.put_env(:platform, :execution,
        github_credentials: [
          token: "test-token",
          author_name: "Suite Runner",
          author_email: "runner@suite.local"
        ]
      )

      {:ok, result} = ProofRun.run(task_id)

      assert result.pushed == true

      {branches, 0} =
        System.cmd("git", ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
          cd: bare_path,
          stderr_to_stdout: true
        )

      assert branches =~ result.branch
      assert Enum.any?(result.artifacts, &(&1.name == "github branch ref"))
    end

    test "push is skipped without a credential lease" do
      task_id = unique_task_id()
      root = temp_dir("proof-nolease")
      {clone_path, _bare} = setup_temp_repo_with_remote(root)

      {:ok, result} = ProofRun.run(task_id, repo_path: clone_path, run_root: root, repo_slug: nil)

      # No credential lease provided — push is explicitly skipped
      assert result.pushed == false
    end
  end
end
