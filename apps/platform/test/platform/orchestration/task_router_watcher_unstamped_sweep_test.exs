defmodule Platform.Orchestration.TaskRouterWatcherUnstampedSweepTest do
  @moduledoc """
  Task 01a136c1 stage 1 — `TaskRouterWatcher.sweep_unstamped_review_ready_members/0`.

  `sweep_in_review_stalls/0` only selects members that already carry
  `merged_into_rollup_at`. A member whose rollup merge was declined has no
  stamp, so before this sweep nothing retried it. These cases drive the new
  sweep directly:

    * an unstamped, all-passed, debounced member is merged, and a second
      pass does not merge it again;
    * an unstamped member with a pending validation is untouched;
    * an unstamped, all-passed member with an OPEN rollup-merge blocker is
      skipped and no second blocker is filed;
    * a blocker that was later unblocked no longer holds the member back.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.{RuntimeEvent, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, StackDeployer, Task}

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{merge_calls: []} end, name: __MODULE__)
    end

    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: "deadbee"}}

    @impl true
    def merge_member_into_rollup(args) do
      Agent.update(__MODULE__, fn state -> %{state | merge_calls: [args | state.merge_calls]} end)
      {:ok, %{status: :merged, merge_sha: "5eed5eed"}}
    end

    @impl true
    def open_stack_pr(_args), do: {:ok, %{number: 7, url: "https://github.com/test/repo/pull/7"}}

    @impl true
    def diff_stat(_args), do: {:ok, " 1 file changed"}

    @impl true
    def revert_member_merge(_args), do: {:ok, %{status: :reverted, revert_sha: "rev0000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    start_supervised!(FakeRunner)
    Application.put_env(:platform, :stack_deployer, git_runner: FakeRunner, async: false)
    on_exit(fn -> Application.put_env(:platform, :stack_deployer, prev) end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Unstamped Sweep " <> Ecto.UUID.generate(),
        repo_url: "https://github.com/test/unstamped-sweep"
      })

    slug = "unstamped-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Unstamped #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    %{project: project, stack: stack}
  end

  # An UNSTAMPED stack member at `in_review` whose current plan has one
  # review stage. `pending?` leaves one of its two validations pending.
  defp unstamped_member!(project, stack, opts \\ []) do
    pending? = Keyword.get(opts, :pending?, false)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unstamped member " <> Ecto.UUID.generate(),
        status: "in_review",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
      })

    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: if(pending?, do: "running", else: "passed")
      })

    payload = %{"setup" => "s", "actions" => "a", "expected" => "e"}

    {:ok, _} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "e2e_behavior",
        status: "passed",
        evaluation_payload: payload
      })

    {:ok, _} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "e2e_behavior",
        status: if(pending?, do: "pending", else: "passed"),
        evaluation_payload: payload
      })

    backdate!(task, 30)
    Tasks.get_task_record(task.id)
  end

  defp backdate!(%Task{id: id}, minutes_ago) do
    backdate = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
    from(t in Task, where: t.id == ^id) |> Repo.update_all(set: [updated_at: backdate])
  end

  defp blocked_events(task_id) do
    from(e in RuntimeEvent,
      where:
        e.task_id == ^task_id and e.runtime_id == "stack_deployer" and
          e.event_type == "execution.blocked"
    )
    |> Repo.all()
  end

  describe "sweep_unstamped_review_ready_members/0" do
    test "merges an unstamped, all-passed, debounced member, and only once", %{
      project: project,
      stack: stack
    } do
      task = unstamped_member!(project, stack)
      refute Map.has_key?(task.metadata || %{}, "merged_into_rollup_at")

      result = TaskRouterWatcher.sweep_unstamped_review_ready_members()

      assert %{scanned: 1, triggered: 1, skipped_blocked: 0, observed: 0} = result
      assert [%{member_task_id: member_id}] = FakeRunner.merge_calls()
      assert member_id == task.id

      reloaded = Tasks.get_task_record(task.id)
      assert %{"sha" => "5eed5eed"} = reloaded.metadata["merged_into_rollup_at"]

      # Second pass: the member is stamped now, so the sweep no longer
      # selects it and the runner is not called again.
      backdate!(reloaded, 30)

      assert %{scanned: 0, triggered: 0} =
               TaskRouterWatcher.sweep_unstamped_review_ready_members()

      assert length(FakeRunner.merge_calls()) == 1
    end

    test "leaves a member with a pending validation untouched", %{project: project, stack: stack} do
      task = unstamped_member!(project, stack, pending?: true)

      result = TaskRouterWatcher.sweep_unstamped_review_ready_members()

      assert %{scanned: 1, triggered: 0, skipped_blocked: 0, observed: 1} = result
      assert FakeRunner.merge_calls() == []

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"
      refute Map.has_key?(reloaded.metadata || %{}, "merged_into_rollup_at")
    end

    test "skips a member with an open rollup-merge blocker and files no second one", %{
      project: project,
      stack: stack
    } do
      task = unstamped_member!(project, stack)
      :ok = StackDeployer.record_merge_blocker(task, "Rollup merge returned error: :boom")
      assert [_one] = blocked_events(task.id)
      backdate!(task, 30)

      for _pass <- 1..2 do
        assert %{scanned: 1, triggered: 0, skipped_blocked: 1, observed: 0} =
                 TaskRouterWatcher.sweep_unstamped_review_ready_members()
      end

      assert FakeRunner.merge_calls() == []
      assert [_still_one] = blocked_events(task.id)
    end

    test "skips a member stamped rollup_diverged even without a blocked event", %{
      project: project,
      stack: stack
    } do
      task = unstamped_member!(project, stack)

      {:ok, _} =
        Tasks.update_task(task, %{
          metadata:
            Map.put(task.metadata || %{}, "paused_reason", %{
              "kind" => "rollup_diverged",
              "rollup_sha" => "abc"
            })
        })

      backdate!(task, 30)

      assert %{scanned: 1, triggered: 0, skipped_blocked: 1} =
               TaskRouterWatcher.sweep_unstamped_review_ready_members()

      assert FakeRunner.merge_calls() == []
    end

    test "a blocker that was later unblocked no longer holds the member back", %{
      project: project,
      stack: stack
    } do
      task = unstamped_member!(project, stack)
      :ok = StackDeployer.record_merge_blocker(task, "Rollup merge raised: transient")

      {:ok, _} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "some-human-runtime",
          "event_type" => "execution.unblocked",
          "occurred_at" => DateTime.add(DateTime.utc_now(), 1, :second),
          "payload" => %{"stage_id" => nil}
        })

      backdate!(task, 30)

      assert %{scanned: 1, triggered: 1, skipped_blocked: 0} =
               TaskRouterWatcher.sweep_unstamped_review_ready_members()

      assert [_merged] = FakeRunner.merge_calls()
    end
  end
end
