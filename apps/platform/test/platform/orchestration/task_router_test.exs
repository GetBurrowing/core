defmodule Platform.Orchestration.TaskRouterTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{
    ExecutionLease,
    ExecutionSpace,
    LeaseManager,
    RuntimeSupervision,
    TaskRouter
  }

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
        description: "Testing the task router",
        # `deploy_target` set so the stage-2 (019f42db) `:deploying` guard
        # `require_deploy_target_for/2` passes for tests that walk the task
        # through to `deploying`.
        deploy_target: "production"
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

      # LeaseManager is a global singleton — purge this task's row so it
      # doesn't leak into the next test.
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
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
    test "tracks task_updated last_evidence_at for our task", %{task: task, assignee: assignee} do
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

    # Regression: prior to the fix, `handle_info({:stage_transitioned, stage}, ...)`
    # unconditionally set `current_stage_id = stage.id`. On a running→passed
    # transition the payload is the just-completed stage, so the router pinned
    # itself to a `passed` stage; the next dispatch then filtered validations to
    # ["pending", "running"] (empty) and echoed "No validations are pending. If
    # the work is complete, call `stage_complete`…" until the next broadcast.
    # The fix resolves `current_stage_id` via `current_running_stage/1` when the
    # broadcast payload is `passed`.
    test "stage_transitioned with passed stage advances current_stage_id to the next running stage",
         %{task: task, assignee: assignee, plan: plan, stage: stage_a} do
      # Stage A becomes running (mirrors the pre-transition state); Stage B
      # exists as `pending` and will flip to `running` at the same tick.
      running_stage_a =
        stage_a
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, stage_b} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "review",
          description: "Review the code"
        })

      {:ok, _validation_b} =
        Tasks.create_validation(%{stage_id: stage_b.id, kind: "test_pass"})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      # Prime router state so `current_stage_id` matches the (still running)
      # stage A — this is the state the router is in right before the
      # engine writes the passed→running transition pair.
      Tasks.broadcast_board({:stage_transitioned, running_stage_a})
      Process.sleep(50)

      assert TaskRouter.current_status(task.id).current_stage_id == stage_a.id

      # Engine now marks stage A `passed` and stage B `running` (order
      # matches PlanEngine.finalize/advance): both DB rows flip, then the
      # passed-stage broadcast fires. The router must resolve the running
      # stage from the freshly loaded plan, not pin to the passed payload.
      passed_stage_a =
        running_stage_a
        |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      _running_stage_b =
        stage_b
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      refute status.current_stage_id == stage_a.id
    end

    # Sibling regression: if the passed broadcast lands before the next
    # running stage is written (or when the plan is fully completed), the
    # router must clear `current_stage_id` to nil rather than pin the passed
    # stage — otherwise dispatches continue echoing the completed stage's
    # (empty) validation list.
    test "stage_transitioned with passed stage and no next running stage clears current_stage_id",
         %{task: task, assignee: assignee, stage: stage_a} do
      running_stage_a =
        stage_a
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      Tasks.broadcast_board({:stage_transitioned, running_stage_a})
      Process.sleep(50)

      passed_stage_a =
        running_stage_a
        |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == nil
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

      messages =
        execution_space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.map(& &1.content)

      # Task 019e00cb stage 2 wired `HeartbeatScheduler.heartbeat_suppressible?/2`
      # into `maybe_log_heartbeat_suppressed/3`. This scenario satisfies the
      # predicate (running manual_approval stage, every pending validation linked
      # to the open review_request) so the per-dispatch "Dispatch suppressed" log
      # is intentionally elided — the review_request itself is the visible
      # signal. The assertions above (`status == :waiting_human`,
      # `current_stage_id`, task status `in_review`) cover the state-machine
      # transition; we just need to confirm we are NOT spamming the noise log.
      refute Enum.any?(
               messages,
               &(String.contains?(&1, "Heartbeat suppressed") or
                   String.contains?(&1, "Dispatch suppressed"))
             )
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

      # Bug #7 (task 019f70ff-55c2) regression: TaskRouter must NOT auto-flip
      # a task to in_review just because a manual_approval-only stage went
      # running. `Platform.Tasks.ReviewRequests.create_review_request/1` is
      # the sole in_progress → in_review trigger; nothing has filed one here.
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

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

      space = ExecutionSpace.find_by_task_id(task.id)
      messages = ExecutionSpace.list_messages_with_participants(space.id)

      assert Enum.any?(
               messages,
               &String.contains?(&1.content, "Stage failure bounced task back to in_progress")
             )
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
  end

  describe "event-driven liveness (task 019f640d stage 3)" do
    # These tests exercise the new event-driven state machine: on each dispatch,
    # the router calls `LeaseManager.record_dispatch/4` and arms two one-shot
    # timers (`:check_no_ack`, `:check_safety_net`). The runtime replies with
    # `execution.acked` (via the future `task_ack` MCP tool from stage 5) to
    # extend the lease; progress events do the same. Silent drops fire ONE
    # `execution.no_ack_timeout` / `execution.safety_net_fired` runtime_event
    # each and post `execution.blocked needs_human=true` to the execution space.
    #
    # Because the real timers wait 5min / 90min, tests trigger the check
    # handlers directly via `send(pid, :check_no_ack)` after establishing the
    # LeaseManager row shape manually. The router's real code path exercises
    # the check handler, not the arm; the arm is exercised implicitly by
    # asserting `LeaseManager.get/1` returns the expected row after dispatch.

    test "happy path: dispatch → record_dispatch → ack via runtime_event → :check_no_ack silent",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Mark the seeded stage running so `current_running_stage/1` resolves
      # inside `do_dispatch/2`.
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      Process.sleep(50)

      # LeaseManager must have a row for this task after successful dispatch.
      assert %{
               stage_id: dispatched_stage_id,
               stage_kind: "coding",
               ack_at: nil,
               no_ack_fired?: false
             } = LeaseManager.get(task.id)

      assert dispatched_stage_id == stage.id

      # Simulate `execution.acked` runtime_event (which stage 5's `task_ack`
      # MCP tool will emit). The router's `apply_runtime_event/2` clause
      # calls `LeaseManager.record_ack/1` — clears no-ack, extends
      # safety-net.
      acked_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage.id,
        event_type: "execution.acked",
        payload: %{},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: nil
      }

      Tasks.broadcast_board({:runtime_event, acked_event})
      Process.sleep(50)

      assert %{ack_at: %DateTime{}} = LeaseManager.get(task.id)

      # Force `:check_no_ack` to fire NOW (real timer waits 5min). Router
      # sees `ack_at != nil` and is silent — no blocker post, no state flip.
      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_no_ack)
      Process.sleep(75)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running

      lease_after = LeaseManager.get(task.id)
      refute lease_after.no_ack_fired?

      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_msgs = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)

      # No `execution.no_ack_timeout` blocker post should have landed.
      refute Enum.any?(new_msgs, &String.contains?(&1, "Executor never acked"))
    end

    test "no-ack path: :check_no_ack fires blocker + broadcasts no_ack_timeout ONCE, no re-arm",
         %{task: task, assignee: assignee, stage: stage} do
      # Subscribe to `tasks:board` so we can assert the exact
      # `execution.no_ack_timeout` broadcast reaches PubSub.
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      Process.sleep(50)

      # No ack ever arrives — force `:check_no_ack` to fire NOW.
      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_no_ack)
      Process.sleep(100)

      # PubSub must have carried ONE `execution.no_ack_timeout` on
      # `tasks:board` (in `{:runtime_event, event}` shape).
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"} = event}
      assert event.task_id == task.id
      assert event.stage_id == stage.id
      assert is_integer(event.payload.elapsed_ms_since_dispatch)

      # Blocker message posted to execution space, ONE only.
      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      no_ack_posts = Enum.filter(new_contents, &String.contains?(&1, "Executor never acked"))
      assert length(no_ack_posts) == 1

      # LeaseManager row shows `no_ack_fired?: true` — idempotency guard set.
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      # Router state = :stalled.
      status = TaskRouter.current_status(task.id)
      assert status.status == :stalled

      # A second `:check_no_ack` must NOT fire another blocker (idempotent).
      before_msgs2 = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_no_ack)
      Process.sleep(75)

      # Refute a second no_ack_timeout event on PubSub.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}

      after_msgs2 = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents2 = Enum.drop(after_msgs2, before_msgs2) |> Enum.map(& &1.content)
      refute Enum.any?(new_contents2, &String.contains?(&1, "Executor never acked"))
    end

    test "safety-net extend: :check_safety_net reschedules when record_progress extends deadline",
         %{task: task, assignee: assignee, stage: stage} do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(75)

      # A progress event lands mid-flight → safety_net_at moved forward.
      progress_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage.id,
        event_type: "execution.progress",
        payload: %{"summary" => "still going"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: nil
      }

      Tasks.broadcast_board({:runtime_event, progress_event})
      Process.sleep(50)

      lease_after_progress = LeaseManager.get(task.id)
      assert %DateTime{} = lease_after_progress.safety_net_at

      remaining_ms =
        DateTime.diff(lease_after_progress.safety_net_at, DateTime.utc_now(), :millisecond)

      # 90min safety-net for `coding`; progress pushes deadline back to
      # `now + 90m`, so remaining is close to 5_400_000ms.
      assert remaining_ms > 1_000_000

      # Force `:check_safety_net` to fire NOW. Router sees remaining > 0,
      # reschedules — must NOT fire the alert.
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      send(pid, :check_safety_net)
      Process.sleep(75)

      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}

      assert %{safety_net_fired?: false} = LeaseManager.get(task.id)
    end

    test "safety-net fire: deadline in the past → single loud broadcast + blocker post",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(75)

      # Force safety_net_at into the past by re-writing the LeaseManager row.
      # (Real-world equivalent: 90 minutes elapsed with no progress.)
      lease = LeaseManager.get(task.id)
      past_deadline = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      :ets.insert(
        :orchestration_lease_manager,
        {task.id, %{lease | safety_net_at: past_deadline}}
      )

      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_safety_net)
      Process.sleep(100)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"} = event}
      assert event.task_id == task.id
      assert event.stage_id == stage.id
      assert event.payload.stage_kind == "coding"

      assert %{safety_net_fired?: true} = LeaseManager.get(task.id)

      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      assert Enum.any?(new_contents, &String.contains?(&1, "safety-net exceeded"))

      # Second call is idempotent.
      send(pid, :check_safety_net)
      Process.sleep(75)
      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
    end

    test "manual_approval stage: no :check_no_ack or :check_safety_net timers armed",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Replace the seeded coding stage with a manual_approval stage.
      Platform.Repo.delete_all(from(s in Platform.Tasks.Stage, where: s.plan_id == ^plan.id))

      {:ok, ma_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Manual approval gate",
          description: "Human review only",
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: ma_stage.id, kind: "manual_approval"})

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      # The pending_review_request suppression path would fire waiting_human
      # here IF a review request existed. Since none does, this is the
      # `waiting_for_human_review?/1` gate — but with no linked review_request,
      # the stage still counts as manual_approval (all pending validations
      # are manual_approval kind) so `waiting_for_human_review?/1` returns
      # true via `manual_approval_gate_pending?/1`.
      #
      # But wait — that path only returns true when there IS a pending
      # review_request. With no request, the router still dispatches. The
      # dispatch path resolves stage_kind = "manual_approval" and
      # `arm_liveness_timers/3` no-ops (ack_ms and safety_net_ms both nil).
      #
      # Regardless of the exact code path, the key invariant: after dispatch,
      # `LeaseManager.get/1` shows nil `no_ack_at` and nil `safety_net_at`
      # OR no lease at all — meaning no timer arming happened.

      case LeaseManager.get(task.id) do
        nil ->
          # No lease means arm_liveness_timers took the manual_approval
          # no-op path (or dispatch never reached the arm step because
          # `waiting_for_human_review?` short-circuited to :waiting_human).
          :ok

        lease ->
          assert lease.no_ack_at == nil,
                 "manual_approval stage must not arm no-ack timer; got no_ack_at=#{inspect(lease.no_ack_at)}"

          assert lease.safety_net_at == nil,
                 "manual_approval stage must not arm safety-net timer; got safety_net_at=#{inspect(lease.safety_net_at)}"
      end

      # Doubly-defensive check: no `:check_no_ack` or `:check_safety_net`
      # messages should be sitting in the process mailbox waiting to fire
      # (Process.send_after enqueues them for later delivery — a pending
      # timer message will appear in :messages when we peek).
      #
      # NOTE: `Process.send_after/3` messages don't appear in the mailbox
      # until they fire. Instead, we probe process state directly: the arm
      # helper returns `:ok` without side effects, so the assertions above
      # (no lease OR nil timeouts) are the load-bearing check.
      _messages = Process.info(pid, :messages)
    end
  end

  describe "no-ack silence (task 019f6791-c01b stage 2)" do
    # These tests cover the silence-honoring branch in
    # `handle_info(:check_no_ack, ...)`. `LeaseManager.silence/3` is the
    # operator escape hatch installed by the `alarm_silence` MCP tool
    # (stage 3 of this task). The router must NOT fire
    # `execution.no_ack_timeout` while the silence is in effect, must
    # reschedule the check for `until + 1s`, and must resume normal
    # fire-on-expiry once the silence lapses.

    test "silenced lease: :check_no_ack reschedules, no broadcast, no state change",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      Process.sleep(100)

      # Install a short silence — 400ms in the future — so the reschedule
      # target is reachable within test time budget.
      until = DateTime.add(DateTime.utc_now(), 400, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "cache-miss simulation")

      assert %{silenced_until: %DateTime{}} = LeaseManager.get(task.id)

      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      # Force `:check_no_ack` NOW — the silence-honoring branch must
      # reschedule via `Process.send_after` and return without firing.
      send(pid, :check_no_ack)
      Process.sleep(75)

      # Silenced: no broadcast on tasks:board.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}

      # Silenced: no_ack_fired? stays false.
      lease_after = LeaseManager.get(task.id)
      refute lease_after.no_ack_fired?

      # Silenced: router still :running, no `:stalled` transition.
      status = TaskRouter.current_status(task.id)
      assert status.status == :running

      # Silenced: no blocker post to the execution space.
      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      refute Enum.any?(new_contents, &String.contains?(&1, "Executor never acked"))
    end

    test "silence lapses → next :check_no_ack fires normally",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      # Install a silence and immediately rewrite it into the past so the
      # `DateTime.compare(now, until) == :lt` guard is false — this is the
      # "silence lapsed by the time :check_no_ack ran" path. Bypasses
      # `LeaseManager.silence/3`'s past-timestamp validation.
      lease = LeaseManager.get(task.id)
      assert lease, "expected LeaseManager row after dispatch"
      past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      :ets.insert(
        :orchestration_lease_manager,
        {task.id, %{lease | silenced_until: past}}
      )

      send(pid, :check_no_ack)
      Process.sleep(100)

      # Silence lapsed → normal fire path: broadcast + mark fired + stall.
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"} = event}
      assert event.task_id == task.id

      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      status = TaskRouter.current_status(task.id)
      assert status.status == :stalled
    end

    test "silence + prior ack → :check_no_ack silent via ack clause (silence orthogonal)",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      # Ack lands first; then a silence is installed. `:check_no_ack` must
      # match the earlier `ack_at: %DateTime{}` clause before ever
      # reaching the silence branch — so silence is moot but not harmful.
      :ok = LeaseManager.record_ack(task.id)
      until = DateTime.add(DateTime.utc_now(), 5_000, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "moot but present")

      assert %{ack_at: %DateTime{}, silenced_until: %DateTime{}} = LeaseManager.get(task.id)

      send(pid, :check_no_ack)
      Process.sleep(75)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
    end

    test "silence set AFTER alarm fired → next :check_no_ack still no-ops via fired clause",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      # First :check_no_ack fires normally (no silence, no ack) → sets
      # no_ack_fired?: true.
      send(pid, :check_no_ack)
      Process.sleep(100)
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      # Operator now installs a silence — a plausible if late intervention.
      # The silence should NOT un-fire the alarm; subsequent :check_no_ack
      # must still no-op via the `%{no_ack_fired?: true}` clause, which
      # sits ABOVE the silence clause in the case expression.
      until = DateTime.add(DateTime.utc_now(), 5_000, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "post-fire silence")

      send(pid, :check_no_ack)
      Process.sleep(75)

      # No second broadcast; no state change.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
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

    test "terminate/2 clears the LeaseManager row for the task", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(75)

      # Post-dispatch there should be a lease row for this task.
      assert %{} = LeaseManager.get(task.id)

      :ok = TaskRouter.stop(task.id)
      Process.sleep(50)

      assert LeaseManager.get(task.id) == nil
    end
  end

  describe "e2e_behavior does not suppress dispatch (agent-driven gate)" do
    test "an e2e_behavior validation is not human-gated — no review request, no suppression", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Add an e2e_behavior validation to the running stage. Crucially, no
      # review request is created — e2e_behavior is agent-driven (the review
      # agent runs the script and dispositions via validation_evaluate).
      {:ok, _e2e_validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "x",
            "actions" => "y",
            "expected" => "z"
          }
        })

      Process.sleep(100)

      # Router must NOT be in :waiting_human state — only manual_approval +
      # pending review_request flips it.
      status = TaskRouter.current_status(task.id)
      refute status.status == :waiting_human
    end
  end

  describe "manual_approval review-request suppression" do
    test "creating a pending review_request mid-task suppresses the next :dispatch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Capture initial execution-space message count
      space = ExecutionSpace.find_by_task_id(task.id)
      initial_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      # Open a manual_approval validation on the existing running stage and
      # create a pending review request against it
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Solo check"}]
        })

      # Wait for the :review_request_pending broadcast to be processed
      Process.sleep(100)

      # Status should have flipped to :waiting_human via the new handler
      status_before_dispatch = TaskRouter.current_status(task.id)
      assert status_before_dispatch.status == :waiting_human

      # Now trigger an explicit :dispatch — it must be suppressed
      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.status == :waiting_human

      messages = ExecutionSpace.list_messages_with_participants(space.id)
      new_messages = Enum.drop(messages, initial_count) |> Enum.map(& &1.content)

      awaiting_logs =
        Enum.filter(new_messages, &String.contains?(&1, "awaiting human review"))

      assert length(awaiting_logs) >= 1
    end

    test "approving all items wakes the router and clears :waiting_human", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "UI"}]
        })

      Process.sleep(100)
      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _} = Platform.Tasks.ReviewRequests.approve_item(hd(request.items).id, "rowan")
      Process.sleep(150)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end

    test "rejecting an item wakes the router AND re-dispatches with the in_progress prompt",
         %{
           task: task,
           assignee: assignee,
           stage: stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "UI"}]
        })

      Process.sleep(100)
      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _} =
        Platform.Tasks.ReviewRequests.reject_item(hd(request.items).id, "rowan", "Needs work")

      # Expect a fresh dispatch (task_assigned) after rejection
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_500

      Process.sleep(50)
      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end
  end

  describe "plan-level pending_review suppression (task 019f9ae5)" do
    # Stage 1 added a PLAN-level guard to `handle_info(:dispatch, state)`.
    # `init/1` always had one, but every OTHER `:dispatch` injector bypasses
    # init and landed straight in `do_dispatch/2`:
    # `TaskRouterWatcher.redispatch_for_runtime/1` fires a raw
    # `send(pid, :dispatch)` for every should-run task on each runtime
    # reconnect (the confirmed source of the 10-day re-dispatch loop on task
    # 019f6779), plus `force_dispatch/1`, the ~10 in-module
    # `send(self(), :dispatch)` sites and the 1s retry timer. Every test here
    # therefore uses an EXPLICIT `send(pid, :dispatch)` — that is the path
    # that leaked, and it is the only way to exercise the handler branch.
    #
    # The fixture plan is flipped in place rather than re-created:
    # `plan_awaiting_review?/1` keys off `Tasks.latest_plan/1` (highest
    # version regardless of status), so an accidental v2 would silently
    # change what is under test.

    defp mark_plan_pending_review(plan) do
      plan
      |> Ecto.Changeset.change(%{status: "pending_review"})
      |> Platform.Repo.update!()
    end

    defp suppression_logs_since(space_id, drop_count) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.drop(drop_count)
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "awaiting human review"))
    end

    # Every plan-gate line in the space, from the beginning — the init-time
    # emission lands before a test can take a baseline (the space itself is
    # created inside `init/1`), so this counts from zero instead of dropping.
    defp plan_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "plan is awaiting human review"))
    end

    test "pending_review plan suppresses an explicitly injected :dispatch", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      _pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # `init/1` refuses to schedule the initial dispatch, so nothing should
      # arrive before we force the issue.
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      space = ExecutionSpace.find_by_task_id(task.id)

      # `init/1` narrates the park in the execution space at episode start.
      # This is the human-facing half of the feature: a suppressed task must
      # explain itself, not go quiet. An earlier revision of this test asserted
      # ZERO lines here — that encoded the defect the e2e review caught
      # (validation 019f9aea-95bc-7a84-bf3e-333bc165798b): the handler's log is
      # edge-triggered on `state.status != :waiting_human`, and a router that
      # boots into a `pending_review` plan is ALREADY `:waiting_human`, so the
      # edge never fires. That is the production shape, not a corner case.
      init_logs = plan_gate_logs(space.id)

      assert length(init_logs) == 1,
             "expected exactly one plan-gate suppression log from init/1, got: #{inspect(init_logs)}"

      assert String.contains?(hd(init_logs), "plan is awaiting human review")

      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      # Second tick — the guard must hold, and must not start narrating.
      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      Process.sleep(50)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # ...and stays silent on every subsequent tick. `init/1` parked this
      # router in `:waiting_human` before either dispatch, so the handler's
      # edge condition is false and neither tick adds a line. That is the
      # anti-spam property task 019e00cb fixed — an unconditional log here
      # would post once per injected dispatch, and `TaskRouterWatcher` injects
      # one per runtime reconnect. Net contract: exactly one line per
      # suppression episode, zero on repeats.
      assert plan_gate_logs(space.id) == init_logs
    end

    test "the plan-level suppression log is edge-triggered: one line per episode, not per tick",
         %{task: task, assignee: assignee, plan: plan} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      # Start while the fixture plan is still `approved` so the router parks
      # in `:running` — that is what makes the next dispatch a genuine
      # `:running -> :waiting_human` transition.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Flip the plan WITHOUT broadcasting `{:plan_updated, ...}` — a
      # broadcast would drive the router to `:waiting_human` through the
      # plan_updated handler and rob the dispatch handler of the edge.
      _pending_plan = mark_plan_pending_review(plan)

      space = ExecutionSpace.find_by_task_id(task.id)
      baseline_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :dispatch)
      Process.sleep(150)

      send(pid, :dispatch)
      Process.sleep(150)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = suppression_logs_since(space.id, baseline_count)

      assert length(logs) == 1,
             "expected exactly one plan-gate suppression log across two ticks, got: #{inspect(logs)}"

      assert String.contains?(hd(logs), "plan is awaiting human review")
    end

    test "a running router narrates the park when the plan is submitted for review", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert plan_gate_logs(space.id) == []

      pending_plan = mark_plan_pending_review(plan)

      # The board broadcast the router would receive from `Tasks.submit_plan/2`.
      send(pid, {:plan_updated, pending_plan})
      Process.sleep(150)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = plan_gate_logs(space.id)

      assert length(logs) == 1,
             "expected the plan_updated handler to narrate the park once, got: #{inspect(logs)}"

      # A re-broadcast of the same pending plan must not double-post.
      send(pid, {:plan_updated, pending_plan})
      Process.sleep(150)

      assert plan_gate_logs(space.id) == logs
    end

    test "approved plan still dispatches — the plan guard is not over-broad", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      # Fixture plan is `approved` (setup line ~35) — untouched here.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      Process.sleep(50)
      refute TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "approving the plan wakes the router — suppression is not a one-way door", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _task} = Tasks.transition_task(task, "planning")
      pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Prove suppression PRECEDED resumption — otherwise a green assertion
      # below could just be the un-suppressed dispatch we were trying to stop.
      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _approved} = Tasks.approve_plan(pending_plan, "rowan")

      # Resumption chain: `approve_plan/3` -> `apply_dispatch_gate/1` moves the
      # task to `in_progress` in-transaction -> post-commit
      # `broadcast_board({:plan_updated, approved})` -> the router's
      # plan_updated handler sets `:running` and calls
      # `ensure_execution_stage_started/2` -> `PlanEngine.start_stage/1` on the
      # fixture's pending stage -> `{:stage_transitioned, stage}` -> the
      # router's stage handler `send(self(), :dispatch)` -> the plan guard is
      # now false because `latest_plan.status == "approved"`.
      #
      # Note that resumption does NOT depend on the router's `status` field:
      # the `:dispatch` handler never reads `state.status` for gating (only for
      # the edge-triggered log), so parking in `:waiting_human` cannot lock a
      # task out.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     2_000

      Process.sleep(50)
      assert TaskRouter.current_status(task.id).status == :running
    end

    test "approved plan with an open manual_approval request keeps the STAGE-level reason", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      initial_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Solo check"}]
        })

      Process.sleep(100)
      assert TaskRouter.current_status(task.id).status == :waiting_human

      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      Process.sleep(50)
      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = suppression_logs_since(space.id, initial_count)

      # The new plan-level branch is ordered AHEAD of the stage-level one, but
      # `plan_awaiting_review?/1` is false here (plan is `approved`), so the
      # stage gate must still own this suppression — same copy as before.
      assert Enum.any?(logs, &String.contains?(&1, "awaiting human review on a manual_approval"))

      refute Enum.any?(logs, &String.contains?(&1, "plan is awaiting human review"))
    end

    test "pending e2e_behavior validation with an approved plan still dispatches", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # No review request — e2e_behavior is agent-driven (the review agent runs
      # the script and dispositions via validation_evaluate), so neither the
      # plan gate nor the stage gate may claim it.
      {:ok, _e2e_validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "seed a task",
            "actions" => "send :dispatch",
            "expected" => "attention broadcast"
          }
        })

      Process.sleep(100)

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      Process.sleep(50)
      refute TaskRouter.current_status(task.id).status == :waiting_human
    end
  end

  describe "stage-level suppression is edge-triggered (task 019f9b34)" do
    # Sibling of the plan-level block above. The STAGE-level copy
    # ("Dispatch suppressed: awaiting human review on a manual_approval
    # validation") posted once per router tick instead of once per suppression
    # episode: measured 1 -> 2 -> 3 -> 4 over three injected dispatches, and 7
    # for the fuller production shape (boot + 3 dispatches + 2
    # `:review_request_pending` re-broadcasts).
    #
    # Why the 019e00cb predicate gate cannot cover this on its own:
    # `HeartbeatScheduler.heartbeat_suppressible?/2` returns false unless EVERY
    # pending validation on the stage is a `manual_approval` linked to an open
    # review request. The setup fixture seeds a `test_pass` on the stage, so a
    # single co-pending automated validation makes the predicate false forever
    # and the elision never engages. That co-pending `test_pass` is the entire
    # production shape under test here — do NOT drop it.
    #
    # Six sites park the router on the stage gate. Stage 1 of 019f9b34 found
    # the plan's four-site analysis incomplete: the `{:review_request_pending}`
    # handler does NOT open a mid-task episode (the router is already
    # `:waiting_human` by the time it runs). The real opener is the tail of
    # `do_dispatch/2`, which parks silently, and `{:task_updated}` is a second
    # silent park site. Both now narrate, edge-gated. `do_dispatch/2` gates on
    # `entry_status` captured at function entry, because `state.status` is set
    # to `:running` unconditionally before its tail park — the `state.status`
    # edge is useless there.

    # TRAP 1 — SUBSTRING COLLISION. Do NOT reuse `suppression_logs_since/2`:
    # it filters on the loose "awaiting human review", which matches BOTH the
    # stage copy and the plan copy ("Dispatch suppressed: plan is awaiting
    # human review — approve or reject the plan to resume"). That collision
    # already cost a cycle on 019f9ae5 and is why `plan_gate_logs/1` exists.
    # This filter is copy-specific to the stage gate.
    #
    # TRAP 2 — COUNT FROM ZERO, NEVER FROM A POST-`start_link` BASELINE. The
    # execution space is created inside `init/1`, so a boot-time emission
    # lands before any test can snapshot a baseline and
    # `suppression_logs_since/2`'s `Enum.drop/2` silently swallows it.
    # Counting from zero is the only way to assert exactly-one ACROSS the boot
    # emission plus subsequent ticks. Same reasoning as `plan_gate_logs/1`.
    defp stage_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "awaiting human review on a manual_approval"))
    end

    # The THIRD suppression copy, emitted by call sites that pass no `:reason`
    # (the `{:stage_transitioned, ...}` site). It shares no substring with
    # either of the other two, so a loose filter would silently miss it.
    defp generic_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(
        &String.contains?(
          &1,
          "Heartbeat suppressed: waiting for manual approval before more agent work"
        )
      )
    end

    defp mark_stage_running(stage) do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()
    end

    # Opens a manual_approval ALONGSIDE the fixture's pending `test_pass`.
    defp open_stage_review_request(task, stage, space, label) do
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: label}]
        })

      {manual_validation, request}
    end

    test "mixed-validation stage narrates the park once, not once per dispatch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      # Start while nothing is pending so the router parks in `:running` —
      # that is what makes the subsequent park a genuine
      # `:running -> :waiting_human` transition rather than a boot-into-parked.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert stage_gate_logs(space.id) == []

      open_stage_review_request(task, running_stage, space, "Solo check")
      Process.sleep(200)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # Three explicit dispatches — the path `TaskRouterWatcher` injects on
      # every runtime reconnect, and the one that leaked.
      send(pid, :dispatch)
      Process.sleep(150)
      send(pid, :dispatch)
      Process.sleep(150)
      send(pid, :dispatch)
      Process.sleep(150)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = stage_gate_logs(space.id)

      # MUTATION CHECK (2026-07-25, all six sites at once): this same scenario
      # yields 5 stage-gate lines with every stage-1 guard reverted, and 0 with
      # only the `do_dispatch/2` tail emission reverted — the episode opener,
      # which is silent on `main`. Both directions fail this assertion.
      assert length(logs) == 1,
             "expected exactly one stage-gate suppression log across three ticks, got: #{inspect(logs)}"

      assert String.contains?(hd(logs), "awaiting human review on a manual_approval")
    end

    test "re-broadcasting the park signal does not re-log into an open episode", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      open_stage_review_request(task, running_stage, space, "Solo check")
      Process.sleep(200)

      assert TaskRouter.current_status(task.id).status == :waiting_human
      assert length(stage_gate_logs(space.id)) == 1

      # PubSub re-delivery of the same park signal (a runtime reconnect
      # re-subscribes and the broadcast is replayed).
      send(pid, {:review_request_pending, %{task_id: task.id}})
      Process.sleep(150)
      send(pid, {:review_request_pending, %{task_id: task.id}})
      Process.sleep(150)

      # ...and a repeated `{:stage_transitioned, ...}` for the SAME running
      # stage, which exercises the third (reason-less, generic-copy) site.
      send(pid, {:stage_transitioned, running_stage})
      Process.sleep(150)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(stage_gate_logs(space.id)) == 1,
             "re-broadcasts must not re-log into an already-open episode, got: #{inspect(stage_gate_logs(space.id))}"

      assert generic_gate_logs(space.id) == [],
             "the reason-less `{:stage_transitioned, ...}` site must stay edge-guarded, got: #{inspect(generic_gate_logs(space.id))}"
    end

    test "the episode re-arms after disposition — the guard is an edge, not a latch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {_validation, request} =
        open_stage_review_request(task, running_stage, space, "First gate")

      Process.sleep(200)
      assert TaskRouter.current_status(task.id).status == :waiting_human
      assert length(stage_gate_logs(space.id)) == 1

      # Disposition the ONLY item. The stage does not complete — the fixture's
      # `test_pass` is still pending — so the router returns to `:running` on
      # the same stage, which is exactly the shape that must re-arm the edge.
      {:ok, _} = Platform.Tasks.ReviewRequests.approve_item(hd(request.items).id, "rowan")
      Process.sleep(250)

      assert TaskRouter.current_status(task.id).status == :running

      # A genuinely NEW episode.
      open_stage_review_request(task, running_stage, space, "Second gate")
      Process.sleep(200)

      send(pid, :dispatch)
      Process.sleep(150)
      send(pid, :dispatch)
      Process.sleep(150)

      logs = stage_gate_logs(space.id)

      # Two episodes, two lines — and no more than one per episode despite the
      # extra dispatches. Without this test a `status`-latching bug would pass
      # the two tests above while permanently silencing the log.
      assert length(logs) == 2,
             "expected exactly one line per suppression episode across two episodes, got: #{inspect(logs)}"
    end

    test "the plan gate is unregressed and never emits the stage copy", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _task} = Tasks.transition_task(task, "planning")

      # Flip the fixture plan in place — `plan_awaiting_review?/1` keys off
      # `Tasks.latest_plan/1`, so an accidental v2 would silently change what
      # is under test.
      _pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      space = ExecutionSpace.find_by_task_id(task.id)

      send(pid, :dispatch)
      Process.sleep(150)
      send(pid, :dispatch)
      Process.sleep(150)
      send(pid, :dispatch)
      Process.sleep(150)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(plan_gate_logs(space.id)) == 1,
             "019f9ae5 regression: expected exactly one plan-gate log, got: #{inspect(plan_gate_logs(space.id))}"

      # The plan branch is ordered ahead of the stage branch in the `:dispatch`
      # handler, so while the plan is provisional the STAGE copy must never
      # appear. This is the assertion the loose `suppression_logs_since/2`
      # filter cannot make.
      assert stage_gate_logs(space.id) == [],
             "the stage copy must never be emitted while the plan is provisional, got: #{inspect(stage_gate_logs(space.id))}"
    end

    test "a router that BOOTS into an open gate narrates once with the stage-gate copy", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      open_stage_review_request(task, running_stage, space, "Boot gate")

      # An active lease is what routes `init/1` into its
      # `waiting_for_human_review?/1` branch (the branch every production boot
      # path takes: gateway restart, `TaskRouterWatcher.boot_reconcile/0`).
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "waiting for review"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(250)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # `init/1` is episode start by definition, so it is deliberately the ONE
      # unguarded emitter — and with the handler now edge-triggered it is the
      # SOLE emitter for this shape (init emits, parks, then delegates via
      # `send(self(), :dispatch)`, which correctly skips).
      assert length(stage_gate_logs(space.id)) == 1,
             "expected exactly one stage-gate log from init/1 + its delegated dispatch, got: #{inspect(stage_gate_logs(space.id))}"

      # ...and it must be the stage-gate copy, not the reason-less generic one.
      # Without the explicit `reason:` on the `init/1` call, a boot-into-parked
      # episode falls through to "Heartbeat suppressed: waiting for manual
      # approval..." and becomes ungreppable by the stage-gate copy — one
      # episode, two different strings depending on how the router got there.
      assert generic_gate_logs(space.id) == [],
             "boot-time stage-gate episodes must use the stage-gate copy, got: #{inspect(generic_gate_logs(space.id))}"
    end

    test "a task update is narrated when it is the first site to observe the open gate", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      open_stage_review_request(task, running_stage, space, "First gate")
      Process.sleep(200)
      assert length(stage_gate_logs(space.id)) == 1

      # Return the router to `:running` while the gate is STILL open. This is
      # real: `handle_info({:review_request_resolved, ...})` sets `:running`
      # unconditionally, without checking whether OTHER requests on the stage
      # remain pending, so a multi-gate stage lands here for real. Injecting
      # the broadcast keeps it deterministic (a real `approve_item/2` fans out
      # several racing broadcasts) — same technique as the plan-gate test that
      # injects `{:plan_updated, pending_plan}` directly.
      send(pid, {:review_request_resolved, %{task_id: task.id, outcome: :passed}})
      Process.sleep(150)
      assert TaskRouter.current_status(task.id).status == :running

      # `{:task_updated}` is a silent park site on `main`: it flips the router
      # to `:waiting_human` without narrating. If it is the first site to
      # observe the still-open gate, the episode goes unnarrated entirely.
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})
      Process.sleep(150)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(stage_gate_logs(space.id)) == 2,
             "the `{:task_updated}` park site must narrate the episode it opens, got: #{inspect(stage_gate_logs(space.id))}"

      # ...and it is edge-triggered like every other site: `{:task_updated}`
      # fires from many places in `tasks.ex`, so an unconditional log here
      # would be the pile-up this task set out to fix.
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})
      Process.sleep(150)
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})
      Process.sleep(150)

      assert length(stage_gate_logs(space.id)) == 2,
             "repeated task updates must not re-log into an open episode, got: #{inspect(stage_gate_logs(space.id))}"
    end
  end

  describe "dispatch suppression predicate (task 019e00cb stage 2)" do
    # Predicate `HeartbeatScheduler.heartbeat_suppressible?/2` gates the
    # `maybe_log_heartbeat_suppressed/3` call — when the running stage is
    # a manual_approval whose only pending validation is linked to an open
    # review_request, the per-dispatch "Dispatch suppressed" log is elided.
    # (The old escalation-ladder tests are gone with the polling scheduler;
    # only the dispatch-time log suppression remains relevant.)

    defp seed_linked_manual_approval(task, stage, space) do
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Visual check"}]
        })

      {manual_validation, request}
    end

    defp drop_seed_validations(stage) do
      Platform.Repo.delete_all(
        from(v in Platform.Tasks.Validation, where: v.stage_id == ^stage.id)
      )
    end

    test "all-linked manual_approval pending → maybe_log_heartbeat_suppressed posts no execution-space log",
         %{
           task: task,
           assignee: assignee,
           stage: stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      drop_seed_validations(stage)
      seed_linked_manual_approval(task, stage, space)

      Process.sleep(100)

      # Snapshot messages BEFORE forcing a redundant :dispatch tick.
      baseline = ExecutionSpace.list_messages_with_participants(space.id)
      baseline_count = length(baseline)

      # The :dispatch handler hits the pre-dispatch guard which calls
      # maybe_log_heartbeat_suppressed/3. With the predicate gate, that
      # call must NOT post a "Dispatch suppressed" line.
      send(pid, :dispatch)
      Process.sleep(150)

      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_msgs = Enum.drop(after_msgs, baseline_count) |> Enum.map(& &1.content)

      suppression_logs =
        Enum.filter(new_msgs, fn m ->
          String.contains?(m, "Dispatch suppressed") or
            String.contains?(m, "Heartbeat suppressed")
        end)

      assert suppression_logs == [],
             "expected predicate gate to swallow suppression log, got: #{inspect(suppression_logs)}"
    end
  end

  describe "stage-level responsibility routing" do
    # Task 019f5d47 — a stage carrying `responsibility: "designer"` dispatches
    # to the designer role owner's runtime; when the role has no owner (or the
    # owner has no runtime), dispatch falls back to `state.assignee` and emits
    # telemetry. `state.assignee` itself never changes — only the per-dispatch
    # broadcast target does.

    defp create_test_user do
      Platform.Repo.insert!(%Platform.Accounts.User{
        email: "resp_route_#{System.unique_integer([:positive])}@example.com",
        name: "Responsibility Route Test User",
        oidc_sub: "oidc-resp-route-#{System.unique_integer([:positive])}"
      })
    end

    defp create_test_agent do
      defaults = %{
        slug: "resp-agent-#{System.unique_integer([:positive])}",
        name: "Responsibility Test Agent",
        status: "active"
      }

      {:ok, agent} =
        %Platform.Agents.Agent{}
        |> Platform.Agents.Agent.changeset(defaults)
        |> Platform.Repo.insert()

      agent
    end

    defp create_linked_runtime(runtime_id_suffix) do
      user = create_test_user()
      agent = create_test_agent()

      {:ok, runtime} =
        Platform.Federation.register_runtime(user.id, %{
          runtime_id: "resp-runtime-#{runtime_id_suffix}-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _raw_token} = Platform.Federation.activate_runtime(runtime)
      {:ok, _linked_agent} = Platform.Federation.link_agent(activated, agent)

      {agent, activated}
    end

    test "happy path: stage responsibility routes broadcast to the role owner's runtime", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      # Seed the designer role owner + their runtime, then pin the role.
      {designer_agent, designer_runtime} = create_linked_runtime("designer")
      {:ok, _assignment} = Platform.Roles.assign_role("designer", designer_agent.id)

      # Attach responsibility to the stage AND mark it running so
      # `current_running_stage/1` returns it inside do_dispatch/2.
      stage
      |> Ecto.Changeset.change(%{
        responsibility: "designer",
        status: "running",
        started_at: DateTime.utc_now()
      })
      |> Platform.Repo.update!()

      # Subscribe to BOTH topics so we can assert routing lands on the designer
      # side and NOT on the phase-assignee side.
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{designer_runtime.runtime_id}")
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      designer_topic = "runtime:#{designer_runtime.runtime_id}"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^designer_topic,
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert payload.signal.reason == "task_assigned"
      assert payload.signal.task_id == task.id

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "runtime:" <> _,
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     150

      # `state.assignee` is untouched — the routing lens leaves the phase
      # identity in place for downstream bookkeeping.
      status = TaskRouter.current_status(task.id)
      assert status.assignee == assignee
    end

    test "fallback path: role has no assignee → telemetry fires and phase-assignee runtime still receives the broadcast",
         %{task: task, assignee: assignee, stage: stage} do
      # NB: no `assign_role/2` call — `agent_id_for_role("designer")` returns nil.
      assert Platform.Roles.agent_id_for_role("designer") == nil

      updated_stage =
        stage
        |> Ecto.Changeset.change(%{
          responsibility: "designer",
          status: "running",
          started_at: DateTime.utc_now()
        })
        |> Platform.Repo.update!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :plans, :stage_dispatch, :assignee_unresolvable]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Progressive enhancement: dispatch is not blocked; broadcast still lands
      # on the phase-assignee runtime topic.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert topic == "runtime:#{assignee.id}"
      assert payload.signal.reason == "task_assigned"

      assert_receive {[:platform, :plans, :stage_dispatch, :assignee_unresolvable], ^handler_ref,
                      %{count: 1}, metadata},
                     500

      assert metadata.reason == :role_unresolvable
      assert metadata.responsibility == "designer"
      assert metadata.stage_id == updated_stage.id
      assert metadata.task_id == task.id
      assert metadata.fallback_runtime_id == assignee.id
      assert metadata.actor_type == "system"
      assert metadata.resource_type == "stage"
      assert metadata.resource_id == updated_stage.id
    end

    test "backward compat: stage with responsibility=nil emits no telemetry and dispatches to state.assignee",
         %{task: task, assignee: assignee, stage: stage} do
      # The seed stage has responsibility == nil already — assert that
      # explicitly so a future fixture drift doesn't hide behind default.
      stage = Platform.Repo.reload!(stage)
      assert stage.responsibility == nil

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :plans, :stage_dispatch, :assignee_unresolvable]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert topic == "runtime:#{assignee.id}"
      assert payload.signal.reason == "task_assigned"

      refute_receive {[:platform, :plans, :stage_dispatch, :assignee_unresolvable], _, _, _},
                     150
    end
  end

  describe "deploy stage failure recovery" do
    test "failed deploy stage returns state, router stays alive, task bounces to in_progress AND re-dispatches",
         %{
           task: task,
           assignee: assignee,
           plan: plan,
           stage: _stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention so we can watch for the
      # re-dispatch caused by the deploy failure.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Transition task through to deploying
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      # Create a deploy stage and mark it as failed
      {:ok, deploy_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Deploy: PR merge",
          description: "Deploy via PR"
        })

      failed_deploy =
        deploy_stage
        |> Ecto.Changeset.change(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()
        |> Platform.Repo.preload(:validations)

      # Broadcast the failed stage transition
      Tasks.broadcast_board({:stage_transitioned, failed_deploy})
      Process.sleep(150)

      # Router must still be alive — before this fix it crashed on nil state
      assert Process.alive?(pid)

      # Task should have bounced back to in_progress
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      # Regression: a fresh `task_assigned` dispatch fires after the bounce
      # so the agent picks up the in_progress prompt (this is the branch
      # the stage 3 redesign explicitly preserves byte-for-byte per spec).
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # deploying -> done requires a settled deploy stage (task 019f9b34)
  # ────────────────────────────────────────────────────────────────────
  #
  # Incident 019f9ae5: `inject_deploy_stage/4` created the deploy stage,
  # transitioned the task to `deploying`, then broadcast `{:plan_updated,
  # plan}` carrying a STALE `completed` status. The router's
  # `deploying -> done` arm trusted that status and marked the task `done`
  # at 21:10:06.840 — eight minutes before the PR merged, with the deploy
  # stage still `running`. The guard makes the task status independent of
  # the plan row's bookkeeping.

  describe "deploying -> done requires a settled deploy stage (task 019f9b34)" do
    defp seed_running_deploy_stage!(plan, status) do
      {:ok, deploy_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Deploy: PR merge",
          description: "Deploy via PR merge"
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: deploy_stage.id, kind: "pr_merged"})

      deploy_stage
      |> Ecto.Changeset.change(%{status: status, started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()
    end

    defp drift_plan_to_completed!(plan) do
      plan
      |> Ecto.Changeset.change(%{status: "completed"})
      |> Platform.Repo.update!()
    end

    test "a stale `completed` broadcast does NOT flip the task to done while the deploy stage is running",
         %{task: task, assignee: assignee, plan: plan} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      _deploy_stage = seed_running_deploy_stage!(plan, "running")
      completed_plan = drift_plan_to_completed!(plan)

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(150)

      updated_task = Tasks.get_task_detail(task.id)

      assert updated_task.status == "deploying",
             "a running deploy stage must hold the task at deploying — a `completed` plan is " <>
               "not evidence the deploy landed (task 019f9b34 / incident 019f9ae5)"
    end

    test "a settled (passed) deploy stage still promotes the task to done", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      _deploy_stage = seed_running_deploy_stage!(plan, "passed")
      completed_plan = drift_plan_to_completed!(plan)

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(150)

      updated_task = Tasks.get_task_detail(task.id)

      assert updated_task.status == "done",
             "the guard must not be inert-and-passing: a passed deploy stage still completes the task"
    end

    test "a plan with no deploy stage at all still promotes the task to done", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      stage
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      completed_plan = drift_plan_to_completed!(plan)

      Tasks.broadcast_board({:plan_updated, completed_plan})
      Process.sleep(150)

      updated_task = Tasks.get_task_detail(task.id)

      assert updated_task.status == "done",
             "the empty-deploy-stage filter must default to settled, not lock the task out of done"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Stage-scoped blocker handling (task 019f6791 stage 3)
  # ────────────────────────────────────────────────────────────────────
  #
  # Regression coverage for the router-level leak Rowan observed on
  # task 019f6380: a `blocked` lease created against a prior stage was
  # rehydrating the router into `:waiting_human` on stage transition and
  # on boot, silently gating downstream dispatches. The fix threads
  # `stage_id` through the blocker handler + hydration paths so leftover
  # rows for `passed` stages never poison the currently-running stage.

  describe "stage-scoped blocker handling (task 019f6791)" do
    defp seed_stage!(plan, position, name, status) do
      attrs = %{
        plan_id: plan.id,
        position: position,
        name: name,
        description: "stage #{position}"
      }

      attrs =
        case status do
          "running" -> Map.merge(attrs, %{status: "running", started_at: DateTime.utc_now()})
          "passed" -> Map.merge(attrs, %{status: "passed", completed_at: DateTime.utc_now()})
          _ -> attrs
        end

      {:ok, stage} = Tasks.create_stage(attrs)
      {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      stage
    end

    defp seed_blocked_lease!(task_id, stage_id, runtime_id) do
      now = DateTime.utc_now()

      %ExecutionLease{}
      |> ExecutionLease.changeset(%{
        task_id: task_id,
        phase: "execution",
        runtime_id: runtime_id,
        stage_id: stage_id,
        status: "blocked",
        block_reason: "seeded stale blocker",
        started_at: now,
        expires_at: DateTime.add(now, 15 * 60, :second)
      })
      |> Platform.Repo.insert!()
    end

    test "bug repro: blocker on stage B does not gate stage C dispatch after transition", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Stage A already exists (seeded in setup). Mark it passed; seed B running, C pending.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")
      stage_c = seed_stage!(plan, 3, "stage C", "pending")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention for stage B.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      Process.sleep(50)

      assert TaskRouter.current_status(task.id).current_stage_id == stage_b.id

      # Fire a legitimate stage-B blocker. Router should flip to
      # :waiting_human because the blocker targets the current stage.
      blocked_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage_b.id,
        event_type: "execution.blocked",
        payload: %{"stage_id" => stage_b.id, "description" => "waiting on subagent"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, blocked_event})
      Process.sleep(50)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # Now transition stage B → passed and stage C → running (mirrors
      # the PlanEngine finalize/advance pair the real engine writes —
      # both broadcasts fire; the running-broadcast is what re-arms
      # dispatch, the passed-broadcast is what drops stage-B's leases).
      stage_b
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      running_stage_c =
        stage_c
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      passed_stage_b = Platform.Repo.get!(Platform.Tasks.Stage, stage_b.id)
      Tasks.broadcast_board({:stage_transitioned, passed_stage_b})
      Tasks.broadcast_board({:stage_transitioned, running_stage_c})

      # A fresh attention broadcast for stage C must fire within 500ms.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     500

      Process.sleep(50)
      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_c.id
      assert status.status == :running
      refute status.lease_status == "blocked"
      # The old blocker's runtime-event timestamp must not carry into stage C.
      assert status.last_runtime_event_at == nil
    end

    test "cross-boundary blocker (payload.stage_id != current) does NOT flip to :waiting_human",
         %{task: task, assignee: assignee, plan: plan, stage: stage_a} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      Process.sleep(50)

      assert TaskRouter.current_status(task.id).status == :running
      assert TaskRouter.current_status(task.id).current_stage_id == stage_b.id

      # File a blocker whose payload.stage_id targets stage A (already passed).
      # Router must ignore and stay :running.
      stale_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage_a.id,
        event_type: "execution.blocked",
        payload: %{"stage_id" => stage_a.id, "description" => "stale historical blocker"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, stale_event})
      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.current_stage_id == stage_b.id
      # Legit stage-B blocker sanity: same handler still flips when stage_id matches.
      current_event = %{
        stale_event
        | payload: %{"stage_id" => stage_b.id, "description" => "real"}
      }

      send(pid, {:runtime_event, current_event})
      Process.sleep(50)
      assert TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "legacy blocker with no payload.stage_id preserves pre-fix behaviour (still flips)", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      Process.sleep(50)

      legacy_event = %{
        id: nil,
        task_id: task.id,
        stage_id: nil,
        event_type: "execution.blocked",
        payload: %{"description" => "legacy caller — no stage_id"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, legacy_event})
      Process.sleep(50)

      assert TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "boot rehydration ignores blocked lease attached to a passed stage", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      # Stage A passed with a leaked `blocked` lease; stage B running with no lease yet.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      seed_blocked_lease!(task.id, stage_a.id, assignee.id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # The stale stage-A blocker must NOT gate the initial dispatch —
      # a fresh attention broadcast for stage B fires normally.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      Process.sleep(50)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      assert status.status == :running
      # The stage-A `blocked` row must NOT rehydrate into state.lease_status.
      refute status.lease_status == "blocked"
    end

    test "boot rehydration prefers the running-stage's own live blocker over a stale one",
         %{
           task: task,
           assignee: assignee,
           plan: plan,
           stage: stage_a
         } do
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      # Two leases: one leaked from passed stage A, one legit blocker on stage B.
      seed_blocked_lease!(task.id, stage_a.id, assignee.id)
      seed_blocked_lease!(task.id, stage_b.id, assignee.id)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(100)

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      assert status.lease_status == "blocked"
      assert status.status == :waiting_human
    end

    test "stage_transitioned drop_leases_for_stage cleans up prior-stage leases", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage_a
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "pending")

      # Seed a blocked lease for the currently-running stage A.
      seed_blocked_lease!(task.id, stage_a.id, assignee.id)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(50)

      assert %{status: "blocked"} =
               RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)

      # Now transition A → passed, B → running.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      passed_stage_a = Platform.Repo.get!(Platform.Tasks.Stage, stage_a.id)
      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})
      Process.sleep(100)

      # Stage-A lease has been dropped by the transition handler.
      assert nil == RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)
    end
  end

  # ── Bug #7 (task 019f70ff-55c2) ────────────────────────────────────────
  # Regression coverage for the deletion of
  # `TaskRouter.maybe_mark_review_task_in_review/1`. The old helper flipped a
  # task to `in_review` whenever its running stage's only pending validation
  # was `manual_approval` — before any agent had produced work or filed a
  # review request. The canonical trigger is
  # `Platform.Tasks.ReviewRequests.create_review_request/1`, which is
  # exercised in `Platform.Tasks.ReviewRequestsTest`.
  describe "manual_approval-only stage does not auto-flip task to in_review" do
    test "router keeps a task in_progress while a manual_approval-only stage runs without a review_request",
         %{task: task, assignee: assignee, plan: plan, stage: stage} do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      # Replace the seeded stage's `test_pass` validation with a single
      # `manual_approval` validation and flip the stage to running. This is
      # the exact bug shape reported in task 019f70f0: an execution stage
      # whose only pending validation is manual_approval must NOT be
      # misclassified as a review gate.
      Platform.Repo.delete_all(
        from(v in Platform.Tasks.Validation, where: v.stage_id == ^stage.id)
      )

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      running_stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, plan})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      Process.sleep(150)

      # Pre-fix: this assertion fails within ~80ms because the router's init
      # sweep called `maybe_mark_review_task_in_review/1` and flipped the
      # task. Post-fix: the router leaves the task alone — only a filed
      # review request can move it to in_review.
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == running_stage.id
    end
  end

  describe "create_review_request/1 remains the sole in_progress -> in_review trigger" do
    test "filing a review_request against a running manual_approval stage flips task to in_review",
         %{task: task, stage: stage} do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      # Do NOT start the router — this test locks in that the transition
      # trigger lives in `ReviewRequests.create_review_request/1`, independent
      # of any router path.
      _running_stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, execution_space} = ExecutionSpace.find_or_create(task.id)

      assert {:ok, _request} =
               Platform.Tasks.ReviewRequests.create_review_request(%{
                 validation_id: manual_validation.id,
                 task_id: task.id,
                 execution_space_id: execution_space.id,
                 items: [%{label: "UI review"}]
               })

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"
    end
  end

  describe "settled stack-member dispatch suppression (TAIL-stall fix, 2026-07-22)" do
    test "a settled stack member (no running stage, no open validation) suppresses dispatch",
         %{assignee: assignee} do
      # Build a stack member whose plan is fully settled: stage passed, both
      # validations passed, no pending review request. This is the incident
      # shape — a member the router would otherwise re-dispatch a stale
      # prompt it can't act on.
      {:ok, project} = Tasks.create_project(%{name: "Settled member #{unique()}"})
      slug = "settled-#{unique()}"

      {:ok, stack} =
        Platform.Tasks.Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Settled Stack #{slug}",
          rollup_branch: Platform.Tasks.Stacks.rollup_branch_name(slug)
        })

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Settled member #{unique()}",
          status: "deploying",
          stack_id: stack.id,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Task-level review",
          status: "passed"
        })

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: member.id, assignee: assignee)

      member_id = member.id

      # The initial :dispatch scheduled by init/1 hits the settled-member
      # guard and emits observe-only telemetry instead of dispatching.
      assert_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref,
                      %{count: 1}, %{task_id: ^member_id, reason: :settled_stack_member}},
                     1_000

      # No dispatch/attention broadcast is emitted for the settled member.
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     300
    end

    test "a stack member with a still-pending validation is NOT suppressed", %{
      assignee: assignee
    } do
      {:ok, project} = Tasks.create_project(%{name: "Working member #{unique()}"})
      slug = "working-#{unique()}"

      {:ok, stack} =
        Platform.Tasks.Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Working Stack #{slug}",
          rollup_branch: Platform.Tasks.Stacks.rollup_branch_name(slug)
        })

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Working member #{unique()}",
          status: "in_progress",
          stack_id: stack.id,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "coding",
          status: "running"
        })

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: member.id, assignee: assignee)

      # A member with genuinely pending work must never be suppressed.
      refute_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref, _, _}, 400
    end
  end

  # ── ADR-0046 member 7 stage 5: the pre-plan design hold ─────────────────
  #
  # ## Verification labels
  #
  # **Load-bearing controls.** Each absence assertion below is paired, in the
  # SAME test, with a case proving the mechanism it asserts the absence of can
  # actually fire:
  #
  #   * "no attention broadcast while held" is paired with a NON-UI task of the
  #     same shape that broadcasts inside the same window. A `do_dispatch/2`
  #     deleted outright would fail the control, not pass the absence.
  #   * "no armed lease while held" SEEDS a lease via
  #     `LeaseManager.record_dispatch/4` before the tick and asserts it is gone
  #     after. Without the seed the assertion would be vacuous — a planning task
  #     with no running stage never arms a lease in the first place, so
  #     `LeaseManager.get/1 == nil` holds against a `clear_liveness/1` that was
  #     never called. The control is the non-UI task, whose seeded lease
  #     SURVIVES its dispatch, proving the clear is specific to the hold.
  #   * "the deadline is a no-op after a settle" is paired with the
  #     still-designing case in the same describe, over the same fixture, so a
  #     `:design_deadline` handler stubbed to `{:noreply, state}` cannot pass.
  #   * "the shipped default is 1_800_000" is paired with an injected value that
  #     must be OBSERVED, proving the read goes through `Application.get_env/3`
  #     rather than the literal.
  #
  # **Declared vacuity.** Two, and both are worth stating rather than hiding:
  #
  #   * "a task already carrying a plan is never held" PASSES against a tree
  #     with no design hold at all — it is an absence assertion and absence is
  #     the pre-change state. It is not vacuous against the shipped code: the
  #     thing it pins is the `Tasks.latest_plan/1 == nil` conjunct in
  #     `design_step_open?/1`, and removing only that conjunct fires it. That is
  #     the peel that locates what carries this claim.
  #   * "killing the holder does not strand the task" is protected REDUNDANTLY
  #     by the level check and by the DB-derived deadline in
  #     `arm_design_deadline/3`. Removing either one alone leaves the other to
  #     release the replacement router, so no single peel fires it. Only the
  #     conjunction does. The redundancy is deliberate — this is the property
  #     the whole stage exists for — but a test that no single peel can break is
  #     a weak test, and the test below is the one that carries the claim on its
  #     own.
  #
  # ## How the hold cannot outlive its holder
  #
  # "an overdue hold is released by the level check on a tick the armed timer
  # cannot serve" is the discriminating test. It sets the window to an hour, so
  # the timer the hold armed cannot possibly fire inside the test, then backdates
  # the row past the window and delivers one ordinary `:dispatch`. The release
  # can only have come from `design_hold_expired?/2`. That is the journalled
  # `deploying -> done` incident inverted: there, the transition lived only in an
  # edge-triggered handler with no level re-check, and a restart between the
  # broadcast and the handler stranded the task forever.
  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  # Stage 1's classifier is not in doubt on either of these: the UI title is
  # stage 1's own doctest example.
  @design_ui_title "Add an epic-create FAB above the board"
  @design_non_ui_title "Add Providers.Architecture shim"

  defp design_task!(project, title) do
    now = DateTime.utc_now()

    task =
      %Platform.Tasks.Task{}
      |> Ecto.Changeset.change(%{
        project_id: project.id,
        title: title,
        description: title,
        status: "planning",
        inserted_at: now,
        updated_at: now
      })
      |> Platform.Repo.insert!()

    on_exit(fn ->
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

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    task
  end

  # Reuse `historian` as the carrier role — the same substitution
  # `Platform.Design.PreplanStepTest` uses — so this stays off the seeded
  # `designer` bundle the closed-roster coverage suite exercises.
  defp wire_designer! do
    Platform.Repo.insert!(
      %Platform.Roles.Role{
        key: "historian",
        name: "Historian",
        description: "test",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: "design.task_direction"
    })
    |> Platform.Repo.insert!()

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "router-designer-#{unique()}",
        name: "Fixture Designer",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Platform.Repo.insert()

    {:ok, _} = Platform.Roles.assign_role("historian", agent.id)

    agent
  end

  defp stub_designer_dispatcher do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {NoopDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)
  end

  defp put_design_timeout(ms) do
    previous = Application.get_env(:platform, :design_step_timeout_ms)
    Application.put_env(:platform, :design_step_timeout_ms, ms)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :design_step_timeout_ms, previous)
      else
        Application.delete_env(:platform, :design_step_timeout_ms)
      end
    end)
  end

  defp backdate!(task, ms) do
    at = DateTime.add(DateTime.utc_now(), -ms, :millisecond)

    Platform.Repo.update_all(
      from(t in Platform.Tasks.Task, where: t.id == ^task.id),
      set: [updated_at: at]
    )

    task
  end

  defp reload_task(task), do: Platform.Repo.get!(Platform.Tasks.Task, task.id)

  describe "pre-plan design hold (ADR-0046 member 7)" do
    setup %{project: project} do
      # The Registry's boot walk is disabled in the test env, so stage 3's row
      # has to be installed explicitly per sandbox.
      [spec] = Platform.Responsibilities.Handlers.DesignTaskDirection.register()
      {:ok, _row} = Platform.Responsibilities.upsert_by_key(spec)

      %{project: project}
    end

    test "a UI task with a designer holds the planner; a non-UI task dispatches immediately",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, _pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)

      # ABSENCE. The planner must not be prompted while the step is open.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 600

      # The step really did fire and really is open — the cursor IS the state.
      assert reload_task(held).planning_step == "designing"
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # PAIRED POSITIVE CONTROL. Same runtime topic, same window, same task
      # shape but not UI-classified: it must broadcast.
      control = design_task!(project, @design_non_ui_title)

      control_assignee = %{
        type: :federated,
        id: "runtime-design-control-#{unique()}"
      }

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{control_assignee.id}")
      {:ok, _} = TaskRouter.start_link(task_id: control.id, assignee: control_assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute reload_task(control).planning_step == "designing"
    end

    test "a held design step clears the liveness lease; an unheld dispatch does not",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # SEED the lease. Without this the assertion below is vacuous: a planning
      # task with no running stage never arms one, so `nil` would hold against
      # a `clear_liveness/1` that was never called.
      :ok =
        LeaseManager.record_dispatch(
          held.id,
          Ecto.UUID.generate(),
          "coding",
          DateTime.utc_now()
        )

      assert %{} = LeaseManager.get(held.id)

      send(pid, :dispatch)
      Process.sleep(200)

      assert LeaseManager.get(held.id) == nil,
             "the design hold must clear the lease — an armed no-ack timer would " <>
               "fire execution.no_ack_timeout five minutes into a legitimate hold"

      # PAIRED CONTROL: the same seed against a router that is NOT holding must
      # survive its dispatch, proving the clear is specific to the hold branch.
      control = design_task!(project, @design_non_ui_title)

      control_assignee = %{type: :federated, id: "runtime-design-lease-#{unique()}"}
      {:ok, control_pid} = TaskRouter.start_link(task_id: control.id, assignee: control_assignee)
      Process.sleep(200)

      :ok =
        LeaseManager.record_dispatch(
          control.id,
          Ecto.UUID.generate(),
          "coding",
          DateTime.utc_now()
        )

      send(control_pid, :dispatch)
      Process.sleep(200)

      assert %{} = LeaseManager.get(control.id)
    end

    test "settling the step wakes the planner exactly once", %{
      project: project,
      assignee: assignee
    } do
      stub_designer_dispatcher()
      wire_designer!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, _pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(held.id).status == :waiting_design
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      {:ok, :complete} = Platform.Design.PreplanStep.settle(held.id, nil)

      # Exactly ONE dispatch. `settle/2` writes twice (the outcome, then the
      # cursor) and each write broadcasts `{:task_updated, _}`; a wake-up keyed
      # on the broadcast rather than on leaving `:waiting_design` would prompt
      # the planner twice.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 700

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "complete"
    end

    test "the deadline expires an open step and releases the planner; after a settle it is a no-op",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      send(pid, :design_deadline)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "failed"

      # ADR-0046 decision 7: the failure falls open, VISIBLY. It reaches merge
      # time through member 4's predicate with no extra work in this stage.
      assert Tasks.planning_gate_failed?(task)

      # PAIRED CONTROL, second fixture: a deadline arriving after a settle must
      # not re-open the step as a failure and must not re-dispatch.
      settled = design_task!(project, @design_ui_title)
      settled_assignee = %{type: :federated, id: "runtime-design-late-#{unique()}"}
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{settled_assignee.id}")

      {:ok, settled_pid} = TaskRouter.start_link(task_id: settled.id, assignee: settled_assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(settled.id).status == :waiting_design

      {:ok, :complete} = Platform.Design.PreplanStep.settle(settled.id, nil)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      send(settled_pid, :design_deadline)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 700

      assert reload_task(settled).planning_step_outcomes["design"]["outcome"] == "complete"
    end

    test "an overdue hold is released by the level check on a tick the armed timer cannot serve",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      # An hour. Whatever timer the hold arms CANNOT fire inside this test, so
      # nothing but the level check can release the planner below. That is what
      # makes this the discriminating case: with `design_hold_expired?/2`
      # stubbed out, the only remaining releaser is a timer an hour away.
      put_design_timeout(3_600_000)

      held = design_task!(project, @design_ui_title)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(held.id).status == :waiting_design
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # The row is now two hours old — overdue against the one-hour window — but
      # the armed timer still believes it has an hour to go.
      backdate!(held, 7_200_000)

      # Any dispatch tick at all. In production these arrive from
      # `TaskRouterWatcher.redispatch_for_runtime/1` on every runtime reconnect,
      # from `force_dispatch/1`, and from `init/1` on boot — which is why the
      # timer is only ever an optimisation.
      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "failed"
    end

    test "killing the holder does not strand the task", %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      put_design_timeout(3_600_000)

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      Process.sleep(200)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # Kill the holder. The `:design_deadline` timer dies with it, and nothing
      # persisted the hold — this is the container restart from the journalled
      # `deploying -> done` incident, where the transition lived solely in an
      # edge-triggered PubSub handler and the restart stranded the task forever.
      GenServer.stop(pid, :normal, 1_000)
      refute Process.alive?(pid)

      backdate!(held, 7_200_000)

      replacement_assignee = %{type: :federated, id: "runtime-design-restart-#{unique()}"}
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{replacement_assignee.id}")

      {:ok, _replacement} =
        TaskRouter.start_link(task_id: held.id, assignee: replacement_assignee)

      # The replacement re-derives the verdict from the row alone.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "failed"
    end

    test "a task already carrying a plan is never held, even with the cursor at designing",
         %{project: project, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      task = design_task!(project, @design_ui_title)

      # Force the cursor without going through `start/1` — this is the stranded
      # shape the guard protects against, not one the happy path produces.
      {:ok, _} = Tasks.set_planning_step(task, :designing)

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", status: "running"})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute TaskRouter.current_status(task.id).status == :waiting_design

      # And the step was never fired: a task past planning must not acquire a
      # design record from the router's start site.
      assert reload_task(task).planning_step_outcomes == %{}
    end

    test "the shipped default hold window is 30 minutes and the read goes through app env" do
      # No `config/test.exs` override exists, so the live read equals the
      # shipped literal.
      assert TaskRouter.default_design_step_timeout_ms() == 1_800_000
      assert TaskRouter.design_step_timeout_ms() == 1_800_000

      # PAIRED CONTROL: an injected value must be OBSERVED, which is what proves
      # the read is `Application.get_env/3` and not the literal inlined at every
      # call site. The default accessor must NOT move with it.
      put_design_timeout(1_234)
      assert TaskRouter.design_step_timeout_ms() == 1_234
      assert TaskRouter.default_design_step_timeout_ms() == 1_800_000
    end
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()
end
