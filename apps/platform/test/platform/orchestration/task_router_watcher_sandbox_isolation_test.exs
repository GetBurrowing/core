defmodule Platform.Orchestration.TaskRouterWatcherSandboxIsolationTest do
  @moduledoc """
  Cross-connection perturbation regression tests for the `TaskRouterWatcher`
  broadcast boundary.

  ## What makes this file different from `task_router_watcher_boundary_test.exs`

  The boundary test drives the watcher by `send/2`-ing payloads straight into
  its mailbox. That is exact and fast, and it is the right shape for testing
  the precondition *mechanics*. It does not, however, reproduce the defect:
  the defect is that a **real `Tasks.update_task/3` on somebody else's sandbox
  connection** fans out through `Phoenix.PubSub` and reaches a watcher sitting
  on ours. This file reproduces exactly that, deterministically, using a
  second independently-owned sandbox connection inside a single test.

  ## The three rules this file follows

  **1. Absence-only assertions are banned.** Every expected drop asserts
  positively on the `SandboxGuard.dropped_event/0` telemetry, carrying the id
  of the thing that was dropped. `refute Registry.lookup(...)` on its own is
  satisfied just as happily by a broadcast that never arrived — which is
  precisely how this defect survived behind a "known TaskRouter flake" label.

  **2. Every guard has a positive control.** A precondition that dropped
  *everything* would satisfy every negative assertion here while breaking
  production. So: a foreign stop-broadcast that must NOT stop a router is
  paired with a visible-row stop-broadcast that MUST stop one, and the whole
  file is backstopped by an end-to-end shared-mode test that starts a real
  `TaskRouter` and asserts a real lease row lands in ETS.

  **3. The measuring instrument gets a control too.** `snapshot equality`
  ("nothing in these two global tables changed") is worthless if the snapshot
  could never observe a change in the first place. `the snapshots can observe
  a change` deliberately perturbs both tables and asserts the snapshots differ.

  ## Determinism: no sleeps, no scheduling luck

  * The second connection is a **plain `spawn`** that calls
    `Sandbox.checkout/1` itself. `Sandbox.start_owner!/2` cannot be used here:
    it is built on `Agent`, which sets `$callers`, so its checkout resolves
    back to *this test's* connection and returns `{:already, :owner}` — the
    "second owner" would be the same connection and every assertion in this
    file would pass vacuously.
  * Mode is **`:manual`**, switched in `setup` ahead of every fixture (the
    switch checks the shared connection back in, rolling back anything written
    on it). Under `{:shared, self()}` the shared connection is a fallback for
    every process that does not own one, so a *second, independent* owner
    cannot exist at all and neither can an unowned watcher.
  * Synchronisation is `await_drop!/3` — a bounded, blocking selective receive
    on the drop telemetry — followed by `TaskRouterWatcher.sync/0`. Never
    `Process.sleep/1`. The telemetry event is emitted as the last act of
    handling the broadcast, so receiving it *is* the happens-after edge, which
    is why it has to come before the global-state assertions rather than after
    them (asserting on global state that the watcher has not reached yet is
    just a slower way of asserting nothing). `await_drop!/3` pays for that
    ordering by dumping the global state it can see into its timeout message,
    so a regression still names the damage instead of only saying "no message".

  ## Why the stub router is not a real `TaskRouter`

  A real `TaskRouter` does Repo work in `init/1`, so it can only start in
  shared mode. In manual mode we use a supervised, Registry-registered stub
  that does no Repo work. It is a real child of the real
  `TaskRouterSupervisor` — a bare `Registry.register/3` from a spawned process
  would not do, because `stop_assignment/1` would find the pid, hand it to
  `terminate_child/2`, get `{:error, :not_found}`, and the test could no
  longer tell a guarded broadcast from an unguarded one.

  The stub deliberately does **not** trap exits, because `TaskRouter` does not
  either. That is load-bearing for how this file's evidence reads: a
  supervisor-initiated `terminate_child/2` sends a `:shutdown` exit to a
  non-trapping process, which dies immediately *without* running `terminate/2`
  — so the stop branch's observable damage on this codebase is the killed
  process and its vanished Registry entry, not a cleared ETS lease row. Both
  tables are snapshotted anyway; see the stage note for which half
  discriminates.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation

  alias Platform.Orchestration.{
    LeaseManager,
    SandboxGuard,
    TaskRouter,
    TaskRouterSupervisor,
    TaskRouterWatcher
  }

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Types.UUIDv7

  @registry Platform.Orchestration.Registry
  @lease_table :orchestration_lease_manager

  # Bound on every blocking receive in this file. Generous enough that a
  # loaded box does not produce false failures, short enough that a genuine
  # regression fails in seconds rather than hanging the suite.
  @receive_timeout 5_000

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
    watcher = Process.whereis(TaskRouterWatcher)
    assert watcher, "TaskRouterWatcher must be running for these tests to mean anything"

    assert :ets.info(@lease_table) != :undefined,
           "the #{inspect(@lease_table)} ETS table must exist for the snapshot assertions"

    unless tags[:shared_sandbox] do
      # Order matters. The mode switch checks the shared connection back IN
      # (rolling back anything written on it) and drops every allowance
      # derived from it, so it has to happen before the checkout, before the
      # allowance, and before every fixture.
      Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo)
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)

      unless tags[:unowned_watcher] do
        # Asserted, not assumed: `{:already, :allowed}` here would mean the
        # watcher is still bound to some other connection, and every
        # assertion below would be measuring the wrong thing.
        assert Sandbox.allow(Repo, self(), watcher) == :ok
      end
    end

    handler_id = "watcher-isolation-#{System.unique_integer([:positive])}"

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

  # Only the watcher's own boundary decisions are forwarded, and each carries
  # the id it dropped, so an assertion here can never be satisfied by some
  # other component's drop. The lower-level `caller: SandboxGuard` events
  # (emitted from inside `connection_owned?/0` and `row_visible?/2`) are
  # filtered out — they are an implementation detail of the probe, not the
  # boundary decision under test.
  @doc false
  def forward_drop(_event, _measurements, %{caller: TaskRouterWatcher} = metadata, %{pid: pid}) do
    send(pid, {:watcher_drop, metadata})
  end

  def forward_drop(_event, _measurements, _metadata, _config), do: :ok

  # ── (a) A real context write on a foreign connection ───────────────────

  describe "foreign-owner context write" do
    test "a real create + update on a second connection starts no router and writes no lease" do
      # The actual production write path — `Tasks.create_task/1` then
      # `Tasks.update_task/3`, which fires the real
      # `broadcast_board({:task_updated, preloaded})` — executed on a sandbox
      # connection this test does not own. This is the exact shape of "async
      # test B writes while the watcher is allow-listed onto test A's
      # connection", with the interleaving made deterministic instead of left
      # to the scheduler.
      owner = start_foreign_owner!()

      task = create_foreign_planning_task!(owner)
      task_id = task.id

      # POSITIVE assertion first. Without this the two negative assertions
      # below pass identically well when the broadcast never arrived.
      await_drop!(:task_id, task_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      assert Registry.lookup(@registry, task_id) == [],
             "a router was started for a task belonging to another sandbox connection"

      assert LeaseManager.get(task_id) == nil,
             "an ETS lease row was written for a task belonging to another connection"
    end

    test "the task really is invisible from this connection (guard-precondition control)" do
      # The discriminator the whole file rests on. If a "foreign" owner were
      # in fact sharing this test's connection — which is what
      # `Sandbox.start_owner!/2` would silently give us — the row WOULD be
      # visible, the watcher would be right to act on it, and every drop
      # assertion above would be testing nothing.
      owner = start_foreign_owner!()
      task = create_foreign_planning_task!(owner)

      refute SandboxGuard.row_visible?(TaskSchema, task.id),
             "the second owner is not on an independent connection — the foreign-write " <>
               "tests in this file would be vacuous"

      assert Repo.get(TaskSchema, task.id) == nil
      assert on_foreign(owner, fn -> Repo.get(TaskSchema, task.id) end).id == task.id
    end
  end

  # ── (b) A broadcast from a process outside the sandbox entirely ────────

  describe "broadcast from an unallowed process" do
    test "a synthetic agent-assigned task from a bare spawned process is dropped" do
      # Same fan-out as (a) — `Tasks.broadcast_board/1` is the function all
      # eleven board call sites use — but raised from a process with no
      # sandbox allowance at all and for a task id that has no row on any
      # connection.
      task_id = UUIDv7.generate()

      broadcast_from_unallowed_process({:task_created, agent_task(task_id, "planning")})

      # `:foreign_connection`, not `:connection_unowned`: the *watcher* is
      # allowed onto this test's connection here, so precondition A passes and
      # precondition B is what refuses. The broadcaster's own ownership is
      # irrelevant — which is the point. The watcher cannot infer anything
      # from who shouted; it can only ask whether it can see the row.
      await_drop!(:task_id, task_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      assert Registry.lookup(@registry, task_id) == []
      assert LeaseManager.get(task_id) == nil
    end

    @tag :unowned_watcher
    test "the same broadcast is dropped for connection ownership when the watcher owns nothing" do
      # The other precondition, reached through the real PubSub fan-out rather
      # than a direct `send/2`. `setup` deliberately skips `Sandbox.allow/3`
      # for this test, so the watcher owns no connection and precondition A
      # short-circuits before the visibility query is ever issued.
      task_id = UUIDv7.generate()

      broadcast_from_unallowed_process({:task_created, agent_task(task_id, "planning")})

      await_drop!(:task_id, task_id, :connection_unowned)

      assert TaskRouterWatcher.sync() == :ok

      # A must short-circuit BEFORE B. If it did not, the visibility query
      # would raise, `guarded/3` would catch it, and the drop would arrive
      # tagged `:foreign_connection` instead.
      refute_received {:watcher_drop, %{task_id: ^task_id, reason: :foreign_connection}}

      assert Registry.lookup(@registry, task_id) == []
    end
  end

  # ── (c) Global-state snapshot equality ─────────────────────────────────

  describe "global-state snapshots" do
    test "neither the lease table nor the Registry changes across foreign broadcasts" do
      # The assertion that detects perturbation *independent of which task id
      # was involved*. The tests above can only see damage they predicted;
      # this one sees any row that appeared, vanished, or changed.
      #
      # The window deliberately spans BOTH branches of `evaluate_task/1`,
      # because they fail differently:
      #
      #   * the START branch would add a Registry entry (and, via a real
      #     router's dispatch, an ETS lease row);
      #   * the STOP branch would remove one — and it is the branch no
      #     return-value guard can reach, since it makes zero Repo calls.
      #
      # A snapshot around the start branch alone would pass on an unguarded
      # tree for the wrong reason (the agent row is invisible too, so runtime
      # resolution fails and no router starts anyway). Including a resident
      # router is what makes the equality load-bearing.
      owner = start_foreign_owner!()

      resident_id = UUIDv7.generate()
      stub = start_registered_stub!(resident_id)
      resident_lease = seed_lease!(resident_id)

      leases_before = lease_snapshot()
      registry_before = registry_snapshot()

      # 1. Start branch: a real context write on the foreign connection.
      foreign_task = create_foreign_planning_task!(owner)
      foreign_id = foreign_task.id

      await_drop!(:task_id, foreign_id, :foreign_connection)

      # 2. Stop branch: a foreign "this task is done" broadcast aimed at the
      #    resident router, which belongs to THIS connection's world.
      broadcast_from(owner, {:task_updated, agent_task(resident_id, "done")})

      await_drop!(:task_id, resident_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      assert registry_snapshot() == registry_before,
             "the Registry was perturbed by broadcasts from a foreign sandbox connection"

      assert lease_snapshot() == leases_before,
             "the #{inspect(@lease_table)} ETS table was perturbed by broadcasts from a " <>
               "foreign sandbox connection — ETS is not transactional, so nothing rolls " <>
               "this back at end of test"

      assert Process.alive?(stub)
      assert LeaseManager.get(resident_id) == resident_lease
    end

    test "the snapshots can observe a change (measuring-instrument control)" do
      # Snapshot equality proves nothing if the snapshot is incapable of
      # differing. This test perturbs both tables the way the stop branch
      # would and asserts both snapshots move. Without it, a helper that
      # returned a constant would make the test above permanently green.
      task_id = UUIDv7.generate()

      leases_before = lease_snapshot()
      registry_before = registry_snapshot()

      stub = start_registered_stub!(task_id)
      seed_lease!(task_id)

      refute lease_snapshot() == leases_before,
             "lease_snapshot/0 cannot observe an ETS write — the equality assertion in " <>
               "this describe block is vacuous"

      refute registry_snapshot() == registry_before,
             "registry_snapshot/0 cannot observe a registration — the equality assertion " <>
               "in this describe block is vacuous"

      assert Process.alive?(stub)
    end
  end

  # ── (d) Stop-branch protection ─────────────────────────────────────────

  describe "stop branch (the branch no return-value guard can reach)" do
    test "a foreign done-broadcast does not stop a router running on this connection" do
      # `evaluate_task/1`'s stop branch runs `should_run?/1` (pure struct
      # reads), `router_running?/1` (a bare `Registry.lookup`) and
      # `terminate_child/2`. Zero Repo calls between the broadcast arriving
      # and a supervised process being killed — there is no return value
      # anywhere on that path that could carry an ownership signal, which is
      # why the guard has to be a precondition at the boundary.
      owner = start_foreign_owner!()

      task_id = UUIDv7.generate()
      stub = start_registered_stub!(task_id)
      lease = seed_lease!(task_id)

      assert TaskRouterWatcher.router_running?(task_id)

      broadcast_from(owner, {:task_updated, agent_task(task_id, "done")})

      await_drop!(:task_id, task_id, :foreign_connection)

      assert TaskRouterWatcher.sync() == :ok

      # Ordered deliberately: the global-state assertion comes first so that
      # when this test catches a regression it names the actual damage rather
      # than a missing telemetry event.
      assert Process.alive?(stub),
             "the watcher terminated a supervised router on behalf of a task row it cannot see"

      assert Registry.lookup(@registry, task_id) == [{stub, nil}]
      assert LeaseManager.get(task_id) == lease
    end

    test "a done-broadcast for a VISIBLE row still stops its router (positive control)" do
      # The same broadcast, the same branch, one difference: the row is on
      # this test's connection. This is what stops "drop everything" from
      # being a passing implementation of the stop branch — and it is the
      # assertion that goes red first if either precondition over-blocks.
      task = create_visible_task!("Isolation stop control")

      stub = start_registered_stub!(task.id)
      ref = Process.monitor(stub)
      assert TaskRouterWatcher.router_running?(task.id)

      Tasks.broadcast_board({:task_updated, %{task | status: "done"}})

      assert TaskRouterWatcher.sync() == :ok

      # `terminate_child/2` returns only after the child has exited, and
      # `sync/0` returns only after the watcher finished handling the
      # broadcast, so the process is already gone. The monitor is belt and
      # braces for the ordering, not a poll with a sleep in it.
      assert_receive {:DOWN, ^ref, :process, ^stub, _reason}, @receive_timeout
      refute Process.alive?(stub)

      task_id = task.id
      refute_received {:watcher_drop, %{task_id: ^task_id}}
    end
  end

  # ── (e) End-to-end positive control ────────────────────────────────────

  describe "legitimate dispatch (shared mode, real TaskRouter)" do
    @tag :shared_sandbox
    test "an agent-assigned task still starts a real router and records a real lease" do
      # Shared mode, real fixtures, a real `TaskRouter` child, and the real
      # `Tasks.update_task/3` broadcast — the production shape end to end. It
      # asserts on BOTH global surfaces the rest of this file watches for
      # damage: a Registry entry appears AND a row lands in the
      # `:orchestration_lease_manager` ETS table. A guard that dropped
      # everything would satisfy every other test here and fail this one.
      user = create_user()
      agent = create_agent()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "isolation-live-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, _linked} = Federation.link_agent(activated, agent)

      task = create_visible_task!("Isolation live-router control")

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "coding",
          description: "Write code"
        })

      {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      # `current_running_stage/1` has to resolve inside `do_dispatch/2` for
      # the router to arm liveness — no running stage, no lease row.
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Repo.update!()

      on_exit(fn ->
        TaskRouterSupervisor.stop_assignment(task.id)
        LeaseManager.clear(task.id)
      end)

      {:ok, _in_progress} =
        Tasks.update_task(task, %{
          status: "in_progress",
          assignee_type: "agent",
          assignee_id: agent.id
        })

      assert TaskRouterWatcher.sync() == :ok

      assert TaskRouterWatcher.router_running?(task.id),
             "the sandbox precondition blocked a legitimate router start"

      task_id = task.id
      refute_received {:watcher_drop, %{task_id: ^task_id}}

      # `current_status/1` is a `GenServer.call`, so it is answered only after
      # the `:dispatch` message `init/1` sent to itself has been fully
      # handled — including `arm_liveness_timers/3`. That makes the lease
      # assertion below exact rather than a race, and leaves the router with
      # no in-flight Repo work to be orphaned when this test's sandbox owner
      # exits. This is what the 100-300ms sleeps elsewhere in the suite are
      # approximating.
      assert %{} = TaskRouter.current_status(task.id)

      assert %{stage_id: leased_stage_id, stage_kind: "coding"} = LeaseManager.get(task.id),
             "the router started but never recorded its dispatch — the lease table is the " <>
               "global state this task's defect corrupts, so the positive control has to " <>
               "cover it too"

      assert leased_stage_id == stage.id

      [{router, _}] = Registry.lookup(@registry, task.id)
      ref = Process.monitor(router)
      :ok = TaskRouterSupervisor.stop_assignment(task.id)
      assert_receive {:DOWN, ^ref, :process, ^router, _reason}, @receive_timeout
    end
  end

  # ── The second sandbox connection ──────────────────────────────────────

  # A plain `spawn` that checks a connection out for itself.
  #
  # NOT `Sandbox.start_owner!/2`: that is built on `Agent`, and
  # `Agent.start_link/2` sets `$callers` to include this test process. The
  # sandbox resolves ownership through `$callers`, so the "new owner" would
  # find this test's existing connection and return `{:already, :owner}` —
  # the same connection under a different pid, and every foreign-write test
  # in this file would pass vacuously. `Task`-based helpers have the same
  # problem. A bare `spawn` inherits neither `$callers` nor `$ancestors`.
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
        # `checkin/1` rolls the foreign transaction back with no sleep and no
        # process-exit race, which is why this loop exists instead of just
        # killing the process.
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

  # Run `fun` inside the foreign owner so its Repo calls land on the foreign
  # connection. Failures are re-raised here rather than swallowed — a fixture
  # that silently failed on the other connection would turn every downstream
  # assertion into a vacuous pass.
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

  # ── Fixtures ───────────────────────────────────────────────────────────

  # The full production write path, executed entirely on the foreign
  # connection: project, user, agent, activated + linked runtime, task, then
  # the `update_task/3` that actually fires
  # `broadcast_board({:task_updated, preloaded})`. Everything the watcher
  # would need to resolve a runtime exists — on a connection it cannot read.
  defp create_foreign_planning_task!(owner) do
    on_foreign(owner, fn ->
      user = insert_user!()
      agent = insert_agent!()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "isolation-foreign-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, _linked} = Federation.link_agent(activated, agent)

      task = insert_task!("Isolation foreign-owner task")

      {:ok, planning} =
        Tasks.update_task(task, %{
          status: "planning",
          assignee_type: "agent",
          assignee_id: agent.id
        })

      planning
    end)
  end

  defp create_visible_task!(title), do: insert_task!(title)

  defp insert_task!(title) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Watcher Isolation Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/watcher-isolation"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        description: "Used by the watcher sandbox-isolation tests",
        deploy_target: "production"
      })

    task
  end

  defp create_user, do: insert_user!()
  defp create_agent, do: insert_agent!()

  defp insert_user! do
    Repo.insert!(%User{
      email: "watcher_isolation_#{System.unique_integer([:positive])}@example.com",
      name: "Watcher Isolation User",
      oidc_sub: "oidc-watcher-isolation-#{System.unique_integer([:positive])}"
    })
  end

  defp insert_agent! do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "isolation-agent-#{System.unique_integer([:positive])}",
        name: "Watcher Isolation Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # A payload shaped exactly like the ones `Tasks.broadcast_board/1` emits,
  # for a task id that has no row on any connection.
  defp agent_task(task_id, status) do
    %TaskSchema{
      id: task_id,
      assignee_type: "agent",
      assignee_id: Ecto.UUID.generate(),
      status: status
    }
  end

  # ── Global-state helpers ───────────────────────────────────────────────

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

  defp seed_lease!(task_id) do
    :ok =
      LeaseManager.record_dispatch(task_id, UUIDv7.generate(), "coding", DateTime.utc_now())

    on_exit(fn -> LeaseManager.clear(task_id) end)

    LeaseManager.get(task_id)
  end

  # A bounded, blocking selective receive for one specific drop.
  #
  # `assert_receive` would do the job, but its timeout message is only "no
  # matching message" — which, for a guard whose whole purpose is to prevent a
  # side effect, is the least useful thing it could say. On timeout this dumps
  # the global state for the id in question, so the failure reads "the watcher
  # did not refuse, AND here is the Registry entry / lease row it left behind".
  # That is the same principle stage 4's polling helper applies to the rest of
  # the watcher suite: a timeout must report the last observed value.
  #
  # Non-matching `{:watcher_drop, _}` messages are left in the mailbox, so a
  # later `refute_received` in the same test still sees them.
  defp await_drop!(key, id, reason) do
    receive do
      {:watcher_drop, %{^key => ^id, reason: ^reason} = metadata} ->
        metadata
    after
      @receive_timeout ->
        flunk("""
        The watcher never recorded a #{inspect(reason)} drop for #{key}=#{inspect(id)} \
        within #{@receive_timeout}ms — it handled the broadcast instead of refusing it.

        Global state for that id right now:
          Registry.lookup/2:   #{inspect(Registry.lookup(@registry, id))}
          LeaseManager.get/1:  #{inspect(LeaseManager.get(id))}
        """)
    end
  end

  defp lease_snapshot, do: @lease_table |> :ets.tab2list() |> Enum.sort()

  defp registry_snapshot do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.sort()
  end

  defp broadcast_from(owner, message) do
    on_foreign(owner, fn -> Tasks.broadcast_board(message) end)
  end

  # A process with no sandbox allowance, no `$callers`, and no `$ancestors`
  # raising a real board broadcast. The handshake back is what makes this
  # deterministic — the test does not proceed until the broadcast has been
  # issued.
  defp broadcast_from_unallowed_process(message) do
    test = self()
    ref = make_ref()

    spawn(fn ->
      Tasks.broadcast_board(message)
      send(test, {ref, :broadcast})
    end)

    assert_receive {^ref, :broadcast}, @receive_timeout

    :ok
  end
end
