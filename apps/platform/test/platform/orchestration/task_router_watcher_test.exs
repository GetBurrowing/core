defmodule Platform.Orchestration.TaskRouterWatcherTest do
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.{TaskRouter, TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Tasks

  # Allow dynamically spawned TaskRouter GenServers to share the test sandbox.
  # We need to set this before any routers start, so we do it in setup.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    # Task 019fb978 stage 2: the watcher is no longer a globally-supervised
    # singleton in test (`:start_task_router_watcher`, config/test.exs), so
    # this file starts its own. Started AFTER the shared-mode switch — that
    # switch checks the connection back in and drops every allowance derived
    # from it, so a watcher started before it would run `boot_reconcile/0`
    # against a connection about to be revoked.
    #
    # ExUnit terminates supervised children before any `on_exit/2` callback
    # runs, so this instance dies while DataCase's sandbox owner is still
    # alive — the ordering the global singleton could never offer.
    start_supervised!(TaskRouterWatcher)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Watcher Test Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/watcher"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Watcher Test Task",
        description: "Used by watcher tests"
      })

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, _stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", description: "Work"})

    on_exit(fn ->
      stop_router_if_running(task.id)
    end)

    %{project: project, task: task}
  end

  # ── should_run?/1 ─────────────────────────────────────────────────────

  describe "should_run?/1" do
    test "returns true for agent-assigned task in planning" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "planning"}
      assert TaskRouterWatcher.should_run?(task) == true
    end

    test "returns true for agent-assigned task in in_progress" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "in_progress"}
      assert TaskRouterWatcher.should_run?(task) == true
    end

    test "returns true for agent-assigned task in in_review" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "in_review"}
      assert TaskRouterWatcher.should_run?(task) == true
    end

    test "returns false for done task" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "done"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns false for blocked task" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "blocked"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    # ADR 0041 stack lifecycle: stack_pending tasks must be invisible to
    # the dispatcher. The dispatch gate (`Stacks.unblocked_in_stack?/1` +
    # `Stacks.try_promote/1`) is the only path out of stack_pending; the
    # watcher must NEVER spin a router for one.
    test "returns false for stack_pending task (ADR 0041 dispatch gate)" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "stack_pending"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns false for backlog task" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "backlog"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns false for task without agent assignee (nil assignee_id)" do
      task = %{assignee_type: "agent", assignee_id: nil, status: "in_progress"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns false for task with non-agent assignee_type" do
      task = %{assignee_type: "user", assignee_id: "some-uuid", status: "in_progress"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns false for task with nil assignee_type" do
      task = %{assignee_type: nil, assignee_id: nil, status: "in_progress"}
      assert TaskRouterWatcher.should_run?(task) == false
    end

    # Stage 4: a soft-deleted task is gone from the dispatch queue even
    # if its other fields would otherwise qualify (active status + agent
    # assignee). This was the root cause of the two ghost routers in
    # task 019e24ac — the watcher kept rebooting them on every reconcile.
    test "returns false for soft-deleted task with otherwise-active fields" do
      task = %{
        assignee_type: "agent",
        assignee_id: "some-uuid",
        status: "in_progress",
        deleted_at: DateTime.utc_now()
      }

      assert TaskRouterWatcher.should_run?(task) == false
    end

    test "returns true for live task carrying an explicit nil deleted_at" do
      task = %{
        assignee_type: "agent",
        assignee_id: "some-uuid",
        status: "in_progress",
        deleted_at: nil
      }

      assert TaskRouterWatcher.should_run?(task) == true
    end

    # Stage 4 + stage 3: `cancelled` is terminal and not in @active_statuses,
    # so the existing status guard already excludes it. Lock that in.
    test "returns false for cancelled task" do
      task = %{assignee_type: "agent", assignee_id: "some-uuid", status: "cancelled"}
      assert TaskRouterWatcher.should_run?(task) == false
    end
  end

  # ── should_run?/1 as the cascade invariant (01a05394 stage 6) ─────────
  #
  # `Stacks.dispatchable_planning_assignee?/2` (stage 1) mirrors this
  # predicate: a stack member whose resolved planning assignee would NOT
  # start a router is treated as unassigned by the planning cascade. These
  # cases pin the exact shape the cascade mirrors — agent-typed AND non-nil
  # id AND active status AND not soft-deleted — one clause per test, so a
  # single dropped guard turns exactly one of them red.

  describe "should_run?/1 — cascade invariant (01a05394)" do
    @active_uuid "01a05394-3bbf-7001-bf10-4a3cc986990c"

    test "agent-typed with a nil assignee_id is not runnable" do
      task = %{assignee_type: "agent", assignee_id: nil, status: "planning"}
      refute TaskRouterWatcher.should_run?(task)
    end

    test "human-typed with a real assignee_id is not runnable" do
      task = %{assignee_type: "human", assignee_id: @active_uuid, status: "planning"}
      refute TaskRouterWatcher.should_run?(task)
    end

    test "agent-typed with a real assignee_id in an active status is runnable" do
      for status <- ["planning", "in_progress", "in_review"] do
        task = %{assignee_type: "agent", assignee_id: @active_uuid, status: status}

        assert TaskRouterWatcher.should_run?(task),
               "expected should_run? to be true for active status #{inspect(status)}"
      end
    end

    test "agent-typed with a real assignee_id in a non-active status is not runnable" do
      for status <- ["backlog", "stack_pending", "blocked", "done", "cancelled"] do
        task = %{assignee_type: "agent", assignee_id: @active_uuid, status: status}

        refute TaskRouterWatcher.should_run?(task),
               "expected should_run? to be false for non-active status #{inspect(status)}"
      end
    end

    test "otherwise-runnable task with a deleted_at timestamp is not runnable" do
      task = %{
        assignee_type: "agent",
        assignee_id: @active_uuid,
        status: "planning",
        deleted_at: ~U[2026-08-30 00:00:00Z]
      }

      refute TaskRouterWatcher.should_run?(task)
    end

    # The map-vs-struct case the function's own comment calls out: a
    # `%Task{}` always carries `:deleted_at`, but the plain maps that some
    # PubSub payloads and helpers use may omit the key entirely. Absent
    # must read as "not deleted", exactly like an explicit nil.
    test "otherwise-runnable map with NO deleted_at key is runnable" do
      task = %{assignee_type: "agent", assignee_id: @active_uuid, status: "planning"}

      refute Map.has_key?(task, :deleted_at)
      assert TaskRouterWatcher.should_run?(task)

      # The same map with the key present-but-nil must agree with key-absent.
      assert TaskRouterWatcher.should_run?(Map.put(task, :deleted_at, nil))
    end
  end

  # ── router_running?/1 ─────────────────────────────────────────────────

  describe "router_running?/1" do
    test "returns false when no router is running" do
      assert TaskRouterWatcher.router_running?("nonexistent-task-id") == false
    end

    test "returns true after a router is started via supervisor", %{task: task} do
      fake_assignee = %{
        type: :federated,
        id: "runtime-watcher-test-#{System.unique_integer([:positive])}"
      }

      {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)

      assert TaskRouterWatcher.router_running?(task.id) == true

      TaskRouterSupervisor.stop_assignment(task.id)
    end
  end

  # ── PubSub-driven start/stop ───────────────────────────────────────────

  describe "task lifecycle event handling" do
    test "watcher starts router when an active agent-assigned task is created", %{task: task} do
      user = create_user()
      agent = create_agent()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "watcher-created-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, _linked_agent} = Federation.link_agent(activated, agent)

      {:ok, created_task} =
        Tasks.update_task(task, %{
          status: "planning",
          assignee_type: "agent",
          assignee_id: agent.id
        })

      assert TaskRouterWatcher.router_running?(task.id) == false

      watcher_pid = Process.whereis(TaskRouterWatcher)
      assert watcher_pid != nil, "TaskRouterWatcher should be running"

      send(watcher_pid, {:task_created, created_task})
      TaskRouterWatcher.sync()

      assert TaskRouterWatcher.router_running?(task.id) == true

      TaskRouterSupervisor.stop_assignment(task.id)
    end

    test "watcher starts router when task transitions to active status with agent assignee",
         %{task: task} do
      # Ensure no router running
      assert TaskRouterWatcher.router_running?(task.id) == false

      # Build a fake task struct with agent assignee and active status.
      # The watcher calls resolve_runtime_for_task which requires a real agent,
      # so we simulate via the supervisor directly, but test the evaluate logic
      # through the watcher by giving it a task that can't resolve (to test graceful failure).
      fake_task =
        Map.merge(task, %{
          assignee_type: "agent",
          assignee_id: "00000000-0000-0000-0000-000000000000",
          status: "planning"
        })

      # Send the task_updated event to the live watcher process
      watcher_pid = Process.whereis(TaskRouterWatcher)
      assert watcher_pid != nil, "TaskRouterWatcher should be running"

      send(watcher_pid, {:task_updated, fake_task})

      # Drain the watcher's mailbox past the broadcast above. This is an exact
      # barrier, not a guess: the `sync/0` reply is issued strictly after the
      # `{:task_updated, ...}` already queued ahead of it has been handled.
      TaskRouterWatcher.sync()

      # No router should be running since the agent UUID doesn't exist
      # (resolve_runtime_for_task returns {:error, :agent_not_found})
      # This verifies graceful handling of resolution failure
      assert TaskRouterWatcher.router_running?(task.id) == false
    end

    test "watcher stops router when task moves to done", %{task: task} do
      fake_assignee = %{
        type: :federated,
        id: "runtime-watcher-stop-#{System.unique_integer([:positive])}"
      }

      # Start a router manually
      {:ok, router_pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Simulate task moved to done
      done_task =
        Map.merge(task, %{
          assignee_type: "agent",
          assignee_id: fake_assignee.id,
          status: "done"
        })

      watcher_pid = Process.whereis(TaskRouterWatcher)
      send(watcher_pid, {:task_updated, done_task})

      # Router should be stopped
      assert_router_stopped(router_pid, task.id)
    end

    test "watcher handles already_started gracefully", %{task: task} do
      fake_assignee = %{
        type: :federated,
        id: "runtime-watcher-dup-#{System.unique_integer([:positive])}"
      }

      # Start a router already
      {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Try starting again via supervisor — should return already_started
      result = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert match?({:error, {:already_started, _}}, result)

      # Cleanup
      TaskRouterSupervisor.stop_assignment(task.id)
    end
  end

  # ── runtime_reconnected follows the PHASE, not the flat pointer ────────
  #
  # Task 019fb977 stage 3. `redispatch_for_runtime/1` needed no change: it
  # decides eligibility with `resolve_runtime_for_task/1`, which stage 2
  # re-pointed at `PhaseRuntime.resolve/1`, so it now pokes routers on behalf
  # of the phase-correct runtime for free. This asserts that rather than
  # trusting the reading. The task's flat pointer names the PLANNING agent
  # (A) while its execution phase names B — so a reconnect for A must be a
  # no-op and a reconnect for B must redispatch. Under the pre-stage-2 watcher
  # the two were exactly inverted.
  describe "runtime_reconnected redispatch (019fb977)" do
    test "reconnecting the EXECUTION-phase runtime redispatches; the planning one does not",
         %{task: task} do
      {agent_a, runtime_a} = create_linked_agent_runtime()
      {agent_b, runtime_b} = create_linked_agent_runtime()

      task =
        task
        |> Ecto.Changeset.change(%{
          status: "in_progress",
          # Flat pointer at the PLANNING agent. It has to be an agent id for
          # `list_should_run_tasks/0` to return the row at all — the point is
          # that it names the WRONG agent.
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => %{"assignee_id" => agent_a.id, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => agent_b.id, "assignee_type" => "agent"}
          }
        })
        |> Repo.update!()

      {:ok, _pid} =
        TaskRouterSupervisor.start_assignment(task.id, %{type: :federated, id: runtime_a})

      # Drain the boot dispatch before subscribing, so every broadcast the
      # assertions below see is attributable to a reconnect.
      # Task 01a00587: `:dispatch` is debounced, so the bare call proves only
      # that a reconcile is SCHEDULED. `sync_router/2` waits for it to run,
      # which is what makes the `refute_received`/`assert_received` below
      # statements about the dispatch rather than about scheduling.
      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_a}")
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_b}")

      watcher = Process.whereis(TaskRouterWatcher)
      assert watcher != nil, "TaskRouterWatcher should be running"

      # The PLANNING agent's runtime reconnects. It owns no current phase of
      # this task, so nothing should be poked.
      send(watcher, {:runtime_reconnected, runtime_a})
      TaskRouterWatcher.sync()
      # Task 01a00587: `:dispatch` is debounced, so the bare call proves only
      # that a reconcile is SCHEDULED. `sync_router/2` waits for it to run,
      # which is what makes the `refute_received`/`assert_received` below
      # statements about the dispatch rather than about scheduling.
      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      # Two exact barriers, not a sleep: `sync/0` returns only after the
      # watcher handled the reconnect, and `current_status/1` only after the
      # router handled any `:dispatch` that reconnect could have sent. So an
      # untimed `refute_received` is a complete statement.
      refute_received %Phoenix.Socket.Broadcast{event: "attention"},
                      "a reconnect from the PLANNING-phase runtime redispatched a task whose " <>
                        "current phase belongs to another agent"

      # The EXECUTION agent's runtime reconnects — this one owns the phase.
      send(watcher, {:runtime_reconnected, runtime_b})
      TaskRouterWatcher.sync()
      # Task 01a00587: `:dispatch` is debounced, so the bare call proves only
      # that a reconcile is SCHEDULED. `sync_router/2` waits for it to run,
      # which is what makes the `refute_received`/`assert_received` below
      # statements about the dispatch rather than about scheduling.
      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      assert_received %Phoenix.Socket.Broadcast{
                        event: "attention",
                        topic: "runtime:" <> ^runtime_b
                      },
                      "the execution-phase runtime reconnected and no redispatch followed"

      TaskRouterSupervisor.stop_assignment(task.id)
    end
  end

  # ── A needs_human hold has no clock (task 01a0665e stage 2) ────────────
  #
  # `redispatch_for_runtime/1` filters on `active_lease_present?/2`. Under
  # 01a04a8c that read `expires_at`, so once the 12-hour horizon passed a
  # `needs_human` hold read as "no lease" and a runtime reconnect re-sent the
  # whole dispatch the executor had already refused (01a04fbc-1e71).
  describe "runtime_reconnected against a needs_human hold (01a0665e)" do
    test "a reconnect does not re-dispatch a task whose needs_human lease is 13 hours old",
         %{task: task} do
      {agent, runtime} = create_linked_agent_runtime()

      task =
        task
        |> Ecto.Changeset.change(%{
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent",
          phase_assignees: %{
            "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })
        |> Repo.update!()

      # The hold keys on the RUNNING stage.
      stage =
        Repo.one!(
          from(s in Platform.Tasks.Stage, where: s.plan_id in subquery(plan_ids(task.id)))
        )
        |> Ecto.Changeset.change(status: "running", started_at: DateTime.utc_now())
        |> Repo.update!()

      {:ok, _pid} =
        TaskRouterSupervisor.start_assignment(task.id, %{type: :federated, id: runtime})

      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      {:ok, event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => runtime,
          "event_type" => "execution.blocked",
          "occurred_at" => DateTime.add(DateTime.utc_now(), -13 * 60 * 60, :second),
          "payload" => %{
            "stage_id" => stage.id,
            "description" => "Needs a human to decide how this task deploys.",
            "needs_human" => true,
            "reported_by" => "agent"
          }
        })

      lease = Repo.get!(Platform.Orchestration.ExecutionLease, event.lease_id)
      assert lease.status == "blocked"
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :lt

      # Drain the router's reaction to the event before subscribing, so
      # every broadcast below is attributable to a reconnect.
      :ok = sync_router(task.id)
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime}")
      watcher = Process.whereis(TaskRouterWatcher)

      # The watcher's OWN verdict, not the router's: the router carries its
      # own needs_human guard in `do_dispatch/3`, which would absorb a
      # `:dispatch` the watcher wrongly sent and leave `refute_received`
      # green against a broken filter. The "re-dispatched N task(s)" line is
      # written by `redispatch_for_runtime/1` alone.
      log =
        with_info_logging(fn ->
          send(watcher, {:runtime_reconnected, runtime})
          TaskRouterWatcher.sync()
          :ok = sync_router(task.id)
          assert %{task_id: _} = TaskRouter.current_status(task.id)
        end)

      refute log =~ "re-dispatched",
             "the watcher re-poked a router whose executor filed a needs_human blocker 13h ago"

      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
      assert Repo.get!(Platform.Orchestration.ExecutionLease, lease.id).status == "blocked"

      # CONTROL on the injector: with the stage's leases dropped (what a
      # stage transition does) the SAME reconnect DOES re-dispatch.
      1 = Platform.Orchestration.RuntimeSupervision.drop_leases_for_stage(task.id, stage.id)

      log =
        with_info_logging(fn ->
          send(watcher, {:runtime_reconnected, runtime})
          TaskRouterWatcher.sync()
          :ok = sync_router(task.id)
          assert %{task_id: _} = TaskRouter.current_status(task.id)
        end)

      assert log =~ "re-dispatched 1 task(s)"

      assert_received %Phoenix.Socket.Broadcast{
                        event: "attention",
                        topic: "runtime:" <> ^runtime
                      },
                      "the hold was dropped and the reconnect still did not re-dispatch"

      TaskRouterSupervisor.stop_assignment(task.id)
    end
  end

  # ── Reconciliation ─────────────────────────────────────────────────────

  describe "reconciliation" do
    test "reconcile message is handled without crashing the watcher" do
      watcher_pid = Process.whereis(TaskRouterWatcher)
      assert watcher_pid != nil

      # Send a reconcile message and verify watcher is still alive.
      #
      # `sync/0` is both the barrier and half the assertion here: it can only
      # return once `:reconcile` has been handled, and it exits (failing the
      # test) if the watcher died handling it. The `alive?` check below is the
      # explicit statement of intent.
      send(watcher_pid, :reconcile)
      TaskRouterWatcher.sync()

      assert Process.alive?(watcher_pid)
    end

    test "reconcile stops orphaned routers (router running but task not in active status)", %{
      task: task
    } do
      fake_assignee = %{
        type: :federated,
        id: "runtime-orphan-#{System.unique_integer([:positive])}"
      }

      # Start a router for a task that is in backlog (not active status)
      # The task is in "backlog" by default after creation, so it's an orphan
      {:ok, router_pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Trigger reconciliation
      watcher_pid = Process.whereis(TaskRouterWatcher)
      send(watcher_pid, :reconcile)

      # Orphaned router should be stopped since task is in backlog
      assert_router_stopped(router_pid, task.id)
    end

    # Stage 4: this is the regression test for the "ghost router"
    # leak. Before stage 4, list_should_run_tasks/0 ignored
    # `deleted_at`, so the watcher kept rebooting routers for tasks
    # that the UI had soft-deleted weeks earlier (see ghost task ids
    # 019df569-028c-704a-acb4-00b7d096f430 and
    # 019df569-6051-7fa9-a638-9bc88dcce694 in the audit).
    test "reconcile stops orphaned routers for soft-deleted tasks (ghost-router leak)", %{
      task: task
    } do
      fake_assignee = %{
        type: :federated,
        id: "runtime-ghost-#{System.unique_integer([:positive])}"
      }

      # Put the task into a state that would normally keep its router alive:
      # active status (in_progress) and an agent assignee.
      {:ok, active} =
        Tasks.update_task(task, %{
          status: "in_progress",
          assignee_type: "agent",
          assignee_id: Ecto.UUID.generate()
        })

      {:ok, router_pid} = TaskRouterSupervisor.start_assignment(active.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(active.id) == true

      # Soft-delete the task directly via Repo so we exercise the
      # watcher's DB query path (not the synchronous teardown in
      # soft_delete_task/1, which is tested separately in task_test.exs).
      Repo.update_all(
        from(t in Platform.Tasks.Task, where: t.id == ^active.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      # Router is still running (we bypassed the synchronous teardown
      # path), so reconcile must catch it.
      assert TaskRouterWatcher.router_running?(active.id) == true

      watcher_pid = Process.whereis(TaskRouterWatcher)
      send(watcher_pid, :reconcile)

      assert_router_stopped(router_pid, active.id)
    end

    # Stage 6: parallel of the soft-deleted reconcile sweep above, but for
    # the `cancelled` terminal status. Stage 4 covered the inline teardown
    # path (transition_task_status -> cancelled stops the router
    # synchronously); this test exercises the FALLBACK reconcile path for
    # rows that landed in `cancelled` without going through the inline
    # teardown (e.g. the cleanup_ghost_tasks Mix task batch-updates rows
    # via `Repo.update_all`, which bypasses the broadcast hook the watcher
    # listens on, so the next reconcile is what actually retires the
    # router). Without the cancelled predicate in list_should_run_tasks
    # these would loop indefinitely.
    test "reconcile stops orphaned routers for cancelled tasks (terminal-status leak)", %{
      task: task
    } do
      fake_assignee = %{
        type: :federated,
        id: "runtime-cancelled-reconcile-#{System.unique_integer([:positive])}"
      }

      # Active state with an agent assignee — this is what would normally
      # keep the router alive across reconcile sweeps.
      {:ok, active} =
        Tasks.update_task(task, %{
          status: "in_progress",
          assignee_type: "agent",
          assignee_id: Ecto.UUID.generate()
        })

      {:ok, router_pid} = TaskRouterSupervisor.start_assignment(active.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(active.id) == true

      # Flip the row to `cancelled` directly via Repo so we bypass the
      # synchronous teardown path in transition_task_status/2 and exercise
      # the reconcile sweep instead.
      Repo.update_all(
        from(t in Platform.Tasks.Task, where: t.id == ^active.id),
        set: [status: "cancelled"]
      )

      # Router is still running (we bypassed the broadcast hook), so
      # reconcile must catch it.
      assert TaskRouterWatcher.router_running?(active.id) == true

      watcher_pid = Process.whereis(TaskRouterWatcher)
      send(watcher_pid, :reconcile)

      assert_router_stopped(router_pid, active.id)
    end
  end

  # ── Stage 4 synchronous teardown (soft-delete + cancel) ────────────────
  #
  # The two paths that retire a task from the dispatch queue —
  # `Tasks.soft_delete_task/1` and `Tasks.transition_task_status/2`
  # with new_status == "cancelled" — must stop the running TaskRouter
  # synchronously so the task is gone from `Registry` immediately,
  # not on the next 5-minute reconcile sweep. Lives in this file
  # (not task_test.exs) because TaskRouterSupervisor is a singleton
  # that's incompatible with task_test.exs's async: true configuration.

  describe "synchronous router teardown (stage 4)" do
    test "soft_delete_task/1 stops the running router inline", %{task: task} do
      fake_assignee = %{
        type: :federated,
        id: "runtime-soft-delete-router-#{System.unique_integer([:positive])}"
      }

      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Let the router's :dispatch tick finish before we yank the task out
      # from under it — otherwise its in-flight Repo work outlives the test
      # pid and orphans a sandbox connection, crashing the next test in the
      # file. `current_status/1` is the exact barrier for that: `init/1`
      # enqueues `:dispatch` before `start_assignment/2` returns, and a pure
      # `GenServer.call` is answered strictly after every message already in
      # the mailbox is handled.
      # Task 01a00587: `:dispatch` is debounced, so the bare call proves only
      # that a reconcile is SCHEDULED. `sync_router/2` waits for it to run,
      # which is what makes the `refute_received`/`assert_received` below
      # statements about the dispatch rather than about scheduling.
      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      assert {:ok, _} = Tasks.soft_delete_task(task)

      # `soft_delete_task/1` must stop the router INLINE, not leave it for the
      # reconcile sweep. The sweep is on a 5-minute timer, so nothing this
      # bounded poll can observe is attributable to it.
      assert_router_stopped(pid, task.id)
    end

    test "transition to 'cancelled' stops the running router inline", %{project: project} do
      # Create a task already in an @active_status (planning) so we
      # can transition it directly to cancelled in one step. Going
      # through a chain of transitions broadcasts intermediate
      # task_updated events to the watcher and races the test.
      {:ok, planning_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Cancellable",
          status: "planning"
        })

      fake_assignee = %{
        type: :federated,
        id: "runtime-cancel-router-#{System.unique_integer([:positive])}"
      }

      {:ok, pid} = TaskRouterSupervisor.start_assignment(planning_task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(planning_task.id) == true

      # See note in soft_delete test above — drain the router's :dispatch tick
      # before yanking the task.
      assert %{task_id: _} = TaskRouter.current_status(planning_task.id)

      assert {:ok, cancelled} = Tasks.transition_task_status(planning_task, "cancelled")
      assert cancelled.status == "cancelled"

      # Inline, not on the 5-minute reconcile sweep.
      assert_router_stopped(pid, planning_task.id)
    end

    test "non-cancellation transitions leave the router alone", %{task: task} do
      # Sanity check: the teardown is gated on new_status == 'cancelled'.
      fake_assignee = %{
        type: :federated,
        id: "runtime-keep-router-#{System.unique_integer([:positive])}"
      }

      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # See note in soft_delete test above — drain the router's :dispatch tick
      # before transitioning.
      # Task 01a00587: `:dispatch` is debounced, so the bare call proves only
      # that a reconcile is SCHEDULED. `sync_router/2` waits for it to run,
      # which is what makes the `refute_received`/`assert_received` below
      # statements about the dispatch rather than about scheduling.
      :ok = sync_router(task.id)
      assert %{task_id: _} = TaskRouter.current_status(task.id)

      assert {:ok, _} = Tasks.transition_task_status(task, "planning")

      # The transition broadcasts `{:task_updated, ...}`; drain the watcher
      # past it so "still running" is a statement about a watcher that has
      # SEEN the transition, not one that has not got to it yet. Without this
      # barrier the assertion below passes for the wrong reason — which is the
      # vacuity a fixed sleep was hiding here too.
      TaskRouterWatcher.sync()

      assert TaskRouterWatcher.router_running?(task.id) == true,
             "non-cancellation transitions must leave the router alone"

      # Cleanly stop and wait so we don't leak the sandbox connection
      # to the next test (see note in soft_delete test above).
      TaskRouterSupervisor.stop_assignment(task.id)
      assert_router_stopped(pid, task.id)
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp plan_ids(task_id) do
    from(p in Platform.Tasks.Plan, where: p.task_id == ^task_id, select: p.id)
  end

  # `config :logger, level: :warning` in test drops the info line
  # `redispatch_for_runtime/1` writes before `capture_log/2` can see it.
  defp with_info_logging(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "watcher_test_#{System.unique_integer([:positive])}@example.com",
      name: "Watcher Test User",
      oidc_sub: "oidc-watcher-test-#{System.unique_integer([:positive])}"
    })
  end

  # An agent linked to its own activated runtime — the only shape
  # `PhaseRuntime.resolve/1` can follow all the way to a runtime id.
  defp create_linked_agent_runtime do
    user = create_user()
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "watcher-phase-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "watcher-agent-#{System.unique_integer([:positive])}",
      name: "Watcher Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # Wait for a router to actually die, rather than sleeping a magic number and
  # hoping (tasks 019fa06a + 019fa003).
  #
  # `TaskRouter` now traps exits, so a supervisor-driven stop runs `terminate/2`
  # — which does real DB work (`ExecutionSpace.post_log/2` + `archive/1`) before
  # the process exits. Teardown is therefore legitimately slower than it was
  # when the router was killed outright, and the fixed `Process.sleep(100)` /
  # `Process.sleep(300)` these call sites used became marginal under load
  # (measured: 5 of 10 runs failing here, vs 2 of 10 before the trap_exit
  # change). Monitoring the pid removes the race instead of widening the sleep.
  #
  # Two halves, and both are load-bearing:
  #
  #   1. A monitor + `:DOWN`. This pins actual process death. It is exact —
  #      there is no timing guess in it — and it still fails loudly if the
  #      router never stops at all.
  #   2. A poll on `router_running?/1`. This one CANNOT be replaced by a
  #      barrier: `router_running?/1` is a `Registry.lookup`, and the Registry
  #      unregisters off its OWN independent monitor of the router. Our `:DOWN`
  #      and the Registry's are unordered messages, so the registry entry
  #      routinely outlives the process by a scheduler hop. Asserting once
  #      immediately after `:DOWN` is itself a race.
  #
  # The generalisation, worth carrying past this file: a `:DOWN` means the
  # process died, NOT that every registry, ETS table or supervisor bookkeeping
  # keyed on it has caught up. Anything reading derived state after a death
  # must poll.
  #
  # `Process.monitor/1` on an already-dead pid delivers `:DOWN` with reason
  # `:noproc` immediately, so this is safe to call after the router has gone.
  #
  # Merge note (task 019fa121): task 019fa06a (commit f1d39849) and task
  # 019fa003 arrived at this same monitor+poll shape independently. Both sides
  # are kept: 019fa06a's trap_exit rationale above, and 019fa003's body, which
  # is expressed on the shared `Platform.AsyncAssertions.eventually/3` so there
  # is one polling idiom in the tree rather than two. 019fa06a's local
  # `wait_until_unregistered/2` (its own `Process.sleep(10)` poll loop) is
  # dropped as the duplicate idiom; it had no other callers.
  defp assert_router_stopped(pid, task_id, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])

        flunk("""
        Router #{inspect(pid)} for task #{task_id} was still alive after #{timeout}ms.

        Global state for that task right now:
          Registry.lookup/2:  #{inspect(Registry.lookup(Platform.Orchestration.Registry, task_id))}
          Process.info/2:     #{inspect(Process.info(pid, [:status, :message_queue_len, :current_function]))}
        """)
    end

    case eventually(fn -> TaskRouterWatcher.router_running?(task_id) == false end, timeout) do
      {:ok, _} ->
        :ok

      {:timeout, _} ->
        flunk("""
        Router process #{inspect(pid)} for task #{task_id} exited, but its Registry entry \
        never cleared within #{timeout}ms.

        Registry.lookup/2: #{inspect(Registry.lookup(Platform.Orchestration.Registry, task_id))}
        """)
    end
  end

  defp stop_router_if_running(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
