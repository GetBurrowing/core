defmodule Platform.Regression.TaskRouterWatcherReconnectOwnershipTest do
  @moduledoc """
  Deterministic regression cover for the `{:runtime_reconnected, runtime_id}`
  arm of `Platform.Orchestration.TaskRouterWatcher`.

  Read `test/platform/orchestration/task_router_watcher_sandbox_isolation_test.exs`
  first — its moduledoc states the two-connection technique and the
  anti-vacuity rules, and this file follows them. What is written below is only
  what is *different* here.

  ## The two halves, and why the second one carries the weight

  **Half 1 — no ownership error is raised.** Asserted positively: a named
  `SandboxGuard.dropped_event/0` drop whose metadata carries the `runtime_id`
  in question, so a reconnect that never arrived cannot satisfy it. Backed by
  `Process.monitor/1` + `refute_received {:DOWN, ...}` + `Process.alive?/1`.

  **Half 2 — the watcher's intended effect still occurs.** Half 1 on its own
  is satisfied just as happily by a `handle_runtime_reconnected/1` that returns
  `:ok` and does nothing, which is exactly the failure mode a green suite would
  hide. So `redispatch_for_runtime/1`'s one observable output — the
  `send(pid, :dispatch)` at `task_router_watcher.ex:1013` — is asserted
  directly, through a `StubRouter` that is a real child of the real
  `TaskRouterSupervisor`, registered via
  `{:via, Registry, {Platform.Orchestration.Registry, task_id}}`.

  Half 2's positive assertion is only worth something if the same harness can
  also come back negative, so it is paired with the mirror: the identical
  fixture plus one active `ExecutionLease` for that task/runtime, where
  `active_lease_present?/2` must suppress the dispatch and `refute_received`
  must hold. Positive and mirror run the identical barrier sequence and differ
  by one row. That pairing — not the `refute_received` alone — is what licenses
  the refutation.

  ## Determinism

  Two arms, no sleeps and no polling anywhere.

  * **Arm 1** drives the mailbox directly: `send(watcher, {:runtime_reconnected,
    id})`, then `TaskRouterWatcher.sync/0`. `sync/0` is a `GenServer.call`, so
    it is answered strictly after every message already queued has been
    handled — an exact happens-after edge for the reconnect's full side
    effects. For the dispatch assertions a second edge is chained on:
    `StubRouter.sync/1`, likewise a `GenServer.call`, answered after the
    `:dispatch` in the stub's own mailbox. Because the stub sends
    `{:dispatched, _}` to the test *before* it replies to that call, and
    message order between one sender and one receiver is guaranteed, the
    message is in the test mailbox by the time the call returns. The bound on
    `assert_receive` is a failure-reporting budget, not the ordering mechanism;
    the `refute_received`s in this file carry no timeout at all and would be
    unsound without the barriers above them.

  * **Arm 2** uses the real production fan-out, `Tasks.broadcast_board/1`,
    raised from a genuinely independent sandbox connection. That owner is a
    bare `spawn` calling `Sandbox.checkout/1` itself, never
    `Sandbox.start_owner!/2`: the latter is built on `Agent`, which sets
    `$callers`, so its checkout resolves back to this test's own connection and
    every foreign-connection assertion here would pass vacuously. Barrier is a
    blocking selective receive on the drop telemetry, then `sync/0`.

  Arm 1 alone would exercise the mailbox rather than the defect; arm 2 alone
  could not isolate the callback from the fan-out. Both.

  ## On the supervision snapshot

  `Supervisor.count_children(Platform.Supervisor)` and the
  `Platform.Execution.RunSupervisor` pid are snapshotted around each hostile
  reconnect. This is a **belt, not the mechanism**. Stage 1 of task 019fb978
  hypothesised a `Platform.Supervisor` max-restart cascade (`max_restarts: 3,
  max_seconds: 5`, `application.ex:139`) as the route by which a watcher crash
  reached the Repo-free tests under `test/platform/execution/`. It then
  measured twenty runs and found **zero max-restart terminations and zero
  `:noproc` events** — the cascade candidate is falsified, and the isolated
  flake turned out to be an unrelated shared-`/tmp` collision. The snapshot is
  kept because it costs two function calls and would still catch a *future*
  regression that took the supervisor down, but nothing in this file rests on
  it and it is not what makes any assertion here discriminating.

  ## Why this file starts its own watcher

  Task 019fb978 stage 2 gated the global singleton off in test
  (`:start_task_router_watcher`, `config/test.exs`) and removed it from
  `data_case.ex`'s `supervised_with_repo`, so `Process.whereis(TaskRouterWatcher)`
  is `nil` by default. Starting one per case is what makes the ownership
  scenarios reproducible on demand rather than at the ~1-in-3 rate the flake
  used to appear at. The ordering against the sandbox mode switch in `setup` is
  load-bearing and is commented there.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation

  alias Platform.Orchestration.{
    ExecutionLease,
    SandboxGuard,
    TaskRouterSupervisor,
    TaskRouterWatcher
  }

  alias Platform.Repo
  alias Platform.Tasks

  @registry Platform.Orchestration.Registry

  # Bound on every blocking receive here. Long enough that a loaded box does
  # not produce false failures, short enough that a real regression fails in
  # seconds instead of hanging the suite.
  @receive_timeout 5_000

  # A supervised, Registry-registered stand-in for a `TaskRouter` that does no
  # Repo work, so it can live in manual sandbox mode (a real `TaskRouter` calls
  # `ExecutionSpace.find_or_create/1` in `init/1` and needs shared mode).
  #
  # It is a real child of the real `TaskRouterSupervisor` for the reason the
  # boundary test gives at `task_router_watcher_boundary_test.exs:55-79`: a bare
  # `Registry.register/3` from a spawned process would be found by
  # `stop_assignment/1` and then rejected by `terminate_child/2`, and the test
  # could no longer tell a guarded broadcast from an unguarded one.
  #
  # Unlike the stubs in the two orchestration files, this one has a body: the
  # property under test on THIS branch is that a `:dispatch` actually arrives.
  defmodule StubRouter do
    @moduledoc false
    use GenServer

    def start_link({task_id, test_pid}) do
      GenServer.start_link(__MODULE__, {task_id, test_pid},
        name: {:via, Registry, {Platform.Orchestration.Registry, task_id}}
      )
    end

    @doc "Happens-after barrier: answered only once any queued `:dispatch` has been handled."
    def sync(pid), do: GenServer.call(pid, :sync)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:sync, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_info(:dispatch, {task_id, test_pid} = state) do
      send(test_pid, {:dispatched, task_id})
      {:noreply, state}
    end

    def handle_info(_other, state), do: {:noreply, state}
  end

  setup tags do
    # Task 019fb978 stage 2: the watcher is gated off in test
    # (`:start_task_router_watcher`, config/test.exs), so this file owns one
    # for the duration of a single test.
    #
    # Started BEFORE the mode switch below, deliberately: the switch checks the
    # shared connection back in and drops every allowance derived from it,
    # which is what makes the `Sandbox.allow/3` assertion return `:ok` rather
    # than `{:already, :allowed}` — and what leaves the watcher genuinely
    # unowned on the `:unowned_watcher` branch.
    #
    # The precondition is asserted rather than assumed. On a tree where the
    # gate is absent or `true`, `start_supervised!/1` fails with an opaque
    # `{:already_started, #PID<...>}` child-spec error; this makes the same
    # failure name the actual finding, which is that the ownership scenarios
    # below cannot be CONSTRUCTED while a process outliving the test owns the
    # registered name. That is the hazard stage 2 removed.
    refute Process.whereis(TaskRouterWatcher),
           "a global TaskRouterWatcher is running. It outlives every individual test, so " <>
             "it cannot be given a per-test sandbox connection and this file cannot own " <>
             "one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)"

    watcher = start_supervised!(TaskRouterWatcher)

    # Order matters. The mode switch checks the shared connection back IN
    # (rolling back anything written on it) and drops every allowance derived
    # from it, so it has to happen before the checkout, before the allowance,
    # and before every fixture.
    Sandbox.mode(Repo, :manual)
    :ok = Sandbox.checkout(Repo)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    unless tags[:unowned_watcher] do
      # Asserted, not assumed: `{:already, :allowed}` here would mean the
      # watcher is still bound to some other connection and every assertion
      # below would be measuring the wrong thing.
      assert Sandbox.allow(Repo, self(), watcher) == :ok
    end

    handler_id = "watcher-reconnect-#{System.unique_integer([:positive])}"

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

  # Only the watcher's own boundary decisions are forwarded, each carrying the
  # id it dropped, so an assertion here can never be satisfied by some other
  # component's drop. The lower-level `caller: SandboxGuard` events — emitted
  # from inside `connection_owned?/0` itself — are filtered out: they are an
  # implementation detail of the probe, not the boundary decision under test.
  @doc false
  def forward_drop(_event, _measurements, %{caller: TaskRouterWatcher} = metadata, %{pid: pid}) do
    send(pid, {:watcher_drop, metadata})
  end

  def forward_drop(_event, _measurements, _metadata, _config), do: :ok

  # ── Half 2: the watcher's intended effect ──────────────────────────────

  describe "arm 1 — direct mailbox drive, intended effect (half 2)" do
    test "a reconnect for a visible runtime redispatches that runtime's router", %{
      watcher: watcher
    } do
      %{task_id: task_id, runtime_id: runtime_id} = seed_dispatchable_task!()
      stub = start_registered_stub!(task_id)

      down_ref = Process.monitor(watcher)
      supervision_before = supervision_snapshot()

      send(watcher, {:runtime_reconnected, runtime_id})

      # Barrier 1: the watcher has finished handling the reconnect, including
      # `send(pid, :dispatch)`.
      assert TaskRouterWatcher.sync() == :ok
      # Barrier 2: the stub has finished handling anything already queued.
      assert StubRouter.sync(stub) == :ok

      assert_receive {:dispatched, ^task_id},
                     @receive_timeout,
                     "the watcher did not redispatch a router for a task assigned to the " <>
                       "reconnected runtime — half 1 of this file would still pass, which " <>
                       "is exactly why half 2 exists"

      # The guard must not over-block. A `handle_runtime_reconnected/1` that
      # dropped everything would satisfy every negative assertion in this file
      # and fail here and on the assertion above.
      refute_received {:watcher_drop, %{runtime_id: ^runtime_id}}

      assert_watcher_survived(watcher, down_ref, supervision_before)
    end

    test "the same reconnect does NOT redispatch when an active lease already exists", %{
      watcher: watcher
    } do
      # The mirror. Identical fixture, identical barrier sequence, one extra
      # row — so the difference in outcome can only be attributable to
      # `active_lease_present?/2` (`task_router_watcher.ex:1041`). Without this
      # case the positive assertion above would be unfalsifiable: a harness
      # that reported "dispatched" unconditionally would pass it.
      %{task_id: task_id, runtime_id: runtime_id} = seed_dispatchable_task!()
      stub = start_registered_stub!(task_id)
      lease = seed_active_lease!(task_id, runtime_id)

      down_ref = Process.monitor(watcher)
      supervision_before = supervision_snapshot()

      send(watcher, {:runtime_reconnected, runtime_id})

      assert TaskRouterWatcher.sync() == :ok
      assert StubRouter.sync(stub) == :ok

      # No timeout, and none is needed: the two barriers above establish that
      # the watcher and the stub have both drained. A timeout here would be a
      # sleep wearing a different hat.
      refute_received {:dispatched, ^task_id}

      # Positive control on the fixture itself: if the lease were not actually
      # active, this test would pass for the wrong reason.
      assert %ExecutionLease{status: "active"} =
               Repo.get!(ExecutionLease, lease.id)

      assert Process.alive?(stub)
      assert_watcher_survived(watcher, down_ref, supervision_before)
    end
  end

  # ── Half 1: no ownership error is raised ───────────────────────────────

  describe "arm 2 — real broadcast_board fan-out from a foreign connection (half 1)" do
    test "a reconnect for a runtime that exists only on another connection is refused", %{
      watcher: watcher
    } do
      # The production shape of the defect: a runtime channel joins during some
      # other test, `runtime_channel.ex:97` broadcasts on `tasks:board`, and the
      # watcher — allow-listed onto THIS test's connection — receives it. The
      # interleaving is made deterministic here instead of left to the
      # scheduler, which is what turns a ~1-in-3 flake into a repeatable test.
      owner = start_foreign_owner!()
      runtime_id = create_foreign_runtime!(owner)

      # The discriminator the whole arm rests on. If the "foreign" owner were
      # in fact sharing this test's connection, the row WOULD be visible, the
      # watcher would be right to act on it, and the drop assertion below
      # would be testing nothing.
      refute runtime_row_present?(runtime_id),
             "the second owner is not on an independent sandbox connection — every " <>
               "assertion in this describe block would be vacuous"

      assert on_foreign(owner, fn -> runtime_row_present?(runtime_id) end)

      down_ref = Process.monitor(watcher)
      supervision_before = supervision_snapshot()

      broadcast_from(owner, {:runtime_reconnected, runtime_id})

      # POSITIVE, and carrying the id. "No error was raised" is satisfied
      # identically by a broadcast that never arrived; this is not.
      assert %{event: :runtime_reconnected} =
               await_drop!(runtime_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      assert_watcher_survived(watcher, down_ref, supervision_before)
    end

    @tag :unowned_watcher
    test "the same reconnect is refused for connection ownership when the watcher owns nothing",
         %{watcher: watcher} do
      # The other precondition, reached through the real fan-out. `setup`
      # deliberately skips `Sandbox.allow/3` for this test, so precondition A
      # (`SandboxGuard.connection_owned?/0`, `task_router_watcher.ex:344`)
      # short-circuits before the visibility query is ever issued.
      owner = start_foreign_owner!()
      runtime_id = create_foreign_runtime!(owner)

      down_ref = Process.monitor(watcher)
      supervision_before = supervision_snapshot()

      broadcast_from(owner, {:runtime_reconnected, runtime_id})

      assert %{event: :runtime_reconnected} =
               await_drop!(runtime_id, :connection_unowned)

      assert TaskRouterWatcher.sync() == :ok

      # A must short-circuit BEFORE B. If it did not, `runtime_row_visible?/1`
      # would issue its `Repo.exists?` on an unowned connection, `guarded/3`
      # would catch the resulting error, and the drop would arrive tagged
      # `:foreign_connection` instead. Sound without a timeout because `sync/0`
      # above already returned.
      refute_received {:watcher_drop, %{runtime_id: ^runtime_id, reason: :foreign_connection}}

      assert_watcher_survived(watcher, down_ref, supervision_before)
    end
  end

  describe "observability control" do
    test "a reconnect for a runtime_id with no row on any connection is observably refused", %{
      watcher: watcher
    } do
      # Without this, every "no ownership error was raised" assertion in the
      # file is unfalsifiable: it proves the harness can see a reconnect
      # ARRIVE at the callback, independent of whether the reconnect succeeds.
      runtime_id = "reconnect-nowhere-#{System.unique_integer([:positive])}"

      refute runtime_row_present?(runtime_id)

      down_ref = Process.monitor(watcher)
      supervision_before = supervision_snapshot()

      send(watcher, {:runtime_reconnected, runtime_id})

      assert %{event: :runtime_reconnected} =
               await_drop!(runtime_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      assert_watcher_survived(watcher, down_ref, supervision_before)
    end
  end

  # ── Half 1's three assertions, in one place ────────────────────────────

  # (a) is the `await_drop!/2` at each call site — positive, and carrying the
  # runtime_id. (b) and (c) are here.
  #
  # (c), the supervision snapshot, is a BELT: stage 1 measured zero
  # max-restart terminations and zero `:noproc` events across twenty runs, so
  # the `Platform.Supervisor` cascade it was written to catch is falsified as
  # the mechanism behind this ticket. It stays because it is two function
  # calls and would still catch a future regression that took the supervisor
  # down — but no assertion in this file depends on it.
  defp assert_watcher_survived(watcher, down_ref, supervision_before) do
    refute_received {:DOWN, ^down_ref, :process, ^watcher, _reason}

    assert Process.alive?(watcher),
           "the watcher died handling a reconnect it should have refused"

    assert supervision_snapshot() == supervision_before,
           "Platform.Supervisor's children changed across a reconnect"

    Process.demonitor(down_ref, [:flush])

    :ok
  end

  defp supervision_snapshot do
    %{
      platform_children: Supervisor.count_children(Platform.Supervisor),
      run_supervisor: Process.whereis(Platform.Execution.RunSupervisor)
    }
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  # A task that satisfies every branch `redispatch_for_runtime/1` walks:
  # listed by `list_should_run_tasks/0` (agent assignee, active status, not
  # deleted), resolvable to the runtime by `resolve_runtime_for_task/1`, and
  # carrying no lease so `active_lease_present?/2` returns false.
  #
  # The assignee is written with a bare `Repo.update!` rather than
  # `Tasks.update_task/3` on purpose: the latter fires
  # `broadcast_board({:task_updated, _})`, which this test's own watcher would
  # service by starting a REAL `TaskRouter` under the same task id — colliding
  # with the stub and doing Repo work in `init/1` that manual mode cannot
  # support. The fixture must not perturb the thing being measured.
  defp seed_dispatchable_task! do
    user = insert_user!()
    agent = insert_agent!()

    runtime_id = "reconnect-visible-#{System.unique_integer([:positive])}"

    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    task = insert_task!("Reconnect redispatch fixture")

    task =
      task
      |> Ecto.Changeset.change(%{
        status: "in_progress",
        assignee_type: "agent",
        assignee_id: agent.id
      })
      |> Repo.update!()

    # Drain the `{:task_created, _}` broadcast `Tasks.create_task/1` raised, so
    # a later `refute_received` cannot trip over it.
    assert TaskRouterWatcher.sync() == :ok

    %{task_id: task.id, runtime_id: runtime_id, agent: agent}
  end

  defp seed_active_lease!(task_id, runtime_id) do
    now = DateTime.utc_now()

    %ExecutionLease{}
    |> ExecutionLease.changeset(%{
      task_id: task_id,
      phase: "execution",
      runtime_id: runtime_id,
      status: "active",
      started_at: now,
      expires_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp insert_task!(title) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Reconnect Ownership Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/reconnect-ownership"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        description: "Used by the watcher reconnect-ownership regression test",
        deploy_target: "production"
      })

    task
  end

  defp insert_user! do
    Repo.insert!(%User{
      email: "watcher_reconnect_#{System.unique_integer([:positive])}@example.com",
      name: "Watcher Reconnect User",
      oidc_sub: "oidc-watcher-reconnect-#{System.unique_integer([:positive])}"
    })
  end

  defp insert_agent! do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "reconnect-agent-#{System.unique_integer([:positive])}",
        name: "Watcher Reconnect Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # `AgentRuntime` is keyed in broadcasts by its string `runtime_id`, not its
  # primary key, so this mirrors `runtime_row_visible?/1` rather than reusing
  # `SandboxGuard.row_visible?/2`.
  defp runtime_row_present?(runtime_id) do
    Repo.exists?(from(r in AgentRuntime, where: r.runtime_id == ^runtime_id))
  end

  defp create_foreign_runtime!(owner) do
    runtime_id = "reconnect-foreign-#{System.unique_integer([:positive])}"

    on_foreign(owner, fn ->
      user = insert_user!()
      agent = insert_agent!()

      {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, _linked} = Federation.link_agent(activated, agent)

      task = insert_task!("Reconnect foreign-owner task")

      task
      |> Ecto.Changeset.change(%{
        status: "in_progress",
        assignee_type: "agent",
        assignee_id: agent.id
      })
      |> Repo.update!()

      :ok
    end)

    runtime_id
  end

  defp start_registered_stub!(task_id) do
    test = self()

    spec = %{
      id: {:stub_router, task_id},
      start: {StubRouter, :start_link, [{task_id, test}]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(TaskRouterSupervisor, spec)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(TaskRouterSupervisor, pid)
      end
    end)

    assert TaskRouterWatcher.router_running?(task_id),
           "the stub did not register under the task id — `redispatch_for_runtime/1` " <>
             "would skip it at the `router_running?/1` branch and half 2 would be vacuous"

    pid
  end

  # ── The second sandbox connection ──────────────────────────────────────

  # A plain `spawn` that checks a connection out for itself. NOT
  # `Sandbox.start_owner!/2` — see the moduledoc, and the fuller explanation at
  # `task_router_watcher_sandbox_isolation_test.exs:504-514`.
  defp start_foreign_owner! do
    test = self()
    ref = make_ref()

    owner =
      spawn(fn ->
        send(test, {ref, Sandbox.checkout(Repo)})
        foreign_owner_loop()
      end)

    assert_receive {^ref, :ok},
                   @receive_timeout,
                   "the foreign owner did not obtain an independent sandbox connection"

    on_exit(fn -> stop_foreign_owner(owner) end)

    owner
  end

  defp foreign_owner_loop do
    receive do
      {:run, from, ref, fun} ->
        send(from, {ref, run_captured(fun)})
        foreign_owner_loop()

      {:stop, from, ref} ->
        Sandbox.checkin(Repo)
        send(from, {ref, :ok})
    end
  end

  defp run_captured(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp stop_foreign_owner(owner) do
    if Process.alive?(owner) do
      ref = make_ref()
      monitor = Process.monitor(owner)
      send(owner, {:stop, self(), ref})

      receive do
        {^ref, :ok} -> :ok
      after
        @receive_timeout -> :ok
      end

      Process.exit(owner, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _} -> :ok
      after
        @receive_timeout -> :ok
      end
    end

    :ok
  end

  # Failures are re-raised here rather than swallowed: a fixture that silently
  # failed on the other connection would turn every downstream assertion into
  # a vacuous pass.
  defp on_foreign(owner, fun) do
    ref = make_ref()
    send(owner, {:run, self(), ref, fun})

    receive do
      {^ref, {:ok, value}} ->
        value

      {^ref, {:raised, exception, stacktrace}} ->
        reraise(exception, stacktrace)

      {^ref, {:caught, kind, reason}} ->
        flunk("the foreign sandbox owner exited: #{inspect({kind, reason})}")
    after
      2 * @receive_timeout ->
        flunk("the foreign sandbox owner did not answer within #{2 * @receive_timeout}ms")
    end
  end

  defp broadcast_from(owner, message) do
    on_foreign(owner, fn -> Tasks.broadcast_board(message) end)
  end

  # A bounded, blocking selective receive for one specific drop.
  #
  # `assert_receive` would match, but its timeout message is only "no matching
  # message" — the least useful thing a guard's failure could say. On timeout
  # this reports what the watcher did instead, so a regression names the damage.
  #
  # Non-matching `{:watcher_drop, _}` messages are left in the mailbox so a
  # later `refute_received` in the same test still sees them.
  defp await_drop!(runtime_id, reason) do
    receive do
      {:watcher_drop, %{runtime_id: ^runtime_id, reason: ^reason} = metadata} ->
        metadata
    after
      @receive_timeout ->
        flunk("""
        The watcher never recorded a #{inspect(reason)} drop for \
        runtime_id=#{inspect(runtime_id)} within #{@receive_timeout}ms — it handled the \
        reconnect instead of refusing it.

        State right now:
          AgentRuntime row visible here?  #{inspect(runtime_row_present?(runtime_id))}
          Registry contents:              #{inspect(Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}]))}
        """)
    end
  end
end
