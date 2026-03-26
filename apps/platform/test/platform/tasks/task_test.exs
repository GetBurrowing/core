defmodule Platform.Tasks.TaskTest do
  use Platform.DataCase, async: true

  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Task, Validation}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Test Project"})
    %{project: project}
  end

  describe "create_task/1" do
    test "creates a task with valid attrs", %{project: project} do
      assert {:ok, %Task{} = task} =
               Tasks.create_task(%{project_id: project.id, title: "Build feature"})

      assert task.title == "Build feature"
      assert task.status == "backlog"
      assert task.priority == "medium"
    end

    test "fails without title", %{project: project} do
      assert {:error, changeset} = Tasks.create_task(%{project_id: project.id})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails with invalid status", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{project_id: project.id, title: "X", status: "invalid"})

      assert %{status: [_]} = errors_on(changeset)
    end

    test "fails with invalid priority", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{project_id: project.id, title: "X", priority: "urgent"})

      assert %{priority: [_]} = errors_on(changeset)
    end
  end

  describe "transition_task_status/2" do
    test "allows valid transitions", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "backlog"})

      assert {:ok, task} = Tasks.transition_task_status(task, "planning")
      assert task.status == "planning"

      assert {:ok, task} = Tasks.transition_task_status(task, "ready")
      assert task.status == "ready"

      assert {:ok, task} = Tasks.transition_task_status(task, "in_progress")
      assert task.status == "in_progress"

      assert {:ok, task} = Tasks.transition_task_status(task, "in_review")
      assert task.status == "in_review"

      assert {:ok, task} = Tasks.transition_task_status(task, "done")
      assert task.status == "done"
    end

    test "rejects invalid transitions", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "backlog"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "done")
    end

    test "done has no outbound transitions", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "done"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "backlog")
    end

    test "blocked can go to multiple states", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "blocked"})
      assert {:ok, _} = Tasks.transition_task_status(task, "backlog")
    end
  end

  describe "transition_task/2" do
    test "reopens a failed manual approval gate and abandons stale execution lease before moving back to in_review",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Retry review", status: "in_progress"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Manual review",
          status: "running"
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval", status: "pending"})

      {:ok, started_event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.started"
        })

      {:ok, _blocked_event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.blocked",
          "payload" => %{"description" => "waiting on review retry"}
        })

      {:ok, _} =
        PlanEngine.evaluate_validation(validation.id, %{status: "failed", evaluated_by: "test"})

      assert Repo.get!(Stage, stage.id).status == "failed"
      assert Repo.get!(Validation, validation.id).status == "failed"
      assert RuntimeSupervision.current_lease_for_task(task.id).status == "blocked"

      assert {:ok, updated_task} = Tasks.transition_task(task, "in_review")
      assert updated_task.status == "in_review"

      retried_stage = Repo.get!(Stage, stage.id)
      assert retried_stage.status == "running"
      assert retried_stage.completed_at == nil

      retried_validation = Repo.get!(Validation, validation.id)
      assert retried_validation.status == "pending"
      assert retried_validation.evidence == %{}
      assert retried_validation.evaluated_by == nil
      assert retried_validation.evaluated_at == nil

      assert RuntimeSupervision.current_lease_for_task(task.id) == nil

      assert Repo.get!(Platform.Orchestration.ExecutionLease, started_event.lease_id).status ==
               "abandoned"
    end
  end

  describe "list_tasks_by_*/1" do
    test "filters by project", %{project: project} do
      {:ok, other} = Tasks.create_project(%{name: "Other"})
      {:ok, _t1} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _t2} = Tasks.create_task(%{project_id: other.id, title: "B"})

      tasks = Tasks.list_tasks_by_project(project.id)
      assert length(tasks) == 1
      assert hd(tasks).title == "A"
    end

    test "filters by epic", %{project: project} do
      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Epic 1"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, epic_id: epic.id, title: "In epic"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "No epic"})

      tasks = Tasks.list_tasks_by_epic(epic.id)
      assert length(tasks) == 1
      assert hd(tasks).title == "In epic"
    end

    test "filters by status", %{project: project} do
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "A", status: "backlog"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "B", status: "done"})

      assert length(Tasks.list_tasks_by_status("backlog")) >= 1
      assert Enum.all?(Tasks.list_tasks_by_status("done"), &(&1.status == "done"))
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
