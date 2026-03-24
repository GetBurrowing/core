defmodule Platform.Orchestration.RehydratorTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.{Rehydrator, TaskRouterAssignment}
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Rehydrator Test Project",
        repo_url: "https://github.com/test/rehydrator"
      })

    {:ok, task1} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Active Task 1",
        description: "Should be rehydrated"
      })

    {:ok, task2} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Active Task 2",
        description: "Should also be rehydrated"
      })

    {:ok, task3} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Completed Task",
        description: "Should NOT be rehydrated"
      })

    # Create plans so task_detail doesn't return nil
    for task <- [task1, task2, task3] do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", description: "Work"})
    end

    # Insert assignments directly into DB
    {:ok, _} =
      TaskRouterAssignment.create_changeset(%{
        task_id: task1.id,
        assignee_type: "federated",
        assignee_id: "runtime-rehydrate-1"
      })
      |> Repo.insert()

    {:ok, _} =
      TaskRouterAssignment.create_changeset(%{
        task_id: task2.id,
        assignee_type: "federated",
        assignee_id: "runtime-rehydrate-2"
      })
      |> Repo.insert()

    {:ok, completed} =
      TaskRouterAssignment.create_changeset(%{
        task_id: task3.id,
        assignee_type: "federated",
        assignee_id: "runtime-rehydrate-3"
      })
      |> Repo.insert()

    completed
    |> TaskRouterAssignment.status_changeset(%{status: "completed"})
    |> Repo.update!()

    # Allow dynamically spawned TaskRouter GenServers to share the test sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      # Stop any routers spawned during rehydration
      for task <- [task1, task2, task3] do
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
      end
    end)

    %{task1: task1, task2: task2, task3: task3}
  end

  describe "rehydration" do
    test "spawns routers for active assignments only", %{
      task1: task1,
      task2: task2,
      task3: task3
    } do
      # The Rehydrator is already running in the app supervision tree.
      # Send it a fresh :rehydrate message to pick up our test assignments.
      pid = Process.whereis(Rehydrator)
      assert pid != nil, "Rehydrator should be running"

      send(pid, :rehydrate)

      # Give the :rehydrate message time to process and routers to init
      Process.sleep(300)

      # Active tasks should have routers running
      assert [{_, _}] = Registry.lookup(Platform.Orchestration.Registry, task1.id)
      assert [{_, _}] = Registry.lookup(Platform.Orchestration.Registry, task2.id)

      # Completed task should NOT have a router
      assert [] = Registry.lookup(Platform.Orchestration.Registry, task3.id)
    end
  end
end
