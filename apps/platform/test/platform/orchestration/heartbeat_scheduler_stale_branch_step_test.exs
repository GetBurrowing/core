defmodule Platform.Orchestration.HeartbeatSchedulerStaleBranchStepTest do
  @moduledoc """
  The dispatch prompt tells a later stage to `--track` a branch Suite cut
  at the FIRST stage's dispatch and has never moved since. When that
  stage's work reached `main` from some other branch, the tracked ref
  still holds nothing and the executor lands where its predecessor's
  artefacts do not exist — an absence, not an error, which reads as
  "this was never built".

  Every assertion that the warning renders is paired, in this file and
  against the same stub, with one that it does NOT. That pairing is the
  point: a step rendered unconditionally would satisfy the positive
  cases while offering to fast-forward branches that carry work, and
  `assess/4` returns `:unknown` for every failed probe precisely so a
  GitHub blip cannot put that offer into every dispatch.

  `async: false` because the runner is pinned through application env —
  `stale_branch_step/3` runs inside prompt rendering and takes no opts.
  """

  use ExUnit.Case, async: false

  alias Platform.Orchestration.HeartbeatScheduler

  @task_id "01a04bb9-8d69-7af9-a943-8139ea638550"

  defmodule Runner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(_args), do: {:error, :not_stubbed}

    @impl true
    def default_branch_sha(_), do: {:error, :not_used}

    @impl true
    def create_ref(_), do: {:error, :not_used}

    @impl true
    def list_matching_refs(_), do: {:error, :not_used}

    @impl true
    def compare_refs(_),
      do: :persistent_term.get({__MODULE__, :answer}, {:error, :unset})
  end

  defp answering(answer) do
    :persistent_term.put({Runner, :answer}, answer)
    previous = Application.get_env(:platform, :branch_provisioner, [])
    Application.put_env(:platform, :branch_provisioner, runner: Runner)

    on_exit(fn ->
      Application.put_env(:platform, :branch_provisioner, previous)
      :persistent_term.erase({Runner, :answer})
    end)
  end

  defp prompt do
    stage = %{id: "stage-2", position: 2, name: "measure", validations: []}
    plan = %{version: 1, stages: [stage]}

    task = %{
      id: @task_id,
      title: "Later stage of a multi-stage task",
      description: "Re-run stage 1's harness and report the new count.",
      status: "in_progress",
      priority: "high",
      project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
      stack_id: nil
    }

    HeartbeatScheduler.dispatch_prompt(task, plan, stage)
  end

  describe "a branch carrying no commits of its own" do
    setup do
      answering({:ok, %{ahead_by: 0, behind_by: 25}})
      %{prompt: prompt()}
    end

    test "names the branch, the distance, and what the absence actually means", %{prompt: p} do
      assert p =~ "task/#{@task_id}` carries NO commits of its own and is 25 behind `origin/main`"

      assert p =~
               "treat a missing file as a stale branch, not as evidence the thing was never built"
    end

    test "sanctions a fast-forward and nothing else", %{prompt: p} do
      # `--ff-only` is the whole safety argument: git refuses it the moment
      # the branch carries unmerged work, so following this step cannot
      # discard commits even if the probe were wrong.
      assert p =~ "git merge --ff-only origin/main"
      refute p =~ "git reset --hard origin/main"
    end

    test "names the destructive alternatives in order to forbid them", %{prompt: p} do
      assert p =~ "Do NOT `git reset --hard`"
      assert p =~ "do NOT delete and re-cut the branch"
    end

    test "a refused fast-forward is a blocker, not a licence to force", %{prompt: p} do
      assert p =~ "Failed: STOP and `report_blocker`"
    end

    test "still renders the ordinary track instruction it is warning about", %{prompt: p} do
      # The step ANNOTATES the dispatch, it does not replace it. If the
      # `--track` line vanished, the positive assertions above would still
      # pass while the prompt had stopped telling the executor what to do.
      assert p =~
               "git worktree add ../worktrees/#{@task_id} --track -b task/#{@task_id} origin/task/#{@task_id}"
    end
  end

  describe "controls — the step must NOT render" do
    test "a branch with commits of its own gets no warning and no fast-forward offer" do
      answering({:ok, %{ahead_by: 3, behind_by: 25}})
      p = prompt()

      refute p =~ "carries NO commits of its own"
      refute p =~ "git merge --ff-only"
      # ...while the surrounding block is untouched.
      assert p =~ "git push -u origin task/#{@task_id}"
    end

    test "a branch level with main gets no warning" do
      answering({:ok, %{ahead_by: 0, behind_by: 0}})
      p = prompt()

      refute p =~ "carries NO commits of its own"
      refute p =~ "git merge --ff-only"
    end

    test "a failed probe gets no warning" do
      answering({:error, {:gh_error, "502"}})
      p = prompt()

      refute p =~ "carries NO commits of its own"
      refute p =~ "git merge --ff-only"
    end

    test "a disabled provisioner gets no warning" do
      answering({:error, :branch_provisioning_disabled})
      p = prompt()

      refute p =~ "carries NO commits of its own"
      refute p =~ "git merge --ff-only"
    end
  end

  describe "stack members" do
    test "a stack member never gets the step — its branch is cut from the rollup" do
      # ADR-0042 retargets a member branch at the rollup head so it already
      # sees merged siblings. The non-stack `--track` path is the one with
      # the gap, and offering a fast-forward to `main` inside a stack would
      # pull the member off its rollup base.
      answering({:ok, %{ahead_by: 0, behind_by: 25}})

      stage = %{id: "stage-2", position: 2, name: "measure", validations: []}
      plan = %{version: 1, stages: [stage]}

      task = %{
        id: @task_id,
        title: "Stack member",
        description: "d",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2474-11c1-7000-8000-000000000009"
      }

      p = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute p =~ "carries NO commits of its own"
      refute p =~ "git merge --ff-only"
    end
  end
end
