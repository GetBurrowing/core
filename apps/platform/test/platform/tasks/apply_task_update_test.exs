defmodule Platform.Tasks.ApplyTaskUpdateTest do
  @moduledoc """
  `Tasks.apply_task_update/3` (task 01a0a4aa stage 1): the single
  pre-validated write behind MCP `task_update`.

  The defect it closes: `task_update` ran up to four statements (plain
  fields, phase_assignees, plan gate, status transition). A status the
  transition table refused still left the plain fields committed and
  `updated_at` moved, so the caller's own retry with the same base came back
  as a false `stale_base`. And a base guarded only the plain-field statement,
  so a status-only or phase_assignees-only call with a stale base was applied
  without comparing anything.

  Every refusal here is asserted as a REFUSAL by re-reading the row: no field
  written, `updated_at` unmoved.

  No `Process.sleep` anywhere. Every concurrency case is composed against ONE
  captured `updated_at` and advances the row with an unrelated write.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransitions

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Apply Update Project #{System.unique_integer([:positive])}"})

    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "apply-#{n}", name: "Apply #{n}", status: "active"}).id

    %{project: project, agent: agent}
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Original", description: "original", priority: "low"},
          attrs
        )
      )

    task
  end

  defp blocked_task(project) do
    {:ok, task} = project |> create_task() |> Tasks.transition_task_status("blocked")
    task
  end

  # Advance the row with an unrelated write so a captured base goes stale.
  # Returns the FRESH struct: the stale-base cases hand this current struct to
  # `apply_task_update/3`, so a filter seeded from the struct (instead of the
  # caller's base) would match and let the write through.
  defp advance(task) do
    {:ok, moved} = Tasks.update_task(task, %{description: "moved by someone else"})
    assert DateTime.compare(moved.updated_at, task.updated_at) == :gt
    moved
  end

  defp rows_to(task_id, status) do
    task_id
    |> PhaseTransitions.list_for_task()
    |> Enum.filter(&(&1.to_status == status))
  end

  describe "a refused status transition writes nothing" do
    test "an illegal edge alongside a plain field: invalid_transition, and the row is untouched",
         %{project: project} do
      task = blocked_task(project)
      before = Tasks.get_task_record(task.id)

      assert {:error, :invalid_transition} =
               Tasks.apply_task_update(task, %{title: "MUTATED"}, status: "done")

      reread = Tasks.get_task_record(task.id)
      assert reread.status == "blocked"
      assert reread.title == "Original"
      assert reread.updated_at == before.updated_at
    end

    test "the plan gate refusing a legal edge also leaves the plain field unwritten",
         %{project: project} do
      task = create_task(project)

      assert {:error, :no_approved_plan} =
               Tasks.apply_task_update(task, %{priority: "high"}, status: "in_progress")

      reread = Tasks.get_task_record(task.id)
      assert reread.status == "backlog"
      assert reread.priority == "low"
      assert reread.updated_at == task.updated_at
    end

    test "a refused call leaves the caller's base usable: the retry is not a false stale_base",
         %{project: project} do
      task = blocked_task(project)
      base = task.updated_at

      assert {:error, :invalid_transition} =
               Tasks.apply_task_update(task, %{priority: "high"},
                 status: "done",
                 base_updated_at: base
               )

      assert {:ok, updated} =
               Tasks.apply_task_update(Tasks.get_task_record(task.id), %{title: "Retry"},
                 base_updated_at: base
               )

      assert updated.title == "Retry"
      assert updated.priority == "low"
    end
  end

  describe "a supplied base guards a status-only call" do
    test "a stale base is refused and the status is unchanged", %{project: project} do
      task = blocked_task(project)
      stale_base = task.updated_at
      moved = advance(task)

      assert {:error, {:stale_base, %{current_updated_at: current, base_updated_at: supplied}}} =
               Tasks.apply_task_update(moved, %{},
                 status: "backlog",
                 base_updated_at: stale_base
               )

      assert current == moved.updated_at
      assert supplied == stale_base

      reread = Tasks.get_task_record(task.id)
      assert reread.status == "blocked"
      assert reread.updated_at == moved.updated_at
      assert rows_to(task.id, "backlog") == []
    end

    test "positive control: the same call with no base succeeds", %{project: project} do
      task = blocked_task(project)
      moved = advance(task)

      assert {:ok, updated} = Tasks.apply_task_update(moved, %{}, status: "backlog")
      assert updated.status == "backlog"
      assert Tasks.get_task_record(task.id).status == "backlog"
    end
  end

  describe "a supplied base guards a phase_assignees-only call" do
    test "a stale base is refused and phase_assignees is unchanged",
         %{project: project, agent: agent} do
      task = create_task(project)
      stale_base = task.updated_at
      moved = advance(task)

      assert {:error, {:stale_base, _}} =
               Tasks.apply_task_update(moved, %{},
                 phase_assignees: %{
                   "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
                 },
                 base_updated_at: stale_base
               )

      reread = Tasks.get_task_record(task.id)
      assert reread.phase_assignees == moved.phase_assignees
      assert reread.updated_at == moved.updated_at
    end

    test "positive control: the same call with no base succeeds",
         %{project: project, agent: agent} do
      task = create_task(project)
      moved = advance(task)

      assert {:ok, updated} =
               Tasks.apply_task_update(moved, %{},
                 phase_assignees: %{
                   "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
                 }
               )

      assert updated.phase_assignees["execution"] == %{
               "assignee_id" => agent,
               "assignee_type" => "agent"
             }
    end
  end

  describe "a legal combined call" do
    test "status and a plain field land in one write with one transition row",
         %{project: project, agent: agent} do
      task = create_task(project)

      assert {:ok, updated} =
               Tasks.apply_task_update(task, %{title: "Both"},
                 status: "planning",
                 base_updated_at: task.updated_at,
                 actor: {:agent, agent}
               )

      reread = Tasks.get_task_record(task.id)
      assert reread.title == "Both"
      assert reread.status == "planning"
      assert DateTime.compare(reread.updated_at, task.updated_at) == :gt
      assert reread.updated_at == updated.updated_at

      assert [row] = rows_to(task.id, "planning")
      assert row.from_status == "backlog"
      assert row.via == "mcp_task_update"
      assert row.actor_kind == "agent"
      assert row.actor_id == agent
    end

    test "a deploy_target supplied in the SAME call satisfies the deploying pre-check",
         %{project: project} do
      task = create_task(project)
      {:ok, task} = Tasks.transition_task_status(task, "in_progress")
      {:ok, task} = Tasks.transition_task_status(task, "in_review")

      # Negative control: without the same-call target the gate refuses, and
      # refuses before writing.
      assert {:error, :no_deploy_target_resolved} =
               Tasks.apply_task_update(task, %{}, status: "deploying")

      assert Tasks.get_task_record(task.id).updated_at == task.updated_at

      # The pre-check reads the PROJECTED struct, so the target in this call
      # is visible to it.
      assert {:ok, updated} =
               Tasks.apply_task_update(task, %{deploy_target: "production"}, status: "deploying")

      assert updated.status == "deploying"
      assert updated.deploy_target == "production"
    end

    test "an empty call writes nothing and returns the task", %{project: project} do
      task = create_task(project)

      assert {:ok, same} = Tasks.apply_task_update(task, %{}, [])
      assert same.id == task.id
      assert Tasks.get_task_record(task.id).updated_at == task.updated_at
    end
  end

  describe "internal writers stay base-less" do
    test "transition_task_status/2 succeeds on a row whose updated_at has moved",
         %{project: project} do
      task = create_task(project)
      _moved = advance(task)

      # `task` is the STALE struct; the internal writer has no base to compare.
      assert {:ok, updated} = Tasks.transition_task_status(task, "blocked")
      assert updated.status == "blocked"
      assert Tasks.get_task_record(task.id).status == "blocked"
    end

    test "transition_task/2 succeeds on a row whose updated_at has moved",
         %{project: project} do
      task = create_task(project)
      _moved = advance(task)

      assert {:ok, updated} = Tasks.transition_task(task, "planning")
      assert updated.status == "planning"
      assert Tasks.get_task_record(task.id).status == "planning"
    end
  end
end
