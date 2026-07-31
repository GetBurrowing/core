defmodule Platform.Orchestration.TaskRouterWatcherBoundaryTest do
  @moduledoc """
  Tests for the sandbox precondition at the `TaskRouterWatcher` broadcast
  boundary, and for `sync/0`.

  ## Two rules this file follows

  **1. No absence-only assertions.** Every expected drop is asserted
  positively, on the `SandboxGuard.dropped_event/0` telemetry, carrying the id
  of the thing that was dropped. A test that only checks "no router started"
  passes just as happily when the broadcast never arrived at all — which is
  precisely how this defect stayed invisible behind a flake label.

  **2. Every guard has a positive control.** A precondition that dropped
  *everything* would satisfy all of the negative assertions here while
  breaking production. So each drop test is paired with a test that drives the
  same code path with a row the watcher *can* see, and asserts the work
  actually happened.

  ## Why the modes differ per test

  `Platform.DataCase` puts every `async: false` module in `{:shared, self()}`
  mode, and under shared mode a process without explicit ownership falls back
  to the test's connection — so an *unowned* watcher, which precondition A
  exists to detect, cannot exist. Those tests are tagged `:manual_sandbox` and
  flip to manual mode in `setup`, before any fixture, because switching modes
  checks the shared connection back IN and rolls back anything written on it.

  The trade-off runs the other way for a real `TaskRouter`: it does Repo work
  in `init/1`, so it can only start under shared mode, where it inherits the
  test's connection. Hence the split — precondition mechanics are exercised in
  manual mode against a supervised stub, and the end-to-end "a legitimate
  broadcast still starts a real router" control runs in shared mode.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation

  alias Platform.Orchestration.{
    SandboxGuard,
    TaskRouter,
    TaskRouterSupervisor,
    TaskRouterWatcher
  }

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Types.UUIDv7

  # A supervised, Registry-registered stand-in for a TaskRouter that does no
  # Repo work at all.
  #
  # The property under test on the stop branch is "did the watcher terminate a
  # supervised process registered under this task id" — nothing about what a
  # real TaskRouter does once alive. A real one cannot start in manual mode
  # (its `init/1` calls `ExecutionSpace.find_or_create/1`), and a bare
  # `Registry.register/3` from a spawned process would NOT do: `stop_assignment/1`
  # would find the pid, hand it to `terminate_child/2`, get `{:error, :not_found}`
  # because it is not a child of the supervisor, and the test could no longer
  # tell a guarded broadcast apart from an unguarded one. A real child of the
  # real supervisor can be terminated, so its survival is meaningful.
  defmodule StubRouter do
    @moduledoc false
    use GenServer

    def start_link(task_id) do
      GenServer.start_link(__MODULE__, task_id,
        name: {:via, Registry, {Platform.Orchestration.Registry, task_id}}
      )
    end

    @impl true
    def init(task_id), do: {:ok, task_id}
  end

  setup tags do
    # Task 019fb978 stage 2: the watcher is gated off in test
    # (`:start_task_router_watcher`, config/test.exs) because the global
    # singleton raised 145 sandbox-ownership violations per full-suite run by
    # servicing broadcasts on connections belonging to already-finished tests.
    # This file owns its watcher for the duration of one test instead.
    #
    # Started BEFORE the mode switch below, deliberately: the switch checks
    # the shared connection back in and drops every allowance derived from
    # it, which is what makes the `Sandbox.allow/3` assertion below return
    # `:ok` rather than `{:already, :allowed}` — and what leaves the watcher
    # genuinely unowned on the `:unowned_watcher` branch.
    watcher = start_supervised!(TaskRouterWatcher)

    if tags[:manual_sandbox] do
      # Order matters: the mode switch checks the shared connection back in
      # (rolling back anything written on it) and drops every allowance
      # derived from it, so it has to happen before the checkout, the
      # allowance, and every fixture.
      Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo)
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)

      unless tags[:unowned_watcher] do
        # Asserted, not assumed: `{:already, :allowed}` here would mean the
        # watcher is still bound to some other connection and every assertion
        # below would be measuring the wrong thing. Fail loudly instead.
        assert Sandbox.allow(Repo, self(), watcher) == :ok
      end
    else
      Sandbox.mode(Repo, {:shared, self()})
    end

    handler_id = "watcher-boundary-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        SandboxGuard.dropped_event(),
        &__MODULE__.forward_drop/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{watcher: watcher}
  end

  # Only the watcher's own boundary drops are forwarded, and each carries the
  # id it dropped, so an assertion can never be satisfied by some other
  # component's drop. The lower-level `caller: SandboxGuard` events (emitted
  # from inside `connection_owned?/0` and `row_visible?/2`) are deliberately
  # filtered out — they are an implementation detail of the probe, not the
  # boundary decision.
  @doc false
  def forward_drop(_event, _measurements, %{caller: TaskRouterWatcher} = metadata, %{pid: pid}) do
    send(pid, {:watcher_drop, metadata})
  end

  def forward_drop(_event, _measurements, _metadata, _config), do: :ok

  # ── sync/0 ─────────────────────────────────────────────────────────────

  describe "sync/0" do
    @tag :manual_sandbox
    test "returns only after every already-queued broadcast has been handled", %{
      watcher: watcher
    } do
      task_id = UUIDv7.generate()

      send(watcher, {:task_updated, agent_task(task_id, "done")})

      assert TaskRouterWatcher.sync() == :ok

      # `assert_received` — zero timeout, no polling. The watcher is the sole
      # sender of both the telemetry forward and the `:sync` reply, and signal
      # order between a single pair of processes is guaranteed, so the drop is
      # already in this mailbox by the time `sync/0` returns. If `sync/0` did
      # not actually drain (a cast, a no-op), this fails.
      assert_received {:watcher_drop, %{task_id: ^task_id}}
    end

    @tag :manual_sandbox
    test "drains a whole batch of queued broadcasts, not just the first", %{watcher: watcher} do
      ids = for _ <- 1..5, do: UUIDv7.generate()

      Enum.each(ids, &send(watcher, {:task_updated, agent_task(&1, "done")}))

      assert TaskRouterWatcher.sync() == :ok

      Enum.each(ids, fn id ->
        assert_received {:watcher_drop, %{task_id: ^id}},
                        "sync/0 returned before broadcast #{id} was handled"
      end)
    end
  end

  # ── Precondition A: the watcher owns no connection ─────────────────────

  describe "precondition A (connection ownership)" do
    @tag :manual_sandbox
    @tag :unowned_watcher
    test "drops a task broadcast when the watcher owns no sandbox connection", %{
      watcher: watcher
    } do
      task_id = UUIDv7.generate()

      send(watcher, {:task_created, agent_task(task_id, "planning")})
      assert TaskRouterWatcher.sync() == :ok

      assert_received {:watcher_drop, %{task_id: ^task_id, reason: :connection_unowned}}

      # A short-circuits BEFORE B. An unowned watcher must not go on to issue
      # the visibility query — that query would raise, be caught by
      # `guarded/3`, and arrive here as a `:foreign_connection` drop instead.
      # This is the assertion that fails if precondition A is deleted.
      refute_received {:watcher_drop, %{task_id: ^task_id, reason: :foreign_connection}}

      refute TaskRouterWatcher.router_running?(task_id)
      assert Process.alive?(watcher)
    end

    @tag :manual_sandbox
    @tag :unowned_watcher
    test "drops a runtime_reconnected broadcast when the watcher owns no connection", %{
      watcher: watcher
    } do
      runtime_id = "boundary-unowned-#{System.unique_integer([:positive])}"

      send(watcher, {:runtime_reconnected, runtime_id})
      assert TaskRouterWatcher.sync() == :ok

      assert_received {:watcher_drop, %{runtime_id: ^runtime_id, reason: :connection_unowned}}
      refute_received {:watcher_drop, %{runtime_id: ^runtime_id, reason: :foreign_connection}}
      assert Process.alive?(watcher)
    end

    @tag :manual_sandbox
    test "does NOT drop when the watcher does own the connection (positive control)", %{
      watcher: watcher
    } do
      # Same broadcast, same code path, one difference: the watcher is allowed
      # onto this test's connection. Without this control, a precondition that
      # answered `false` unconditionally would satisfy both tests above.
      task = create_task!("Owned-connection control")

      send(watcher, {:task_updated, %{task | status: "done"}})
      assert TaskRouterWatcher.sync() == :ok

      task_id = task.id
      refute_received {:watcher_drop, %{task_id: ^task_id}}
    end
  end

  # ── Precondition B: the row belongs to another connection ──────────────

  describe "precondition B (row visibility)" do
    @tag :manual_sandbox
    test "does not stop a running router for a task whose row it cannot see", %{watcher: watcher} do
      # THE test for this task. The stop branch of `evaluate_task/1` runs
      # `should_run?/1` (pure struct reads), `router_running?/1` (a bare
      # Registry lookup) and `terminate_child/2` — zero Repo calls between the
      # broadcast and the termination. No return-value guard anywhere
      # downstream can reach it; only a precondition at the boundary can.
      task_id = UUIDv7.generate()
      stub = start_registered_stub!(task_id)

      assert TaskRouterWatcher.router_running?(task_id)

      send(watcher, {:task_updated, agent_task(task_id, "done")})
      assert TaskRouterWatcher.sync() == :ok

      # Ordered deliberately: the global-state assertion comes first, so that
      # when this test catches a regression it names the actual damage rather
      # than a missing telemetry event.
      assert Process.alive?(stub),
             "the watcher terminated a supervised router on behalf of a task row it cannot see"

      assert TaskRouterWatcher.router_running?(task_id)

      assert_received {:watcher_drop, %{task_id: ^task_id, reason: :foreign_connection}}
    end

    @tag :manual_sandbox
    test "stops a running router for a task whose row IS visible (positive control)", %{
      watcher: watcher
    } do
      # The same broadcast against a row on this connection. `terminate_child/2`
      # returns after the child has exited, and `sync/0` returns after the
      # watcher has finished handling the broadcast, so this needs no polling.
      task = create_task!("Visible-row stop control")
      assert TaskRouterWatcher.sync() == :ok

      stub = start_registered_stub!(task.id)
      assert TaskRouterWatcher.router_running?(task.id)

      send(watcher, {:task_updated, %{task | status: "done"}})
      assert TaskRouterWatcher.sync() == :ok

      refute Process.alive?(stub),
             "the guard over-blocked: a visible row must still stop its router"

      task_id = task.id
      refute_received {:watcher_drop, %{task_id: ^task_id}}
    end

    @tag :manual_sandbox
    test "drops a runtime_reconnected for a runtime row it cannot see", %{watcher: watcher} do
      runtime_id = "boundary-foreign-#{System.unique_integer([:positive])}"

      send(watcher, {:runtime_reconnected, runtime_id})
      assert TaskRouterWatcher.sync() == :ok

      assert_received {:watcher_drop, %{runtime_id: ^runtime_id, reason: :foreign_connection}}
      assert Process.alive?(watcher)
    end

    @tag :manual_sandbox
    test "does not drop a runtime_reconnected for a visible runtime row (positive control)", %{
      watcher: watcher
    } do
      runtime = register_runtime!()

      send(watcher, {:runtime_reconnected, runtime.runtime_id})
      assert TaskRouterWatcher.sync() == :ok

      runtime_id = runtime.runtime_id
      refute_received {:watcher_drop, %{runtime_id: ^runtime_id}}
      assert Process.alive?(watcher)
    end
  end

  # ── End-to-end: the guard does not over-block a real start ─────────────

  describe "legitimate broadcasts (shared mode, real TaskRouter)" do
    test "an agent-assigned task moving to planning still starts a real router", %{
      watcher: watcher
    } do
      # Shared mode, real fixtures, a real `TaskRouter` child — the production
      # shape end to end. If either precondition were over-eager, this is the
      # test that goes red, which is what stops "drop everything" from being a
      # passing implementation.
      user = create_user()
      agent = create_agent()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "boundary-live-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, _linked} = Federation.link_agent(activated, agent)

      task = create_task!("Live router control")

      {:ok, planning} =
        Tasks.update_task(task, %{
          status: "planning",
          assignee_type: "agent",
          assignee_id: agent.id
        })

      on_exit(fn -> TaskRouterSupervisor.stop_assignment(task.id) end)

      send(watcher, {:task_created, planning})
      assert TaskRouterWatcher.sync() == :ok

      assert TaskRouterWatcher.router_running?(task.id),
             "the sandbox precondition blocked a legitimate router start"

      task_id = task.id
      refute_received {:watcher_drop, %{task_id: ^task_id}}

      # Drain and retire the router before this test's sandbox owner exits.
      # `current_status/1` is a `GenServer.call` and therefore answered only
      # after the `:dispatch` message `init/1` sent to itself has been fully
      # handled — including the preloads it runs — so the router has no
      # in-flight Repo work left to be orphaned. That is what the 100-300ms
      # sleeps elsewhere in this suite are approximating; the call is exact.
      [{router, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
      ref = Process.monitor(router)
      assert %{} = TaskRouter.current_status(task.id)

      :ok = TaskRouterSupervisor.stop_assignment(task.id)
      assert_receive {:DOWN, ^ref, :process, ^router, _reason}, 2_000
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # A payload shaped exactly like the broadcasts `Tasks.broadcast_board/1`
  # emits, for a task id that has no row on any connection.
  defp agent_task(task_id, status) do
    %TaskSchema{
      id: task_id,
      assignee_type: "agent",
      assignee_id: Ecto.UUID.generate(),
      status: status
    }
  end

  defp start_registered_stub!(task_id) do
    spec = %{
      id: {:stub_router, task_id},
      start: {StubRouter, :start_link, [task_id]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(TaskRouterSupervisor, spec)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(TaskRouterSupervisor, pid)
      end
    end)

    pid
  end

  defp create_task!(title) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Watcher Boundary Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/watcher-boundary"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        description: "Used by the watcher boundary tests"
      })

    task
  end

  defp register_runtime! do
    user = create_user()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "boundary-visible-#{System.unique_integer([:positive])}"
      })

    runtime
  end

  defp create_user do
    Repo.insert!(%User{
      email: "watcher_boundary_#{System.unique_integer([:positive])}@example.com",
      name: "Watcher Boundary User",
      oidc_sub: "oidc-watcher-boundary-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "boundary-agent-#{System.unique_integer([:positive])}",
        name: "Watcher Boundary Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end
end
