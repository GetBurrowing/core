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
