defmodule Platform.Orchestration.TaskRouterSupervisorTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.{ExecutionSpace, LeaseManager, TaskRouterSupervisor}
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Supervisor Test Project",
        repo_url: "https://github.com/test/supervisor"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Supervisor Test Task",
        description: "Testing the supervisor"
      })

    assignee = %{type: :federated, id: "runtime-sup-#{System.unique_integer([:positive])}"}

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

    %{project: project, task: task, assignee: assignee}
  end

  describe "start_assignment/2" do
    test "starts a TaskRouter under the supervisor", %{task: task, assignee: assignee} do
      assert {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      assert Process.alive?(pid)
      _ = :sys.get_state(pid)
      TaskRouterSupervisor.stop_assignment(task.id)
    end

    test "returns error if already started", %{task: task, assignee: assignee} do
      assert {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      _ = :sys.get_state(pid)

      assert {:error, {:already_started, _}} =
               TaskRouterSupervisor.start_assignment(task.id, assignee)

      TaskRouterSupervisor.stop_assignment(task.id)
    end
  end

  describe "stop_assignment/1" do
    test "stops a running TaskRouter", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      assert Process.alive?(pid)
      _ = :sys.get_state(pid)

      assert :ok = TaskRouterSupervisor.stop_assignment(task.id)
      refute Process.alive?(pid)
    end

    test "returns error for unknown task" do
      assert {:error, :not_found} = TaskRouterSupervisor.stop_assignment("nonexistent")
    end
  end

  # Task 019fa06a. `stop_assignment/1` goes through
  # `DynamicSupervisor.terminate_child/2`, which sends a raw `:shutdown` EXIT
  # signal. Until `TaskRouter.init/1` started trapping exits, that signal killed
  # the router instantly — wherever it happened to be — with two consequences
  # these tests pin independently:
  #
  #   * `terminate/2` never ran, so `clear_liveness/1` and
  #     `ExecutionSpace.archive/1` were skipped on EVERY supervisor-driven stop.
  #     That is a live production leak (deploy credential leases outliving
  #     their routers), not a test artifact.
  #   * A router killed mid-Ecto-query destroys the DBConnection it holds,
  #     which under the sandbox takes the ownership process with it and leaves
  #     the TEST process raising `DBConnection.OwnershipError` on its next Repo
  #     call — the failure `Mix.Tasks.Platform.CleanupGhostTasksTest` hit.
  describe "stop_assignment/1 teardown safety" do
    test "runs terminate/2 rather than killing the router outright", %{
      task: task,
      assignee: assignee
    } do
      # A plan with a running stage so `do_dispatch/2` actually dispatches and
      # arms a LeaseManager row. Without it `clear_liveness/1` would have
      # nothing to clear and the assertion below would be vacuous.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "coding",
          description: "Write code"
        })

      {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      _ = :sys.get_state(pid)

      # Pre-state: both teardown effects are observably NOT yet applied, so a
      # green run cannot be explained by them having never been needed.
      assert %{stage_id: _} = LeaseManager.get(task.id)
      assert %Platform.Chat.Space{archived_at: nil} = ExecutionSpace.find_by_task_id(task.id)

      # The archive is now gated on the TASK being terminal, not on the
      # shutdown happening (task 019fe9c5 stage 2): `stop_assignment/1` and a
      # node teardown both deliver `:shutdown`, so the reason cannot tell
      # "finished" from "the box went away". This test's subject is that
      # `terminate/2` RAN, and the archive is only its proxy — so put the task
      # in the state where archiving is the correct outcome, and the proxy
      # keeps working. A router stopped on a NON-terminal task must leave the
      # space live; that is asserted in `task_router_test.exs`.
      task
      |> Ecto.Changeset.change(%{status: "done"})
      |> Platform.Repo.update!()

      ref = Process.monitor(pid)
      assert :ok = TaskRouterSupervisor.stop_assignment(task.id)

      # Registry absence is a proxy; process death is the thing.
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      # `clear_liveness/1` and `ExecutionSpace.archive/1` are reachable from
      # `terminate/2` and nowhere else on this path, so both assertions fail if
      # the router was killed instead of shut down.
      assert LeaseManager.get(task.id) == nil

      assert %Platform.Chat.Space{archived_at: %DateTime{}} =
               ExecutionSpace.find_by_task_id(task.id)
    end

    test "leaves the test process's own sandbox connection usable", %{
      task: task,
      assignee: assignee
    } do
      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)

      # Deliberately do NOT drain with `:sys.get_state/1` — the point is to
      # terminate the router while it still has DB work in flight, which is the
      # shape that destroys the shared sandbox connection. `init/1` already
      # queued a `:dispatch`; this second one widens the window.
      send(pid, :dispatch)

      ref = Process.monitor(pid)
      assert :ok = TaskRouterSupervisor.stop_assignment(task.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      # Before the fix this raised `DBConnection.OwnershipError` — "cannot find
      # ownership process ... using mode :manual" — despite DataCase having set
      # `{:shared, self()}`, because the connection had been torn down under us.
      assert is_integer(Platform.Repo.aggregate(Platform.Tasks.Task, :count))
    end
  end

  describe "list_active/0" do
    test "lists active assignments", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)
      # :sys.get_state/1 is synchronous — blocks until the GenServer finishes
      # processing its current message (the initial :dispatch). This prevents
      # sandbox ownership races during teardown.
      _ = :sys.get_state(pid)

      active = TaskRouterSupervisor.list_active()
      assert length(active) >= 1
      assert Enum.any?(active, &(&1.task_id == task.id))

      # Stop explicitly before sandbox teardown
      TaskRouterSupervisor.stop_assignment(task.id)
    end

    test "returns empty list when no assignments" do
      # Stop any leftover assignments first
      for status <- TaskRouterSupervisor.list_active() do
        TaskRouterSupervisor.stop_assignment(status.task_id)
      end

      assert TaskRouterSupervisor.list_active() == []
    end
  end
end
