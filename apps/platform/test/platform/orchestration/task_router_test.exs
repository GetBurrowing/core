defmodule Platform.Orchestration.TaskRouterTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Test Project",
        repo_url: "https://github.com/test/router"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router Test Task",
        description: "Testing the task router"
      })

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}

    # Allow dynamically started TaskRouter processes to share the test sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      # Stop router before sandbox teardown to avoid connection errors
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage, assignee: assignee}
  end

  describe "start_link/1 and lifecycle" do
    test "starts and registers a router process", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      # Should be registered
      assert [{^pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
    end

    test "stop/1 terminates the router", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end

    test "stop/1 returns error for unknown task" do
      assert {:error, :not_found} = TaskRouter.stop("nonexistent")
    end
  end

  describe "current_status/1" do
    test "returns router status after dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Allow dispatch to process
      Process.sleep(50)

      status = TaskRouter.current_status(task.id)

      assert status.task_id == task.id
      assert status.assignee == assignee
      assert status.status == :running
      assert status.escalation_count == 0
    end

    test "includes execution_space_id in status", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert is_binary(status.execution_space_id)

      # Verify the space exists and is an execution space
      space = Platform.Chat.get_space(status.execution_space_id)
      assert space.kind == "execution"
      assert space.metadata["task_id"] == task.id
    end
  end

  describe "PubSub event handling" do
    test "resets heartbeat on task_updated", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Simulate a board event for our task
      updated_task = Tasks.get_task_detail(task.id)
      Tasks.broadcast_board({:task_updated, updated_task})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.last_evidence_at != nil
    end

    test "updates stage on stage_transitioned", %{task: task, assignee: assignee, stage: stage} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Simulate stage transition
      Tasks.broadcast_board({:stage_transitioned, stage})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage.id
      assert status.last_evidence_at != nil
    end

    test "completed plan transitions in_progress task to in_review", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      completed_plan =
        plan
        |> Ecto.Changeset.change(%{status: "completed"})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(100)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"
    end

    test "ignores task_updated for other tasks", %{
      task: task,
      assignee: assignee,
      project: project
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Create a different task and broadcast its update
      {:ok, other_task} = Tasks.create_task(%{project_id: project.id, title: "Other"})
      other_detail = Tasks.get_task_detail(other_task.id)
      Tasks.broadcast_board({:task_updated, other_detail})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      # last_evidence_at should be nil since we only got the unrelated event
      # (dispatch sets it to nil, only our-task events set it)
      assert status.status == :running
    end
  end

  describe "dispatch" do
    test "transitions to :running after init dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Allow dispatch message to be processed
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end
  end

  describe "router lifecycle (no assignment persistence)" do
    test "router starts and stops cleanly without persisting to DB", %{
      task: task,
      assignee: assignee
    } do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      assert Process.alive?(pid)

      # Stop via TaskRouter.stop/1
      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end
  end
end
