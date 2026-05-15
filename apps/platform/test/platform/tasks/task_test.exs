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
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T", status: "backlog"})

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
        assert {:error, :invalid_transition} = Tasks.transition_task_status(task, target),
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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
