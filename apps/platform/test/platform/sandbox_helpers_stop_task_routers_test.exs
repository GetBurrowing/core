# Pins `Platform.SandboxHelpers.stop_task_routers_or_warn/1`, the shared-mode
# teardown step that keeps every TaskRouter inside the sandbox owner's
# lifetime (task 01a0d4d6 stage 2).
#
# The leak it closes: a router traps exits and its `terminate/2` writes "Task
# router stopped for task …" through `ExecutionSpace.post_log/2`. A router
# still alive at `Sandbox.stop_owner/1` was mid-query (in `terminate/2`, or in a
# `:dispatch_now` handler), which produced the TASKROUTER events (9/9/7 per
# full run at seeds 77/7700/70007 in the 01a0d265 sweep). No drain could see a
# router: it has no `$callers` link to its test and is not a TaskSupervisor
# child.
#
# `async: false`: the helper is shared-mode only, and routers use this test's
# connection through shared sandbox mode.
defmodule Platform.SandboxHelpersStopTaskRoutersTest do
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat.Message
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.TaskRouterSupervisor
  alias Platform.SandboxHelpers
  alias Platform.Tasks

  defmodule HeldRouter do
    @moduledoc false
    # A router-shaped process under PRIVATE names: it traps exits, registers
    # in a registry, and can be held inside a handler until the test releases
    # it. `terminate/2` reports its reason to the test, which shows whether
    # the process ended through its parent's EXIT or was stopped by someone
    # else.
    use GenServer

    def start_link({registry, key, test}),
      do: GenServer.start_link(__MODULE__, test, name: {:via, Registry, {registry, key}})

    @impl true
    def init(test) do
      Process.flag(:trap_exit, true)
      {:ok, test}
    end

    @impl true
    def handle_info(:hold, test) do
      send(test, {:held, self()})

      receive do
        :release -> :ok
      end

      {:noreply, test}
    end

    @impl true
    def terminate(reason, test) do
      send(test, {:router_terminated, self(), reason})
      :ok
    end
  end

  describe "supervised routers" do
    test "are stopped through the prod path, and terminate/2's log row lands" do
      {:ok, project} = Tasks.create_project(%{name: "Router teardown #{unique()}"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Router teardown"})

      assignee = %{type: :federated, id: "runtime-teardown-#{unique()}"}
      {:ok, pid} = TaskRouterSupervisor.start_assignment(task.id, assignee)

      # BARRIER: init/1 has run (it created the execution space), and the
      # boot dispatch has drained.
      :ok = sync_router(task.id)

      # PRE-state. Without it the "row written" assertion below could pass on
      # a space that never had a router, and "router gone" on one never started.
      assert %{id: space_id} = ExecutionSpace.find_by_task_id(task.id)
      assert Process.alive?(pid)
      assert stopped_rows(space_id, task.id) == 0

      assert :ok = SandboxHelpers.stop_task_routers_or_warn()

      # Not also a Registry lookup: Registry drops the entry when it handles the
      # router's exit, which can land after terminate_child/2 has returned (seen
      # once under load on test-host).
      refute Process.alive?(pid)

      assert stopped_rows(space_id, task.id) == 1,
             "the router is gone but its terminate/2 row is missing: terminate/2 did " <>
               "not run to completion against a live connection"
    end

    test "a router its supervisor has to kill is named in a warning, not hidden" do
      router_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :routers)
      test = self()

      spec = %{
        id: :stuck,
        start: {Agent, :start_link, [fn -> Process.flag(:trap_exit, true) end]},
        shutdown: 50
      }

      {:ok, stuck} = DynamicSupervisor.start_child(router_sup, spec)

      # Hold the process inside a callback, so the shutdown EXIT waits behind
      # it until the supervisor's 50 ms runs out and it is killed.
      spawn(fn ->
        Agent.get(
          stuck,
          fn _ ->
            send(test, :stuck_held)

            receive do
              :never -> :ok
            end
          end,
          :infinity
        )
      end)

      assert_receive :stuck_held

      log =
        capture_log(fn ->
          assert :ok =
                   SandboxHelpers.stop_task_routers_or_warn(
                     supervisor: router_sup,
                     registry: :no_such_registry
                   )
        end)

      refute Process.alive?(stuck)
      assert log =~ "was killed by its supervisor shutdown timeout"
      assert log =~ inspect(stuck)
    end
  end

  describe "routers a test start_link'ed" do
    setup do
      registry = :"held_router_registry_#{unique()}"
      start_supervised!({Registry, keys: :unique, name: registry})
      %{registry: registry}
    end

    test "are waited for while they finish exiting, and never terminated by the helper",
         %{registry: registry} do
      test = self()

      # The parent plays the test process: it links the router, then exits
      # :shutdown, which is how an ExUnit test process ends.
      parent =
        spawn(fn ->
          {:ok, router} = HeldRouter.start_link({registry, "held", test})
          send(test, {:router, router})

          receive do
            :exit -> exit(:shutdown)
          end
        end)

      assert_receive {:router, router}
      send(router, :hold)
      assert_receive {:held, ^router}

      ref = Process.monitor(parent)
      send(parent, :exit)
      assert_receive {:DOWN, ^ref, :process, ^parent, :shutdown}

      helper =
        Task.async(fn ->
          SandboxHelpers.stop_task_routers_or_warn(
            supervisor: :no_such_router_sup,
            registry: registry
          )
        end)

      # The router is inside its handler with its parent's EXIT queued. The
      # helper must still be waiting, not have returned past it.
      assert Task.yield(helper, 100) == nil
      assert Process.alive?(router)

      send(router, :release)

      assert Task.await(helper) == :ok
      refute Process.alive?(router)

      # :shutdown is the parent's EXIT. A router the helper had terminated
      # would not end this way through a DynamicSupervisor it is not a child of,
      # and a kill would skip terminate/2 entirely.
      assert_received {:router_terminated, ^router, :shutdown}
    end

    test "one that never exits is reported after the timeout and left alone",
         %{registry: registry} do
      # Parent stays alive, so the router has no reason to exit.
      {:ok, router} = HeldRouter.start_link({registry, "stays", self()})

      log =
        capture_log(fn ->
          assert :ok =
                   SandboxHelpers.stop_task_routers_or_warn(
                     supervisor: :no_such_router_sup,
                     registry: registry,
                     timeout: 50
                   )
        end)

      assert log =~ "1 task router(s)"
      assert log =~ inspect(router)
      assert log =~ "waited for, not stopped"
      assert Process.alive?(router)
      refute_received {:router_terminated, ^router, _}
    end
  end

  test "is a no-op when neither the supervisor nor the registry is running" do
    assert :ok =
             SandboxHelpers.stop_task_routers_or_warn(
               supervisor: :no_such_router_sup,
               registry: :no_such_registry
             )
  end

  defp stopped_rows(space_id, task_id) do
    content = "Task router stopped for task #{task_id}"

    Repo.aggregate(
      from(m in Message, where: m.space_id == ^space_id and m.content == ^content),
      :count
    )
  end

  defp unique, do: System.unique_integer([:positive])
end
