defmodule Platform.Tasks.TaskCompleteAttributionTest do
  @moduledoc """
  The three real signatures a `-> done`-class transition can carry, asserted
  to be mutually distinguishable on one project.

  Task 01a094d4 stage 1: this file is written to FAIL on today's code. The
  MCP `task_complete` handler
  (`Platform.Federation.ToolSurface.execute("task_complete", ...)`) matches
  `_context` and discards the calling agent, so `Task.maybe_record/2` reads
  `TransitionActor.current()` and gets the honest `unknown` default. The
  engine close and the agent `task_update` are both attributed; only
  `task_complete` is not. Stage 2 stamps it, at which point these
  assertions go green with no edit.
  """

  use Platform.DataCase

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransitions

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Attribution Project"})
    %{project: project, agent_a: agent_fixture("a"), agent_b: agent_fixture("b")}
  end

  defp agent_fixture(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{slug: "attr-#{tag}-#{n}", name: "Attr #{tag} #{n}", status: "active"}).id
  end

  # A task parked in `deploying` with a resolvable deploy target, which is
  # the state every one of the three signatures is measured from.
  defp deploying_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Attribution Task",
        deploy_target: "production"
      })

    # Setup walk only. These rows carry no `via` and are never asserted on;
    # every assertion below selects by `to_status`.
    {:ok, task} = Tasks.transition_task_status(task, "in_progress")
    {:ok, task} = Tasks.transition_task_status(task, "in_review")
    task
  end

  defp row(task_id, to_status) do
    task_id
    |> PhaseTransitions.list_for_task()
    |> Enum.find(&(&1.to_status == to_status))
  end

  defp signature(row), do: {row.actor_kind, row.actor_id, row.via}

  describe "the three signatures are mutually distinguishable" do
    test "engine close, agent task_update and agent task_complete", %{
      project: project,
      agent_a: agent_a
    } do
      # (a) engine close — `transition_task/2` wraps the write in
      # `TransitionActor.with_actor(:system, "transition_task", ...)`.
      engine_task = deploying_task(project)
      {:ok, _} = Tasks.transition_task(engine_task, "done")
      engine_row = row(engine_task.id, "done")

      assert engine_row.via == "transition_task"
      assert engine_row.actor_kind == "system"
      assert engine_row.actor_label == "system:auto"
      assert is_nil(engine_row.actor_id)

      # (b) agent task_update — attributed today via
      # `maybe_transition_status/3`.
      update_task = deploying_task(project)

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => update_task.id, "status" => "deploying"},
                 %{agent_id: agent_a}
               )

      update_row = row(update_task.id, "deploying")

      assert update_row.via == "mcp_task_update"
      assert update_row.actor_kind == "agent"
      assert update_row.actor_id == agent_a

      # (c) agent task_complete — the defect. The same agent, through the
      # tool whose entire purpose is "I am ruling this delivered", records
      # nothing about who ruled.
      complete_task = deploying_task(project)
      {:ok, complete_task} = Tasks.transition_task_status(complete_task, "deploying")

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_complete",
                 %{"task_id" => complete_task.id},
                 %{agent_id: agent_a}
               )

      complete_row = row(complete_task.id, "done")

      # Not "some actor" — this agent specifically.
      assert complete_row.actor_id == agent_a
      assert complete_row.actor_kind == "agent"
      assert complete_row.via == "mcp_task_complete"

      # And the three are pairwise distinct, so a reader can tell an engine
      # close from an agent update from an agent completion.
      sigs = [signature(engine_row), signature(update_row), signature(complete_row)]
      assert length(Enum.uniq(sigs)) == 3
    end
  end

  describe "the recorded actor is the CALLING agent" do
    # A fix that stamps a constant — the task's assignee, the project owner,
    # or any single hardcoded id — passes the test above and fails here.
    test "a second agent completing a second task records ITS id", %{
      project: project,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      task_a = deploying_task(project)
      {:ok, task_a} = Tasks.transition_task_status(task_a, "deploying")

      assert {:ok, _} =
               ToolSurface.execute("task_complete", %{"task_id" => task_a.id}, %{
                 agent_id: agent_a
               })

      task_b = deploying_task(project)
      {:ok, task_b} = Tasks.transition_task_status(task_b, "deploying")

      assert {:ok, _} =
               ToolSurface.execute("task_complete", %{"task_id" => task_b.id}, %{
                 agent_id: agent_b
               })

      row_a = row(task_a.id, "done")
      row_b = row(task_b.id, "done")

      assert row_a.actor_id == agent_a
      assert row_b.actor_id == agent_b
      refute row_a.actor_id == row_b.actor_id
    end
  end
end
