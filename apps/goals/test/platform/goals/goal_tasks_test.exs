defmodule Platform.Goals.GoalTasksTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{TaskLink, WakeUp}
  setup do: setup_outcome()

  test "do creates a normal task with three coach phase assignments and private link provenance",
       c do
    project = project(c.org)
    wake = fire(c.goal)

    attrs =
      prediction(%{
        undo_note: "Cancel the work item",
        task: %{
          "project_id" => project.id,
          "title" => "Coach supplied title",
          "description" => "Coach supplied description"
        }
      })

    assert {:ok, %{task: task, entry: entry}} = Goals.close_wake_up(c.coach, wake.id, "do", attrs)
    assert task.project_id == project.id
    assert task.kind == "chore"
    refute task.auto_approve_plan

    for phase <- ~w(planning execution review) do
      assert task.phase_assignees[phase]["assignee_id"] == c.coach.id
      assert task.phase_assignees[phase]["assignee_type"] == "agent"
    end

    assert task.metadata["source"] == "goals.wake_up"
    refute inspect({task.title, task.description, task.metadata}) =~ c.goal.id
    assert entry.details["task_id"] == task.id
    assert entry.details["undo_note"] == "Cancel the work item"
    link = Repo.one!(from(l in TaskLink, where: l.task_id == ^task.id))
    assert link.goal_id == c.goal.id
    assert link.wake_up_id == wake.id
    assert link.entry_id == entry.id
    assert link.created_by_agent_id == c.coach.id
    assert {:ok, [listed]} = Goals.list_goal_tasks(c.owner, c.goal.id)
    assert listed.task_id == task.id
    assert listed.open
    assert listed.wake_up_id == wake.id
    assert listed.linked_at == link.inserted_at

    next = fire(c.goal)
    assert Enum.any?(next.briefing["since_last"]["open_tasks"], &(&1["id"] == task.id))
    assert {:ok, _} = Goals.close_wake_up(c.coach, next.id, "wait", %{reason: "Work in progress"})
    Repo.update!(Ecto.Changeset.change(task, status: "done"))
    finished = fire(c.goal)
    assert Enum.any?(finished.briefing["since_last"]["finished_tasks"], &(&1["id"] == task.id))
    assert Repo.get!(TaskLink, link.id).reported_wake_up_id == finished.id

    assert {:ok, _} =
             Goals.close_wake_up(c.coach, finished.id, "wait", %{reason: "Work complete"})

    after_finished = fire(c.goal)

    refute Enum.any?(
             after_finished.briefing["since_last"]["finished_tasks"],
             &(&1["id"] == task.id)
           )
  end

  test "unavailable projects refuse indistinguishably without creating any rows", c do
    foreign = project(org_id!())
    archived = project(c.org, %{archived_at: DateTime.utc_now()})
    deleting = project(c.org, %{deletion_scheduled_at: DateTime.utc_now()})
    wake = fire(c.goal)
    before = row_counts()

    for id <- [foreign.id, archived.id, deleting.id, Ecto.UUID.generate(), "not-a-uuid"] do
      attrs =
        prediction(%{
          task: %{"project_id" => id, "title" => "Unreachable work", "description" => "Work"}
        })

      assert Goals.close_wake_up(c.coach, wake.id, "do", attrs) ==
               {:error, :project_not_available}

      assert row_counts() == before
      assert Repo.get!(WakeUp, wake.id).status == "open"
    end
  end

  test "a coach pinned to another tenant cannot use an otherwise live goal-org project", c do
    other_org = org_id!()
    coach = Repo.update!(Ecto.Changeset.change(c.coach, metadata: %{"org_id" => other_org}))
    assert Platform.Experiments.Tools.home_org(coach) == {:tenant, other_org}
    project = project(c.org)

    task =
      Repo.insert!(%Platform.Tasks.Task{
        project_id: project.id,
        title: "Existing",
        status: "backlog"
      })

    assert Goals.link_task(coach, c.goal.id, task.id) == {:error, :project_not_available}
  end

  test "existing tasks are linked once across goals and soft deletion frees cap space", c do
    project = project(c.org)

    task =
      Repo.insert!(%Platform.Tasks.Task{
        project_id: project.id,
        title: "Existing",
        status: "backlog"
      })

    assert {:ok, link} = Goals.link_task(c.coach, c.goal.id, task.id)
    assert link.task_id == task.id
    another = goal!(c.owner, c.org, %{coach_agent_id: c.coach.id, agent_mode: "do"})
    assert Goals.link_task(c.coach, another.id, task.id) == {:error, :task_already_linked}
    assert Goals.link_task(c.coach, c.goal.id, task.id) == {:error, :task_already_linked}
    Repo.update!(Ecto.Changeset.change(task, deleted_at: DateTime.utc_now()))
    assert {:ok, [listed]} = Goals.list_goal_tasks(c.owner, c.goal.id)
    refute listed.open
  end
end

