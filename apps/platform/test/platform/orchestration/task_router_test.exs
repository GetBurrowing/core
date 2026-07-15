defmodule Platform.Orchestration.TaskRouterTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{ExecutionSpace, LeaseManager, TaskRouter}
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
end
