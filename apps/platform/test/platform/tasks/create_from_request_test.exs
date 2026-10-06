defmodule Platform.Tasks.CreateFromRequestTest do
  @moduledoc """
  Task 01a111bb stage 1: `Platform.Tasks.create_from_request/2`, the one
  creation path the web New Task sheet and `POST /api/app/tasks` share.

  It exists so a flat assignee always lands in `phase_assignees["planning"]`
  (task 019f42fd bug 1) and survives the first phase transition.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tasks

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "cfr-agent-#{n}", name: "CFR Agent #{n}", status: "active"})
  end

  defp project! do
    {:ok, project} = Tasks.create_project(%{name: "CFR #{System.unique_integer([:positive])}"})
    project
  end

  test "a flat assignee lands in phase_assignees[\"planning\"] and on the flat pointer" do
    project = project!()
    agent = agent!()

    assert {:ok, task} =
             Tasks.create_from_request(%{
               "project_id" => project.id,
               "title" => "Routed",
               "status" => "backlog",
               "assignee_id" => agent.id,
               "assignee_type" => "agent",
               "reported_by" => "Someone"
             })

    task = Tasks.get_task_record(task.id)
    assert task.assignee_id == agent.id
    assert task.assignee_type == "agent"

    assert task.phase_assignees["planning"] == %{
             "assignee_id" => agent.id,
             "assignee_type" => "agent"
           }

    assert task.reported_by == "Someone"
  end

  test "the UI extras TaskAttrs drops are carried across" do
    project = project!()

    assert {:ok, task} =
             Tasks.create_from_request(%{
               "project_id" => project.id,
               "title" => "Extras",
               "status" => "backlog",
               "metadata" => %{"validation_modes" => ["manual"]}
             })

    assert Tasks.get_task_record(task.id).metadata == %{"validation_modes" => ["manual"]}
  end

  test "no assignee leaves phase_assignees empty" do
    assert {:ok, task} =
             Tasks.create_from_request(%{
               "project_id" => project!().id,
               "title" => "Nobody",
               "status" => "backlog"
             })

    assert Tasks.get_task_record(task.id).phase_assignees in [nil, %{}]
  end

  test "a missing title is a changeset error and writes no task" do
    project = project!()

    assert {:error, %Ecto.Changeset{}} =
             Tasks.create_from_request(%{"project_id" => project.id, "status" => "backlog"})

    assert Tasks.list_tasks_by_project(project.id) == []
  end
end
