defmodule Platform.Tasks.PlanEngineStackMemberMergeTest do
  @moduledoc """
  Task 019e2be4 stage 1 — verify that when a stack member's plan completes
  via `PlanEngine.advance/1`, the engine fires the rollup-merge trigger
  (`StackDeployer.handle_member_transition/3`) instead of just logging
  "deferring to stack deployer" and walking away.

  These tests are `async: false` because they install a fake `GitRunner`
  via `Application.put_env(:platform, :stack_deployer, ...)` to observe
  what the deployer was asked to do.
  """

  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stacks, StackDeployer}

  # Reuse the same FakeRunner shape as `StackDeployerTest`. Kept local so
  # this file has no link-time dependency on a sibling test module.
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
          Keyword.get(opts, :revert_default, {:ok, %{status: :reverted, revert_sha: "rev0000"}}),
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

    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()

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

    {:ok, project} =
      Tasks.create_project(%{
        name: "PlanEngine StackMember Merge Project #{uniq()}",
        repo_url: "https://github.com/test/plan-engine-stack-#{uniq()}"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: "merge-trigger-#{uniq()}",
        name: "Merge Trigger Stack",
        rollup_branch: "stack/merge-trigger-#{uniq()}"
      })

    %{project: project, stack: stack}
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  describe "stack-member plan completion fires StackDeployer.handle_member_transition" do
    test "stack member at in_review whose plan completes triggers a merge call to the runner",
         %{project: project, stack: stack} do
      {:ok, _} = FakeRunner.start_link([])

      # Stack member that is already in_review (review request flipped it
      # earlier in the lifecycle). Branch metadata is required for the
      # deployer to compute the merge args.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member ready to merge",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      # The plan has one review stage so review_ready? returns true with
      # zero pending validations (vacuously ready).
      {:ok, review_stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review"})

      {:ok, _} = PlanEngine.start_stage(review_stage.id)

      # Advance the plan — the only stage passes, and the stack-member
      # branch of `maybe_inject_deploy_or_complete` MUST fire the
      # deployer hook (the missing seam this task closes).
      {:ok, completed_plan} = PlanEngine.advance(plan.id)
      assert completed_plan.status == "completed"

      assert [call] = FakeRunner.merge_calls(),
             "expected the deployer's git runner to be invoked exactly once"

      # `member_branch_for/1` derives `task/<short_id>` from task.id
      # (ADR 0041 §"Branch model"). We don't hardcode the short id here
      # — assertion is on the conventional prefix and the cross-cutting
      # identifiers we actually care about.
      assert String.starts_with?(call.member_branch, "task/")
      assert call.rollup_branch == stack.rollup_branch
      assert call.member_task_id == task.id
      assert call.stack_id == stack.id
    end

    test "stack member NOT yet at in_review still invokes the hook (which noops as :not_ready)",
         %{project: project, stack: stack} do
      {:ok, _} = FakeRunner.start_link([])

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member still in_progress",
          status: "in_progress",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, build} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      {:ok, _} = PlanEngine.start_stage(build.id)

      {:ok, completed_plan} = PlanEngine.advance(plan.id)
      assert completed_plan.status == "completed"

      # The deployer was invoked, but `merge_member_into_rollup/1` short-
      # circuits as `{:ok, :not_ready}` before reaching the runner because
      # the task is still in_progress (not in_review). So no runner call
      # is observed — and crucially, no crash and no double-fire either.
      assert FakeRunner.merge_calls() == []
    end

    test "re-running engine over an already-merged member is a noop (no double merge call)",
         %{project: project, stack: stack} do
      {:ok, _} = FakeRunner.start_link([])

      now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already merged member",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}},
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc123", "at" => now_iso}
          }
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, review} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review"})
      {:ok, _} = PlanEngine.start_stage(review.id)

      {:ok, completed_plan} = PlanEngine.advance(plan.id)
      assert completed_plan.status == "completed"

      # already_merged? short-circuits inside merge_member_into_rollup/1
      # before the runner is touched. The hook itself fires (we expect
      # idempotency to live in the deployer, not in the engine), but no
      # actual merge work is done.
      assert FakeRunner.merge_calls() == []
    end
  end

  describe "solo-task path remains unchanged" do
    test "solo task (no stack_id) still gets per-task deploy stage injected and no merge fired",
         %{project: project} do
      {:ok, _} = FakeRunner.start_link([])

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Solo task gets deploy stage",
          status: "in_progress",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}},
          # Stage-2 guard `require_deploy_target_for/2` needs a resolvable
          # target before the engine can inject a Deploy stage; without it
          # the advance would refuse the :deploying transition.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(build.id)

      {:ok, plan_after_advance} = PlanEngine.advance(plan.id)

      # Deploy stage was injected, task transitioned to deploying.
      deploy_stage =
        Enum.find(plan_after_advance.stages, &String.starts_with?(&1.name, "Deploy:"))

      assert deploy_stage != nil
      assert deploy_stage.status == "running"

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "deploying"

      # And the rollup-merge runner was NOT invoked — solo tasks are
      # untouched by stage 1's new wiring.
      assert FakeRunner.merge_calls() == []
    end
  end

  # Sanity: the public hook has the shape we wire to.
  describe "StackDeployer.handle_member_transition/3 contract" do
    test "is callable with (task, atom, atom) without raising for non-stack tasks",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Solo callable",
          status: "in_progress"
        })

      record = Tasks.get_task_record(task.id)
      assert :ok = StackDeployer.handle_member_transition(record, :plan_completed, :in_review)
    end
  end
end
