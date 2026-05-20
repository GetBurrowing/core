defmodule Platform.Tasks.TasksContextTest do
  @moduledoc "Integration tests for the Tasks context module."
  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Task

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

  describe "epic broadcasts + changeset (task 019d60ca stage 1)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Epic Broadcast Project"})
      :ok = Tasks.subscribe_board()
      %{project: project}
    end

    test "create_epic/1 broadcasts {:epic_created, epic} on the board topic", %{
      project: project
    } do
      {:ok, epic} =
        Tasks.create_epic(%{
          project_id: project.id,
          name: "Newly Broadcast Epic"
        })

      assert_receive {:epic_created, %Platform.Tasks.Epic{} = received}
      assert received.id == epic.id
      assert received.project_id == project.id
      assert received.name == "Newly Broadcast Epic"
    end

    test "create_epic/1 does NOT broadcast when the changeset is invalid", %{project: project} do
      # Missing :name — should hit validate_required, never insert, never broadcast.
      assert {:error, %Ecto.Changeset{}} =
               Tasks.create_epic(%{project_id: project.id})

      refute_receive {:epic_created, _}, 50
    end

    test "update_epic/2 broadcasts {:epic_updated, epic} on the board topic", %{
      project: project
    } do
      {:ok, epic} =
        Tasks.create_epic(%{project_id: project.id, name: "Original"})

      # Drain the create-side broadcast so the assertion below is unambiguous.
      assert_receive {:epic_created, _}

      {:ok, updated} = Tasks.update_epic(epic, %{name: "Renamed"})

      assert_receive {:epic_updated, %Platform.Tasks.Epic{} = received}
      assert received.id == updated.id
      assert received.name == "Renamed"
    end

    test "update_epic/2 does NOT broadcast when the changeset is invalid", %{project: project} do
      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Stable"})
      assert_receive {:epic_created, _}

      assert {:error, %Ecto.Changeset{}} = Tasks.update_epic(epic, %{name: ""})

      refute_receive {:epic_updated, _}, 50
    end

    test "Epic changeset rejects missing name + project_id with friendly errors" do
      cs = Platform.Tasks.Epic.changeset(%Platform.Tasks.Epic{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.project_id
    end

    test "Epic changeset rejects empty-string name", %{project: project} do
      cs =
        Platform.Tasks.Epic.changeset(%Platform.Tasks.Epic{}, %{
          project_id: project.id,
          name: ""
        })

      refute cs.valid?
      # validate_required is what catches an empty string here, since ""
      # collapses to nil per Ecto's default :empty_values handling.
      assert "can't be blank" in errors_on(cs).name
    end

    test "Epic changeset rejects an over-long name", %{project: project} do
      cs =
        Platform.Tasks.Epic.changeset(%Platform.Tasks.Epic{}, %{
          project_id: project.id,
          name: String.duplicate("x", 121)
        })

      refute cs.valid?
      assert errors_on(cs).name |> Enum.any?(&String.contains?(&1, "120"))
    end

    test "Epic changeset accepts optional description + acceptance_criteria", %{
      project: project
    } do
      cs =
        Platform.Tasks.Epic.changeset(%Platform.Tasks.Epic{}, %{
          project_id: project.id,
          name: "With body",
          description: "Long-form description.",
          acceptance_criteria: "Users can sign in with email."
        })

      assert cs.valid?
    end

    test "Epic changeset accepts the bare minimum (project_id + name)", %{project: project} do
      cs =
        Platform.Tasks.Epic.changeset(%Platform.Tasks.Epic{}, %{
          project_id: project.id,
          name: "Minimal"
        })

      assert cs.valid?
    end
  end

  describe "legacy ETS-based list_tasks/0" do
    test "returns a list (may be empty without active runs)" do
      assert is_list(Tasks.list_tasks())
    end
  end

  describe "list_tasks/1 composable filters (task 019e24ac — Obs 2 false positives)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Filter Compose"})
      {:ok, other_project} = Tasks.create_project(%{name: "Other Project"})
      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Compose Epic"})

      # 2 planning + 4 done in `project` — mirrors the parent ticket's repro.
      planning =
        for n <- 1..2 do
          {:ok, t} =
            Tasks.create_task(%{
              project_id: project.id,
              epic_id: epic.id,
              title: "Planning #{n}",
              status: "planning"
            })

          t
        end

      done =
        for n <- 1..4 do
          {:ok, t} =
            Tasks.create_task(%{
              project_id: project.id,
              epic_id: epic.id,
              title: "Done #{n}",
              status: "done"
            })

          t
        end

      # A planning task in a different project — must not leak into a
      # project-scoped query.
      {:ok, other_planning} =
        Tasks.create_task(%{
          project_id: other_project.id,
          title: "Other planning",
          status: "planning"
        })

      %{
        project: project,
        other_project: other_project,
        epic: epic,
        planning: planning,
        done: done,
        other_planning: other_planning
      }
    end

    test "project_id + status compose — zero false positives", %{
      project: project,
      planning: planning
    } do
      result = Tasks.list_tasks(project_id: project.id, status: "planning")

      # Exactly the 2 planning tasks in this project — none of the 4 done.
      assert length(result) == 2
      assert Enum.all?(result, &(&1.status == "planning"))
      assert Enum.all?(result, &(&1.project_id == project.id))
      assert MapSet.new(result, & &1.id) == MapSet.new(planning, & &1.id)
    end

    test "project_id + status does not leak tasks from other projects", %{
      project: project,
      other_planning: other_planning
    } do
      result = Tasks.list_tasks(project_id: project.id, status: "planning")
      refute Enum.any?(result, &(&1.id == other_planning.id))
    end

    test "epic_id + status compose", %{epic: epic, planning: planning} do
      result = Tasks.list_tasks(epic_id: epic.id, status: "planning")
      assert length(result) == 2
      assert MapSet.new(result, & &1.id) == MapSet.new(planning, & &1.id)
    end

    test "project_id alone returns every non-deleted task in the project", %{
      project: project
    } do
      result = Tasks.list_tasks(project_id: project.id)
      assert length(result) == 6
      assert Enum.all?(result, &(&1.project_id == project.id))
    end

    test "status alone returns matching tasks across all projects", %{
      planning: planning,
      other_planning: other_planning
    } do
      result = Tasks.list_tasks(status: "planning")
      ids = MapSet.new(result, & &1.id)
      assert Enum.all?(result, &(&1.status == "planning"))
      assert Enum.all?(planning, &MapSet.member?(ids, &1.id))
      assert MapSet.member?(ids, other_planning.id)
    end

    test "empty opts returns all non-deleted tasks", %{project: project} do
      result = Tasks.list_tasks([])
      # 6 in `project` + 1 in `other_project`.
      assert length(result) >= 7
      assert Enum.all?(result, &is_nil(&1.deleted_at))
      assert Enum.any?(result, &(&1.project_id == project.id))
    end

    test "soft-deleted tasks are excluded even when filters match", %{
      project: project,
      planning: [to_delete | _]
    } do
      {:ok, _} = Tasks.soft_delete_task(to_delete)

      result = Tasks.list_tasks(project_id: project.id, status: "planning")
      assert length(result) == 1
      refute Enum.any?(result, &(&1.id == to_delete.id))
    end
  end

  describe "count_in_progress_for_user/1 (mobile bottom-nav badge — task 019e1322)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Badge Test"})
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      %{project: project, user_a: user_a, user_b: user_b}
    end

    test "returns 0 for nil user_id" do
      assert Tasks.count_in_progress_for_user(nil) == 0
    end

    test "returns 0 when user has no in-progress tasks", %{user_a: user_a} do
      assert Tasks.count_in_progress_for_user(user_a) == 0
    end

    test "counts only in_progress tasks assigned to the user", %{
      project: project,
      user_a: user_a,
      user_b: user_b
    } do
      {:ok, _t1} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mine, in-progress 1",
          status: "in_progress",
          assignee_id: user_a,
          assignee_type: "user"
        })

      {:ok, _t2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mine, in-progress 2",
          status: "in_progress",
          assignee_id: user_a,
          assignee_type: "user"
        })

      # Other user — not counted.
      {:ok, _t3} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Other user's in-progress",
          status: "in_progress",
          assignee_id: user_b,
          assignee_type: "user"
        })

      # Mine, but wrong status — not counted.
      {:ok, _t4} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mine, but backlog",
          status: "backlog",
          assignee_id: user_a,
          assignee_type: "user"
        })

      assert Tasks.count_in_progress_for_user(user_a) == 2
      assert Tasks.count_in_progress_for_user(user_b) == 1
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

  describe "add_dependency/3 + remove_dependency/3 (atomic edge helpers)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Edge Project"})
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      %{project: project, a: a, b: b}
    end

    test "add_dependency/3 appends a new edge with default kind", %{a: a, b: b} do
      assert {:ok, updated} = Tasks.add_dependency(b, a.id)

      assert updated.dependencies == [%{"task_id" => a.id, "kind" => "blocks"}]
    end

    test "add_dependency/3 accepts a task id string", %{a: a, b: b} do
      assert {:ok, updated} = Tasks.add_dependency(b.id, a.id, "blocks")

      assert updated.dependencies == [%{"task_id" => a.id, "kind" => "blocks"}]
    end

    test "add_dependency/3 is idempotent: re-adding the same edge returns :duplicate_edge",
         %{a: a, b: b} do
      assert {:ok, updated} = Tasks.add_dependency(b, a.id)
      assert {:error, :duplicate_edge} = Tasks.add_dependency(updated, a.id)

      # State on disk is the single edge — not duplicated.
      reloaded = Tasks.get_task_record(b.id)
      assert reloaded.dependencies == [%{"task_id" => a.id, "kind" => "blocks"}]
    end

    test "add_dependency/3 rejects a self-edge", %{a: a} do
      assert {:error, :self_edge} = Tasks.add_dependency(a, a.id)
    end

    test "add_dependency/3 returns :task_not_found for unknown task id", %{a: a} do
      bogus = Ecto.UUID.generate()
      assert {:error, :task_not_found} = Tasks.add_dependency(bogus, a.id)
    end

    test "add_dependency/3 preserves existing edges when appending", %{
      project: project,
      a: a,
      b: b
    } do
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, b1} = Tasks.add_dependency(b, a.id)
      {:ok, b2} = Tasks.add_dependency(b1, c.id)

      assert length(b2.dependencies) == 2
      assert %{"task_id" => a.id, "kind" => "blocks"} in b2.dependencies
      assert %{"task_id" => c.id, "kind" => "blocks"} in b2.dependencies
    end

    test "remove_dependency/3 drops the matching edge", %{a: a, b: b} do
      {:ok, b1} = Tasks.add_dependency(b, a.id)
      assert b1.dependencies != []

      assert {:ok, b2} = Tasks.remove_dependency(b1, a.id)
      assert b2.dependencies == []
    end

    test "remove_dependency/3 accepts a task id string", %{a: a, b: b} do
      {:ok, _b1} = Tasks.add_dependency(b, a.id)
      assert {:ok, b2} = Tasks.remove_dependency(b.id, a.id, "blocks")
      assert b2.dependencies == []
    end

    test "remove_dependency/3 returns :not_an_edge when the edge is absent", %{a: a, b: b} do
      assert {:error, :not_an_edge} = Tasks.remove_dependency(b, a.id)
    end

    test "remove_dependency/3 returns :not_an_edge when the kind doesn't match", %{a: a, b: b} do
      {:ok, b1} = Tasks.add_dependency(b, a.id, "blocks")
      # Currently the only valid kind is "blocks"; assert that a non-matching
      # kind on remove is treated as absent edge rather than removing the
      # "blocks" edge that exists. We pick a string the changeset would
      # reject on insert but that we never use to mutate state — pure read.
      assert {:error, :not_an_edge} = Tasks.remove_dependency(b1, a.id, "wat")

      # Original "blocks" edge is untouched.
      reloaded = Tasks.get_task_record(b.id)
      assert reloaded.dependencies == [%{"task_id" => a.id, "kind" => "blocks"}]
    end

    test "remove_dependency/3 returns :task_not_found for unknown task id", %{a: a} do
      bogus = Ecto.UUID.generate()
      assert {:error, :task_not_found} = Tasks.remove_dependency(bogus, a.id)
    end

    test "remove_dependency/3 preserves siblings", %{project: project, a: a, b: b} do
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, b1} = Tasks.add_dependency(b, a.id)
      {:ok, b2} = Tasks.add_dependency(b1, c.id)

      assert {:ok, b3} = Tasks.remove_dependency(b2, a.id)
      assert b3.dependencies == [%{"task_id" => c.id, "kind" => "blocks"}]
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

  describe "needs_human_action?/1 and /2 (task 019e2c25 — badge predicate)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Badge Project"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Badge Task"})
      %{project: project, task: task}
    end

    test "returns true when task status is in_review", %{task: task} do
      {:ok, in_review} = Tasks.transition_task_status(task, "planning")
      {:ok, in_review} = Tasks.transition_task_status(in_review, "in_progress")
      {:ok, in_review} = Tasks.transition_task_status(in_review, "in_review")

      reloaded =
        in_review.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      assert Tasks.needs_human_action?(reloaded)
    end

    test "returns true when there is at least one pending review_request", %{task: task} do
      # Land the task in `in_progress` and stand up a manual_approval gate
      # with a pending review request. We toggle the task back to a non-
      # in_review status post-creation to isolate the "pending request"
      # branch from the "status == in_review" branch.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review Stage"})

      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          items: [%{label: "Desktop view"}]
        })

      # `create_review_request/1` transitions the task to `in_review`. Pull
      # it back to `in_progress` so the `status == "in_review"` branch
      # cannot mask the pending-request branch we want to assert on.
      task
      |> Ecto.Changeset.change(%{status: "in_progress"})
      |> Platform.Repo.update!()

      reloaded =
        task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      assert reloaded.status == "in_progress"
      assert Tasks.needs_human_action?(reloaded)
    end

    test "returns true when latest plan is in pending_review", %{task: task} do
      # Move task into `planning` and submit a plan for review without
      # approving it. Mirrors the "Plan Ready" UX case.
      {:ok, planning_task} = Tasks.transition_task_status(task, "planning")
      {:ok, plan} = Tasks.create_plan(%{task_id: planning_task.id})
      {:ok, _plan} = Tasks.submit_plan_for_review(plan)

      reloaded =
        planning_task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      assert Enum.any?(reloaded.plans, &(&1.status == "pending_review"))
      assert Tasks.needs_human_action?(reloaded)
    end

    test "returns false for backlog/planning/in_progress/deploying/done with no plans or requests",
         %{task: task} do
      reloaded =
        task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      # backlog (default)
      refute Tasks.needs_human_action?(reloaded)

      # Walk through statuses that should NOT trigger the badge.
      for target <- ~w(planning in_progress deploying done) do
        moved =
          if reloaded.status == target do
            reloaded
          else
            stepped = step_through_to(reloaded, target)
            stepped.id |> Tasks.get_task_record() |> Platform.Repo.preload(:plans)
          end

        refute Tasks.needs_human_action?(moved),
               "expected needs_human_action?/1 to be false for status=#{target}"
      end
    end

    test "needs_human_action_reason/2 ranks :review_request_pending above :plan_pending_review (stage 5)",
         %{task: task} do
      # Stage-5 re-rank (019e2c25): when BOTH a pending plan_review AND an
      # open review_request apply to a task, the predicate must surface
      # `:review_request_pending` because the contract says "ALSO show
      # Needs review" — i.e. the live review request is the more
      # actionable signal. Prior to this change the cond ranked
      # plan_pending_review first, so the M2 demo task could not change
      # badge while the plan was still pending_review.
      {:ok, planning_task} = Tasks.transition_task_status(task, "planning")
      {:ok, plan} = Tasks.create_plan(%{task_id: planning_task.id})
      {:ok, _plan} = Tasks.submit_plan_for_review(plan)

      reloaded =
        planning_task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      # Sanity: with no pending review_requests, plan_pending_review still wins.
      assert Tasks.needs_human_action_reason(reloaded, 0) == :plan_pending_review

      # With a pending review_request count, review_request_pending takes precedence.
      assert Tasks.needs_human_action_reason(reloaded, 1) == :review_request_pending
      assert Tasks.needs_human_action_reason(reloaded, 5) == :review_request_pending
    end

    test "needs_human_action_reason/2 still returns :plan_pending_review when only plan signal applies",
         %{task: task} do
      # Stage-5 guardrail: re-ranking must not regress the single-signal
      # plan-pending-review case. With zero pending review_requests, the
      # predicate continues to surface :plan_pending_review.
      {:ok, planning_task} = Tasks.transition_task_status(task, "planning")
      {:ok, plan} = Tasks.create_plan(%{task_id: planning_task.id})
      {:ok, _plan} = Tasks.submit_plan_for_review(plan)

      reloaded =
        planning_task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      assert Tasks.needs_human_action_reason(reloaded, 0) == :plan_pending_review
    end

    test "/2 with explicit count uses the count and skips the per-task DB query", %{task: task} do
      reloaded =
        task.id
        |> Tasks.get_task_record()
        |> Platform.Repo.preload(:plans)

      # No DB pending requests exist for this task — but passing a
      # positive count must still flip the predicate to true. This proves
      # the count branch is wired up and the DB is not consulted.
      assert Tasks.needs_human_action?(reloaded, 1)
      assert Tasks.needs_human_action?(reloaded, 5)

      # Explicit zero with no other signals stays false.
      refute Tasks.needs_human_action?(reloaded, 0)

      # `nil` falls through to the 1-arity DB lookup, which finds no
      # pending requests and (with no in_review status / pending plan)
      # returns false.
      refute Tasks.needs_human_action?(reloaded, nil)
    end
  end

  describe "list_by_status/1 — 7-column kanban data shape (Tasks v2 stage 1)" do
    # Stage 1 of task 019e389c-1f65 (revised 2026-05-19): a dedicated Planning
    # bucket is added between Backlog and In Progress, and a dedicated Blocked
    # bucket is added between In Progress and In Review. Cancelled tasks fold
    # into the Done bucket; stack_pending is excluded. These tests pin the
    # returned shape so Stage 2 (template wiring) and downstream consumers
    # can rely on it.

    setup do
      {:ok, project} = Tasks.create_project(%{name: "Kanban Project"})
      %{project: project}
    end

    test "returns exactly the 7 kanban-status keys, in canonical order", %{project: project} do
      # Empty DB for this project — the shape must still expose all 7 keys.
      _other_task = Tasks.create_task(%{project_id: project.id, title: "Untouched"})

      buckets = Tasks.list_by_status()

      assert Map.keys(buckets) |> Enum.sort() ==
               Enum.sort([
                 :backlog,
                 :planning,
                 :in_progress,
                 :blocked,
                 :in_review,
                 :deploying,
                 :done
               ])

      # kanban_status_keys/0 declares the canonical column order; assert the
      # function itself agrees with the keys returned, so future reorderings
      # update both in lockstep.
      assert Tasks.kanban_status_keys() ==
               [:backlog, :planning, :in_progress, :blocked, :in_review, :deploying, :done]
    end

    test "tasks with status :planning land under the :planning key", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Plan it",
          status: "planning"
        })

      buckets = Tasks.list_by_status(project_id: project.id)

      planning_ids = Enum.map(buckets.planning, & &1.id)
      assert task.id in planning_ids

      # And NOT under any other bucket — Stage 1's whole point is that
      # `:planning` no longer leaks into the Backlog bucket.
      for key <- [:backlog, :in_progress, :blocked, :in_review, :deploying, :done] do
        other_ids = Enum.map(Map.fetch!(buckets, key), & &1.id)
        refute task.id in other_ids, "expected planning task to be absent from #{inspect(key)}"
      end
    end

    test "tasks with each non-planning status land under their respective key", %{
      project: project
    } do
      {:ok, backlog} =
        Tasks.create_task(%{project_id: project.id, title: "B", status: "backlog"})

      {:ok, in_progress} =
        Tasks.create_task(%{project_id: project.id, title: "I", status: "in_progress"})

      {:ok, in_review} =
        Tasks.create_task(%{project_id: project.id, title: "R", status: "in_review"})

      {:ok, deploying} =
        Tasks.create_task(%{project_id: project.id, title: "D", status: "deploying"})

      {:ok, done} =
        Tasks.create_task(%{project_id: project.id, title: "X", status: "done"})

      buckets = Tasks.list_by_status(project_id: project.id)

      assert Enum.map(buckets.backlog, & &1.id) == [backlog.id]
      assert Enum.map(buckets.in_progress, & &1.id) == [in_progress.id]
      assert Enum.map(buckets.in_review, & &1.id) == [in_review.id]
      assert Enum.map(buckets.deploying, & &1.id) == [deploying.id]
      assert Enum.map(buckets.done, & &1.id) == [done.id]
      assert buckets.planning == []
    end

    test "an empty Planning bucket exists as [] so callers can iterate safely", %{
      project: project
    } do
      # Seed only non-planning tasks. The :planning key still has to be
      # present with an empty list so the rendering template can `for`-
      # loop without `Map.get/3` nil-guards.
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "B", status: "backlog"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "I", status: "in_progress"})

      buckets = Tasks.list_by_status(project_id: project.id)

      assert Map.has_key?(buckets, :planning)
      assert buckets.planning == []
    end

    test "within a bucket, tasks are ordered by updated_at descending", %{project: project} do
      {:ok, older} =
        Tasks.create_task(%{project_id: project.id, title: "Older", status: "planning"})

      {:ok, newer} =
        Tasks.create_task(%{project_id: project.id, title: "Newer", status: "planning"})

      # Force a known temporal gap so we are not at the mercy of microsecond
      # precision in the DB clock. Backdating `older.updated_at` is the
      # simplest way to make the ordering deterministic without a `sleep`.
      stale_time = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      from(t in Task, where: t.id == ^older.id)
      |> Repo.update_all(set: [updated_at: stale_time])

      buckets = Tasks.list_by_status(project_id: project.id)

      ids = Enum.map(buckets.planning, & &1.id)
      assert ids == [newer.id, older.id]
    end

    test "blocked tasks land under the :blocked key (own bucket)", %{project: project} do
      # Marlowe's call 2026-05-19: blocked tasks get their own visible bucket
      # so a human or AI agent can take action to unblock. Without this
      # bucket they would be invisible on the board.
      {:ok, blocked} =
        Tasks.create_task(%{project_id: project.id, title: "Blocked", status: "blocked"})

      buckets = Tasks.list_by_status(project_id: project.id)

      blocked_ids = Enum.map(buckets.blocked, & &1.id)
      assert blocked.id in blocked_ids

      # And NOT under any other bucket — blocked is its own column, not a
      # synonym for in_progress or in_review.
      for key <- [:backlog, :planning, :in_progress, :in_review, :deploying, :done] do
        other_ids = Enum.map(Map.fetch!(buckets, key), & &1.id)
        refute blocked.id in other_ids, "expected blocked task to be absent from #{inspect(key)}"
      end
    end

    test "cancelled tasks fold into the :done bucket", %{project: project} do
      # Marlowe's call 2026-05-19: cancelled and done share the same
      # "no further action required" semantic for the board, so they
      # collapse into a single visual column rather than giving cancel
      # its own. There is no :cancelled key in the returned shape.
      {:ok, cancelled} =
        Tasks.create_task(%{project_id: project.id, title: "Cancelled", status: "cancelled"})

      buckets = Tasks.list_by_status(project_id: project.id)

      done_ids = Enum.map(buckets.done, & &1.id)
      assert cancelled.id in done_ids

      # Defensive: there should be no `:cancelled` key at all in the shape.
      refute Map.has_key?(buckets, :cancelled)

      # And the cancelled task must not leak into any other bucket.
      for key <- [:backlog, :planning, :in_progress, :blocked, :in_review, :deploying] do
        other_ids = Enum.map(Map.fetch!(buckets, key), & &1.id)

        refute cancelled.id in other_ids,
               "expected cancelled task to be absent from #{inspect(key)}"
      end
    end

    test "tasks with :stack_pending are excluded from the rendered shape", %{project: project} do
      # `:stack_pending` represents pre-backlog stack queueing rather than
      # active board state, so it gets no rendered column. Marlowe didn't
      # speak to it in the 2026-05-19 revision; keeping the existing
      # exclusion. Blocked and cancelled used to share this exclusion but
      # are now bucketed (covered by the two tests above).
      {:ok, stack_pending} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "StackPending",
          status: "stack_pending"
        })

      buckets = Tasks.list_by_status(project_id: project.id)

      all_ids =
        buckets
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.id)

      refute stack_pending.id in all_ids
    end

    test "soft-deleted tasks are excluded from every bucket", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Going away", status: "planning"})

      # Soft-delete via the supported context API to match production reads.
      {:ok, _} = Tasks.soft_delete_task(task)

      buckets = Tasks.list_by_status(project_id: project.id)
      assert buckets.planning == []
    end

    test ":project_id option scopes results to one project", %{project: project} do
      {:ok, other_project} = Tasks.create_project(%{name: "Other Project"})

      {:ok, mine} =
        Tasks.create_task(%{project_id: project.id, title: "Mine", status: "planning"})

      {:ok, _theirs} =
        Tasks.create_task(%{project_id: other_project.id, title: "Theirs", status: "planning"})

      buckets = Tasks.list_by_status(project_id: project.id)

      assert Enum.map(buckets.planning, & &1.id) == [mine.id]
    end

    test ":epic_id option scopes results to one epic", %{project: project} do
      {:ok, epic} =
        Tasks.create_epic(%{project_id: project.id, name: "Auth"})

      {:ok, _other_epic} =
        Tasks.create_epic(%{project_id: project.id, name: "Billing"})

      {:ok, scoped} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic.id,
          title: "In epic",
          status: "planning"
        })

      {:ok, _unscoped} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Out of epic",
          status: "planning"
        })

      buckets = Tasks.list_by_status(epic_id: epic.id)

      assert Enum.map(buckets.planning, & &1.id) == [scoped.id]
    end
  end

  describe "count_by_scope/0 — sub-org scope counts (Tasks v2 stage 3)" do
    # Stage 3 of task 019e389c-1f65-7018-bb54-e256ba29fd59 (2026-05-19): the
    # desktop scope-filter rail pulls counts from `count_by_scope/0`. The
    # today-state contract is to fold every non-deleted task under :fabrikam and
    # return 0 for the other four sub-orgs, because `tasks` has no `org_id`
    # column yet — once MT/RBAC lands the body of the helper becomes a real
    # GROUP BY org_id but the public API stays unchanged.

    setup do
      {:ok, project} = Tasks.create_project(%{name: "Scope Project"})
      %{project: project}
    end

    test "returns the five sub-org keys with non-negative integer counts", %{project: project} do
      _t1 = Tasks.create_task(%{project_id: project.id, title: "Some task"})

      counts = Tasks.count_by_scope()

      assert Map.keys(counts) |> Enum.sort() ==
               Enum.sort([:fabrikam, :soylent, :wayne_tech, :sxi, :paragon])

      for {_key, value} <- counts do
        assert is_integer(value) and value >= 0
      end
    end

    test "scope_keys/0 matches the canonical PlatformWeb.Components.ScopePill list" do
      # Single source of truth — if the rail's scope list ever drifts from
      # the foundation component's list the rail can't render correctly.
      assert Tasks.scope_keys() == PlatformWeb.Components.ScopePill.scopes()
    end

    test "today-state: all tasks fold under :fabrikam, other sub-orgs are 0", %{project: project} do
      # Seed three tasks across different statuses. Since `tasks.org_id`
      # doesn't exist yet, every one of them must land under :fabrikam.
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "B", status: "backlog"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "I", status: "in_progress"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "D", status: "done"})

      counts = Tasks.count_by_scope()

      assert counts.fabrikam >= 3
      assert counts.soylent == 0
      assert counts.wayne_tech == 0
      assert counts.sxi == 0
      assert counts.paragon == 0
    end

    test "soft-deleted tasks are excluded from the fabrikam count", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "To delete", status: "backlog"})

      before_count = Tasks.count_by_scope().fabrikam

      # Soft-delete via the same deleted_at column the rest of the board reads.
      task
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      after_count = Tasks.count_by_scope().fabrikam

      assert after_count == before_count - 1
    end
  end

  defp step_through_to(task, "planning"), do: step_status(task, "planning")

  defp step_through_to(task, "in_progress") do
    task
    |> step_status("planning")
    |> step_status("in_progress")
  end

  defp step_through_to(task, "deploying") do
    task
    |> step_status("planning")
    |> step_status("in_progress")
    |> step_status("in_review")
    |> step_status("deploying")
  end

  defp step_through_to(task, "done") do
    task
    |> step_through_to("deploying")
    |> step_done()
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
