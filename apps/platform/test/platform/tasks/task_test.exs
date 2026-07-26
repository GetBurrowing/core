defmodule Platform.Tasks.TaskTest do
  use Platform.DataCase, async: true

  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Task, Validation}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Test Project"})
    %{project: project}
  end

  describe "create_task/1" do
    test "creates a task with valid attrs", %{project: project} do
      assert {:ok, %Task{} = task} =
               Tasks.create_task(%{project_id: project.id, title: "Build feature"})

      assert task.title == "Build feature"
      assert task.status == "backlog"
      assert task.priority == "medium"
    end

    test "fails without title", %{project: project} do
      assert {:error, changeset} = Tasks.create_task(%{project_id: project.id})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails with invalid status", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{project_id: project.id, title: "X", status: "invalid"})

      assert %{status: [_]} = errors_on(changeset)
    end

    test "fails with invalid priority", %{project: project} do
      assert {:error, changeset} =
               Tasks.create_task(%{project_id: project.id, title: "X", priority: "urgent"})

      assert %{priority: [_]} = errors_on(changeset)
    end
  end

  describe "transition_task_status/2" do
    test "allows valid transitions", %{project: project} do
      # `deploy_target` set so the `:deploying` transition guard added in
      # stage 2 of task 019f42db passes.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "T",
          status: "backlog",
          deploy_target: "production"
        })

      assert {:ok, task} = Tasks.transition_task_status(task, "planning")
      assert task.status == "planning"

      # Per ADR 0029, plan approval transitions planning → in_progress
      # directly. The `ready` intermediate gate has been removed.
      assert {:ok, task} = Tasks.transition_task_status(task, "in_progress")
      assert task.status == "in_progress"

      assert {:ok, task} = Tasks.transition_task_status(task, "in_review")
      assert task.status == "in_review"

      assert {:ok, task} = Tasks.transition_task_status(task, "deploying")
      assert task.status == "deploying"

      assert {:ok, task} = Tasks.transition_task_status(task, "done")
      assert task.status == "done"
    end

    # Task 019e2be4 stage 1: `in_review → done` is now permitted at the
    # automated pipeline layer to support the stack rollup-PR fan-out (a
    # member that rides the stack PR has no per-task deploy stage and must
    # jump straight to done when the rollup PR merges). Solo tasks still
    # take in_review → deploying → done because the plan engine injects a
    # per-task deploy stage for them; nothing in the engine emits the
    # short-circuit transition for solo tasks.
    test "in_review can transition directly to done (stack rollup fan-out)", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "in_review"})
      assert {:ok, updated} = Tasks.transition_task_status(task, "done")
      assert updated.status == "done"
    end

    test "deploying can go to in_progress or blocked", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "deploying"})
      assert {:ok, _} = Tasks.transition_task_status(task, "in_progress")

      {:ok, task2} =
        Tasks.create_task(%{project_id: project.id, title: "T2", status: "deploying"})

      assert {:ok, _} = Tasks.transition_task_status(task2, "blocked")
    end

    test "rejects invalid transitions", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "backlog"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "done")
    end

    test "done has no outbound transitions", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "done"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "backlog")
    end

    test "blocked can go to multiple states", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "blocked"})
      assert {:ok, _} = Tasks.transition_task_status(task, "backlog")
    end
  end

  describe "cancelled terminal status (task 019e24ac stage 3)" do
    test "create_task/1 accepts cancelled as a valid initial status", %{project: project} do
      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Born cancelled",
                 status: "cancelled"
               })

      assert task.status == "cancelled"
    end

    test "Task.deletable?/1 says cancelled is soft-deletable", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "T", status: "cancelled"})

      assert Task.deletable?(task)
      assert "cancelled" in Task.deletable_statuses()
    end

    for source <- ~w(backlog planning in_progress blocked stack_pending) do
      test "transition #{source} -> cancelled is allowed", %{project: project} do
        {:ok, task} =
          Tasks.create_task(%{project_id: project.id, title: "T", status: unquote(source)})

        assert {:ok, updated} = Tasks.transition_task_status(task, "cancelled")
        assert updated.status == "cancelled"
      end
    end

    test "transition in_review -> cancelled is rejected (not in allowed sources)", %{
      project: project
    } do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "in_review"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "cancelled")
    end

    test "transition deploying -> cancelled is rejected (would orphan a deploy in flight)", %{
      project: project
    } do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "deploying"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "cancelled")
    end

    test "transition done -> cancelled is rejected (done is its own terminal)", %{
      project: project
    } do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "done"})
      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "cancelled")
    end

    test "cancelled is terminal — no outbound transitions allowed", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "cancelled"})

      for target <-
            ~w(backlog planning in_progress in_review deploying done blocked stack_pending) do
        # Stage-2 (019f42db) deploy-target guard fires ahead of the invalid-
        # transition check on `deploying` targets — accept either refusal so
        # the terminal property still holds regardless of the ordering.
        expected_error =
          if target == "deploying", do: :no_deploy_target_resolved, else: :invalid_transition

        assert {:error, ^expected_error} = Tasks.transition_task_status(task, target),
               "expected cancelled -> #{target} to be rejected, but it succeeded"
      end
    end
  end

  describe "transition_task/2" do
    test "reopens a failed manual approval gate and abandons stale execution lease before moving back to in_review",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Retry review", status: "in_progress"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Manual review",
          status: "running"
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval", status: "pending"})

      {:ok, started_event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.started"
        })

      {:ok, _blocked_event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.blocked",
          "payload" => %{"description" => "waiting on review retry"}
        })

      {:ok, _} =
        PlanEngine.evaluate_validation(validation.id, %{status: "failed", evaluated_by: "test"})

      assert Repo.get!(Stage, stage.id).status == "failed"
      assert Repo.get!(Validation, validation.id).status == "failed"
      assert RuntimeSupervision.current_lease_for_task(task.id).status == "blocked"

      assert {:ok, updated_task} = Tasks.transition_task(task, "in_review")
      assert updated_task.status == "in_review"

      retried_stage = Repo.get!(Stage, stage.id)
      assert retried_stage.status == "running"
      assert retried_stage.completed_at == nil

      retried_validation = Repo.get!(Validation, validation.id)
      assert retried_validation.status == "pending"
      assert retried_validation.evidence == %{}
      assert retried_validation.evaluated_by == nil
      assert retried_validation.evaluated_at == nil

      assert RuntimeSupervision.current_lease_for_task(task.id) == nil

      assert Repo.get!(Platform.Orchestration.ExecutionLease, started_event.lease_id).status ==
               "abandoned"
    end
  end

  describe "deploy_strategy" do
    test "creates a task with deploy_strategy", %{project: project} do
      strategy = %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}

      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "With strategy",
                 deploy_strategy: strategy
               })

      assert task.deploy_strategy == strategy
    end

    test "deploy_strategy defaults to nil", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No strategy"})
      assert task.deploy_strategy == nil
    end
  end

  describe "resolve_deploy_strategy/1" do
    test "returns task-level strategy when set", %{project: project} do
      strategy = %{"type" => "docker_deploy", "config" => %{}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task override",
          deploy_strategy: strategy
        })

      task = Platform.Repo.preload(task, :project)
      assert Tasks.resolve_deploy_strategy(task) == strategy
    end

    test "falls back to project default_strategy", %{project: project} do
      project_strategy = %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_strategy" => project_strategy}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Inherit"})
      task = Platform.Repo.preload(task, :project)
      assert Tasks.resolve_deploy_strategy(task) == project_strategy
    end

    test "falls back to manual when no strategy anywhere", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Fallback"})
      task = Platform.Repo.preload(task, :project)
      assert Tasks.resolve_deploy_strategy(task) == %{"type" => "manual"}
    end

    test "task strategy takes precedence over project default", %{project: project} do
      project_strategy = %{"type" => "pr_merge", "config" => %{}}
      task_strategy = %{"type" => "none"}

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_strategy" => project_strategy}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Override",
          deploy_strategy: task_strategy
        })

      task = Platform.Repo.preload(task, :project)
      assert Tasks.resolve_deploy_strategy(task) == task_strategy
    end

    test "auto-preloads project when not preloaded", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Auto preload"})
      # Don't preload project — resolve_deploy_strategy should handle it
      assert Tasks.resolve_deploy_strategy(task) == %{"type" => "manual"}
    end
  end

  # Bug #5 (task 019f708f): stack members with a live rollup_branch must
  # NOT inherit the project's per-member `pr_merge` default — the stack
  # ships as ONE rollup PR via `StackDeployer.maybe_open_stack_pr/1`,
  # so a per-member PR shatters the rollup discipline. Resolver returns
  # `no_op_wait_for_rollup` in that case; explicit task overrides still
  # win.
  describe "resolve_deploy_strategy/1 — bug #5 stack member gate" do
    alias Platform.Tasks.Stacks

    defp stack_with_rollup!(project, opts \\ []) do
      slug = Keyword.get(opts, :slug, "b5-#{System.unique_integer([:positive])}")

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "B5 " <> slug,
          base_branch: "main",
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      stack
    end

    defp attach_to_stack!(task, stack) do
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})
      task
    end

    test "standalone task with project pr_merge default → pr_merge",
         %{project: project} do
      pr_merge = %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}

      {:ok, project} =
        Tasks.update_project(project, %{deploy_config: %{"default_strategy" => pr_merge}})

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Standalone"})
      task = Platform.Repo.preload(task, :project)

      assert Tasks.resolve_deploy_strategy(task) == pr_merge
    end

    test "stack member with rollup_branch → no_op_wait_for_rollup (overrides project default)",
         %{project: project} do
      pr_merge = %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}

      {:ok, project} =
        Tasks.update_project(project, %{deploy_config: %{"default_strategy" => pr_merge}})

      stack = stack_with_rollup!(project)
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stack member"})
      task = attach_to_stack!(task, stack)
      task = Platform.Repo.preload(task, :project)

      assert Tasks.resolve_deploy_strategy(task) == %{"type" => "no_op_wait_for_rollup"}
    end

    test "stack member with blank rollup_branch falls through to project default",
         %{project: project} do
      pr_merge = %{"type" => "pr_merge", "config" => %{}}

      {:ok, project} =
        Tasks.update_project(project, %{deploy_config: %{"default_strategy" => pr_merge}})

      # Defensive scenario: a stack row whose `rollup_branch` is a
      # blank string (schema-level NOT NULL prevents outright NULL,
      # but "" is legal at the column and defensively equivalent to
      # "no rollup"). The resolver must degrade gracefully to the
      # project default.
      stack = stack_with_rollup!(project)

      Platform.Repo.query!(
        "UPDATE task_stacks SET rollup_branch = '' WHERE id = $1",
        [Ecto.UUID.dump!(stack.id)]
      )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Bare stack member"})
      task = attach_to_stack!(task, stack)
      task = Platform.Repo.preload(task, :project)

      assert Tasks.resolve_deploy_strategy(task) == pr_merge
    end

    test "explicit task.deploy_strategy wins over the stack-member override",
         %{project: project} do
      pr_merge = %{"type" => "pr_merge", "config" => %{}}

      {:ok, project} =
        Tasks.update_project(project, %{deploy_config: %{"default_strategy" => pr_merge}})

      stack = stack_with_rollup!(project)

      override = %{"type" => "skill_driven", "skill_id" => "custom-deploy"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member with explicit override",
          deploy_strategy: override
        })

      task = attach_to_stack!(task, stack)
      task = Platform.Repo.preload(task, :project)

      # Explicit override wins even when the task IS a stack member with
      # a live rollup — operators can always force a per-member deploy.
      assert Tasks.resolve_deploy_strategy(task) == override
    end
  end

  describe "resolve_deploy_target/1" do
    test "returns explicit task target when set", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task override",
          deploy_target: "production"
        })

      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:explicit, "production"}
    end

    test "falls back to project default_deploy_target", %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Inherit"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:inherited, "staging"}
    end

    test "task target takes precedence over project default", %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Override",
          deploy_target: "production"
        })

      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:explicit, "production"}
    end

    test "infers inheritance from sole-entry deploy_targets list with no explicit default",
         %{project: project} do
      # v2 semantics: `deploy_targets: ["production"]` (list of one) with no
      # `default_deploy_target` set is unambiguous — the resolver infers
      # inheritance rather than falling to `:none`. This is the shape real
      # projects use.
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production"]}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Sole-entry infer"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:inherited, "production"}
    end

    test "sole-entry deploy_targets list also infers inheritance for arbitrary entry name",
         %{project: project} do
      # Locks the contract on the entry value: whatever the sole entry is,
      # it gets returned verbatim as the inherited value.
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["exp"]}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Sole-entry exp"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:inherited, "exp"}
    end

    test "multi-entry deploy_targets list without default_deploy_target returns :none",
         %{project: project} do
      # Ambiguous input — the user must pick explicitly (either via
      # task.deploy_target or by setting default_deploy_target on the
      # project). Implicit inference here would silently ship to the
      # wrong target.
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["exp", "production"]}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Multi ambiguous"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == :none
    end

    test "default_deploy_target wins over first-of-list when both are set",
         %{project: project} do
      # Preserves the explicit-default ordering: the resolver's second
      # branch (default_deploy_target) fires before the sole-entry
      # inference. Even a multi-entry list resolves via default.
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{
            "deploy_targets" => ["exp", "production"],
            "default_deploy_target" => "exp"
          }
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Default wins"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:inherited, "exp"}
    end

    test "returns :none when project deploy_config is empty map default", %{project: project} do
      # `deploy_config` defaults to `%{}` on the schema
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Empty config"})
      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == :none
    end

    test "empty-string task deploy_target treated as unset, falls through to inherited",
         %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Empty string",
          deploy_target: ""
        })

      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == {:inherited, "staging"}
    end

    test "empty-string task deploy_target with no project default returns :none",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Empty string, no default",
          deploy_target: ""
        })

      task = Repo.preload(task, :project)
      assert Tasks.resolve_deploy_target(task) == :none
    end

    test "auto-preloads project when not preloaded", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Auto preload"})
      # Don't preload project — resolve_deploy_target should handle it
      assert Tasks.resolve_deploy_target(task) == :none
    end
  end

  describe "has_deploy_target?/1" do
    test "true for explicit task target", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Explicit",
          deploy_target: "production"
        })

      task = Repo.preload(task, :project)
      assert Tasks.has_deploy_target?(task) == true
    end

    test "true for inherited project default", %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Inherited"})
      task = Repo.preload(task, :project)
      assert Tasks.has_deploy_target?(task) == true
    end

    test "false when neither task nor project has a target", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "None"})
      task = Repo.preload(task, :project)
      assert Tasks.has_deploy_target?(task) == false
    end
  end

  describe "list_tasks_by_*/1" do
    test "filters by project", %{project: project} do
      {:ok, other} = Tasks.create_project(%{name: "Other"})
      {:ok, _t1} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _t2} = Tasks.create_task(%{project_id: other.id, title: "B"})

      tasks = Tasks.list_tasks_by_project(project.id)
      assert length(tasks) == 1
      assert hd(tasks).title == "A"
    end

    test "filters by epic", %{project: project} do
      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Epic 1"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, epic_id: epic.id, title: "In epic"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "No epic"})

      tasks = Tasks.list_tasks_by_epic(epic.id)
      assert length(tasks) == 1
      assert hd(tasks).title == "In epic"
    end

    test "filters by status", %{project: project} do
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "A", status: "backlog"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "B", status: "done"})

      assert length(Tasks.list_tasks_by_status("backlog")) >= 1
      assert Enum.all?(Tasks.list_tasks_by_status("done"), &(&1.status == "done"))
    end
  end

  describe "soft_delete_task/1" do
    test "soft-deletes a backlog task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Deletable", status: "backlog"})

      assert {:ok, deleted} = Tasks.soft_delete_task(task)
      assert deleted.deleted_at != nil
    end

    test "soft-deletes a done task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Done Task", status: "done"})

      assert {:ok, deleted} = Tasks.soft_delete_task(task)
      assert deleted.deleted_at != nil
    end

    test "soft-deletes a planning task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Planning", status: "planning"})

      assert {:ok, _} = Tasks.soft_delete_task(task)
    end

    test "soft-deletes a blocked task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Blocked", status: "blocked"})

      assert {:ok, _} = Tasks.soft_delete_task(task)
    end

    test "refuses to delete an in_progress task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Active", status: "in_progress"})

      assert {:error, :restricted_status} = Tasks.soft_delete_task(task)
    end

    test "refuses to delete an in_review task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Reviewing", status: "in_review"})

      assert {:error, :restricted_status} = Tasks.soft_delete_task(task)
    end

    test "refuses to delete a deploying task", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Deploying", status: "deploying"})

      assert {:error, :restricted_status} = Tasks.soft_delete_task(task)
    end

    test "deleted tasks are excluded from list_all_tasks", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Soon Gone"})
      assert Enum.any?(Tasks.list_all_tasks(), &(&1.id == task.id))

      {:ok, _} = Tasks.soft_delete_task(task)
      refute Enum.any?(Tasks.list_all_tasks(), &(&1.id == task.id))
    end

    test "deleted tasks are excluded from get_task_detail", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Invisible"})
      assert Tasks.get_task_detail(task.id) != nil

      {:ok, _} = Tasks.soft_delete_task(task)
      assert Tasks.get_task_detail(task.id) == nil
    end

    test "deleted tasks are excluded from list_tasks_by_project", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Filter Me"})
      {:ok, _} = Tasks.soft_delete_task(task)
      refute Enum.any?(Tasks.list_tasks_by_project(project.id), &(&1.id == task.id))
    end

    test "deleted tasks are excluded from list_tasks_by_status", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Filter Status"})
      {:ok, _} = Tasks.soft_delete_task(task)
      refute Enum.any?(Tasks.list_tasks_by_status("backlog"), &(&1.id == task.id))
    end

    # Stage 4: soft-delete must tear down any active execution lease
    # synchronously so the task disappears from the dispatch queue
    # immediately, not on the next 5-minute reconcile. (Router teardown
    # is exercised in task_router_watcher_test.exs which is async: false
    # — TaskRouterSupervisor is a singleton, incompatible with this
    # async: true file.)
    test "abandons the active execution lease synchronously", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has Lease",
          status: "backlog"
        })

      runtime_id = "runtime-soft-delete-lease-#{System.unique_integer([:positive])}"

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => runtime_id,
          "event_type" => "execution.started"
        })

      lease_before = RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id)
      assert lease_before != nil
      assert lease_before.status in ["active", "blocked"]

      assert {:ok, _} = Tasks.soft_delete_task(task)

      lease_after = RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id)

      assert lease_after == nil,
             "soft_delete_task/1 must abandon any active execution lease inline " <>
               "(current_lease_for_task_runtime filters out abandoned leases)"
    end
  end

  # Stage 4: cancellation is a terminal status (added in stage 3). The
  # transition path — both `transition_task_status/2` (used by the MCP
  # `task_update` tool) and `transition_task/2` (used by internal
  # callers) — must tear down the running router and any active lease
  # synchronously so a cancelled task leaves the dispatch queue at once
  # instead of waiting on the next 5-minute reconcile.
  #
  # Router teardown lives in task_router_watcher_test.exs (async: false)
  # because TaskRouterSupervisor is a singleton; here we cover the lease
  # half, which is safe under async: true.
  describe "cancellation teardown (stage 4)" do
    test "transition_task_status to 'cancelled' abandons the active execution lease", %{
      project: project
    } do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Will Cancel With Lease",
          status: "in_progress"
        })

      runtime_id = "runtime-cancel-lease-#{System.unique_integer([:positive])}"

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => runtime_id,
          "event_type" => "execution.started"
        })

      lease_before = RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id)
      assert lease_before != nil
      assert lease_before.status in ["active", "blocked"]

      assert {:ok, cancelled} = Tasks.transition_task_status(task, "cancelled")
      assert cancelled.status == "cancelled"

      lease_after = RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id)

      assert lease_after == nil,
             "transition to 'cancelled' must abandon any active execution lease inline " <>
               "(current_lease_for_task_runtime filters out abandoned leases)"
    end

    test "non-cancelled transitions do NOT abandon the active lease", %{project: project} do
      # Sanity check: the teardown is gated on new_status == 'cancelled'.
      # A backlog → planning move must leave the lease intact.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stay Active",
          status: "backlog"
        })

      runtime_id = "runtime-keep-lease-#{System.unique_integer([:positive])}"

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => runtime_id,
          "event_type" => "execution.started"
        })

      assert RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id) != nil

      assert {:ok, _} = Tasks.transition_task_status(task, "planning")

      lease_after = RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id)
      assert lease_after != nil
      assert lease_after.status in ["active", "blocked"]
    end
  end

  describe "require_approved_plan_for/2 (gating execution without an approved plan)" do
    setup %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan-gated task"})
      %{task: task}
    end

    test "rejects transition_task into in_progress when no plan exists", %{task: task} do
      assert {:error, :no_approved_plan} = Tasks.transition_task(task, "in_progress")
    end

    test "rejects transition_task into in_progress when only a draft plan exists", %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "draft"})
      assert {:error, :no_approved_plan} = Tasks.transition_task(task, "in_progress")
    end

    test "rejects transition_task into in_progress when only a pending_review plan exists",
         %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "pending_review"})
      assert {:error, :no_approved_plan} = Tasks.transition_task(task, "in_progress")
    end

    test "allows transition_task into in_progress once a plan is approved", %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      assert {:ok, updated} = Tasks.transition_task(task, "in_progress")
      assert updated.status == "in_progress"
    end

    test "rejects drag-drop into in_progress when no plan exists", %{task: task} do
      assert {:error, :no_approved_plan} = Tasks.drop_task_to_column(task, "in_progress")
    end

    test "rejects drag-drop into in_review when no plan exists", %{task: task} do
      assert {:error, :no_approved_plan} = Tasks.drop_task_to_column(task, "in_review")
    end

    test "rejects drag-drop into done when no plan exists", %{task: task} do
      assert {:error, :no_approved_plan} = Tasks.drop_task_to_column(task, "done")
    end

    test "allows drag-drop into in_progress once a plan is approved", %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      assert {:ok, updated} = Tasks.drop_task_to_column(task, "in_progress")
      assert updated.status == "in_progress"
    end

    test "allows non-execution transitions without a plan (e.g. backlog -> planning)",
         %{task: task} do
      assert {:ok, planning} = Tasks.transition_task(task, "planning")
      assert planning.status == "planning"
    end

    test "allows intra-execution transitions even though plan may be executing/completed",
         %{project: project} do
      # Task already in_progress with an approved plan — moving to in_review
      # should not be re-checked against current_plan (which may now return nil
      # if the plan transitioned to executing or completed).
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already running",
          status: "in_progress"
        })

      assert {:ok, updated} = Tasks.transition_task(task, "in_review")
      assert updated.status == "in_review"
    end
  end

  # Stage 2 of task 019f42db (deploy consolidation): refuse `:deploying`
  # transitions unless the task or its project supplies a deploy target.
  describe "require_deploy_target_for/2 (deploying gate)" do
    setup %{project: project} do
      # Approved plan attached so `require_approved_plan_for/2` does not
      # fire first and mask the deploy-target guard we're testing.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Gate task",
          status: "in_review"
        })

      {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      %{task: task}
    end

    test "returns :ok for non-deploying transitions regardless of target", %{task: task} do
      assert Tasks.require_deploy_target_for(task, "in_progress") == :ok
      assert Tasks.require_deploy_target_for(task, "done") == :ok
      assert Tasks.require_deploy_target_for(task, "blocked") == :ok
    end

    test "returns :ok for deploying when task has explicit deploy_target",
         %{project: project, task: task} do
      {:ok, task} = Tasks.update_task(task, %{deploy_target: "production"})
      task = Platform.Repo.preload(task, :project)
      assert Tasks.require_deploy_target_for(task, "deploying") == :ok
      _ = project
    end

    test "returns :ok for deploying when project has default_deploy_target",
         %{project: project, task: task} do
      {:ok, _project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      task = Platform.Repo.preload(Tasks.get_task_record(task.id), :project, force: true)
      assert Tasks.require_deploy_target_for(task, "deploying") == :ok
    end

    test "returns :error for deploying when neither task nor project has a target",
         %{task: task} do
      task = Platform.Repo.preload(task, :project)

      assert Tasks.require_deploy_target_for(task, "deploying") ==
               {:error, :no_deploy_target_resolved}
    end

    test "transition_task/2 refuses deploying without a resolved target", %{task: task} do
      assert {:error, :no_deploy_target_resolved} = Tasks.transition_task(task, "deploying")

      # Task remains in its original status
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"
    end

    test "transition_task/2 allows deploying with an explicit task target",
         %{task: task} do
      {:ok, task} = Tasks.update_task(task, %{deploy_target: "production"})
      assert {:ok, updated} = Tasks.transition_task(task, "deploying")
      assert updated.status == "deploying"
    end

    test "transition_task/2 allows deploying with an inherited project default",
         %{project: project, task: task} do
      {:ok, _project} =
        Tasks.update_project(project, %{
          deploy_config: %{"default_deploy_target" => "staging"}
        })

      task = Tasks.get_task_record(task.id)
      assert {:ok, updated} = Tasks.transition_task(task, "deploying")
      assert updated.status == "deploying"
    end

    test "transition_task/2 allows deploying via sole-entry deploy_targets inference",
         %{project: project, task: task} do
      # Locks the round-trip through require_deploy_target_for/2 →
      # has_deploy_target?/1 → resolve_deploy_target/1 under the v2
      # sole-entry-list semantics. Task.deploy_target stays nil; project
      # has no explicit default; but the sole-entry list is unambiguous.
      {:ok, _project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production"]}
        })

      task = Tasks.get_task_record(task.id)
      assert {:ok, updated} = Tasks.transition_task(task, "deploying")
      assert updated.status == "deploying"
    end

    test "transition_task/2 allows non-deploying transitions with no target set",
         %{task: task} do
      # `in_review → in_progress` doesn't invoke the deploy guard at all,
      # even without a target resolvable.
      assert {:ok, updated} = Tasks.transition_task(task, "in_progress")
      assert updated.status == "in_progress"
    end

    test "transition_task_status/2 (MCP path) refuses deploying without a resolved target",
         %{task: task} do
      assert {:error, :no_deploy_target_resolved} =
               Tasks.transition_task_status(task, "deploying")
    end

    test "transition_task_status/2 (MCP path) allows deploying once a task target is set",
         %{task: task} do
      {:ok, task} = Tasks.update_task(task, %{deploy_target: "production"})
      assert {:ok, updated} = Tasks.transition_task_status(task, "deploying")
      assert updated.status == "deploying"
    end
  end

  # ADR 0042 — Task Sponsor (human shepherd) field. Nullable belongs_to on
  # `Platform.Accounts.User`, cleared on user delete via `on_delete:
  # :nilify_all`. Distinct from the current-phase `assignee_id` (which is
  # typically an agent).
  describe "sponsor_user_id (ADR 0042 human shepherd)" do
    test "changeset accepts nil sponsor_user_id (nullable)", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "No sponsor",
          sponsor_user_id: nil
        })

      assert changeset.valid?
    end

    test "changeset accepts sponsor_user_id when omitted entirely", %{project: project} do
      changeset = Task.changeset(%Task{}, %{project_id: project.id, title: "Sponsor absent"})

      assert changeset.valid?
      assert get_field(changeset, :sponsor_user_id) == nil
    end

    test "changeset casts a valid UUID into sponsor_user_id", %{project: project} do
      user = insert_sponsor_user()

      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Has sponsor",
          sponsor_user_id: user.id
        })

      assert changeset.valid?
      assert get_change(changeset, :sponsor_user_id) == user.id
    end

    test "create_task/1 persists sponsor_user_id when set", %{project: project} do
      user = insert_sponsor_user()

      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Sponsored",
                 sponsor_user_id: user.id
               })

      assert task.sponsor_user_id == user.id
    end

    test "insert with a bogus sponsor_user_id returns FK violation", %{project: project} do
      # UUID that will never exist — FK constraint fires on Repo.insert.
      fake_user_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Bad sponsor",
                 sponsor_user_id: fake_user_id
               })

      assert %{sponsor_user_id: [_]} = errors_on(changeset)
    end

    test "get_task_record/1 preloads :sponsor", %{project: project} do
      user = insert_sponsor_user()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Preload sponsor",
          sponsor_user_id: user.id
        })

      reloaded = Tasks.get_task_record(task.id)
      assert %Platform.Accounts.User{id: sponsor_id} = reloaded.sponsor
      assert sponsor_id == user.id
    end

    test "get_task_record/1 returns nil for unknown id", _ctx do
      assert Tasks.get_task_record(Ecto.UUID.generate()) == nil
    end

    test "get_task_record/1 preloads :sponsor as nil when unset", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No sponsor set"})

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.sponsor == nil
    end

    test "list_all_tasks/1 preloads :sponsor", %{project: project} do
      user = insert_sponsor_user()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored in list",
          sponsor_user_id: user.id
        })

      found = Tasks.list_all_tasks() |> Enum.find(&(&1.id == task.id))
      assert %Platform.Accounts.User{id: sponsor_id} = found.sponsor
      assert sponsor_id == user.id
    end

    test "deleting the sponsoring user nilifies sponsor_user_id (on_delete: :nilify_all)",
         %{project: project} do
      user = insert_sponsor_user()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor about to leave",
          sponsor_user_id: user.id
        })

      # Bypass any Accounts context guardrails — go straight through the Repo
      # so we're testing the FK's `ON DELETE SET NULL` behaviour.
      Repo.delete!(user)

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.sponsor_user_id == nil
    end
  end

  # Auto-approve plan (task 019f25f2) stage 1: schema foundation only —
  # opt-in boolean on the parent task that later stages will read from the
  # planner's submit_plan_for_review/1 short-circuit. Non-null default false
  # keeps existing rows explicit.
  describe "auto_approve_plan (task 019f25f2 stage 1)" do
    test "changeset accepts auto_approve_plan: true", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Auto approver",
          auto_approve_plan: true
        })

      assert changeset.valid?
      assert get_change(changeset, :auto_approve_plan) == true
    end

    test "changeset accepts auto_approve_plan: false explicitly", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Explicit manual",
          auto_approve_plan: false
        })

      assert changeset.valid?
      # false is the default so cast may or may not surface it as a change
      # depending on whether the empty %Task{} struct's default matches;
      # the important behaviour is the changeset is valid.
    end

    test "create_task/1 defaults auto_approve_plan to false when unset", %{project: project} do
      assert {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Default flag"})
      assert task.auto_approve_plan == false
    end

    test "create_task/1 persists auto_approve_plan: true when set", %{project: project} do
      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Opt in",
                 auto_approve_plan: true
               })

      assert task.auto_approve_plan == true

      # Round-trip through the DB to confirm persistence.
      reloaded = Repo.get!(Task, task.id)
      assert reloaded.auto_approve_plan == true
    end
  end

  # `deploy_target_config` (task 019f5e66 stage 2) — richer per-task
  # deploy config replacing the legacy `deploy_target` string. Migration
  # `20260713010000_add_deploy_target_config_to_tasks.exs` backfills
  # existing rows that carry a legacy `deploy_target` string; the schema
  # gains a changeset validator that pins `"strategy"` to the registered
  # set.
  describe "deploy_target_config (task 019f5e66 stage 2)" do
    test "migration backfill: legacy deploy_target 'production' becomes docker_deploy config",
         %{project: project} do
      # Simulate a row created before the column existed: insert with the
      # legacy string set, then run the backfill's UPDATE by hand. This
      # locks the exact SQL shape used by the migration.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Legacy prod row",
          deploy_target: "production"
        })

      # Ensure the row starts without config (defence-in-depth — the
      # column default is nil, but a prior test in the module could have
      # written one).
      {1, _} =
        Repo.update_all(
          from(t in Task, where: t.id == ^task.id),
          set: [deploy_target_config: nil]
        )

      Repo.query!("""
      UPDATE tasks
         SET deploy_target_config = jsonb_build_object(
           'strategy', 'docker_deploy',
           'target',   deploy_target
         )
       WHERE deploy_target IS NOT NULL
         AND deploy_target_config IS NULL
      """)

      reloaded = Repo.get!(Task, task.id)

      assert reloaded.deploy_target_config == %{
               "strategy" => "docker_deploy",
               "target" => "production"
             }
    end

    test "migration backfill: nil legacy deploy_target leaves config nil",
         %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No legacy target"})
      assert task.deploy_target == nil

      Repo.query!("""
      UPDATE tasks
         SET deploy_target_config = jsonb_build_object(
           'strategy', 'docker_deploy',
           'target',   deploy_target
         )
       WHERE deploy_target IS NOT NULL
         AND deploy_target_config IS NULL
      """)

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.deploy_target_config == nil
    end

    test "changeset rejects an unknown strategy", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Bad strategy",
          deploy_target_config: %{"strategy" => "invalid"}
        })

      refute changeset.valid?
      assert %{deploy_target_config: [msg]} = errors_on(changeset)
      assert msg =~ "strategy must be one of"
    end

    test "changeset rejects a map that has no strategy key", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "No strategy key",
          deploy_target_config: %{"target" => "production"}
        })

      refute changeset.valid?
      assert %{deploy_target_config: [msg]} = errors_on(changeset)
      assert msg =~ "strategy"
    end

    test "changeset accepts project_files strategy with extra config keys", %{project: project} do
      config = %{
        "strategy" => "project_files",
        "project_id" => Ecto.UUID.generate(),
        "folder" => "Deliverables"
      }

      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Project files deploy",
          deploy_target_config: config
        })

      assert changeset.valid?
      assert get_change(changeset, :deploy_target_config) == config
    end

    for strategy <- ~w(pr_merge docker_deploy skill_driven manual project_files) do
      test "changeset accepts strategy '#{strategy}'", %{project: project} do
        changeset =
          Task.changeset(%Task{}, %{
            project_id: project.id,
            title: "Strategy " <> unquote(strategy),
            deploy_target_config: %{"strategy" => unquote(strategy)}
          })

        assert changeset.valid?,
               "expected strategy #{unquote(strategy)} to be accepted, errors: #{inspect(errors_on(changeset))}"
      end
    end

    test "changeset accepts nil (default) explicitly", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Explicit nil",
          deploy_target_config: nil
        })

      assert changeset.valid?
    end

    test "create_task/1 persists a valid deploy_target_config end-to-end",
         %{project: project} do
      config = %{"strategy" => "docker_deploy", "target" => "production"}

      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 title: "Persist config",
                 deploy_target_config: config
               })

      assert task.deploy_target_config == config

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.deploy_target_config == config
    end
  end

  # Bug #3 (task 019f708f): shape-validate metadata["merged_into_rollup_at"]
  # at the changeset boundary so the FunctionClauseError class in
  # `stack_deployer.ex` (every `%{"sha" => sha}` pattern match on the
  # raw stamp) is closed structurally.
  describe "validate_metadata (bug #3) merged_into_rollup_at shape" do
    test "invalid: bare string stamp", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Bare string stamp",
          metadata: %{"merged_into_rollup_at" => "plain string"}
        })

      refute changeset.valid?
      assert %{metadata: [msg]} = errors_on(changeset)
      assert msg =~ "merged_into_rollup_at must be"
      assert msg =~ "must be a map"
    end

    test "invalid: map with sha but bad iso8601 at", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Bad iso",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "not-iso"}
          }
        })

      refute changeset.valid?
      assert %{metadata: [msg]} = errors_on(changeset)
      assert msg =~ "at is not ISO8601"
    end

    test "invalid: map with too-short sha", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Short sha",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc", "at" => "2026-07-17T00:00:00Z"}
          }
        })

      refute changeset.valid?
      assert %{metadata: [msg]} = errors_on(changeset)
      assert msg =~ "sha must be at least 7 hex chars"
    end

    test "invalid: map with non-hex sha", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Non-hex sha",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "zzzzzzzz", "at" => "2026-07-17T00:00:00Z"}
          }
        })

      refute changeset.valid?
      assert %{metadata: [msg]} = errors_on(changeset)
      assert msg =~ "sha must be hex-shaped"
    end

    test "invalid: map missing required keys", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Missing keys",
          metadata: %{"merged_into_rollup_at" => %{"sha" => "abc1234"}}
        })

      refute changeset.valid?
      assert %{metadata: [msg]} = errors_on(changeset)
      assert msg =~ "must include :sha and :at keys"
    end

    test "valid: full map with 7-char sha + iso8601 at", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Well-shaped stamp",
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "abc1234",
              "at" => "2026-07-17T00:00:00Z"
            }
          }
        })

      assert changeset.valid?, "unexpected errors: #{inspect(errors_on(changeset))}"
    end

    test "valid: full-length 40-char sha + iso8601 at with offset", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Full sha",
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "0123456789abcdef0123456789abcdef01234567",
              "at" => "2026-07-17T00:00:00.123456+00:00"
            }
          }
        })

      assert changeset.valid?, "unexpected errors: #{inspect(errors_on(changeset))}"
    end

    test "valid: metadata map without merged_into_rollup_at key", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Metadata absent stamp",
          metadata: %{"other_key" => "value"}
        })

      assert changeset.valid?
    end

    test "valid: empty metadata map", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Empty metadata",
          metadata: %{}
        })

      assert changeset.valid?
    end

    test "valid: metadata omitted from attrs entirely", %{project: project} do
      # No `:metadata` key in attrs — validate_metadata gets a nil change
      # and must be a no-op.
      changeset = Task.changeset(%Task{}, %{project_id: project.id, title: "No metadata attr"})
      assert changeset.valid?
    end
  end

  describe "stack_pending status + stack assoc" do
    test "stack_pending is included in statuses/0" do
      assert "stack_pending" in Task.statuses()
    end

    test "stack_pending is included in deletable_statuses/0" do
      assert "stack_pending" in Task.deletable_statuses()
    end

    test "changeset accepts status: stack_pending", %{project: project} do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Stack pending task",
          status: "stack_pending"
        })

      assert changeset.valid?
      assert get_change(changeset, :status) == "stack_pending"
    end

    test "changeset casts stack_id and stack_position cleanly", %{project: project} do
      stack_uuid = Ecto.UUID.generate()

      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Stacked task",
          stack_id: stack_uuid,
          stack_position: 1
        })

      assert changeset.valid?
      assert get_change(changeset, :stack_id) == stack_uuid
      assert get_change(changeset, :stack_position) == 1
    end
  end

  # ADR-0046 member 4 (task 019f9b28-ab82) stage 1. Schema only — there
  # is no production writer for these fields until stage 2, so every test
  # below is a GUARD, not a detector: none of them can detonate against
  # the unfixed tree, because the field they assert on does not exist
  # there. What each one DOES do is carry a paired positive control, so a
  # future refactor cannot make them pass vacuously.
  describe "planning_step + planning_step_outcomes (ADR-0046 member 4)" do
    test "planning_steps/0, planning_step_keys/0, planning_step_outcomes/0 expose the domains" do
      assert Task.planning_steps() == ~w(designing planning architecting)
      assert Task.planning_step_keys() == ~w(design architecture)
      assert Task.planning_step_outcomes() == ~w(complete not_applicable failed)
    end

    test "no planning sub-phase leaked into statuses/0" do
      # The hard constraint on this task: planning_step is a cursor, not
      # a status. If either value shows up here, the status-transition
      # table has been expanded and this task overstepped.
      refute "designing" in Task.statuses()
      refute "architecting" in Task.statuses()
      assert length(Task.statuses()) == 9
    end

    test "create_task/1 defaults planning_step to \"planning\" and outcomes to %{}", %{
      project: project
    } do
      assert {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Fresh task"})
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes == %{}

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.planning_step == "planning"
      assert reloaded.planning_step_outcomes == %{}
    end

    # GUARD (paired positive control). The first half asserts the narrow
    # changeset does not carry :status. On its own that assertion also
    # passes against a changeset that casts NOTHING, so the second half
    # runs the identical attrs through changeset/2 and asserts :status
    # DOES change there — proving the assertion can tell the two apart.
    test "planning_step_changeset/2 cannot smuggle a :status change; changeset/2 can", %{
      project: project
    } do
      attrs = %{status: "done", planning_step: "architecting"}
      task = %Task{project_id: project.id, title: "Cursor", status: "backlog"}

      narrow = Task.planning_step_changeset(task, attrs)

      assert narrow.valid?
      assert get_change(narrow, :planning_step) == "architecting"
      assert get_change(narrow, :status) == nil
      refute Map.has_key?(narrow.changes, :status)

      # Positive control: the same attrs, the wide changeset.
      wide = Task.changeset(task, attrs)
      assert get_change(wide, :status) == "done"
      # ...and symmetrically, the wide changeset does not touch the
      # planning cursor: the field is absent from its cast list.
      assert get_change(wide, :planning_step) == nil
    end

    test "update_task/3 does not change planning_step", %{project: project} do
      assert {:ok, task} =
               Tasks.create_task(%{project_id: project.id, title: "Unguarded surface"})

      assert {:ok, updated} = Tasks.update_task(task, %{planning_step: "architecting"})
      assert updated.planning_step == "planning"
      assert Repo.get!(Task, task.id).planning_step == "planning"
    end

    test "planning_step outside the domain is invalid" do
      changeset = Task.planning_step_changeset(%Task{}, %{planning_step: "reviewing"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).planning_step

      # Positive control: each legal value in the same position is valid.
      for step <- Task.planning_steps() do
        assert Task.planning_step_changeset(%Task{}, %{planning_step: step}).valid?
      end
    end

    # GUARD (paired positive control). A writer must not be able to
    # introduce a fourth outcome value — every reader added by this stack
    # branches on the three-value table, and an unknown string would have
    # to be guessed about (which is how not_applicable/failed collapse).
    test "an unknown outcome value is rejected, and \"failed\" in the same position is accepted" do
      invalid =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{"architecture" => %{"outcome" => "skipped"}}
        })

      refute invalid.valid?
      assert Enum.any?(errors_on(invalid).planning_step_outcomes, &(&1 =~ "skipped"))

      valid =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{"architecture" => %{"outcome" => "failed"}}
        })

      assert valid.valid?
    end

    test "every member of planning_step_outcomes/0 is accepted in the same position" do
      for outcome <- Task.planning_step_outcomes() do
        changeset =
          Task.planning_step_changeset(%Task{}, %{
            planning_step_outcomes: %{"architecture" => %{"outcome" => outcome}}
          })

        assert changeset.valid?, "outcome #{inspect(outcome)} should be accepted"
      end
    end

    test "an unknown step key is rejected" do
      changeset =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{"security" => %{"outcome" => "failed"}}
        })

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).planning_step_outcomes, &(&1 =~ "security"))

      # Positive control: both legal keys, together, in one map.
      valid =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{
            "design" => %{"outcome" => "not_applicable"},
            "architecture" => %{"outcome" => "complete"}
          }
        })

      assert valid.valid?
    end

    test "an entry without a string \"outcome\" key is rejected" do
      changeset =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{"architecture" => %{"recorded_at" => "2026-07-26T00:00:00Z"}}
        })

      refute changeset.valid?

      not_a_map =
        Task.planning_step_changeset(%Task{}, %{
          planning_step_outcomes: %{"architecture" => "failed"}
        })

      refute not_a_map.valid?
    end

    test "an empty outcomes map is valid (nothing recorded yet)" do
      assert Task.planning_step_changeset(%Task{}, %{planning_step_outcomes: %{}}).valid?
    end

    test "a full outcome entry round-trips through the database", %{project: project} do
      assert {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Round trip"})

      entry = %{
        "outcome" => "failed",
        "recorded_at" => "2026-07-26T00:00:00.000000Z",
        "detail" => "econnrefused"
      }

      assert {:ok, saved} =
               task
               |> Task.planning_step_changeset(%{
                 planning_step: "architecting",
                 planning_step_outcomes: %{"architecture" => entry}
               })
               |> Repo.update()

      assert saved.planning_step == "architecting"

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.planning_step == "architecting"
      assert reloaded.planning_step_outcomes == %{"architecture" => entry}
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Insert a bare user row for sponsor tests. Bypasses the
  # `Platform.Accounts.User.changeset/2` name requirement so tests don't
  # need to plumb an OIDC identity fixture.
  defp insert_sponsor_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "Sponsor #{n}"),
      email: Keyword.get(opts, :email, "sponsor-#{n}@example.com"),
      oidc_sub: "sub-sponsor-#{n}"
    })
  end
end
