defmodule Platform.Federation.ToolSurfacePlanDeployReposTest do
  @moduledoc """
  Task 01a1e4fa stage 1 — `plan_create` / `plan_update` accept `deploy_repos`
  and refuse a plan that names another repository without declaring it.

  The persistence instrument throughout is `Tasks.latest_plan(task.id) == nil`
  plus a reload of `deploy_strategy`: every refusal's envelope reads the same
  whether or not something was written, so only a reload can see a leak.
  """

  # Not async: T2 calls BranchProvisioner with a stub runner pinned through
  # the `:runner` option, but the module's call log lives in a named Agent.
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.Stacks

  @core "https://github.com/GetBurrowing/core"
  @cloud "https://github.com/GetBurrowing/burrow-cloud"

  defmodule RecordingRunner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
    defp record(call), do: Agent.update(__MODULE__, &[call | &1])

    @impl true
    def default_branch_sha(%{repo: repo}) do
      record({:default_branch_sha, repo})
      {:ok, "0123456789abcdef0123456789abcdef01234567"}
    end

    @impl true
    def branch_head_sha(%{repo: repo}) do
      record({:branch_head_sha, repo})
      {:error, :not_stubbed}
    end

    @impl true
    def list_matching_refs(%{repo: repo}) do
      record({:list_matching_refs, repo})
      {:ok, []}
    end

    @impl true
    def create_ref(%{repo: repo, ref: ref}) do
      record({:create_ref, repo, ref})
      {:ok, ref}
    end

    @impl true
    def compare_refs(%{repo: repo}) do
      record({:compare_refs, repo})
      {:error, :not_stubbed}
    end
  end

  defp pr_merge_project(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{
            name: "Deploy repos #{System.unique_integer([:positive])}",
            repo_url: @core,
            deploy_config: %{"default_strategy" => %{"type" => "pr_merge"}}
          },
          attrs
        )
      )

    project
  end

  defp task_in(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "Cross-repo work"}, attrs))

    task
  end

  defp stage(name, description) do
    %{
      "name" => name,
      "description" => description,
      "position" => 1,
      "validations" => [%{"kind" => "test_pass"}]
    }
  end

  defp plan_create(task, stages, extra \\ %{}) do
    ToolSurface.execute(
      "plan_create",
      Map.merge(%{"task_id" => task.id, "stages" => stages}, extra),
      %{}
    )
  end

  defp reload(task), do: Repo.get!(Platform.Tasks.Task, task.id)

  describe "T1 — deploy_repos is written onto the task with the plan" do
    test "a burrow-cloud declaration on a core-project task resolves to burrow-cloud only" do
      task = task_in(pr_merge_project())

      assert {:ok, _plan} =
               plan_create(
                 task,
                 [stage("Ship the worker", "All work lands in GetBurrowing/burrow-cloud")],
                 %{"deploy_repos" => [%{"repo_url" => @cloud}]}
               )

      strategy = reload(task).deploy_strategy

      assert strategy == %{
               "type" => "pr_merge",
               "repos" => [%{"repo_url" => @cloud}],
               "repos_declared_by" => "plan"
             }

      resolved = Tasks.resolve_deploy_strategy_with_repos(reload(task))
      assert [entry] = resolved["repos"]
      assert entry["slug"] == "GetBurrowing/burrow-cloud"
      refute Enum.any?(resolved["repos"], &(&1["slug"] == "GetBurrowing/core"))
    end

    test "plan_update writes the declaration too, and may replace a previous plan's" do
      task = task_in(pr_merge_project())

      {:ok, plan} =
        plan_create(task, [stage("Ship", "Work")], %{
          "deploy_repos" => [%{"repo_url" => @core}]
        })

      assert reload(task).deploy_strategy["repos"] == [%{"repo_url" => @core}]

      assert {:ok, _} =
               ToolSurface.execute(
                 "plan_update",
                 %{
                   "plan_id" => plan.id,
                   "stages" => [stage("Ship", "Work")],
                   "deploy_repos" => [%{"repo_url" => @cloud, "ci" => "none"}]
                 },
                 %{}
               )

      assert reload(task).deploy_strategy["repos"] == [%{"repo_url" => @cloud, "ci" => "none"}]
      assert reload(task).deploy_strategy["repos_declared_by"] == "plan"
    end
  end

  describe "T2 — BranchProvisioner sees the declared set" do
    test "ensure_branches creates the ref in burrow-cloud only, never core" do
      {:ok, _} = RecordingRunner.start()
      task = task_in(pr_merge_project())

      {:ok, _} =
        plan_create(task, [stage("Ship", "Work in GetBurrowing/burrow-cloud")], %{
          "deploy_repos" => [%{"repo_url" => @cloud}]
        })

      assert {:ok, %{results: [_]}} =
               BranchProvisioner.ensure_branches(reload(task), runner: RecordingRunner)

      created = for {:create_ref, repo, _ref} <- RecordingRunner.calls(), do: repo
      assert created == ["GetBurrowing/burrow-cloud"]

      refute Enum.any?(RecordingRunner.calls(), fn call -> elem(call, 1) == "GetBurrowing/core" end)
    end
  end

  describe "T3 — undeclared cross-repo plan is refused" do
    test "a bare GetBurrowing/burrow-cloud in stage text without deploy_repos" do
      task = task_in(pr_merge_project())

      assert {:error, env} =
               plan_create(task, [
                 stage("Add the worker", "Add the queue consumer in GetBurrowing/burrow-cloud.")
               ])

      assert env.code == :undeclared_cross_repo
      assert env.recoverable == true
      assert env.error =~ "GetBurrowing/burrow-cloud"
      assert env.suggestion =~ "deploy_repos"
      assert env.suggestion =~ "GetBurrowing/core"

      assert Tasks.latest_plan(task.id) == nil
      assert reload(task).deploy_strategy == nil
    end

    test "a full github.com URL of any owner is refused, and plan_update refuses it too" do
      task = task_in(pr_merge_project())

      assert {:error, %{code: :undeclared_cross_repo} = env} =
               plan_create(task, [stage("Vendor", "Patch https://github.com/acme/widgets.git")])

      assert env.error =~ "acme/widgets"
      assert Tasks.latest_plan(task.id) == nil

      {:ok, plan} = plan_create(task, [stage("Ship", "Work")])

      assert {:error, %{code: :undeclared_cross_repo}} =
               ToolSurface.execute(
                 "plan_update",
                 %{
                   "plan_id" => plan.id,
                   "stages" => [stage("Ship", "Now in GetBurrowing/burrow-cloud")]
                 },
                 %{}
               )

      assert [%{name: "Ship", description: "Work"}] =
               Repo.preload(Tasks.latest_plan(task.id), :stages).stages
    end
  end

  describe "T4 — paths and the project's own slug are not cross-repo" do
    test "apps/platform paths and GetBurrowing/core are accepted, deploy_strategy untouched" do
      task = task_in(pr_merge_project())

      assert {:ok, _} =
               plan_create(task, [
                 stage(
                   "Edit the engine",
                   "Change apps/platform/lib/platform/tasks/plan_engine.ex and " <>
                     "test/platform/tasks/plan_engine_test.exs in GetBurrowing/core " <>
                     "(https://github.com/GetBurrowing/core). See getburrowing/CORE too."
                 )
               ])

      assert reload(task).deploy_strategy == nil
    end
  end

  describe "T5 — stack members" do
    test "deploy_repos on a stack member is refused and nothing is written" do
      project = pr_merge_project()

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "s-#{System.unique_integer([:positive])}",
          name: "Stack",
          rollup_branch: "stack/s"
        })

      task = task_in(project)
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      assert {:error, env} =
               plan_create(task, [stage("Ship", "Work")], %{
                 "deploy_repos" => [%{"repo_url" => @cloud}]
               })

      assert env.code == :deploy_repos_on_stack_member
      assert env.recoverable == true
      assert Tasks.latest_plan(task.id) == nil
      assert reload(task).deploy_strategy == nil
    end
  end

  describe "T6 — a human declaration wins" do
    test "a differing human-set repo list refuses with :deploy_repos_conflict" do
      task = task_in(pr_merge_project())
      human = %{"type" => "pr_merge", "repos" => [%{"repo_url" => @core}]}
      {:ok, task} = Tasks.update_task(task, %{deploy_strategy: human})

      assert {:error, env} =
               plan_create(task, [stage("Ship", "Work")], %{
                 "deploy_repos" => [%{"repo_url" => @cloud}]
               })

      assert env.code == :deploy_repos_conflict
      assert Tasks.latest_plan(task.id) == nil
      assert reload(task).deploy_strategy == human
    end

    test "an identical declaration is accepted and keeps the human's mark" do
      task = task_in(pr_merge_project())
      human = %{"type" => "pr_merge", "repos" => [%{"repo_url" => @cloud}]}
      {:ok, task} = Tasks.update_task(task, %{deploy_strategy: human})

      assert {:ok, _} =
               plan_create(task, [stage("Ship", "Work in GetBurrowing/burrow-cloud")], %{
                 "deploy_repos" => [%{"repo_url" => "https://github.com/getburrowing/burrow-cloud"}]
               })

      assert reload(task).deploy_strategy == human
    end
  end

  describe "T7 — validation goes through validate_strategy" do
    test "an invalid ci value is refused" do
      task = task_in(pr_merge_project())

      assert {:error, env} =
               plan_create(task, [stage("Ship", "Work")], %{
                 "deploy_repos" => [%{"repo_url" => @cloud, "ci" => "sometimes"}]
               })

      assert env.code == :invalid_deploy_repos
      assert env.error =~ "invalid ci"
      assert Tasks.latest_plan(task.id) == nil
      assert reload(task).deploy_strategy == nil
    end

    test "a non-pr_merge effective strategy refuses with :deploy_repos_needs_pr_merge" do
      task = task_in(pr_merge_project(%{deploy_config: %{}}))

      assert {:error, %{code: :deploy_repos_needs_pr_merge}} =
               plan_create(task, [stage("Ship", "Work")], %{
                 "deploy_repos" => [%{"repo_url" => @cloud}]
               })

      assert reload(task).deploy_strategy == nil
    end
  end

  describe "atomicity — the declaration commits with the plan or not at all" do
    test "a plan insert that fails leaves deploy_strategy unchanged" do
      task = task_in(pr_merge_project())

      # A live draft makes `Tasks.create_plan/1` refuse inside the transaction.
      {:ok, _draft} = plan_create(task, [stage("Ship", "Work")])
      assert reload(task).deploy_strategy == nil

      assert {:error, _} =
               plan_create(task, [stage("Ship", "Work")], %{
                 "deploy_repos" => [%{"repo_url" => @cloud}]
               })

      assert reload(task).deploy_strategy == nil
    end
  end
end
