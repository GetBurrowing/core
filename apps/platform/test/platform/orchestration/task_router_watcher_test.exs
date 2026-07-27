defmodule Platform.Orchestration.TaskRouterWatcherTest do
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.{TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Tasks

  # Allow dynamically spawned TaskRouter GenServers to share the test sandbox.
  # We need to set this before any routers start, so we do it in setup.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

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
      Process.sleep(100)

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

      # Allow processing
      Process.sleep(100)

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

  # ── Reconciliation ─────────────────────────────────────────────────────

  describe "reconciliation" do
    test "reconcile message is handled without crashing the watcher" do
      watcher_pid = Process.whereis(TaskRouterWatcher)
      assert watcher_pid != nil

      # Send a reconcile message and verify watcher is still alive
      send(watcher_pid, :reconcile)
      Process.sleep(200)

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
      ref = Process.monitor(pid)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Let the router's async :dispatch tick finish before we yank the
      # task out from under it — otherwise its inflight Task.Supervised
      # preload work outlives the test pid and orphans a sandbox
      # connection, crashing the next test in the file.
      Process.sleep(150)

      assert {:ok, _} = Tasks.soft_delete_task(task)

      # Wait for the router pid to actually go DOWN before exiting.
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      Process.sleep(100)

      refute TaskRouterWatcher.router_running?(task.id),
             "soft_delete_task/1 must stop the TaskRouter inline, not wait on reconcile"
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
      ref = Process.monitor(pid)
      assert TaskRouterWatcher.router_running?(planning_task.id) == true

      # See note in soft_delete test above — let the router's async
      # :dispatch tick finish before yanking the task.
      Process.sleep(150)

      assert {:ok, cancelled} = Tasks.transition_task_status(planning_task, "cancelled")
      assert cancelled.status == "cancelled"

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      Process.sleep(100)

      refute TaskRouterWatcher.router_running?(planning_task.id),
             "transition to 'cancelled' must stop the TaskRouter inline"
    end

    test "non-cancellation transitions leave the router alone", %{task: task} do
      # Sanity check: the teardown is gated on new_status == 'cancelled'.
      fake_assignee = %{
        type: :federated,
        id: "runtime-keep-router-#{System.unique_integer([:positive])}"
      }

      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      ref = Process.monitor(pid)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # See note in soft_delete test above — let the router's async
      # :dispatch tick finish before transitioning.
      Process.sleep(150)

      assert {:ok, _} = Tasks.transition_task_status(task, "planning")

      assert TaskRouterWatcher.router_running?(task.id) == true,
             "non-cancellation transitions must leave the router alone"

      # Cleanly stop and wait so we don't leak the sandbox connection
      # to the next test (see note in soft_delete test above).
      TaskRouterSupervisor.stop_assignment(task.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      Process.sleep(100)
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp create_user do
    Repo.insert!(%User{
      email: "watcher_test_#{System.unique_integer([:positive])}@example.com",
      name: "Watcher Test User",
      oidc_sub: "oidc-watcher-test-#{System.unique_integer([:positive])}"
    })
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
  # hoping (task 019fa06a).
  #
  # `TaskRouter` now traps exits, so a supervisor-driven stop runs `terminate/2`
  # — which does real DB work (`ExecutionSpace.post_log/2` + `archive/1`) before
  # the process exits. Teardown is therefore legitimately slower than it was
  # when the router was killed outright, and the fixed `Process.sleep(100)` /
  # `Process.sleep(300)` these call sites used became marginal under load
  # (measured: 5 of 10 runs failing here, vs 2 of 10 before the trap_exit
  # change). Monitoring the pid removes the race instead of widening the sleep,
  # and is strictly stronger: it pins actual process death rather than Registry
  # bookkeeping, and still fails if the router never stops at all.
  defp assert_router_stopped(pid, task_id, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        flunk("router for task #{task_id} was still alive after #{timeout}ms")
    end

    # `router_running?/1` is a `Registry.lookup`, and the Registry unregisters
    # off its OWN monitor of the router. Our `:DOWN` and the Registry's are
    # independent messages with no ordering guarantee, so the registry entry
    # routinely outlives the process by a scheduler hop. Poll rather than
    # assert once — this is bookkeeping catching up, not the router refusing to
    # die (the `:DOWN` above already proved it died).
    assert wait_until_unregistered(task_id, timeout),
           "router process for task #{task_id} exited but its Registry entry never cleared"
  end

  defp wait_until_unregistered(task_id, remaining_ms) do
    cond do
      TaskRouterWatcher.router_running?(task_id) == false ->
        true

      remaining_ms <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until_unregistered(task_id, remaining_ms - 10)
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
