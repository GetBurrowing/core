defmodule Platform.TasksTest do
  @moduledoc """
  Tests for the central `Platform.Tasks` seam introduced in Stack v2 stage 1:
  `Tasks.dispatch_deploy_for_task/1` — the single guard consulted by every
  per-task deploy-dispatch call site (auto-merger, webhook controller,
  plan-engine's deploy-stage injection) so the "stacks ship as ONE rollup
  PR" invariant can never regress silently.
  """

  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  describe "dispatch_deploy_for_task/1 — guard behavior" do
    test "returns :ok for a task with no stack_id" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Solo #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/solo"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Solo task"})

      assert :ok = Tasks.dispatch_deploy_for_task(task)
      assert :ok = Tasks.dispatch_deploy_for_task(task.id)
    end

    test "returns :ok for nil and unknown task id" do
      assert :ok = Tasks.dispatch_deploy_for_task(nil)
      assert :ok = Tasks.dispatch_deploy_for_task(Ecto.UUID.generate())
    end

    test "returns {:error, :stack_ships_atomically} for a stacked task" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Stacked #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/stacked"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "stacked-#{System.unique_integer([:positive])}",
          name: "Guard Stack",
          rollup_branch: "stack/guard"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task)
      # Same via task id — recovers the record and applies the same guard.
      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task.id)
    end
  end

  describe "dispatch_deploy_for_task/1 — telemetry" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Telem #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/telem"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "telem-#{System.unique_integer([:positive])}",
          name: "Telem Stack",
          rollup_branch: "stack/telem"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      # Per-test telemetry handler with a unique id so async runs don't
      # collide even though we've opted out of :async — belt and braces.
      handler_id = "rejected_stack_member_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :tasks, :deploy_dispatch, :rejected_stack_member],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{task: task, stack: stack}
    end

    test "fires exactly once per invocation on the blocked path", %{task: task, stack: stack} do
      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task)

      assert_receive {:telemetry_event,
                      [:platform, :tasks, :deploy_dispatch, :rejected_stack_member], %{count: 1},
                      %{task_id: task_id, stack_id: stack_id}}

      assert task_id == task.id
      assert stack_id == stack.id

      # Exactly once — nothing else in the queue after draining.
      refute_receive {:telemetry_event, _, _, _}, 50
    end

    test "does NOT fire on the allowed (non-stack) path" do
      {:ok, project} =
        Tasks.create_project(%{name: "Allowed #{System.unique_integer([:positive])}"})

      {:ok, solo} = Tasks.create_task(%{project_id: project.id, title: "Solo"})

      assert :ok = Tasks.dispatch_deploy_for_task(solo)

      refute_receive {:telemetry_event, _, _, _}, 50
    end
  end
end
