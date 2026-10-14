defmodule Platform.Orchestration.ExternalFeedbackQuarantineTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{TaskRouter, TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  test "watcher, supervisor, and router independently refuse quarantined tasks" do
    {:ok, project} = Tasks.create_project(%{name: "Router quarantine"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Quarantined dispatch",
        origin: "external_feedback",
        trust: "trusted",
        external_repository_identity: "Startup-Suite/feedback",
        external_issue_number: 111,
        assignee_type: "agent",
        assignee_id: Ecto.UUID.generate()
      })

    Repo.update_all(
      from(t in Task, where: t.id == ^task.id),
      set: [trust: "quarantined", status: "planning"]
    )

    quarantined = Tasks.get_task_record(task.id)
    assignee = %{type: :federated, id: quarantined.assignee_id}

    refute TaskRouterWatcher.should_run?(quarantined)
    refute Enum.any?(TaskRouterWatcher.list_should_run_tasks(), &(&1.id == quarantined.id))

    assert {:error, :quarantined, %{task_id: id}} =
             TaskRouterSupervisor.start_assignment(quarantined.id, assignee)

    assert id == quarantined.id

    assert {:stop, {:quarantined, %{task_id: id}}} =
             TaskRouter.init(%{task_id: quarantined.id, assignee: assignee})

    assert id == quarantined.id
    refute TaskRouterWatcher.router_running?(quarantined.id)
  end
end
