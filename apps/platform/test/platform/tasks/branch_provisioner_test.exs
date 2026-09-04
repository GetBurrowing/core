defmodule Platform.Tasks.BranchProvisionerTest do
  @moduledoc """
  The branch Suite's `pr_merged` gate watches is DERIVED from the task id
  (`StackDeployer.member_branch_for/1` → `DeployStageBuilder` →
  `MergeControl`). These tests pin that `BranchProvisioner` creates that
  exact name and no other, that a redispatch is a no-op rather than a
  failure, and that a missing `gh` reports rather than raises.

  A stub runner stands in for GitHub — pinned per-call through the
  `:runner` option, so nothing here mutates application env and nothing
  here touches the network.
  """

  # NOT async (changed in task 01a001ac stage 2): the `runner/0` default test
  # deletes `:platform, :branch_provisioner` from application env, which is
  # global. An async case doing that can be observed by any other async case
  # that reads the same key.
  use ExUnit.Case, async: false

  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.Project
  alias Platform.Tasks.StackDeployer
  alias Platform.Tasks.Task, as: TaskRecord

  @task_id "01a001ac-0ad8-7ece-bea6-2c524238fb86"
  @branch "task/" <> @task_id
  @ref "refs/heads/" <> @branch
  @sha "0123456789abcdef0123456789abcdef01234567"

  @core "https://github.com/Startup-Suite/core"
  @bridge "https://github.com/Startup-Suite/claude-code-suite-channel"

  # ── Stub runner ─────────────────────────────────────────────────────────
  #
  # Records every call on the calling process's agent so a test can assert
  # what was NOT called — the second `create_ref` an idempotent path must
  # not issue is invisible to a return-value-only assertion.
  defmodule StubRunner do
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(_args), do: {:error, :not_stubbed}

    def start(script), do: Agent.start_link(fn -> %{script: script, calls: []} end)

    def calls(pid), do: pid |> Agent.get(& &1.calls) |> Enum.reverse()

    @impl true
    def default_branch_sha(%{repo: repo} = args) do
      respond(args, {:default_branch_sha, repo}, :default_branch_sha)
    end

    @impl true
    def list_matching_refs(%{repo: repo, ref: ref} = args) do
      respond(args, {:list_matching_refs, repo, ref}, :list_matching_refs)
    end

    @impl true
    def create_ref(%{repo: repo, ref: ref, sha: sha} = args) do
      respond(args, {:create_ref, repo, ref, sha}, :create_ref)
    end

    defp respond(args, call, key) do
      pid = Map.fetch!(args, :agent)
      Agent.update(pid, &%{&1 | calls: [call | &1.calls]})
      responder = Agent.get(pid, &Map.fetch!(&1.script, key))

      case responder do
        fun when is_function(fun, 1) -> fun.(call)
        value -> value
      end
    end
  end

  # The stub needs its agent pid, and `ensure_branch/3` passes only the
  # runner module through. A tiny wrapper module per test would work; a
  # closure module cannot. Instead we pin the pid in the process dictionary
  # of the STUB call by threading it through the runner map — done by
  # wrapping the module in one that injects `:agent`.
  defmodule Injector do
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(_args), do: {:error, :not_stubbed}

    @impl true
    def default_branch_sha(args), do: StubRunner.default_branch_sha(inject(args))
    @impl true
    def list_matching_refs(args), do: StubRunner.list_matching_refs(inject(args))
    @impl true
    def create_ref(args), do: StubRunner.create_ref(inject(args))

    defp inject(args), do: Map.put(args, :agent, Process.get(:stub_agent))
  end

  defp stub(overrides \\ %{}) do
    script =
      Map.merge(
        %{
          list_matching_refs: {:ok, []},
          default_branch_sha: {:ok, @sha},
          create_ref: {:ok, @ref}
        },
        overrides
      )

    {:ok, pid} = StubRunner.start(script)
    Process.put(:stub_agent, pid)
    pid
  end

  defp task(attrs \\ []) do
    struct!(
      TaskRecord,
      Keyword.merge(
        [
          id: @task_id,
          stack: nil,
          project: %Project{repo_url: @core, deploy_config: %{}}
        ],
        attrs
      )
    )
  end

  describe "branch_for/1" do
    test "is StackDeployer.member_branch_for/1 and carries the FULL uuid" do
      task = task()

      assert BranchProvisioner.branch_for(task) == StackDeployer.member_branch_for(task)
      assert BranchProvisioner.branch_for(task) == @branch

      # The defect this module exists to prevent: an abbreviated id
      # collapses every task filed in the same ~minute into one branch.
      refute BranchProvisioner.branch_for(task) == "task/" <> String.slice(@task_id, 0, 8)
    end
  end

  describe "ensure_branch/3 — creation" do
    test "creates task/<full-uuid> off the resolved default branch sha" do
      pid = stub()

      assert {:ok, :created} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)

      assert [
               {:list_matching_refs, "Startup-Suite/core", "heads/" <> @branch},
               {:default_branch_sha, "Startup-Suite/core"},
               {:create_ref, "Startup-Suite/core", @ref, @sha}
             ] = StubRunner.calls(pid)
    end

    test "refuses a repo_url that does not normalize to owner/name" do
      pid = stub()

      assert {:error, {:unresolvable_repo, "not a repo"}} =
               BranchProvisioner.ensure_branch(task(), "not a repo", runner: Injector)

      # Refusing means asking GitHub NOTHING — a guessed slug would create
      # the branch in the wrong repository.
      assert StubRunner.calls(pid) == []
    end
  end

  describe "ensure_branch/3 — idempotence" do
    test "an existing ref is {:ok, :exists} and issues NO create" do
      pid = stub(%{list_matching_refs: {:ok, [@ref]}})

      assert {:ok, :exists} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)

      assert [{:list_matching_refs, _, _}] = StubRunner.calls(pid)

      refute Enum.any?(StubRunner.calls(pid), &match?({:create_ref, _, _, _}, &1)),
             "a redispatch must not re-create a branch an executor is already committing to"
    end

    test "a ref pointing somewhere else is still {:ok, :exists} — never force-updated" do
      # The ref exists at a sha we did not choose: an executor has been
      # committing. Moving it would destroy that work.
      pid = stub(%{list_matching_refs: {:ok, [@ref]}, default_branch_sha: {:ok, "deadbeef"}})

      assert {:ok, :exists} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)

      assert [{:list_matching_refs, _, _}] = StubRunner.calls(pid)
    end

    test "GitHub's 422 Reference already exists maps to {:ok, :exists}, not an error" do
      # The race: existence check said no, a concurrent provisioner won.
      pid = stub(%{create_ref: {:error, :ref_exists}})

      assert {:ok, :exists} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)

      assert Enum.any?(StubRunner.calls(pid), &match?({:create_ref, _, _, _}, &1))
    end

    test "a prefix-only match is NOT existence" do
      # `matching-refs/heads/task/<uuid>` also returns longer names.
      stub(%{list_matching_refs: {:ok, [@ref <> "-scratch"]}})

      assert {:ok, :created} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)
    end
  end

  describe "ensure_branch/3 — gh missing" do
    @gh_missing {:error, :gh_unavailable, "`gh` not found"}

    test "reports rather than raising when the CLI is absent" do
      stub(%{list_matching_refs: @gh_missing})

      assert {:error, :gh_unavailable, _message} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)
    end

    test "also reports when the CLI disappears between the check and the create" do
      stub(%{default_branch_sha: @gh_missing})

      assert {:error, :gh_unavailable, _message} =
               BranchProvisioner.ensure_branch(task(), @core, runner: Injector)
    end
  end

  describe "ensure_branches/2" do
    test "one ref per declared repo, all carrying the SAME branch name" do
      pid = stub()

      task =
        task(
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{},
            "repos" => [%{"repo_url" => @core}, %{"repo_url" => @bridge}]
          }
        )

      assert {:ok, %{branch: @branch, results: results}} =
               BranchProvisioner.ensure_branches(task, runner: Injector)

      assert [
               %{repo_url: @core, result: {:ok, :created}},
               %{repo_url: @bridge, result: {:ok, :created}}
             ] = results

      creates = for {:create_ref, repo, ref, _sha} <- StubRunner.calls(pid), do: {repo, ref}

      assert creates == [
               {"Startup-Suite/core", @ref},
               {"Startup-Suite/claude-code-suite-channel", @ref}
             ]

      # One task pushes ONE branch — mirrors the assertion at
      # `deploy_stage_builder_test.exs` on the gates built from this set.
      assert creates |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    end

    test "a task with no declared repo set falls back to the project repo_url" do
      stub()

      assert {:ok, %{branch: @branch, results: [%{repo_url: @core, result: {:ok, :created}}]}} =
               BranchProvisioner.ensure_branches(task(), runner: Injector)
    end
  end

  describe "runner/0" do
    # `config/test.exs` pins `NoopRunner` (task 01a001ac stage 2) so the suite
    # does not shell out to `gh` on every router dispatch. That pin is exactly
    # what this test must NOT observe: the claim is about the module's own
    # default when the key is absent, so the key is removed for the duration.
    test "defaults to the gh-backed runner when nothing is configured" do
      previous = Application.get_env(:platform, :branch_provisioner)
      Application.delete_env(:platform, :branch_provisioner)

      on_exit(fn ->
        if previous, do: Application.put_env(:platform, :branch_provisioner, previous)
      end)

      assert BranchProvisioner.runner() == Platform.Tasks.BranchProvisioner.GhRunner
    end

    test "the test environment pins the inert runner" do
      assert BranchProvisioner.runner() == Platform.Tasks.BranchProvisioner.NoopRunner
    end
  end
end
