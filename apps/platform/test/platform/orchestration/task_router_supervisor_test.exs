defmodule Platform.Orchestration.TaskRouterSupervisorTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.TaskRouterSupervisor
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Supervisor Test Project",
        repo_url: "https://github.com/test/supervisor"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Supervisor Test Task",
        description: "Testing the supervisor"
      })

    assignee = %{type: :federated, id: "runtime-sup-#{System.unique_integer([:positive])}"}

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

    %{project: project, task: task, assignee: assignee}
  end

  describe "start_assignment/2" do
    test "starts a TaskRouter under the supervisor", %{task: task, assignee: assignee} do
      assert {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      assert Process.alive?(pid)
    end

    test "returns error if already started", %{task: task, assignee: assignee} do
      assert {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)

      assert {:error, {:already_started, _}} =
               TaskRouterSupervisor.start_assignment(task.id, assignee)
    end
  end

  describe "stop_assignment/1" do
    test "stops a running TaskRouter", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      assert Process.alive?(pid)

      assert :ok = TaskRouterSupervisor.stop_assignment(task.id)
      refute Process.alive?(pid)
    end

    test "returns error for unknown task" do
      assert {:error, :not_found} = TaskRouterSupervisor.stop_assignment("nonexistent")
    end
  end

  describe "list_active/0" do
    test "lists active assignments", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      Process.sleep(50)

      active = TaskRouterSupervisor.list_active()
      assert length(active) >= 1
      assert Enum.any?(active, &(&1.task_id == task.id))
    end

    test "returns empty list when no assignments" do
      # Stop any leftover assignments first
      for status <- TaskRouterSupervisor.list_active() do
        TaskRouterSupervisor.stop_assignment(status.task_id)
      end

      assert TaskRouterSupervisor.list_active() == []
    end
  end
end
