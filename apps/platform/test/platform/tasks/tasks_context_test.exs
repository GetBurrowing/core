defmodule Platform.Tasks.TasksContextTest do
  @moduledoc "Integration tests for the Tasks context module."
  use Platform.DataCase, async: true

  alias Platform.Tasks

  describe "full hierarchy CRUD" do
    test "project → epic → task → plan → stage → validation" do
      # Project
      assert {:ok, project} =
               Tasks.create_project(%{
                 name: "Integration App",
                 repo_url: "https://github.com/org/app",
                 tech_stack: %{"language" => "elixir"}
               })

      assert project.slug == "integration-app"

      # Epic
      assert {:ok, epic} =
               Tasks.create_epic(%{
                 project_id: project.id,
                 name: "Auth System",
                 acceptance_criteria: "Users can log in"
               })

      # Task
      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 epic_id: epic.id,
                 title: "Implement login",
                 priority: "high"
               })

      assert task.status == "backlog"

      # Plan (auto-versioned)
      assert {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      assert plan.version == 1

      # Stage
      assert {:ok, stage} =
               Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Code"})

      # Validation
      assert {:ok, validation} =
               Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      # Verify hierarchy reads
      assert Tasks.list_epics(project.id) |> length() == 1
      assert Tasks.list_tasks_by_project(project.id) |> length() == 1
      assert Tasks.list_tasks_by_epic(epic.id) |> length() == 1
      assert Tasks.list_plans(task.id) |> length() == 1
      assert Tasks.list_stages(plan.id) |> length() == 1
      assert Tasks.list_validations(stage.id) |> length() == 1

      # Evaluate the validation
      {:ok, _} = Tasks.evaluate_validation(validation.id, "passed", %{"ok" => true})
    end
  end

  describe "task status transition chain" do
    test "backlog → planning → in_progress → in_review → deploying → done" do
      {:ok, project} = Tasks.create_project(%{name: "Status Project"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Full chain"})

      # Per ADR 0029, plan approval transitions planning → in_progress
      # directly. The `ready` intermediate gate has been removed.
      transitions = ~w(planning in_progress in_review deploying done)

      final_task =
        Enum.reduce(transitions, task, fn status, t ->
          {:ok, updated} = Tasks.transition_task_status(t, status)
          assert updated.status == status
          updated
        end)

      assert final_task.status == "done"
    end
  end

  describe "plan approval flow end-to-end" do
    test "create → submit → approve moves task directly to in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Approve Project"})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Approvable", status: "planning"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, Ecto.UUID.generate())

      current = Tasks.current_plan(task.id)
      assert current != nil
      assert current.status == "approved"
      assert current.version == 1

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "in_progress"
    end
  end

  describe "cascade delete" do
    test "deleting a project cascades to tasks" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade"})
      {:ok, _task} = Tasks.create_task(%{project_id: project.id, title: "Will be deleted"})

      Repo.delete!(project)
      assert Tasks.list_tasks_by_project(project.id) == []
    end
  end

  describe "legacy ETS-based list_tasks/0" do
    test "returns a list (may be empty without active runs)" do
      assert is_list(Tasks.list_tasks())
    end
  end

  describe "dependency schema + helpers" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Dep Project"})
      %{project: project}
    end

    test "changeset accepts nil and empty dependencies", %{project: project} do
      # nil is allowed (no error). The schema default of `[]` only applies
      # when the field is omitted entirely, so an explicit nil persists as nil.
      assert {:ok, t1} =
               Tasks.create_task(%{project_id: project.id, title: "T1", dependencies: nil})

      assert t1.dependencies in [nil, []]

      assert {:ok, t2} =
               Tasks.create_task(%{project_id: project.id, title: "T2", dependencies: []})

      assert t2.dependencies == []

      # Field omitted entirely picks up the schema default.
      assert {:ok, t3} = Tasks.create_task(%{project_id: project.id, title: "T3"})
      assert t3.dependencies == []
    end

    test "changeset accepts a well-formed dependency", %{project: project} do
      dep_id = Ecto.UUID.generate()

      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Has dep",
                 dependencies: [%{"task_id" => dep_id, "kind" => "blocks"}]
               })

      assert [%{"task_id" => ^dep_id, "kind" => "blocks"}] = task.dependencies
    end

    test "changeset rejects entries missing task_id", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Bad dep",
                 dependencies: [%{"kind" => "blocks"}]
               })

      assert %{dependencies: [_]} = errors_on(changeset)
    end

    test "changeset rejects non-uuid task_id", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Bad dep",
                 dependencies: [%{"task_id" => "not-a-uuid", "kind" => "blocks"}]
               })

      assert %{dependencies: [_]} = errors_on(changeset)
    end

    test "changeset rejects unknown kind", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Bad dep",
                 dependencies: [%{"task_id" => Ecto.UUID.generate(), "kind" => "lol"}]
               })

      assert %{dependencies: [_]} = errors_on(changeset)
    end

    test "changeset rejects non-list dependencies", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Bad dep",
                 dependencies: "not a list"
               })

      assert %{dependencies: [_]} = errors_on(changeset)
    end

    test "dependency_task_ids/1 returns the declared ids", %{project: project} do
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"}
          ]
        })

      ids = Tasks.dependency_task_ids(d)
      assert length(ids) == 2
      assert a.id in ids
      assert b.id in ids
      assert Enum.all?(ids, &is_binary/1)

      # Same answer when called by id.
      assert MapSet.new(Tasks.dependency_task_ids(d.id)) == MapSet.new(ids)
    end

    test "unmet_dependencies/1 returns only the not-done subset", %{project: project} do
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})
      {:ok, a} = Tasks.transition_task_status(a, "in_review")
      {:ok, a} = Tasks.transition_task_status(a, "deploying")
      {:ok, a} = Tasks.transition_task_status(a, "done")

      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B", status: "in_progress"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C", status: "planning"})

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => c.id, "kind" => "blocks"}
          ]
        })

      unmet = Tasks.unmet_dependencies(d)
      ids = Enum.map(unmet, & &1.id)

      assert length(unmet) == 2
      assert b.id in ids
      assert c.id in ids
      refute a.id in ids
      assert Enum.all?(unmet, &(Map.keys(&1) |> Enum.sort() == [:id, :status, :title]))
    end

    test "unmet_dependencies/1 returns [] when every dep is done", %{project: project} do
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})
      {:ok, a} = Tasks.transition_task_status(a, "in_review")
      {:ok, a} = Tasks.transition_task_status(a, "deploying")
      {:ok, a} = Tasks.transition_task_status(a, "done")

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      assert Tasks.unmet_dependencies(d) == []
    end

    test "unmet_dependencies/1 ignores self-references and unknown ids", %{project: project} do
      bogus_id = Ecto.UUID.generate()
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B", status: "in_progress"})

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => bogus_id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"}
          ]
        })

      # Now mutate D to add a self-reference. Going through the changeset
      # validates the shape (a uuid + known kind), so this is fine.
      {:ok, d} =
        Tasks.update_task(d, %{
          dependencies: [
            %{"task_id" => bogus_id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => d.id, "kind" => "blocks"}
          ]
        })

      unmet = Tasks.unmet_dependencies(d)
      assert [%{id: id, status: "in_progress"}] = unmet
      assert id == b.id
    end
  end

  describe "approve_plan dependency gate" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Gate Project"})
      %{project: project}
    end

    test "deps all done → task lands on in_progress with no unmet metadata", %{
      project: project
    } do
      {:ok, dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "backlog"})

      _dep_done = drive_to_done(dep)

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gated B",
          status: "planning",
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      updated = approve_latest_plan(task)
      assert updated.status == "in_progress"
      refute Map.has_key?(updated.metadata || %{}, "unmet_dependencies")
    end

    test "any dep unmet → task lands on blocked with unmet ids in metadata", %{
      project: project
    } do
      {:ok, dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "in_progress"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gated B",
          status: "planning",
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      updated = approve_latest_plan(task)
      assert updated.status == "blocked"
      assert updated.metadata["unmet_dependencies"] == [dep.id]
    end

    test "mixed deps → only the unmet ids appear in metadata", %{project: project} do
      {:ok, done_dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "backlog"})

      _done_dep = drive_to_done(done_dep)

      {:ok, in_progress_dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep X", status: "in_progress"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gated B",
          status: "planning",
          dependencies: [
            %{"task_id" => done_dep.id, "kind" => "blocks"},
            %{"task_id" => in_progress_dep.id, "kind" => "blocks"}
          ]
        })

      updated = approve_latest_plan(task)
      assert updated.status == "blocked"
      assert updated.metadata["unmet_dependencies"] == [in_progress_dep.id]
      refute done_dep.id in updated.metadata["unmet_dependencies"]
    end

    test "blocked task keeps its planning-phase assignee (no execution leak)", %{
      project: project
    } do
      {:ok, dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "in_progress"})

      planning_agent_id = Ecto.UUID.generate()
      execution_agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gated B",
          status: "planning",
          assignee_id: planning_agent_id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => %{
              "assignee_id" => planning_agent_id,
              "assignee_type" => "agent"
            },
            "execution" => %{
              "assignee_id" => execution_agent_id,
              "assignee_type" => "agent"
            }
          },
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      updated = approve_latest_plan(task)
      assert updated.status == "blocked"
      # Planning and blocked share the "planning" orchestration phase, so the
      # assignee must remain the planning-phase agent — never silently flip to
      # the execution agent that would have taken over had we reached
      # in_progress.
      assert updated.assignee_id == planning_agent_id
      assert updated.assignee_type == "agent"
    end

    test "preserves prior metadata when stamping unmet_dependencies", %{project: project} do
      {:ok, dep} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "in_progress"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gated B",
          status: "planning",
          metadata: %{"keep_me" => "yes"},
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      updated = approve_latest_plan(task)
      assert updated.status == "blocked"
      assert updated.metadata["keep_me"] == "yes"
      assert updated.metadata["unmet_dependencies"] == [dep.id]
    end
  end

  describe "auto-unblock sweep on done" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Sweep Project"})
      %{project: project}
    end

    test "A done → B (single dep) auto-unblocks to in_progress with cleared metadata", %{
      project: project
    } do
      {:ok, dep_a} =
        Tasks.create_task(%{project_id: project.id, title: "Dep A", status: "in_progress"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          status: "planning",
          dependencies: [%{"task_id" => dep_a.id, "kind" => "blocks"}]
        })

      blocked_b = approve_latest_plan(b)
      assert blocked_b.status == "blocked"
      assert blocked_b.metadata["unmet_dependencies"] == [dep_a.id]

      _done_a = drive_to_done(dep_a)

      unblocked_b = Tasks.get_task_record(b.id)
      assert unblocked_b.status == "in_progress"
      refute Map.has_key?(unblocked_b.metadata || %{}, "unmet_dependencies")
    end

    test "A → B → C chain: completing A unblocks B, completing B unblocks C", %{
      project: project
    } do
      {:ok, dep_a} =
        Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          status: "planning",
          dependencies: [%{"task_id" => dep_a.id, "kind" => "blocks"}]
        })

      blocked_b = approve_latest_plan(b)
      assert blocked_b.status == "blocked"

      # Stand C up before B is unblocked, so its dep on B is "unmet" at
      # approve-time and it lands on blocked too.
      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          status: "planning",
          dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
        })

      blocked_c = approve_latest_plan(c)
      assert blocked_c.status == "blocked"
      assert blocked_c.metadata["unmet_dependencies"] == [b.id]

      # Phase 1: complete A → B should unblock; C still blocked (B not done).
      _done_a = drive_to_done(dep_a)

      after_a = Tasks.get_task_record(b.id)
      assert after_a.status == "in_progress"
      refute Map.has_key?(after_a.metadata || %{}, "unmet_dependencies")

      c_after_a = Tasks.get_task_record(c.id)
      assert c_after_a.status == "blocked"
      assert c_after_a.metadata["unmet_dependencies"] == [b.id]

      # Phase 2: drive B to done → C should auto-unblock via the cascade.
      _done_b = drive_to_done(after_a)

      after_b = Tasks.get_task_record(c.id)
      assert after_b.status == "in_progress"
      refute Map.has_key?(after_b.metadata || %{}, "unmet_dependencies")
    end

    test "two-dep B (A and X): partial completion keeps blocked; final completion unblocks", %{
      project: project
    } do
      {:ok, dep_a} =
        Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})

      {:ok, dep_x} =
        Tasks.create_task(%{project_id: project.id, title: "X", status: "in_progress"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          status: "planning",
          dependencies: [
            %{"task_id" => dep_a.id, "kind" => "blocks"},
            %{"task_id" => dep_x.id, "kind" => "blocks"}
          ]
        })

      blocked_b = approve_latest_plan(b)
      assert blocked_b.status == "blocked"

      assert Enum.sort(blocked_b.metadata["unmet_dependencies"]) ==
               Enum.sort([dep_a.id, dep_x.id])

      # Complete only A — B should stay blocked, with X remaining.
      _done_a = drive_to_done(dep_a)

      after_a = Tasks.get_task_record(b.id)
      assert after_a.status == "blocked"
      assert after_a.metadata["unmet_dependencies"] == [dep_x.id]

      # Complete X — B should now unblock.
      _done_x = drive_to_done(dep_x)

      after_x = Tasks.get_task_record(b.id)
      assert after_x.status == "in_progress"
      refute Map.has_key?(after_x.metadata || %{}, "unmet_dependencies")
    end

    test "completing A does not disturb an unrelated blocked task Y (depends on Z)", %{
      project: project
    } do
      {:ok, dep_a} =
        Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})

      {:ok, dep_z} =
        Tasks.create_task(%{project_id: project.id, title: "Z", status: "in_progress"})

      {:ok, y} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Y",
          status: "planning",
          dependencies: [%{"task_id" => dep_z.id, "kind" => "blocks"}]
        })

      blocked_y = approve_latest_plan(y)
      assert blocked_y.status == "blocked"
      assert blocked_y.metadata["unmet_dependencies"] == [dep_z.id]

      _done_a = drive_to_done(dep_a)

      after_a = Tasks.get_task_record(y.id)
      assert after_a.status == "blocked"
      assert after_a.metadata["unmet_dependencies"] == [dep_z.id]
    end

    test "metadata keys other than unmet_dependencies are preserved on unblock", %{
      project: project
    } do
      {:ok, dep_a} =
        Tasks.create_task(%{project_id: project.id, title: "A", status: "in_progress"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          status: "planning",
          metadata: %{"some_other_key" => "value"},
          dependencies: [%{"task_id" => dep_a.id, "kind" => "blocks"}]
        })

      blocked_b = approve_latest_plan(b)
      assert blocked_b.status == "blocked"
      assert blocked_b.metadata["some_other_key"] == "value"
      assert blocked_b.metadata["unmet_dependencies"] == [dep_a.id]

      _done_a = drive_to_done(dep_a)

      unblocked_b = Tasks.get_task_record(b.id)
      assert unblocked_b.status == "in_progress"
      assert unblocked_b.metadata["some_other_key"] == "value"
      refute Map.has_key?(unblocked_b.metadata, "unmet_dependencies")
    end
  end

  defp drive_to_done(task) do
    task
    |> step_status("in_progress")
    |> step_status("in_review")
    |> step_status("deploying")
    # Final hop goes through transition_task/2 so the auto-unblock sweep
    # in maybe_finalize_transition/3 fires (transition_task_status is the
    # raw schema-level write and bypasses the finalize hook).
    |> step_done()
  end

  # No-op if the task is already at the target status; otherwise raw
  # schema-level transition. Lets a single helper drive both backlog-origin
  # and in_progress-origin tasks to done without duplicating chains.
  defp step_status(%{status: status} = task, status), do: task

  defp step_status(task, target) do
    {:ok, t} = Tasks.transition_task_status(task, target)
    t
  end

  defp step_done(%{status: "done"} = task), do: task

  defp step_done(task) do
    {:ok, t} = Tasks.transition_task(task, "done")
    t
  end

  defp approve_latest_plan(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, plan} = Tasks.submit_plan_for_review(plan)
    {:ok, _plan} = Tasks.approve_plan(plan, "system")
    Tasks.get_task_record(task.id)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
