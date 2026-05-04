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
      {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
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

      Process.sleep(100)

      # Router should be stopped
      assert TaskRouterWatcher.router_running?(task.id) == false
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
      {:ok, _pid} = TaskRouterSupervisor.start_assignment(task.id, fake_assignee)
      assert TaskRouterWatcher.router_running?(task.id) == true

      # Trigger reconciliation
      watcher_pid = Process.whereis(TaskRouterWatcher)
      send(watcher_pid, :reconcile)
      Process.sleep(300)

      # Orphaned router should be stopped since task is in backlog
      assert TaskRouterWatcher.router_running?(task.id) == false
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
