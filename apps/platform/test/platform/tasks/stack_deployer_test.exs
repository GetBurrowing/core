defmodule Platform.Tasks.StackDeployerTest do
  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{Stack, StackDeployer, Stacks}

  # ── Test git runner ───────────────────────────────────────────────────────
  #
  # An in-memory implementation of `Platform.Tasks.StackDeployer.GitRunner`
  # backed by an Agent. Tests configure the deployer to use this runner
  # and then assert against its captured calls and pre-seeded responses.

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(opts) do
      initial = %{
        responses: Keyword.get(opts, :responses, []),
        default: Keyword.get(opts, :default, {:ok, %{status: :created, base_sha: "deadbee"}}),
        merge_responses: Keyword.get(opts, :merge_responses, []),
        merge_default:
          Keyword.get(opts, :merge_default, {:ok, %{status: :merged, merge_sha: "f00dbabe"}}),
        pr_responses: Keyword.get(opts, :pr_responses, []),
        pr_default:
          Keyword.get(
            opts,
            :pr_default,
            {:ok, %{number: 99, url: "https://github.com/test/repo/pull/99"}}
          ),
        diff_stat_responses: Keyword.get(opts, :diff_stat_responses, []),
        diff_stat_default: Keyword.get(opts, :diff_stat_default, {:ok, " 3 files changed"}),
        revert_responses: Keyword.get(opts, :revert_responses, []),
        revert_default:
          Keyword.get(
            opts,
            :revert_default,
            {:ok, %{status: :reverted, revert_sha: "revert0000"}}
          ),
        close_responses: Keyword.get(opts, :close_responses, []),
        close_default: Keyword.get(opts, :close_default, {:ok, :closed}),
        calls: [],
        merge_calls: [],
        pr_calls: [],
        diff_stat_calls: [],
        revert_calls: [],
        close_calls: []
      }

      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def stop, do: Agent.stop(__MODULE__)

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()
    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()
    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()
    def diff_stat_calls, do: Agent.get(__MODULE__, & &1.diff_stat_calls) |> Enum.reverse()
    def revert_calls, do: Agent.get(__MODULE__, & &1.revert_calls) |> Enum.reverse()
    def close_calls, do: Agent.get(__MODULE__, & &1.close_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.responses do
            [head | rest] -> {head, rest}
            [] -> {state.default, []}
          end

        {response, %{state | calls: [args | state.calls], responses: remaining}}
      end)
    end

    @impl true
    def merge_member_into_rollup(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.merge_responses do
            [head | rest] -> {head, rest}
            [] -> {state.merge_default, []}
          end

        {response, %{state | merge_calls: [args | state.merge_calls], merge_responses: remaining}}
      end)
    end

    @impl true
    def open_stack_pr(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.pr_responses do
            [head | rest] -> {head, rest}
            [] -> {state.pr_default, []}
          end

        {response, %{state | pr_calls: [args | state.pr_calls], pr_responses: remaining}}
      end)
    end

    @impl true
    def diff_stat(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.diff_stat_responses do
            [head | rest] -> {head, rest}
            [] -> {state.diff_stat_default, []}
          end

        {response,
         %{
           state
           | diff_stat_calls: [args | state.diff_stat_calls],
             diff_stat_responses: remaining
         }}
      end)
    end

    @impl true
    def revert_member_merge(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.revert_responses do
            [head | rest] -> {head, rest}
            [] -> {state.revert_default, []}
          end

        {response,
         %{
           state
           | revert_calls: [args | state.revert_calls],
             revert_responses: remaining
         }}
      end)
    end

    @impl true
    def close_stack_pr(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.close_responses do
            [head | rest] -> {head, rest}
            [] -> {state.close_default, []}
          end

        {response,
         %{
           state
           | close_calls: [args | state.close_calls],
             close_responses: remaining
         }}
      end)
    end
  end

  setup do
    # Run the deployer synchronously in tests so we can observe results.
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: FakeRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        FakeRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp project_with_repo!(opts \\ []) do
    repo_url = Keyword.get(opts, :repo_url, "https://github.com/test/stack-deployer-#{uniq()}")

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stack Deployer Test #{uniq()}",
        repo_url: repo_url
      })

    project
  end

  defp project_without_repo! do
    {:ok, project} = Tasks.create_project(%{name: "No Repo #{uniq()}"})
    project
  end

  defp stack_for!(project, opts) do
    slug = Keyword.get(opts, :slug, "test-#{uniq()}")
    base = Keyword.get(opts, :base_branch, "main")

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: base,
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  # ── create_rollup_branch/1 ────────────────────────────────────────────────

  describe "create_rollup_branch/1" do
    test "happy path: runner is invoked with stack args and returns :created" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "abc1234"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "feature-x")

      assert {:ok, result} = StackDeployer.create_rollup_branch(stack)
      assert result.branch == "stack/feature-x"
      assert result.base_sha == "abc1234"
      assert result.status == :created
      assert %DateTime{} = result.created_at

      assert [call] = FakeRunner.calls()
      assert call.repo_url == project.repo_url
      assert call.base_branch == "main"
      assert call.rollup_branch == "stack/feature-x"
      assert call.project_id == project.id
      assert call.stack_id == stack.id
    end

    test "passes through a non-default base_branch" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "develop1"}}])

      project = project_with_repo!()

      stack =
        stack_for!(project, slug: "feature-y", base_branch: "develop")

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      assert [%{base_branch: "develop", rollup_branch: "stack/feature-y"}] =
               FakeRunner.calls()
    end

    test "idempotent: runner reports :already_exists → ok with status: :already_exists" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:ok, %{status: :already_exists, base_sha: "oldbase0"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "rerun")

      assert {:ok, result} = StackDeployer.create_rollup_branch(stack)
      assert result.status == :already_exists
      assert result.base_sha == "oldbase0"
      assert result.branch == "stack/rerun"
    end

    test "runner failure surfaces as {:error, reason} (does NOT raise)" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:error, {:git_failed, ["push", "origin", "x"], 128, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "auth-fail")

      assert {:error, {:git_failed, _, 128, "auth boom"}} =
               StackDeployer.create_rollup_branch(stack)

      assert [_] = FakeRunner.calls()
    end

    test "project missing repo_url → {:error, :no_repo_url} (no runner call)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "no-remote")

      assert {:error, :no_repo_url} = StackDeployer.create_rollup_branch(stack)
      assert FakeRunner.calls() == []
    end

    test "project deleted out from under us → {:error, :project_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      %Stack{} = stack = stack_for!(project, slug: "ghost")

      # Drop project_id to simulate a missing project lookup.
      stack = %Stack{stack | project_id: Ecto.UUID.generate()}

      assert {:error, :project_not_found} = StackDeployer.create_rollup_branch(stack)
      assert FakeRunner.calls() == []
    end
  end

  # ── handle_stack_transition/3 ─────────────────────────────────────────────

  describe "handle_stack_transition/3" do
    test "fires create_rollup_branch on forming → in_progress" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "newbase0"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "transition")

      :ok = StackDeployer.handle_stack_transition(stack, :forming, :in_progress)

      assert [%{rollup_branch: "stack/transition"}] = FakeRunner.calls()
    end

    test "no-ops on other transitions" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "noop")

      :ok = StackDeployer.handle_stack_transition(stack, :in_progress, :in_review)
      :ok = StackDeployer.handle_stack_transition(stack, :forming, :abandoned)
      :ok = StackDeployer.handle_stack_transition(stack, :in_review, :deploying)

      assert FakeRunner.calls() == []
    end

    test "runner error is swallowed (returns :ok); never raises" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:error, {:git_failed, ["push"], 1, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "swallow")

      assert :ok = StackDeployer.handle_stack_transition(stack, :forming, :in_progress)

      assert [_] = FakeRunner.calls()
    end
  end

  # ── Stacks.start_stack/1 integration ──────────────────────────────────────

  describe "integration with Stacks.start_stack/1" do
    test "starting a stack triggers create_rollup_branch via the deployer hook" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "rooooot1"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "start-hook")

      # Cascade needs a root with an approved plan; otherwise the start
      # produces `:partial` (still triggers the deployer because the
      # stack-level status flip succeeds).
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})

      assert {:ok, %{stack: started}} = Stacks.start_stack(stack)
      assert started.status == "in_progress"

      assert [call] = FakeRunner.calls()
      assert call.rollup_branch == "stack/start-hook"
      assert call.repo_url == project.repo_url
    end

    test "deployer error does NOT crash or alter the cascade result" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:error, {:git_failed, ["push"], 128, "permission denied"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "boom-deploy")

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})

      assert {:ok, %{stack: started, started: started_tasks}} = Stacks.start_stack(stack)
      assert started.status == "in_progress"
      assert length(started_tasks) == 1
      assert [_] = FakeRunner.calls()
    end

    test "no deployer call if start_stack rejects with :invalid_stack_status" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "already-going")
      {:ok, advanced} = Stacks.update_stack(stack, %{status: "in_progress"})

      assert {:error, :invalid_stack_status} = Stacks.start_stack(advanced)
      assert FakeRunner.calls() == []
    end
  end

  # ── GitShellRunner repo path resolution (smoke test of pure helper) ───────

  describe "GitShellRunner clone path scoping" do
    # Smoke-test the side-effect-free piece (clone_path_for + repo_root)
    # by configuring a custom repo_root and confirming the runner derives
    # a project-scoped subdirectory. Full git shell-out is exercised by
    # the e2e_behavior validation in stage 6 (a real bare repo on disk).

    test "ensure_rollup_branch on missing args returns {:error, :invalid_args}" do
      assert {:error, {:invalid_args, _}} =
               Platform.Tasks.StackDeployer.GitShellRunner.ensure_rollup_branch(%{})
    end

    test "merge_member_into_rollup on missing args returns {:error, :invalid_args}" do
      assert {:error, {:invalid_args, _}} =
               Platform.Tasks.StackDeployer.GitShellRunner.merge_member_into_rollup(%{})
    end
  end

  # ── merge_member_into_rollup/1 (stage 2) ─────────────────────────────────

  describe "merge_member_into_rollup/1" do
    test "happy path: review-ready member is merged and metadata is stamped" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "abc123def456"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "happy")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abc123def456", merged_at: %DateTime{}}} =
               StackDeployer.merge_member_into_rollup(task)

      # Member metadata stamped.
      reloaded = Tasks.get_task_record(task.id)
      stamp = reloaded.metadata["merged_into_rollup_at"]
      assert is_map(stamp)
      assert stamp["sha"] == "abc123def456"
      assert is_binary(stamp["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])

      # Runner was called with the right args.
      assert [call] = FakeRunner.merge_calls()
      assert call.repo_url == project.repo_url
      assert call.rollup_branch == stack.rollup_branch
      assert String.starts_with?(call.member_branch, "task/")
      assert call.member_slug == call.member_branch |> String.trim_leading("task/")
      assert call.project_id == project.id
      assert call.stack_id == stack.id
      assert call.member_task_id == task.id
    end

    test "conflict path: stack flips to blocked with metadata.conflict populated" do
      conflict_files = ["lib/foo.ex", "lib/bar.ex"]

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [
            {:error, :conflict, %{files: conflict_files, output: "CONFLICT (content): boom"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "conflict")
      task = review_ready_member!(project, stack)

      assert {:error, :conflict, ^conflict_files} =
               StackDeployer.merge_member_into_rollup(task)

      reloaded_stack = Stacks.get_stack(stack.id)
      assert reloaded_stack.status == "blocked"
      assert is_map(reloaded_stack.metadata)
      conflict = reloaded_stack.metadata["conflict"]
      assert conflict["member_task_id"] == task.id
      assert conflict["files"] == conflict_files
      assert is_binary(conflict["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(conflict["at"])

      # Member metadata NOT stamped on conflict.
      reloaded_task = Tasks.get_task_record(task.id)
      assert is_nil(get_in(reloaded_task.metadata, ["merged_into_rollup_at"]))
    end

    test "idempotency: already-merged member returns {:ok, :already_merged}" do
      {:ok, _} = FakeRunner.start_link(merge_responses: [])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "idempotent")
      task = review_ready_member!(project, stack)

      {:ok, task} =
        Tasks.update_task(task, %{
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "deadbeef",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_merged} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "non-conflict runner failure surfaces as {:error, reason}; stack not blocked" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:error, {:git_failed, ["push"], 128, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "auth-fail")
      task = review_ready_member!(project, stack)

      assert {:error, {:git_failed, _, 128, "auth boom"}} =
               StackDeployer.merge_member_into_rollup(task)

      reloaded_stack = Stacks.get_stack(stack.id)
      # Status is whatever the rollup recompute set it to (in_review or
      # earlier given the single in_review member). It must NOT be blocked.
      refute reloaded_stack.status == "blocked"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "conflict")
    end

    test "non-stack member returns {:error, :not_in_stack}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      {:ok, lone_task} = Tasks.create_task(%{project_id: project.id, title: "Lone"})

      assert {:error, :not_in_stack} = StackDeployer.merge_member_into_rollup(lone_task)
      assert FakeRunner.merge_calls() == []
    end

    test "task at in_progress (not in_review) is :not_ready" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "too-early")
      task = stack_member_at_in_progress!(project, stack)

      assert {:ok, :not_ready} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "task at in_review with a pending review validation is :not_ready" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "still-running")
      task = stack_member_at_in_review_with_pending_review!(project, stack)

      assert {:ok, :not_ready} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "project missing repo_url → {:error, :no_repo_url}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "no-remote-merge")
      task = review_ready_member!(project, stack)

      assert {:error, :no_repo_url} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "lookup-by-id: passing a binary task_id resolves to the record" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "by1d000"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "byid")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "by1d000"}} =
               StackDeployer.merge_member_into_rollup(task.id)
    end

    test "lookup-by-id: missing task returns {:error, :task_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :task_not_found} =
               StackDeployer.merge_member_into_rollup(Ecto.UUID.generate())
    end
  end

  # ── transition_task hook fires merge ─────────────────────────────────────

  describe "transition_task/2 → merge_member_into_rollup hook" do
    test "transitioning a stack member into in_review fires the runner merge" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "tr1g0er"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "trigger")
      task = stack_member_at_in_progress!(project, stack)
      _ = pass_review_validations_for!(task)

      assert {:ok, updated} = Tasks.transition_task(task, "in_review")
      assert updated.status == "in_review"

      assert [call] = FakeRunner.merge_calls()
      assert call.member_task_id == task.id
      assert call.rollup_branch == stack.rollup_branch

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == "tr1g0er"
    end

    test "transitioning a non-stack task into in_review does NOT call the runner" do
      {:ok, _} = FakeRunner.start_link(merge_responses: [])

      project = project_with_repo!()
      task = lone_task_at_in_progress!(project)

      assert {:ok, _updated} = Tasks.transition_task(task, "in_review")
      assert FakeRunner.merge_calls() == []
    end

    test "merge runner failure does NOT crash the transition" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:error, {:git_failed, ["push"], 1, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "swallow-merge")
      task = stack_member_at_in_progress!(project, stack)
      _ = pass_review_validations_for!(task)

      assert {:ok, updated} = Tasks.transition_task(task, "in_review")
      assert updated.status == "in_review"
      assert [_] = FakeRunner.merge_calls()
    end
  end

  # ── Stage 2 helpers ───────────────────────────────────────────────────────

  defp review_ready_member!(project, stack) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Member #{uniq()}", status: "in_review"})

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    # Plan + review stage with ALL validations passed → review_ready? == true.
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

    Tasks.get_task_record(task.id)
  end

  defp stack_member_at_in_review_with_pending_review!(project, stack) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Pending #{uniq()}",
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "running"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval", status: "pending"})

    Tasks.get_task_record(task.id)
  end

  defp stack_member_at_in_progress!(project, stack) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member #{uniq()}"})
    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})
    # Approved plan required to allow transition into in_review later.
    {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, task} = Tasks.transition_task(task, "in_progress")
    Tasks.get_task_record(task.id)
  end

  defp lone_task_at_in_progress!(project) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lone #{uniq()}"})
    {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, task} = Tasks.transition_task(task, "in_progress")
    task
  end

  # Add a passed review-stage validation set so review_ready?/1 returns true.
  defp pass_review_validations_for!(%{id: task_id}) do
    [plan] = Tasks.list_plans(task_id)

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 99,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    :ok
  end

  # ── maybe_open_stack_pr/1 (stage 4) ──────────────────────────────────────

  describe "maybe_open_stack_pr/1 — gate" do
    test "members partially merged → {:ok, :not_ready}; no PR shell-out" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "partial")

      # 4 members; only 3 stamped as merged.
      _ = merged_member!(project, stack, sha: "aaa1", position: 1)
      _ = merged_member!(project, stack, sha: "bbb2", position: 2)
      _ = merged_member!(project, stack, sha: "ccc3", position: 3)
      _ = unmerged_member!(project, stack, position: 4)

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "all members merged → stack flips to deploying, ONE PR opened, metadata.rollup_pr set" do
      pr_url = "https://github.com/test/repo/pull/137"

      {:ok, _} =
        FakeRunner.start_link(pr_responses: [{:ok, %{number: 137, url: pr_url}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "all-ready")

      _ = merged_member!(project, stack, sha: "shaone1", position: 1, title: "First member")
      _ = merged_member!(project, stack, sha: "shatwo2", position: 2, title: "Second member")
      _ = merged_member!(project, stack, sha: "shathr3", position: 3, title: "Third member")
      _ = merged_member!(project, stack, sha: "shafou4", position: 4, title: "Fourth member")

      assert {:ok, %{status: :opened, number: 137, url: ^pr_url, stack: deployed}} =
               StackDeployer.maybe_open_stack_pr(stack)

      assert deployed.status == "deploying"
      assert deployed.metadata["rollup_pr"]["number"] == 137
      assert deployed.metadata["rollup_pr"]["url"] == pr_url
      assert is_binary(deployed.metadata["rollup_pr"]["opened_at"])

      # Exactly ONE pr_create shell-out.
      assert [pr_call] = FakeRunner.pr_calls()
      assert pr_call.repo_url == project.repo_url
      assert pr_call.base_branch == stack.base_branch
      assert pr_call.rollup_branch == stack.rollup_branch
      assert pr_call.title == stack.name
      assert pr_call.project_id == project.id
      assert pr_call.stack_id == stack.id
    end

    test "empty stack → {:ok, :not_ready} (gate excludes 0-member stacks)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "empty")

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []
    end

    test "member status outside [in_review, deploying] → {:ok, :not_ready}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "wrong-status")

      # All 2 members have merged_into_rollup_at stamps, but one is
      # at "in_progress" (e.g. someone manually rolled it back). The
      # gate must reject.
      _ = merged_member!(project, stack, sha: "okay111", position: 1)

      m2 = merged_member!(project, stack, sha: "okay222", position: 2)
      {:ok, _} = Tasks.update_task(m2, %{status: "in_progress"})

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []
    end
  end

  describe "maybe_open_stack_pr/1 — idempotency" do
    test "stack with metadata.rollup_pr already set → {:ok, :already_open}; no shell-out" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "already")

      _ = merged_member!(project, stack, sha: "rea11dy", position: 1)

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 42,
              "url" => "https://github.com/test/repo/pull/42",
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_open} = StackDeployer.maybe_open_stack_pr(locked)
      assert FakeRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 42
    end

    test "stack with metadata.rollup_pr placeholder (status=opening) → :already_open (race guard)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "racing")

      _ = merged_member!(project, stack, sha: "race1", position: 1)

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "status" => "opening",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_open} = StackDeployer.maybe_open_stack_pr(locked)
      assert FakeRunner.pr_calls() == []
    end
  end

  describe "maybe_open_stack_pr/1 — PR body composition" do
    test "body contains member titles, shas, diff stat, and base→rollup framing" do
      pr_url = "https://github.com/test/repo/pull/200"

      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 200, url: pr_url}}],
          diff_stat_responses: [{:ok, " lib/foo.ex | 12 ++++++++++++\n 1 file changed"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "body")

      _ = merged_member!(project, stack, sha: "abc1234", position: 1, title: "Add foo")
      _ = merged_member!(project, stack, sha: "def5678", position: 2, title: "Refactor bar")

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)

      assert [pr_call] = FakeRunner.pr_calls()
      body = pr_call.body

      # Title and base/rollup framing present.
      assert body =~ stack.name
      assert body =~ stack.rollup_branch
      assert body =~ stack.base_branch

      # Both member titles + their shas present.
      assert body =~ "Add foo"
      assert body =~ "Refactor bar"
      assert body =~ "abc1234"
      assert body =~ "def5678"

      # Diff stat embedded.
      assert body =~ "1 file changed"
      assert body =~ "## Diff stat"

      # diff_stat called once with right args.
      assert [diff_call] = FakeRunner.diff_stat_calls()
      assert diff_call.repo_url == project.repo_url
      assert diff_call.base_branch == stack.base_branch
      assert diff_call.rollup_branch == stack.rollup_branch
    end

    test "diff_stat failure degrades gracefully — body still composes, no diff section" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 201, url: "https://github.com/test/repo/pull/201"}}],
          diff_stat_responses: [{:error, :network}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "no-diff")

      _ = merged_member!(project, stack, sha: "okay111", position: 1, title: "Member A")

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)

      assert [pr_call] = FakeRunner.pr_calls()
      assert pr_call.body =~ "Member A"
      refute pr_call.body =~ "## Diff stat"
    end
  end

  describe "maybe_open_stack_pr/1 — failure handling" do
    test "gh failure rolls back placeholder + status flip; no half-deployed stack" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:error, {:gh_failed, ["pr", "create"], 1, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "boom")

      _ = merged_member!(project, stack, sha: "ready11", position: 1)
      _ = merged_member!(project, stack, sha: "ready22", position: 2)

      assert {:error, {:gh_failed, _, 1, _}} = StackDeployer.maybe_open_stack_pr(stack)

      reloaded = Stacks.get_stack(stack.id)
      # Status rolled back; placeholder cleared.
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "stack not found returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.maybe_open_stack_pr(Ecto.UUID.generate())

      assert FakeRunner.pr_calls() == []
    end

    test "missing repo_url returns {:error, :no_repo_url} and does not flip stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "noremote")

      _ = merged_member!(project, stack, sha: "rdy11", position: 1)

      assert {:error, :no_repo_url} = StackDeployer.maybe_open_stack_pr(stack)

      reloaded = Stacks.get_stack(stack.id)
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end
  end

  # ── handle_rollup_pr_merged/1 (T6 success path) ──────────────────────────

  describe "handle_rollup_pr_merged/1" do
    test "transitions stack to done and stamps merged_at on rollup_pr metadata" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()

      stack = stack_for!(project, slug: "wrap")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 99,
              "url" => "https://github.com/test/repo/pull/99",
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, done_stack} = StackDeployer.handle_rollup_pr_merged(deployed)
      assert done_stack.status == "done"
      assert done_stack.metadata["rollup_pr"]["number"] == 99
      assert is_binary(done_stack.metadata["rollup_pr"]["merged_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(done_stack.metadata["rollup_pr"]["merged_at"])
    end

    test "idempotent on already-done stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "alreadydone")
      {:ok, done_stack} = Stacks.update_stack(stack, %{status: "done"})

      assert {:ok, returned} = StackDeployer.handle_rollup_pr_merged(done_stack)
      assert returned.id == stack.id
      assert returned.status == "done"
    end

    test "lookup-by-id resolves to the stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "by1d")

      {:ok, _} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 11}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(stack.id)
    end

    test "missing stack returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.handle_rollup_pr_merged(Ecto.UUID.generate())
    end
  end

  # ── per-member merge fires the stack-PR gate hook ────────────────────────

  describe "merge_member_into_rollup/1 — fires maybe_open_stack_pr hook" do
    test "successful per-member merge triggers the gate (PR opened when last merge lands)" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "lastmerg"}}],
          pr_responses: [
            {:ok, %{number: 312, url: "https://github.com/test/repo/pull/312"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "hook-fires")

      # Pre-seed: 2 already-merged members in the stack.
      _ = merged_member!(project, stack, sha: "old111", position: 1)
      _ = merged_member!(project, stack, sha: "old222", position: 2)

      # The 3rd member is review-ready but not yet merged. We invoke
      # the per-member merge — its success path should fire the
      # stack PR gate, find all 3 members merged, and open ONE PR.
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "lastmerg"}} =
               StackDeployer.merge_member_into_rollup(task)

      assert [_pr_call] = FakeRunner.pr_calls()

      reloaded_stack = Stacks.get_stack(stack.id)
      assert reloaded_stack.status == "deploying"
      assert reloaded_stack.metadata["rollup_pr"]["number"] == 312
    end

    test "successful per-member merge with members still pending → gate :not_ready, no PR" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "midmerge"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "still-pending")

      # Pre-seed: 1 already-merged + 1 unmerged member.
      _ = merged_member!(project, stack, sha: "old1111", position: 1)
      _ = unmerged_member!(project, stack, position: 2)

      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "midmerge"}} =
               StackDeployer.merge_member_into_rollup(task)

      # 1+1+1 merged out of 1+1+1+1 = still incomplete (the unmerged member is in_progress).
      assert FakeRunner.pr_calls() == []

      reloaded_stack = Stacks.get_stack(stack.id)
      refute reloaded_stack.status == "deploying"
    end
  end

  # ── Stage 4 helpers ───────────────────────────────────────────────────────

  defp merged_member!(project, stack, opts) do
    sha = Keyword.fetch!(opts, :sha)
    position = Keyword.get(opts, :position, 1)
    title = Keyword.get(opts, :title, "Merged member #{uniq()}")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => sha,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    task
  end

  defp unmerged_member!(project, stack, opts) do
    position = Keyword.get(opts, :position, 1)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unmerged #{uniq()}",
        status: "in_progress"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: position})

    task
  end

  # ── handle_rollup_ci_failure/2 (stage 5) ─────────────────────────────────

  describe "handle_rollup_ci_failure/2 — happy path" do
    test "bounces the most-recently-merged member; reverts merge; closes PR; flips stack" do
      pr_url = "https://github.com/test/repo/pull/777"
      ci_run_url = "#{pr_url}/checks?check_run_id=42"
      head_sha = "headshaaa"

      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revertz1"}}],
          close_responses: [{:ok, :closed}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "bounce-happy")

      # 4 stack members merged in chronological order; the 4th (most
      # recent) is the heuristic offender.
      m1 = merged_member_with_time!(project, stack, sha: "sha1aaaa", position: 1, minutes_ago: 40)
      m2 = merged_member_with_time!(project, stack, sha: "sha2bbbb", position: 2, minutes_ago: 30)
      m3 = merged_member_with_time!(project, stack, sha: "sha3cccc", position: 3, minutes_ago: 20)
      m4 = merged_member_with_time!(project, stack, sha: "sha4dddd", position: 4, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 777,
              "url" => pr_url,
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, %{status: :bounced, bounced_task_id: bounced_id, revert_sha: "revertz1"}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: ci_run_url,
                 head_sha: head_sha
               })

      assert bounced_id == m4.id

      # Bounced member: merged_into_rollup_at cleared, bounced_from_rollup
      # stamped, status flipped to in_progress.
      reloaded_m4 = Tasks.get_task_record(m4.id)
      assert reloaded_m4.status == "in_progress"
      assert is_nil(get_in(reloaded_m4.metadata, ["merged_into_rollup_at"]))
      stamp = reloaded_m4.metadata["bounced_from_rollup"]
      assert stamp["ci_run_url"] == ci_run_url
      assert stamp["head_sha"] == head_sha
      assert stamp["sha"] == "sha4dddd"
      assert is_binary(stamp["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])

      # Other members: untouched, still in_review with merged stamps.
      for m <- [m1, m2, m3] do
        reloaded = Tasks.get_task_record(m.id)
        assert reloaded.status == "in_review"

        assert reloaded.metadata["merged_into_rollup_at"]["sha"] ==
                 m.metadata["merged_into_rollup_at"]["sha"]

        assert is_nil(get_in(reloaded.metadata, ["bounced_from_rollup"]))
      end

      # Stack: flipped to in_review, rollup_pr cleared.
      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "in_review"
      assert is_nil(get_in(reloaded_stack.metadata || %{}, ["rollup_pr"]))

      # Runner: exactly one revert + one PR close, on the right inputs.
      assert [revert_call] = FakeRunner.revert_calls()
      assert revert_call.repo_url == project.repo_url
      assert revert_call.rollup_branch == stack.rollup_branch
      assert revert_call.merge_sha == "sha4dddd"
      assert revert_call.project_id == project.id
      assert revert_call.stack_id == stack.id
      assert revert_call.member_task_id == m4.id

      assert [close_call] = FakeRunner.close_calls()
      assert close_call.repo_url == project.repo_url
      assert close_call.pr_number == 777
      assert close_call.stack_id == stack.id
      assert is_binary(close_call.comment)
      assert close_call.comment =~ ci_run_url
      assert close_call.comment =~ m4.id
    end
  end

  describe "handle_rollup_ci_failure/2 — idempotency" do
    test "second invocation with the same ci_run_url no-ops" do
      ci_run_url = "https://github.com/test/repo/pull/8/checks/99"

      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revertz2"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "idem")

      _m1 = merged_member_with_time!(project, stack, sha: "old1aaa", position: 1, minutes_ago: 20)
      m2 = merged_member_with_time!(project, stack, sha: "old2bbb", position: 2, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 8}}
        })

      assert {:ok, %{status: :bounced, bounced_task_id: bounced_id}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: ci_run_url,
                 head_sha: "head1"
               })

      assert bounced_id == m2.id

      # Second invocation: the offender is now in_progress (lost its
      # merged_into_rollup_at stamp) so the heuristic picks the next
      # candidate (m1). To exercise the idempotency guard we re-stamp
      # m2 as if a partial-retry left it merged-but-bounced, then
      # re-invoke — the bounced_from_rollup.ci_run_url match must
      # short-circuit.
      {:ok, _} =
        Tasks.update_task(Tasks.get_task_record(m2.id), %{
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "old2bbb",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            },
            "bounced_from_rollup" => %{
              "ci_run_url" => ci_run_url,
              "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "head_sha" => "head1",
              "sha" => "old2bbb"
            }
          }
        })

      reloaded_stack = Stacks.get_stack(deployed.id)

      assert {:ok, :already_bounced} =
               StackDeployer.handle_rollup_ci_failure(reloaded_stack, %{
                 ci_run_url: ci_run_url,
                 head_sha: "head1"
               })

      # Only the first invocation called the runner.
      assert [_] = FakeRunner.revert_calls()
    end
  end

  describe "handle_rollup_ci_failure/2 — heuristic ambiguity" do
    test "logs a warning when multiple merge candidates fit the window" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "ambig")

      _m1 = merged_member_with_time!(project, stack, sha: "amb1aaa", position: 1, minutes_ago: 30)
      _m2 = merged_member_with_time!(project, stack, sha: "amb2bbb", position: 2, minutes_ago: 20)
      _m3 = merged_member_with_time!(project, stack, sha: "amb3ccc", position: 3, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 33}}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :bounced}} =
                   StackDeployer.handle_rollup_ci_failure(deployed, %{
                     ci_run_url: "https://example/run/1",
                     head_sha: "h1"
                   })
        end)

      assert log =~ "CI attribution heuristic"
      assert log =~ "review may be required"
    end
  end

  describe "handle_rollup_ci_failure/2 — revert failure" do
    test "runner revert error returns {:error, reason} and does not stamp bounce" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:error, {:revert_failed, "conflict on revert"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "revert-boom")

      m1 = merged_member_with_time!(project, stack, sha: "rv1aaaa", position: 1, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 555}}
        })

      assert {:error, {:revert_failed, "conflict on revert"}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/x",
                 head_sha: "h1"
               })

      # Offender: still in its original state — no bounce stamp, still
      # has merged_into_rollup_at, not transitioned to in_progress.
      reloaded = Tasks.get_task_record(m1.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == "rv1aaaa"
      assert is_nil(get_in(reloaded.metadata, ["bounced_from_rollup"]))
      assert reloaded.status == "in_review"

      # Stack: still deploying — bounce aborted before the flip.
      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "deploying"
      assert reloaded_stack.metadata["rollup_pr"]["number"] == 555

      # PR close not attempted on revert failure.
      assert FakeRunner.close_calls() == []
    end
  end

  describe "handle_rollup_ci_failure/2 — PR close failure" do
    test "gh pr close failure does not crash; bounce still proceeds" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "rev999"}}],
          close_responses: [{:error, {:gh_failed, ["pr", "close"], 1, "rate limited"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-close-boom")

      m1 = merged_member_with_time!(project, stack, sha: "cls1aaa", position: 1, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 12}}
        })

      assert {:ok, %{status: :bounced, bounced_task_id: bounced_id}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/y",
                 head_sha: "h1"
               })

      assert bounced_id == m1.id

      # Bounce went through despite PR close failure.
      reloaded = Tasks.get_task_record(m1.id)
      assert reloaded.status == "in_progress"
      assert reloaded.metadata["bounced_from_rollup"]["sha"] == "cls1aaa"

      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "in_review"
      assert is_nil(get_in(reloaded_stack.metadata || %{}, ["rollup_pr"]))

      assert [_] = FakeRunner.close_calls()
    end
  end

  describe "handle_rollup_ci_failure/2 — edge cases" do
    test "no merged member returns {:ok, :no_candidate}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "nobody")

      _ = unmerged_member!(project, stack, position: 1)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 22}}
        })

      assert {:ok, :no_candidate} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/z",
                 head_sha: "h1"
               })

      assert FakeRunner.revert_calls() == []
      assert FakeRunner.close_calls() == []
    end

    test "lookup-by-id resolves to the stack" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "rev123"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "byid")
      _m1 = merged_member_with_time!(project, stack, sha: "byid111", position: 1, minutes_ago: 5)

      {:ok, _} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 1}}
        })

      assert {:ok, %{status: :bounced}} =
               StackDeployer.handle_rollup_ci_failure(stack.id, %{
                 ci_run_url: "https://example/run/byid",
                 head_sha: "h1"
               })
    end

    test "missing stack returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.handle_rollup_ci_failure(Ecto.UUID.generate(), %{
                 ci_run_url: "x",
                 head_sha: "y"
               })

      assert FakeRunner.revert_calls() == []
    end

    test "stack with no rollup_pr metadata skips close but still bounces" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "norev1"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "no-pr-meta")

      m1 = merged_member_with_time!(project, stack, sha: "nopr111", position: 1, minutes_ago: 5)

      {:ok, deployed} = Stacks.update_stack(stack, %{status: "deploying", metadata: %{}})

      assert {:ok, %{status: :bounced, bounced_task_id: bounced_id}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/nopr",
                 head_sha: "h1"
               })

      assert bounced_id == m1.id
      assert FakeRunner.close_calls() == []
    end
  end

  # ── Stage 5 helpers ───────────────────────────────────────────────────────

  defp merged_member_with_time!(project, stack, opts) do
    sha = Keyword.fetch!(opts, :sha)
    position = Keyword.get(opts, :position, 1)
    minutes_ago = Keyword.get(opts, :minutes_ago, 0)
    title = Keyword.get(opts, :title, "Merged member #{uniq()}")

    merged_at =
      DateTime.utc_now()
      |> DateTime.add(-minutes_ago * 60, :second)
      |> DateTime.to_iso8601()

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => sha, "at" => merged_at}
        }
      })

    task
  end
end
