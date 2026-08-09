defmodule Platform.Lifecycle.TerminalWorktreeCleanupTest do
  @moduledoc """
  The terminal worktree-cleanup EFFECT, exercised through
  `Platform.Tasks.transition_task/2` (task 019fe1b7 stage 3).

  ## Why a file of its own rather than more cases in `status_edge_dispatch_test.exs`

  That file's `setup` points `:lifecycle_step_registry` at a per-case registry
  holding only its own `s_*` test steps, so the SHIPPED `worktree_cleanup`
  name would not resolve there. These cases must run against the shipped
  allowlist, because the whole point is that nothing here configures a
  pipeline: the declaration under test is
  `Platform.Lifecycle.Edges.default_steps/1`, resolved by
  `Platform.Lifecycle.resolve_steps/2` exactly as production resolves it.

  **A test that supplies its own configuration cannot test the shipped
  configuration.** No `steps:` is injected and no project row carries a
  pipeline anywhere in this file.

  ## Every path here is under a `tmp_dir`

  `:local_run_root` is redirected to a per-test temporary directory before
  anything runs. No case computes a path under a real worktree root, not even
  to assert about it — this is the one module in the stack whose subject
  deletes directories, and a derived-then-asserted real path is one refactor
  away from removing a live checkout.
  """

  use Platform.DataCase, async: false

  alias Platform.Execution
  alias Platform.Execution.LocalWorkspace
  alias Platform.Lifecycle.EdgeInventory
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.Runs
  alias Platform.Tasks

  @cleanup_step "worktree_cleanup"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "platform-terminal-cleanup-#{Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)}"
      )

    File.mkdir_p!(root)

    previous = Application.get_env(:platform, :execution, [])
    Application.put_env(:platform, :execution, Keyword.put(previous, :local_run_root, root))

    on_exit(fn ->
      Application.put_env(:platform, :execution, previous)
      File.rm_rf(root)
    end)

    %{run_root: root}
  end

  describe "the edge set is DERIVED, and terminal does not mean `deploying`" do
    test "every inbound edge to done and to cancelled carries the effect" do
      # Explicit sorted list, not set membership and not a transcription of
      # the transition table: if the table widens, this list is what has to
      # change, deliberately.
      assert EdgeInventory.terminal_edges() == [
               "backlog->cancelled",
               "blocked->cancelled",
               "deploying->done",
               "in_progress->cancelled",
               "in_progress->done",
               "in_review->done",
               "planning->cancelled",
               "stack_pending->cancelled"
             ]

      for edge <- EdgeInventory.terminal_edges() do
        assert Edges.default_steps(edge) == [
                 %{"step" => @cleanup_step, "await" => false, "can_divert" => false}
               ],
               "terminal edge #{edge} ships no cleanup effect"
      end
    end

    test "THE STACK-MEMBER PATH: in_review->done carries it without touching deploying" do
      # The discriminating case. An implementation hung on the deploy edge
      # passes every assertion about `deploying->done` and silently never
      # cleans up after an ADR-0041 stack member, which reaches `done` from
      # `in_review` and never enters `deploying` at all.
      assert "in_review->done" in EdgeInventory.terminal_edges()
      assert "in_progress->done" in EdgeInventory.terminal_edges()

      # CONTROL: a non-terminal edge ships nothing, so the declaration
      # discriminates by terminality rather than applying to everything.
      assert Edges.default_steps("backlog->planning") == []
      assert Edges.default_steps("in_progress->in_review") == []
    end

    test "the shipped default is what an unconfigured project resolves" do
      # The resolver, not the declaration. Before this stage nothing on a
      # shipped path consulted `default_steps/1` at all.
      project = project_fixture()

      assert Platform.Lifecycle.resolve_steps(project, "in_review->done") == [
               %{"step" => @cleanup_step, "await" => false, "can_divert" => false}
             ]

      assert Platform.Lifecycle.resolve_steps(project, "backlog->planning") == []
    end
  end

  describe "a task WITH a worktree" do
    test "reaching done through in_review removes the directory", %{run_root: root} do
      %{task: task} = fixture()
      {repo, branch} = temp_git_repo(root)

      run_id = "run-#{System.unique_integer([:positive])}"
      {:ok, run} = start_live_run(task.id, run_id)
      {:ok, workspace} = LocalWorkspace.ensure_workspace(run, run_root: root)
      {:ok, worktree} = LocalWorkspace.setup_git_worktree(workspace, repo, branch: branch)

      assert File.dir?(worktree)

      task = walk_to_in_review(task)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done")

      refute File.exists?(worktree)

      assert Enum.map(Runs.for_edge(task.id, "in_review->done"), &{&1.step_name, &1.status}) ==
               [{@cleanup_step, "completed"}]
    end

    test "firing the same terminal edge TWICE does not fail the second time", %{run_root: root} do
      %{task: task} = fixture()
      {repo, branch} = temp_git_repo(root)

      run_id = "run-#{System.unique_integer([:positive])}"
      {:ok, run} = start_live_run(task.id, run_id)
      {:ok, workspace} = LocalWorkspace.ensure_workspace(run, run_root: root)
      {:ok, worktree} = LocalWorkspace.setup_git_worktree(workspace, repo, branch: branch)

      task = walk_to_in_review(task)
      {:ok, task} = Tasks.transition_task(task, "done")
      refute File.exists?(worktree)

      # `done -> planning` is legal, so the same edge really can be traversed
      # again. The second pass finds nothing and must still be `completed` —
      # not `failed`, and not `absent`-as-an-error.
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, task} = Tasks.transition_task(task, "in_review")
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done")

      statuses = Enum.map(Runs.for_edge(task.id, "in_review->done"), & &1.status)

      assert statuses == ["completed", "completed"]
      refute "failed" in statuses
    end
  end

  describe "a task with NO run" do
    test "reaches done cleanly AND the pipeline demonstrably fired" do
      %{task: task} = fixture()

      # No run, no workspace, nothing on disk.
      assert Execution.run_ids_for_task(task.id) == []

      task = walk_to_in_review(task)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done")

      # THE ASSERTION THAT MATTERS. "No crash" is satisfied by a pipeline
      # that never ran at all, so the positive control is the run row itself:
      # the shipped step resolved, started, found nothing, and COMPLETED.
      # `not_applicable` would be wrong here — that is reserved for a
      # traversed edge with an EMPTY configured pipeline, and this pipeline
      # is not empty.
      assert Enum.map(Runs.for_edge(task.id, "in_review->done"), &{&1.step_name, &1.status}) ==
               [{@cleanup_step, "completed"}]
    end

    test "a live run that never allocated a workspace is also complete", %{run_root: root} do
      %{task: task} = fixture()
      run_id = "run-#{System.unique_integer([:positive])}"
      {:ok, _run} = start_live_run(task.id, run_id)

      # The run exists and is found — the difference from the case above is
      # only that nothing was ever allocated for it on disk.
      assert Execution.run_ids_for_task(task.id) == [run_id]
      {:ok, path} = LocalWorkspace.worktree_path(run_id, run_root: root)
      refute File.exists?(path)

      task = walk_to_in_review(task)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done")

      assert Enum.map(Runs.for_edge(task.id, "in_review->done"), &{&1.step_name, &1.status}) ==
               [{@cleanup_step, "completed"}]
    end

    test "a cancelled task fires it too — a run CAN exist for one" do
      # `in_progress -> cancelled` is in the transition table and a run is
      # started while a task is in progress, so a cancelled task's worktree
      # is a real thing nobody would otherwise come back for.
      %{task: task} = fixture()
      task = walk_to_in_progress(task)

      assert {:ok, %{status: "cancelled"}} = Tasks.transition_task(task, "cancelled")

      assert Enum.map(
               Runs.for_edge(task.id, "in_progress->cancelled"),
               &{&1.step_name, &1.status}
             ) == [{@cleanup_step, "completed"}]
    end
  end

  describe "a removal that genuinely fails" do
    test "a dirty worktree records `failed`, and the work survives", %{run_root: root} do
      %{task: task} = fixture()
      {repo, branch} = temp_git_repo(root)

      run_id = "run-#{System.unique_integer([:positive])}"
      {:ok, run} = start_live_run(task.id, run_id)
      {:ok, workspace} = LocalWorkspace.ensure_workspace(run, run_root: root)
      {:ok, worktree} = LocalWorkspace.setup_git_worktree(workspace, repo, branch: branch)

      dirty = Path.join(worktree, "uncommitted.txt")
      File.write!(dirty, "work in progress\n")

      task = walk_to_in_review(task)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done")

      # Recorded as failed rather than swallowed — and the transition still
      # committed, because an effect cannot hold the task.
      assert Enum.map(Runs.for_edge(task.id, "in_review->done"), &{&1.step_name, &1.status}) ==
               [{@cleanup_step, "failed"}]

      assert File.exists?(dirty)
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp project_fixture do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Terminal Cleanup Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/terminal-cleanup",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"}
      })

    project
  end

  defp fixture do
    project = project_fixture()

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Terminal Cleanup Task"})

    %{project: project, task: task}
  end

  defp start_live_run(task_id, run_id) do
    {:ok, run} = Execution.start_run(task_id, run_id: run_id)
    on_exit(fn -> Platform.Execution.RunSupervisor.stop_run(run_id) end)
    {:ok, run}
  end

  # `in_progress` is behind the approved-plan gate; seed a plan rather than
  # route around it, so this walks the real path.
  defp walk_to_in_progress(task) do
    {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, task} = Tasks.transition_task(task, "planning")
    {:ok, task} = Tasks.transition_task(task, "in_progress")
    task
  end

  defp walk_to_in_review(task) do
    task = walk_to_in_progress(task)
    {:ok, task} = Tasks.transition_task(task, "in_review")
    task
  end

  defp temp_git_repo(root) do
    repo = Path.join(root, "repo-#{System.unique_integer([:positive])}")
    branch = "run-wt-#{System.unique_integer([:positive])}"
    File.mkdir_p!(repo)

    System.cmd("git", ["init", "--initial-branch=main"], cd: repo, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: repo)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# test\n")
    System.cmd("git", ["add", "."], cd: repo)
    System.cmd("git", ["commit", "-m", "init"], cd: repo, stderr_to_stdout: true)

    {repo, branch}
  end
end
