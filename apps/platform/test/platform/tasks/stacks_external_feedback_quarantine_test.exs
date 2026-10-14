defmodule Platform.Tasks.StacksExternalFeedbackQuarantineTest do
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks, Task}

  test "planning, commencement, promotion, and stack transport refuse quarantined members before mutation" do
    {:ok, project} = Tasks.create_project(%{name: "Stack quarantine"})

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: "quarantine-#{System.unique_integer([:positive])}",
        name: "Quarantine stack",
        rollup_branch: "stack/quarantine"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "External stack member",
        origin: "external_feedback",
        trust: "trusted",
        external_repository_identity: "Startup-Suite/feedback",
        external_issue_number: 121
      })

    assert {:ok, member} = Stacks.add_task(stack, task)
    Repo.update_all(from(t in Task, where: t.id == ^member.id), set: [trust: "quarantined"])

    assert {:error, :quarantined, %{task_id: id}} = Stacks.start_planning(stack)
    assert id == member.id
    assert Tasks.get_task_record(member.id).status == "backlog"

    assert {:error, :quarantined, %{task_id: ^id}} = Stacks.start_stack(stack)
    assert Repo.get!(Stack, stack.id).status == "forming"

    assert {:error, envelope} =
             ToolSurface.execute("stack_start_planning", %{"stack_id" => stack.id}, %{})

    assert envelope.quarantine.task_id == member.id
    assert envelope.recoverable == false

    # Coverage (passes against 2e607e870): the stack_start transport and
    # wave advancement refuse too, before any member moves.
    assert {:error, envelope} =
             ToolSurface.execute("stack_start", %{"stack_id" => stack.id}, %{})

    assert envelope.quarantine.task_id == member.id
    assert Repo.get!(Stack, stack.id).status == "forming"

    assert {:error, :quarantined, %{task_id: ^id}} = Stacks.advance_planning_waves(stack)
    assert Tasks.get_task_record(member.id).status == "backlog"

    Repo.update_all(from(t in Task, where: t.id == ^member.id), set: [status: "stack_pending"])
    pending = Tasks.get_task_record(member.id)

    assert {:error, :quarantined, %{task_id: ^id}} = Stacks.try_promote(pending)
    assert Tasks.get_task_record(member.id).status == "stack_pending"
  end

  # Coverage (passes against 2e607e870): attaching quarantined feedback to
  # a COMMENCED stack would park it at stack_pending; the Task.changeset/2
  # guard refuses that write and the whole attach rolls back.
  test "stack_add of quarantined feedback to a commenced stack is refused and rolled back" do
    {:ok, project} = Tasks.create_project(%{name: "Stack add quarantine"})

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: "quarantine-add-#{System.unique_integer([:positive])}",
        name: "Commenced stack",
        rollup_branch: "stack/quarantine-add"
      })

    Repo.update_all(from(s in Stack, where: s.id == ^stack.id), set: [status: "in_progress"])

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "External newcomer",
        origin: "external_feedback",
        trust: "quarantined",
        external_repository_identity: "Startup-Suite/feedback",
        external_issue_number: 131
      })

    assert {:error, %Ecto.Changeset{} = changeset} = Stacks.add_task(stack.id, task.id)

    assert {"cannot enter planning or execution while task trust is quarantined", _} =
             changeset.errors[:status]

    assert {:error, envelope} =
             ToolSurface.execute(
               "stack_add",
               %{"stack_id" => stack.id, "task_id" => task.id},
               %{}
             )

    assert envelope.error =~ "quarantined"

    persisted = Tasks.get_task_record(task.id)
    assert persisted.stack_id == nil
    assert persisted.status == "backlog"
  end
end
