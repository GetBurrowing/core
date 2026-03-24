defmodule Platform.Orchestration.TaskRouterAssignmentTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.TaskRouterAssignment
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Assignment Test Project",
        repo_url: "https://github.com/test/assignment"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Assignment Test Task",
        description: "Testing assignment persistence"
      })

    %{project: project, task: task}
  end

  describe "create_changeset/1" do
    test "valid with required fields", %{task: task} do
      cs =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_type: "federated",
          assignee_id: "runtime-test-1"
        })

      assert cs.valid?
      assert get_change(cs, :task_id) == task.id
      assert get_change(cs, :assignee_type) == "federated"
      assert get_change(cs, :assignee_id) == "runtime-test-1"
      # assigned_at gets a default
      assert get_change(cs, :assigned_at) != nil
    end

    test "invalid without task_id" do
      cs =
        TaskRouterAssignment.create_changeset(%{
          assignee_type: "federated",
          assignee_id: "runtime-test-1"
        })

      refute cs.valid?
      assert {:task_id, _} = hd(cs.errors)
    end

    test "invalid without assignee_type", %{task: task} do
      cs =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_id: "runtime-test-1"
        })

      refute cs.valid?
      assert {:assignee_type, _} = hd(cs.errors)
    end

    test "invalid without assignee_id", %{task: task} do
      cs =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_type: "federated"
        })

      refute cs.valid?
      assert {:assignee_id, _} = hd(cs.errors)
    end
  end

  describe "status_changeset/2" do
    test "accepts valid status values", %{task: task} do
      {:ok, assignment} =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_type: "federated",
          assignee_id: "runtime-test-1"
        })
        |> Repo.insert()

      for status <- ~w(active completed failed) do
        cs = TaskRouterAssignment.status_changeset(assignment, %{status: status})
        assert cs.valid?, "expected status #{status} to be valid"
      end
    end

    test "rejects invalid status values", %{task: task} do
      {:ok, assignment} =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_type: "federated",
          assignee_id: "runtime-test-1"
        })
        |> Repo.insert()

      cs = TaskRouterAssignment.status_changeset(assignment, %{status: "bogus"})
      refute cs.valid?
    end
  end

  describe "list_active/0" do
    test "returns only active records", %{task: task, project: project} do
      {:ok, task2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Second Task",
          description: "Another task"
        })

      {:ok, task3} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Third Task",
          description: "Completed task"
        })

      # Insert active assignment
      {:ok, _} =
        TaskRouterAssignment.create_changeset(%{
          task_id: task.id,
          assignee_type: "federated",
          assignee_id: "runtime-1"
        })
        |> Repo.insert()

      # Insert another active
      {:ok, _} =
        TaskRouterAssignment.create_changeset(%{
          task_id: task2.id,
          assignee_type: "federated",
          assignee_id: "runtime-2"
        })
        |> Repo.insert()

      # Insert a completed one
      {:ok, completed} =
        TaskRouterAssignment.create_changeset(%{
          task_id: task3.id,
          assignee_type: "federated",
          assignee_id: "runtime-3"
        })
        |> Repo.insert()

      completed
      |> TaskRouterAssignment.status_changeset(%{status: "completed"})
      |> Repo.update!()

      active = TaskRouterAssignment.list_active()
      active_ids = Enum.map(active, & &1.task_id)

      assert task.id in active_ids
      assert task2.id in active_ids
      refute task3.id in active_ids
      assert length(active) == 2
    end
  end
end
