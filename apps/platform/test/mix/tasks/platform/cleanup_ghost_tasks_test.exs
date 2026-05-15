defmodule Mix.Tasks.Platform.CleanupGhostTasksTest do
  @moduledoc """
  Tests for the ghost-task cleanup Mix task. Async: false because we
  drive the singleton `TaskRouterSupervisor` and need shared sandbox
  ownership so the live `TaskRouter` GenServers can see the test data.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.CleanupGhostTasks
  alias Platform.Orchestration.{RuntimeSupervision, TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Tasks

  setup do
    # DataCase already sets {:shared, self()} for non-async tests, so
    # we don't need to call Sandbox.mode here. We do still need to
    # explicitly allow the live `TaskRouterWatcher` GenServer to use
    # our sandbox — it reacts to `{:task_updated, ...}` PubSub
    # broadcasts triggered by `Tasks.update_task` and runs its own
    # DB queries; without `allow`, it crashes mid-test under the
    # OwnershipError.
    if pid = Process.whereis(Platform.Orchestration.TaskRouterWatcher) do
      Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, self(), pid)
    end

    {:ok, project} =
      Tasks.create_project(%{
        name: "Cleanup Ghost Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/cleanup"
      })

    started_routers = Agent.start_link(fn -> [] end) |> elem(1)

    on_exit(fn ->
      # Stop any routers tests started so they don't leak across the
      # singleton supervisor into the next test module.
      task_ids =
        try do
          Agent.get(started_routers, & &1)
        catch
          :exit, _ -> []
        end

      for task_id <- task_ids do
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
    end)

    %{project: project, started_routers: started_routers}
  end

  # Start a real TaskRouter under the supervisor. The router is allowed
  # to use this test's sandbox connection so its `init/1` and
  # `terminate/2` Repo calls don't crash the pool when we tear it down
  # mid-test via `stop_assignment`.
  defp start_router(started_routers, task_id, runtime_id) do
    {:ok, pid} =
      TaskRouterSupervisor.start_assignment(task_id, %{type: :federated, id: runtime_id})

    Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, self(), pid)
    Agent.update(started_routers, &[task_id | &1])

    # Give init time to hydrate from the DB before any teardown call.
    Process.sleep(50)
    :ok
  end

  describe "cleanup_one/1" do
    test "absent task: returns :absent and is a no-op", %{project: _project} do
      missing_id = "00000000-0000-7000-8000-000000000099"

      output = capture_io(fn -> assert CleanupGhostTasks.cleanup_one(missing_id) == :absent end)

      assert output =~ "row absent"
      assert TaskRouterWatcher.router_running?(missing_id) == false
    end

    test "live task with no router: cancels and stamps deleted_at", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ghost-style task",
          status: "planning"
        })

      assert task.status == "planning"
      assert is_nil(task.deleted_at)

      output = capture_io(fn -> assert CleanupGhostTasks.cleanup_one(task.id) == :cleaned end)

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "cancelled"
      refute is_nil(reloaded.deleted_at)

      assert output =~ "cancelling"
      assert output =~ "stamped deleted_at"
    end

    test "live task with active router + lease: tears both down", %{
      project: project,
      started_routers: started_routers
    } do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has Router And Lease",
          status: "in_progress"
        })

      runtime_id = "runtime-cleanup-#{System.unique_integer([:positive])}"

      start_router(started_routers, task.id, runtime_id)
      assert TaskRouterWatcher.router_running?(task.id) == true

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => runtime_id,
          "event_type" => "execution.started"
        })

      assert RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id) != nil

      capture_io(fn -> assert CleanupGhostTasks.cleanup_one(task.id) == :cleaned end)

      assert TaskRouterWatcher.router_running?(task.id) == false
      assert RuntimeSupervision.current_lease_for_task_runtime(task.id, runtime_id) == nil

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "cancelled"
      refute is_nil(reloaded.deleted_at)
    end

    test "already cancelled + soft-deleted: returns :already_cleaned without re-mutating",
         %{project: project} do
      # Note: a "residual router" in production is a real `TaskRouter`
      # GenServer started before stage 4's auto-teardown landed. We
      # don't simulate that here because the live `TaskRouter.init/1`
      # self-terminates the moment it sees a cancelled/deleted task,
      # so any router we start in this test would be gone before our
      # assertion ran. The router-stop branch is exercised by the
      # "live task with active router + lease" test above; this test
      # focuses on the no-op idempotency path.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already Cancelled",
          status: "in_progress"
        })

      {:ok, cancelled} = Tasks.transition_task_status(task, "cancelled")
      {:ok, deleted} = Tasks.soft_delete_task(cancelled)
      original_deleted_at = deleted.deleted_at
      assert deleted.status == "cancelled"
      refute is_nil(original_deleted_at)

      output =
        capture_io(fn ->
          assert CleanupGhostTasks.cleanup_one(task.id) == :already_cleaned
        end)

      assert output =~ "already cancelled"
      assert output =~ "sweeping registry only"

      # We did not re-transition or re-stamp anything.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "cancelled"
      assert DateTime.compare(reloaded.deleted_at, original_deleted_at) == :eq
    end

    test "idempotent: second invocation on a freshly-cleaned ghost is a no-op",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Idempotency target",
          status: "planning"
        })

      capture_io(fn -> assert CleanupGhostTasks.cleanup_one(task.id) == :cleaned end)

      first = Tasks.get_task_record(task.id)
      assert first.status == "cancelled"
      first_deleted_at = first.deleted_at
      refute is_nil(first_deleted_at)

      output =
        capture_io(fn ->
          assert CleanupGhostTasks.cleanup_one(task.id) == :already_cleaned
        end)

      assert output =~ "already cancelled"

      second = Tasks.get_task_record(task.id)
      assert second.status == "cancelled"
      assert DateTime.compare(second.deleted_at, first_deleted_at) == :eq
    end
  end

  describe "run/1" do
    test "with --task-id flags, processes only those ids", %{project: project} do
      {:ok, t1} =
        Tasks.create_task(%{project_id: project.id, title: "Run T1", status: "planning"})

      {:ok, t2} =
        Tasks.create_task(%{project_id: project.id, title: "Run T2", status: "planning"})

      output =
        capture_io(fn ->
          # Skip the `app.start` mix step — already started in test env.
          # Calling run/1 directly works because Mix.Task.run/1 is a no-op
          # on already-started apps.
          assert CleanupGhostTasks.run(["--task-id", t1.id, "--task-id", t2.id]) == :ok
        end)

      assert output =~ "processing 2 task id(s)"
      assert Tasks.get_task_record(t1.id).status == "cancelled"
      assert Tasks.get_task_record(t2.id).status == "cancelled"
    end

    test "with no flags, defaults to the hardcoded ghost ids (no-op when absent)" do
      output =
        capture_io(fn ->
          assert CleanupGhostTasks.run([]) == :ok
        end)

      assert output =~ "processing 2 task id(s)"
      # The two hardcoded ghost ids are not present in the test DB, so
      # both must report as absent.
      assert output =~ "row absent"
    end
  end
end
