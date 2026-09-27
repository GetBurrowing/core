defmodule Platform.Tasks.TaskCompleteCasTest do
  @moduledoc """
  Task 01a094d4 stage 3 — `task_complete`'s compare-and-set token.

  WHAT IS BEING GUARDED: `task_complete` is a pure status transition, guarded
  by `Tasks.transition_task_status_if_unmodified/3`. (`task_update`'s base
  guards its whole call through `Tasks.apply_task_update/3`, task 01a0a4aa.)

  The refusal must be REFUSAL, not acceptance-with-a-complaint: the stale-base
  test re-reads the row and asserts the status is unchanged AND that no new
  `-> done` row exists in `task_phase_transitions`.
  """

  use Platform.DataCase

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransitions

  setup do
    {:ok, project} = Tasks.create_project(%{name: "CAS Project"})

    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "cas-#{n}", name: "CAS #{n}", status: "active"}).id

    %{project: project, agent: agent}
  end

  # A task parked in `deploying`, which is where a `task_complete` call is
  # legitimately made from.
  defp deploying_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "CAS Task",
        deploy_target: "production"
      })

    {:ok, task} = Tasks.transition_task_status(task, "in_progress")
    {:ok, task} = Tasks.transition_task_status(task, "in_review")
    {:ok, task} = Tasks.transition_task_status(task, "deploying")
    task
  end

  defp done_rows(task_id) do
    task_id
    |> PhaseTransitions.list_for_task()
    |> Enum.filter(&(&1.to_status == "done"))
  end

  describe "a stale base is refused" do
    test "the completion is rejected, the status is unchanged, and no transition row is written",
         %{project: project, agent: agent} do
      task = deploying_task(project)
      stale_base = task.updated_at

      # A concurrent writer moves the row on, so the caller's token is now
      # behind. `Process.sleep/1` is not needed: `update_task/2` stamps a
      # fresh microsecond `updated_at` and we assert it actually advanced.
      {:ok, moved} = Tasks.update_task(task, %{description: "someone else edited this"})
      assert DateTime.compare(moved.updated_at, stale_base) == :gt

      rows_before = done_rows(task.id)
      assert rows_before == []

      assert {:error, err} =
               ToolSurface.execute(
                 "task_complete",
                 %{
                   "task_id" => task.id,
                   "base_updated_at" => DateTime.to_iso8601(stale_base)
                 },
                 %{agent_id: agent}
               )

      assert err.recoverable == true
      assert err.error =~ "stale_base"
      # Both timestamps named, so the caller can see how far behind it was.
      assert err.error =~ DateTime.to_iso8601(moved.updated_at)
      assert err.error =~ DateTime.to_iso8601(stale_base)

      # REFUSED, not accepted-and-ignored.
      reread = Tasks.get_task_record(task.id)
      assert reread.status == "deploying"
      assert done_rows(task.id) == []
    end

    test "the alias `if_unmodified_since` refuses on the same token", %{
      project: project,
      agent: agent
    } do
      task = deploying_task(project)
      stale_base = task.updated_at
      {:ok, _} = Tasks.update_task(task, %{description: "moved"})

      assert {:error, err} =
               ToolSurface.execute(
                 "task_complete",
                 %{
                   "task_id" => task.id,
                   "if_unmodified_since" => DateTime.to_iso8601(stale_base)
                 },
                 %{agent_id: agent}
               )

      assert err.recoverable == true
      assert err.error =~ "stale_base"
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "an unparseable base is rejected naming task_complete, not task_update", %{
      project: project,
      agent: agent
    } do
      task = deploying_task(project)

      assert {:error, err} =
               ToolSurface.execute(
                 "task_complete",
                 %{"task_id" => task.id, "base_updated_at" => "yesterday"},
                 %{agent_id: agent}
               )

      assert err.recoverable == true
      assert err.error =~ "task_complete: `base_updated_at`"
      refute err.error =~ "task_update:"
      assert Tasks.get_task_record(task.id).status == "deploying"
      assert done_rows(task.id) == []
    end
  end

  describe "a current base succeeds" do
    test "the task completes and previous_updated_at is strictly older than updated_at", %{
      project: project,
      agent: agent
    } do
      task = deploying_task(project)

      assert {:ok, result} =
               ToolSurface.execute(
                 "task_complete",
                 %{
                   "task_id" => task.id,
                   "base_updated_at" => DateTime.to_iso8601(task.updated_at)
                 },
                 %{agent_id: agent}
               )

      assert result.status == "done"
      assert result.task_id == task.id
      assert result.previous_updated_at == task.updated_at
      assert DateTime.compare(result.updated_at, result.previous_updated_at) == :gt

      assert Tasks.get_task_record(task.id).status == "done"

      # The guarded path records the SAME attribution the unguarded one does.
      assert [row] = done_rows(task.id)
      assert row.via == "mcp_task_complete"
      assert row.actor_kind == "agent"
      assert row.actor_id == agent
    end
  end

  describe "no base at all still succeeds" do
    test "the pre-existing last-write-wins path is unchanged and still attributed", %{
      project: project,
      agent: agent
    } do
      task = deploying_task(project)

      assert {:ok, result} =
               ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{agent_id: agent})

      assert result.status == "done"
      assert result.previous_updated_at == task.updated_at
      assert DateTime.compare(result.updated_at, result.previous_updated_at) == :gt

      assert [row] = done_rows(task.id)
      assert row.via == "mcp_task_complete"
      assert row.actor_id == agent
    end

    test "a base that is stale is refused even though the same call without one succeeds", %{
      project: project,
      agent: agent
    } do
      # POSITIVE CONTROL for the refusal: the identical call, differing only
      # in whether the token is present, is accepted. So the refusal above is
      # the guard firing, not the fixture being unable to complete anything.
      task = deploying_task(project)
      stale_base = task.updated_at
      {:ok, _} = Tasks.update_task(task, %{description: "moved"})

      assert {:error, _} =
               ToolSurface.execute(
                 "task_complete",
                 %{"task_id" => task.id, "base_updated_at" => DateTime.to_iso8601(stale_base)},
                 %{agent_id: agent}
               )

      assert {:ok, %{status: "done"}} =
               ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{agent_id: agent})
    end
  end

  describe "the context-level guarded transition" do
    test "transition_task_status_if_unmodified/3 refuses a stale base and writes nothing", %{
      project: project
    } do
      task = deploying_task(project)
      stale_base = task.updated_at
      {:ok, _} = Tasks.update_task(task, %{description: "moved"})

      assert {:error, {:stale_base, %{current_updated_at: current, base_updated_at: supplied}}} =
               Tasks.transition_task_status_if_unmodified(task, "done", stale_base)

      assert supplied == stale_base
      assert DateTime.compare(current, stale_base) == :gt
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "an invalid transition is refused BEFORE the base is compared", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "CAS Backlog", deploy_target: nil})

      assert {:error, :invalid_transition} =
               Tasks.transition_task_status_if_unmodified(task, "done", task.updated_at)

      assert Tasks.get_task_record(task.id).status == task.status
    end
  end
end
