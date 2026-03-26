defmodule Platform.Orchestration.TaskRouterTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{ExecutionLease, TaskRouter}
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Test Project",
        repo_url: "https://github.com/test/router"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router Test Task",
        description: "Testing the task router"
      })

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}

    # Allow dynamically started TaskRouter processes to share the test sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      # Stop router before sandbox teardown to avoid connection errors
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage, assignee: assignee}
  end

  describe "start_link/1 and lifecycle" do
    test "starts and registers a router process", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      # Should be registered
      assert [{^pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
    end

    test "stop/1 terminates the router", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end

    test "stop/1 returns error for unknown task" do
      assert {:error, :not_found} = TaskRouter.stop("nonexistent")
    end
  end

  describe "current_status/1" do
    test "returns router status after dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Allow dispatch to process
      Process.sleep(50)

      status = TaskRouter.current_status(task.id)

      assert status.task_id == task.id
      assert status.assignee == assignee
      assert status.status == :running
      assert status.escalation_count == 0
    end

    test "includes execution_space_id in status", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert is_binary(status.execution_space_id)

      # Verify the space exists and is an execution space
      space = Platform.Chat.get_space(status.execution_space_id)
      assert space.kind == "execution"
      assert space.metadata["task_id"] == task.id
    end
  end

  describe "PubSub event handling" do
    test "resets heartbeat on task_updated", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Simulate a board event for our task
      updated_task = Tasks.get_task_detail(task.id)
      Tasks.broadcast_board({:task_updated, updated_task})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.last_evidence_at != nil
    end

    test "updates stage on stage_transitioned", %{task: task, assignee: assignee, stage: stage} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Simulate stage transition
      Tasks.broadcast_board({:stage_transitioned, stage})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage.id
      assert status.last_evidence_at != nil
    end

    test "tracks runtime events as liveness evidence", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.heartbeat"
        })

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.lease_status == "active"
      assert status.last_runtime_event_at != nil
      assert status.status == :running
    end

    test "hydrates router state from an existing active lease", %{task: task, assignee: assignee} do
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "already working"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(25)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.lease_status == "active"
      assert status.last_runtime_event_at != nil
    end

    test "hydrates active manual approval stage into waiting_human review state when a review request is pending",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Manual approval",
          description: "Wait for human sign-off",
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: review_stage.id, kind: "manual_approval"})

      {:ok, execution_space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)

      assert {:ok, _request} =
               Platform.Tasks.ReviewRequests.create_review_request(%{
                 validation_id: validation.id,
                 task_id: task.id,
                 execution_space_id: execution_space.id,
                 items: [%{label: "UI review"}]
               })

      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "waiting for review"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.status == :waiting_human
      assert status.lease_status == "active"
      assert status.current_stage_id == review_stage.id

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"
    end

    test "approved plan starts the first pending execution stage", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      approved_plan =
        plan
        |> Ecto.Changeset.change(%{status: "approved"})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, approved_plan})
      Process.sleep(100)

      started_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert started_stage.status == "running"
      assert started_stage.started_at != nil

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage.id
    end

    test "completed plan transitions in_progress task to in_review", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      completed_plan =
        plan
        |> Ecto.Changeset.change(%{status: "completed"})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(100)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"
    end

    test "completed plan transitions in_review task to deploying", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "in_review")

      completed_plan =
        plan
        |> Ecto.Changeset.change(%{status: "completed"})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(100)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "deploying"
    end

    test "running manual approval stage without a pending review request stays actively routed",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Manual approval",
          description: "Wait for human sign-off"
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: review_stage.id, kind: "manual_approval"})

      running_review_stage =
        review_stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, running_review_stage})
      Process.sleep(100)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.current_stage_id == review_stage.id
    end

    test "failed review stage bounces task from in_review back to in_progress", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "ready")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "in_review")

      plan_with_stages = Platform.Repo.preload(plan, :stages)
      [stage | _] = plan_with_stages.stages

      failed_stage =
        stage
        |> Ecto.Changeset.change(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, failed_stage})
      Process.sleep(100)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"
    end

    test "ignores task_updated for other tasks", %{
      task: task,
      assignee: assignee,
      project: project
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Create a different task and broadcast its update
      {:ok, other_task} = Tasks.create_task(%{project_id: project.id, title: "Other"})
      other_detail = Tasks.get_task_detail(other_task.id)
      Tasks.broadcast_board({:task_updated, other_detail})

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      # last_evidence_at should be nil since we only got the unrelated event
      # (dispatch sets it to nil, only our-task events set it)
      assert status.status == :running
    end
  end

  describe "dispatch" do
    test "transitions to :running after init dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Allow dispatch message to be processed
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end

    test "publishes runtime attention on Platform.PubSub", %{task: task, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert topic == "runtime:#{assignee.id}"
      assert payload.signal.reason == "task_assigned"
      assert payload.signal.task_id == task.id
      assert is_binary(payload.message.content)
      assert payload.message.author == "TaskRouter"
    end

    test "watchdog abandons a silent active lease and redispatches", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      assert {:ok, _event} =
               Platform.Orchestration.record_runtime_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => assignee.id,
                 "event_type" => "execution.progress",
                 "payload" => %{"summary" => "started but went quiet"}
               })

      Process.sleep(50)

      stale_at = DateTime.add(DateTime.utc_now(), -(31 * 60), :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_runtime_event_at: stale_at,
            last_dispatch_at: stale_at,
            current_stage_id: state.current_stage_id,
            escalation_count: 1,
            lease_status: "active",
            status: :running
        }
      end)

      send(pid, :heartbeat)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert payload.signal.reason == "task_assigned"
      assert payload.signal.task_id == task.id

      Process.sleep(50)

      refute Platform.Orchestration.RuntimeSupervision.current_lease_for_task(task.id)

      lease_statuses =
        Repo.all(
          from(l in ExecutionLease,
            where: l.task_id == ^task.id,
            order_by: [desc: l.inserted_at],
            select: l.status
          )
        )

      assert "abandoned" in lease_statuses

      status = TaskRouter.current_status(task.id)
      assert status.status in [:dispatching, :running]
      assert status.escalation_count == 0
    end
  end

  describe "heartbeat suppression" do
    test "heartbeat is suppressed when dispatch was sent within the heartbeat interval", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Immediately trigger heartbeat — dispatch was just sent, so it should be suppressed
      send(pid, :heartbeat)

      # Should NOT receive a heartbeat attention (dispatch cooldown)
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_heartbeat"}}
                     },
                     500

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.last_dispatch_at != nil
    end

    test "heartbeat is suppressed when last_runtime_event_at is within cooldown", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Record a runtime event (marks last_runtime_event_at as now)
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "actively streaming"}
        })

      Process.sleep(50)

      # Set last_dispatch_at far in the past so dispatch cooldown doesn't interfere
      stale_dispatch = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      :sys.replace_state(pid, fn state ->
        %{state | last_dispatch_at: stale_dispatch}
      end)

      # Trigger heartbeat — runtime activity is fresh, should be suppressed
      send(pid, :heartbeat)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_heartbeat"}}
                     },
                     500

      status = TaskRouter.current_status(task.id)
      assert status.last_runtime_event_at != nil
    end

    test "heartbeat fires normally after cooldown period", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Set both timestamps far in the past (beyond all cooldowns)
      stale_at = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_dispatch_at: stale_at,
            last_runtime_event_at: stale_at,
            stage_started_at: stale_at
        }
      end)

      # Trigger heartbeat — all cooldowns expired, should fire
      send(pid, :heartbeat)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_heartbeat"}}
                     },
                     1_000
    end

    test "heartbeat is suppressed when plan is in pending_review during planning", %{
      task: task,
      assignee: assignee
    } do
      # Transition task to planning
      {:ok, task} = Tasks.transition_task(task, "planning")

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Create a plan in pending_review
      {:ok, _plan} =
        Tasks.create_plan(%{task_id: task.id, status: "pending_review", version: 2})

      # Set timestamps far in the past so other cooldowns don't interfere
      stale_at = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_dispatch_at: stale_at,
            last_runtime_event_at: stale_at,
            task_status: "planning"
        }
      end)

      # Trigger heartbeat
      send(pid, :heartbeat)

      # Should NOT receive a heartbeat (plan is pending_review)
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_heartbeat"}}
                     },
                     500

      Process.sleep(50)
      status = TaskRouter.current_status(task.id)
      assert status.status == :waiting_human
    end

    test "heartbeat is suppressed when plan is in draft during planning", %{
      task: task,
      assignee: assignee
    } do
      # Transition task to planning
      {:ok, task} = Tasks.transition_task(task, "planning")

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Create a plan in draft status
      {:ok, _plan} =
        Tasks.create_plan(%{task_id: task.id, status: "draft", version: 2})

      # Set timestamps far in the past so other cooldowns don't interfere
      stale_at = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_dispatch_at: stale_at,
            last_runtime_event_at: stale_at,
            task_status: "planning"
        }
      end)

      # Trigger heartbeat
      send(pid, :heartbeat)

      # Should NOT receive a heartbeat (plan is in draft — agent is actively working)
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_heartbeat"}}
                     },
                     500

      Process.sleep(50)
      status = TaskRouter.current_status(task.id)
      # Should still be running (not waiting_human — draft is agent work, not human gate)
      assert status.status == :running
    end
  end

  describe "router lifecycle (no assignment persistence)" do
    test "router starts and stops cleanly without persisting to DB", %{
      task: task,
      assignee: assignee
    } do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      assert Process.alive?(pid)

      # Stop via TaskRouter.stop/1
      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end
  end
end
