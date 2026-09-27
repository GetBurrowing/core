defmodule Platform.SandboxHelpers do
  @moduledoc """
  Test helpers that keep supervised, fire-and-forget writers inside the
  lifetime of the SQL sandbox connection that owns their transaction.

  ## Why this module exists

  `Platform.Audit.TelemetryHandler` routes the `[:platform, :historian | _]`
  and `[:platform, :agents, :historian | _]` events through
  `Task.Supervisor.start_child(Platform.TaskSupervisor, ...)` so
  `:telemetry.execute/3` returns in well under a millisecond. The spawned
  child then calls `Platform.Audit.record/1`.

  That child has **no lifecycle relationship to the process that emitted
  the event**. In production that is exactly right — the Repo connection
  outlives any single request. Under `Ecto.Adapters.SQL.Sandbox` it is
  not: in shared mode the child borrows the *test process's* connection,
  and when the test process exits, `DBConnection` tears that connection
  down underneath every child still using it.

  Measured on `Platform.Audit.HistorianLatencyTest` (task 019f9d80 stage 3):
  at the instant its 10 500-event emit loop returns, **10 011 supervised
  children are still alive and queued for the single shared sandbox
  connection.** The test body then returns, the owner exits, and those
  children are killed mid-write:

      [error] Postgrex.Protocol (#PID<...>) disconnected:
        ** (DBConnection.ConnectionError) owner #PID<...> exited
        Client #PID<...> (Task.Supervised) is still using a connection
        ...
          (platform) lib/platform/audit/telemetry_handler.ex:286:
            Platform.Audit.TelemetryHandler.persist_or_skip/4
          (elixir) lib/task/supervised.ex:105: Task.Supervised.invoke_mfa/2

  ## Why this is a drain and not a rescue

  Every one of those children is a **victim**: it is performing a real,
  wanted `INSERT` and the connection dies out from under it. The write is
  genuinely lost. Two things follow.

  First, the arriving failure is a process **exit** (`shutdown:
  %DBConnection.ConnectionError{}`), not a raise, so the `rescue`
  clauses in `persist_or_skip/4` cannot see it and never have — see the
  measurements in `notes/2026-07-26-boot-telemetry-detach.md` §4 and §11.
  Second, and more importantly, *making* them see it would be the wrong
  fix. Catching the exit would convert "an audit write was destroyed and
  a pooled connection was force-reconnected" into silence, which is the
  same defect class this task exists to end.

  The fix is therefore upstream of the failure, not around it: **the
  sandbox owner waits for its writers before releasing the connection**,
  so there is no orphan to kill and no error to swallow.

  This is the invariant the repo already states but did not enforce.
  `test/platform/regression/supervised_task_repo_audit_test.exs`'s
  `@known_safe` entry for `StackDeployer` spells it out — "each test
  monitors the spawned child and awaits its `:DOWN` before returning, so
  **no child outlives the sandbox checkin**. Any FUTURE test that flips
  `:async` to `true` must do the same." `HistorianLatencyTest` breaks
  exactly that rule, at 10 000×, and nothing was checking.

  ## Why `Platform.DataCase` calls it, rather than each test

  Per-test drains are the copy-pasted-idiom shape that stage 2 of this
  task removed for handler restores: five independent copies, no
  enforcement, and drift. `Platform.DataCase`'s `on_exit` already drains
  `Platform.Chat.AttentionRouter` and `Platform.Chat.ContextPlane` for
  the identical stated reason ("so in-flight telemetry handle_info
  messages have been fully processed ... before the sandbox owner exits
  and the connection is freed"). Extending that same callback to
  supervised writers completes an existing mechanism instead of adding a
  parallel one, and it covers future emitters for free.

  ## Why the UNCONDITIONAL drain is shared-mode only

  `async: true` modules run concurrently, so `Platform.TaskSupervisor`'s
  child set there belongs to *other* modules as much as to this one, and
  waiting on all of it would be waiting on an unrelated test. That
  objection stands and is not negotiable: `await_supervised_writes/1` and
  `drain_or_warn/1` are called only from the shared-mode branch of
  `Platform.DataCase` and `PlatformWeb.ConnCase`, and must stay there.

  ### A correction to the reason this paragraph used to give

  Until task 01a08b49 stage 2 this section ALSO said that in `:manual`
  mode "a `Task.Supervisor` child is not in the owner chain at all — it
  has no connection to protect, and `Repo` calls from it raise
  `DBConnection.OwnershipError`". **That half is false**, and it mattered:
  it made the async case look like it had nothing to protect.

  Measured. `Ecto.Adapters.SQL.Sandbox.start_owner!/2` on its
  `shared: false` branch calls `allow(repo, self(), parent)` — the TEST
  process is an allowed process even in `async: true`. A supervised child
  therefore resolves that owner through `:"$callers"`
  (`DBConnection.Ownership.Manager.proxy_for/2` walks the caller list
  against the ownership table) and its `Repo` calls SUCCEED while the test
  is alive. `PlatformWeb.ConnCaseSupervisedOrphanTest`'s positive control
  2 asserts exactly that from an `async: true` ConnCase case, and passes.
  What raises `DBConnection.OwnershipError` is a child that reaches the
  Repo *after* the owner is gone — which is a statement about timing, not
  about mode.

  So the async case has the same thing to protect as the shared one. It is
  only the SET that differs.

  ## The scoped drain, and why it is admissible where the other is not

  `await_own_supervised_writes/2` keeps only the children whose
  `:"$callers"` chain contains a given owner pid. The asymmetry that makes
  this safe is that the mechanism creating the exposure is the mechanism
  that scopes the remedy: `Task.Supervisor.start_child/2` seeds
  `:"$callers"` in the child, that entry is *why* the child can reach the
  sandbox connection, and the same entry says whose child it is. Waiting
  on that filtered set cannot wait on a concurrent module, so the
  objection above does not apply to it.

  `PlatformWeb.ConnCase`'s `async: true` branch calls it (via
  `quiesce_own_or_warn/3`, the scoped drain plus the terminal step recorded
  below) before `Sandbox.stop_owner/1`, which is what
  removes the orphan this module's opening section describes. Both
  directions of the filter are pinned by
  `Platform.SandboxHelpersScopedDrainTest`, in particular that a child
  started by a foreign process is NOT waited for — because "excludes
  everything" would satisfy a one-sided test and would silently reinstate
  the defect.

  ## Why a WAIT is not always enough: the terminal step

  A drain waits for children to EXIT, and a child with no exit inside any
  teardown-shaped deadline defeats it. Task 01a0d265 stage 2 measured exactly
  that: the architect gate's lifecycle edge parks its runner in a `receive`
  on a 30-minute budget, so ConnCase's scoped drain ran, gave up, and the
  runner was still inside a query when its owner exited — 14
  "owner exited, client still using a connection" events in one full-suite
  log, with the drain wired in the whole time. `quiesce_own_or_warn/3` is the
  scoped drain plus the missing step: after the deadline, terminate the
  owner's leftovers while the owner is STILL alive (a client that dies first
  returns its connection; an owner that dies first leaks it), and only in
  that order. Its doc carries the full argument, including why the
  termination is gated on the owner being alive — the beyond-drain
  construction depends on the gate.

  ## What NO drain here can see: bare `spawn`

  A bare `spawn(fn -> ... end)` does not seed `:"$callers"`. Such a child
  never resolves a sandbox owner, so it is invisible to both drains **by
  construction** — not by omission, and not because the filter is too
  narrow. That is the INVERSE defect family (task 01a06638 / PR #965,
  where the remedy is to give those sites a caller chain at the spawn
  site), and the two must not be conflated: aiming an ownership drain at
  a process that has no ownership to key on is a fix at the wrong layer.
  `Platform.SandboxHelpersScopedDrainTest` pins this as a stated
  limitation so a later reader does not try to "widen" the drain to
  reach it.
  """

  require Logger

  @default_timeout_ms 5_000
  @poll_interval_ms 5

  @doc """
  Block until `supervisor` has no active children, or until `:timeout`
  elapses.

  Returns `:ok` when the supervisor quiesced, or `{:timeout, active}`
  with the number of children still running when the deadline passed.

  A timeout is **reported, never swallowed** — callers that cannot act on
  it (like `Platform.DataCase`) log a warning naming the still-running
  count, because a supervised writer that outlives a 5 s drain is a real
  finding about that test, not background noise.

  ## Options

    * `:timeout` — milliseconds to wait (default `#{@default_timeout_ms}`)
    * `:supervisor` — supervisor to drain (default `Platform.TaskSupervisor`)
  """
  @spec await_supervised_writes(keyword()) :: :ok | {:timeout, non_neg_integer()}
  def await_supervised_writes(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    supervisor = Keyword.get(opts, :supervisor, Platform.TaskSupervisor)

    poll(fn -> active_children(supervisor) end, System.monotonic_time(:millisecond) + timeout)
  end

  @doc """
  Number of children currently running under `supervisor`.

  Returns `0` when the supervisor is not running — several test setups
  boot a trimmed supervision tree, and "not started" is indistinguishable
  from "nothing in flight" for drain purposes.
  """
  @spec active_children(Supervisor.supervisor()) :: non_neg_integer()
  def active_children(supervisor \\ Platform.TaskSupervisor) do
    case Process.whereis(supervisor) do
      nil -> 0
      _pid -> Supervisor.count_children(supervisor).active
    end
  end

  # Default deadline for a singleton whose `:__drain__` only has to wait for
  # short telemetry handlers (AttentionRouter, ContextPlane). Unchanged from
  # the inline loop this replaced.
  @singleton_settle_ms 2_000

  # Headroom on top of a full DeadLetterReplay drain, for the Repo reads and
  # writes around the spaced deliveries.
  @dlr_settle_margin_ms 5_000

  @doc """
  Synchronously settle the app-supervised singletons that do Repo work off a
  cast or a telemetry message, so none of it is still in flight when the
  sandbox owner is stopped.

  Each singleton answers `:__drain__` with `{:reply, :ok, state}`; because a
  GenServer mailbox is serial, that reply cannot be sent until every message
  queued ahead of it has been handled. Waiting on the reply is therefore
  waiting on the in-flight work.

  `Platform.Federation.DeadLetterReplay` is the one added in task 01a0d4d6
  stage 1: `RuntimeChannel.join/3` casts `schedule/1`, the drain runs inline in
  `handle_cast` with `spacing_ms/0` sleeps between deliveries, and nothing
  waited for it, so the owner exited mid-`pending_for_runtime/1`. Its deadline
  is derived from its own accessors (one full drain plus a margin), not a
  literal, so a change to the cap or the spacing moves it too.

  `targets` defaults to `settle_targets/0`; the parameter exists so the
  warning path can be pinned against a private process instead of suspending
  a real singleton.

  Resolved with `Process.whereis/1` at call time, never a cached pid: a test
  that restarts a singleton (`dead_letters_test.exs`) replaces it.

  A timeout or exit is **logged, naming the singleton**, and teardown carries
  on — it never terminates anything. Callers: `Platform.DataCase`,
  `PlatformWeb.ConnCase` and `PlatformWeb.ChannelCase` `on_exit`, in BOTH
  sandbox modes, before any drain, quiesce or `Sandbox.stop_owner/1`.
  """
  @spec settle_singletons([{atom(), pos_integer()}]) :: :ok
  def settle_singletons(targets \\ settle_targets()) do
    Enum.each(targets, fn {name, timeout} -> settle_singleton(name, timeout) end)
  end

  @doc false
  @spec settle_targets() :: [{atom(), pos_integer()}]
  def settle_targets do
    dlr = Platform.Federation.DeadLetterReplay

    [
      {Platform.Chat.AttentionRouter, @singleton_settle_ms},
      {Platform.Chat.ContextPlane, @singleton_settle_ms},
      {dlr, dlr.max_per_reconnect() * dlr.spacing_ms() + @dlr_settle_margin_ms}
    ]
  end

  defp settle_singleton(name, timeout) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.call(pid, :__drain__, timeout)
        catch
          :exit, reason ->
            Logger.warning(
              "[SandboxHelpers] #{inspect(name)} did not settle within #{timeout}ms " <>
                "before the sandbox owner released its connection " <>
                "(#{inspect(reason, limit: 5)}) — its in-flight Repo work may be " <>
                "killed mid-query. See Platform.SandboxHelpers.settle_singletons/1."
            )

            :ok
        end
    end
  end

  @doc """
  Make sure no `Platform.Orchestration.TaskRouter` is still running when the
  sandbox owner is stopped. **Shared mode only.**

  ## The leak

  A router traps exits, and its `terminate/2` writes the "Task router stopped
  for task …" row through `ExecutionSpace.post_log/2`. A router still alive at
  `Sandbox.stop_owner/1` was mid-query in `terminate/2` or in a
  `handle_info/2` (a `:dispatch_now` preload,
  `suppress_unresolved_stage_dispatch/3`), and the owner exited under it. That
  is the TASKROUTER class of "owner exited — client is still using a
  connection" events (task 01a0d4d6 stage 2): 9/9/7 per full run at seeds
  77/7700/70007 in the 01a0d265 sweep.

  Neither drain could see it. A router has no `$callers` link to its test, so
  `quiesce_own_or_warn/3` misses it, and it is not a `Platform.TaskSupervisor`
  child, so `drain_or_warn/1` misses it too.

  ## Two kinds of router, two remedies

    * **Children of `Platform.Orchestration.TaskRouterSupervisor`**, which are
      started by `start_assignment/2` or by a `TaskRouterWatcher`. Nothing ends
      these when the test does. Each is stopped with
      `DynamicSupervisor.terminate_child/2`, exactly as
      `TaskRouterSupervisor.stop_assignment/1` does, so `terminate/2` runs its
      real body against a live connection. The child spec is the default
      `GenServer` one, and its 5 000 ms shutdown is enough for `terminate/2`.
      A router the supervisor had to kill is logged by name; the timeout is not
      widened.
    * **Every other router in `Platform.Orchestration.Registry`**. These are
      started with `TaskRouter.start_link/1` straight from a test body, so they
      are linked to the test process. That process has already exited
      (`:shutdown`), so each of these routers already has its parent's EXIT
      queued and is already on its way out. It only needs time to finish the
      handler it is in and then run `terminate/2`. So the helper WAITS for them
      and never terminates them, bounded by `:timeout`, and logs any still
      alive. Measured on the stage-1 tip (`task_router_test.exs`, seed 77, with
      probes): every TASKROUTER event was a start_link router registered under
      a task other than the file's setup task, so the file's own `on_exit`
      never stopped it. It was still registered when `stop_owner/1` ran,
      milliseconds after its test exited.

  Run this before `drain_or_warn/1`. A stopped router ends the preplan settle
  watch it owns (`Platform.Design.PreplanLifecycleStep`), and the unconditional
  drain then waits for that watch.

  ## Why shared mode only

  The reasoning is the same as for `drain_or_warn/1`. In shared mode one test
  owns the VM, so every running router is that test's. In `async: true` mode a
  router could belong to a sibling module that is still running. An async
  file that starts a router must stop it itself, by registering
  `on_exit(fn -> TaskRouterSupervisor.stop_assignment(id) end)` in the test,
  which runs before the case template's callback. No async file starts one
  today.

  Options: `:supervisor` (default `Platform.Orchestration.TaskRouterSupervisor`),
  `:registry` (default `Platform.Orchestration.Registry`) and `:timeout` for
  the wait (default `#{@default_timeout_ms}`, the unconditional drain's). The
  guard test uses the first two to point the helper at private processes.
  """
  @spec stop_task_routers_or_warn(keyword()) :: :ok
  def stop_task_routers_or_warn(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, Platform.Orchestration.TaskRouterSupervisor)
    registry = Keyword.get(opts, :registry, Platform.Orchestration.Registry)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    supervised = supervised_routers(supervisor)
    Enum.each(supervised, &stop_supervised_router(supervisor, &1))

    registry
    |> registered_routers()
    |> Enum.reject(&(&1 in supervised))
    |> await_exits(System.monotonic_time(:millisecond) + timeout)
  end

  defp supervised_routers(supervisor) do
    case GenServer.whereis(supervisor) do
      nil ->
        []

      _pid ->
        for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
            is_pid(pid),
            do: pid
    end
  end

  defp registered_routers(registry) do
    case GenServer.whereis(registry) do
      nil -> []
      _pid -> Registry.select(registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    end
  end

  # Bounds only the gap between the supervisor's reply and our own `:DOWN`
  # (see `stop_supervised_router/2`); it never waits on a live router.
  @router_down_confirm_ms 250

  defp stop_supervised_router(supervisor, pid) do
    ref = Process.monitor(pid)

    try do
      DynamicSupervisor.terminate_child(supervisor, pid)
    catch
      :exit, reason ->
        Logger.warning(
          "[SandboxHelpers] could not stop task router #{inspect(pid)} " <>
            "(#{inspect(reason, limit: 5)}) before the sandbox owner released its " <>
            "connection. See Platform.SandboxHelpers.stop_task_routers_or_warn/1."
        )
    end

    # `terminate_child/2` returns only after the child is gone (or
    # `{:error, :not_found}` when it exited on its own first), so the `:DOWN`
    # has already been sent. Erlang does not order signals from different
    # senders, so it can land a moment after the supervisor's reply.
    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} ->
        Logger.warning(
          "[SandboxHelpers] task router #{inspect(pid)} was killed by its supervisor " <>
            "shutdown timeout. Its terminate/2 did not finish, so its Repo work was cut " <>
            "off. See Platform.SandboxHelpers.stop_task_routers_or_warn/1."
        )

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      @router_down_confirm_ms ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp await_exits([], _deadline), do: :ok

  defp await_exits(pids, deadline) do
    refs = Map.new(pids, &{Process.monitor(&1), &1})
    await_downs(refs, deadline)
  end

  defp await_downs(refs, _deadline) when map_size(refs) == 0, do: :ok

  defp await_downs(refs, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(refs, ref) ->
        await_downs(Map.delete(refs, ref), deadline)
    after
      remaining ->
        Enum.each(refs, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

        Logger.warning(
          "[SandboxHelpers] #{map_size(refs)} task router(s) " <>
            "#{inspect(Map.values(refs))} still running when the sandbox owner " <>
            "released its connection. They are not TaskRouterSupervisor children, " <>
            "so they were waited for, not stopped. See " <>
            "Platform.SandboxHelpers.stop_task_routers_or_warn/1."
        )

        :ok
    end
  end

  @doc false
  @spec drain_or_warn(keyword()) :: :ok
  def drain_or_warn(opts \\ []) do
    case await_supervised_writes(opts) do
      :ok ->
        :ok

      {:timeout, active} ->
        Logger.warning(
          "[SandboxHelpers] #{active} supervised child(ren) still running when the " <>
            "sandbox owner released its connection — their Repo writes will be killed " <>
            "mid-flight. See Platform.SandboxHelpers's moduledoc."
        )

        :ok
    end
  end

  # ONE poller for both drains: the only thing that varies between them is
  # which children get counted, so that is the only thing parameterised. A
  # second copy would be a second deadline shape to keep in step.
  @doc """
  Block until every supervised child **started by `owner_pid`** has exited,
  or until `:timeout` elapses.

  This is `await_supervised_writes/1` narrowed to one owner, and the
  narrowing is what makes it admissible from an `async: true` case where
  the unconditional drain is not. `Task.Supervisor.start_child/2` seeds
  the child's `:"$callers"` process-dictionary entry — which is why such
  a child reaches the sandbox connection at all, since
  `DBConnection.Ownership.Manager.proxy_for/2` resolves an owner by
  walking that chain
  (`deps/db_connection/lib/db_connection/ownership/manager.ex:24-27`).
  The same entry says whose child it is, so the mechanism that creates
  the exposure is the mechanism that scopes the remedy.

  Returns `:ok` when the owner's filtered child set is empty, or
  `{:timeout, active}` with the number of the OWNER'S children still
  running when the deadline passed. As with `await_supervised_writes/1` a
  timeout is **reported, never swallowed** — see `drain_own_or_warn/2`.

  ## Options

    * `:timeout` — milliseconds to wait (default `#{@default_timeout_ms}`,
      the same number as the shared-mode drain). The shared default
      encodes "a supervised writer still running 5 s after its test
      finished is a finding about that test", and that judgement does not
      change with the sharing mode. What changes is the cost of being
      wrong, and it changes in the SAFE direction: this set contains only
      children this owner started, so an idle test pays one poll and
      exits, and the only thing a long wait can be waiting on is work
      this test itself launched. A shorter async-only default would buy
      nothing at the median and would convert a real finding into a
      warning nobody reads.
    * `:supervisor` — supervisor to drain (default `Platform.TaskSupervisor`)
  """
  @spec await_own_supervised_writes(pid(), keyword()) :: :ok | {:timeout, non_neg_integer()}
  def await_own_supervised_writes(owner_pid, opts \\ []) when is_pid(owner_pid) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    supervisor = Keyword.get(opts, :supervisor, Platform.TaskSupervisor)

    poll(
      fn -> length(own_children(owner_pid, supervisor)) end,
      System.monotonic_time(:millisecond) + timeout
    )
  end

  @doc """
  The children of `supervisor` whose `:"$callers"` chain contains `owner_pid`.

  Ownership is the WHOLE chain, not its head: a child that starts a
  further supervised child passes its own callers down, and the audit
  path is exactly that shape (test -> emitter -> `Platform.Audit.record/1`).
  Matching only the head would miss every transitive writer.

  `Process.info/2` returns `nil` for a pid that has already exited, which
  is counted as **not ours** — a child that is gone needs no waiting for,
  and it is the common case in a tight poll loop.

  Returns `[]` when `supervisor` is not running, for the same reason
  `active_children/1` returns `0`: several test setups boot a trimmed
  supervision tree, and "not started" is indistinguishable from "nothing
  in flight" for drain purposes.
  """
  @spec own_children(pid(), Supervisor.supervisor()) :: [pid()]
  def own_children(owner_pid, supervisor \\ Platform.TaskSupervisor) when is_pid(owner_pid) do
    case Process.whereis(supervisor) do
      nil ->
        []

      _pid ->
        supervisor
        |> Task.Supervisor.children()
        |> Enum.filter(&started_by?(&1, owner_pid))
    end
  end

  @doc false
  @spec drain_own_or_warn(pid(), keyword()) :: :ok
  def drain_own_or_warn(owner_pid, opts \\ []) do
    case await_own_supervised_writes(owner_pid, opts) do
      :ok ->
        :ok

      {:timeout, active} ->
        warn_drain_gave_up(owner_pid, active)

        :ok
    end
  end

  # One shared warning body for both drains' deadline branch: the wording IS
  # the finding ("the owner released its connection under a live client"), and
  # two copies of it would drift.
  defp warn_drain_gave_up(owner_pid, active) do
    Logger.warning(
      "[SandboxHelpers] #{active} supervised child(ren) started by " <>
        "#{inspect(owner_pid)} still running when the sandbox owner released " <>
        "its connection — their Repo writes will be killed mid-flight. " <>
        "See Platform.SandboxHelpers's moduledoc."
    )
  end

  # The confirmation wait between termination rounds. Longer than a killed
  # child needs to die (an exit signal is immediate and the poll interval is
  # 5 ms), short enough that a stuck terminate cannot hang a teardown.
  @terminate_confirm_ms 250

  # The quiesce's OWN default for its drain phase. It is NOT the wait-only
  # drain's 5 s, on purpose, and the difference is measured: the drain phase
  # of a QUIESCE exists to let in-flight Repo writes land (millisecond-scale —
  # the baseline leak log shows the edge's writes arriving as single queries),
  # while the children that actually need quiescing are parked on a 30-minute
  # gate budget and will NEVER exit inside any drain. Every second of waiting
  # for them is paid again on every teardown of every plan-submission test,
  # and the terminal step below is what actually ends them. An explicit
  # `:timeout` opt (the `sandbox_drain_timeout` tag) still wins untouched.
  @quiesce_drain_default_ms 1_000

  # Rounds of {snapshot, terminate} after the drain deadline. One is enough for
  # a child that spawns nothing; the architect gate's edge runner spawns its
  # own watcher child, and a child that dies between the snapshot and its own
  # termination can leave that grandchild behind — so the loop re-looks rather
  # than trusting one snapshot. Three is not a tuned number: a shape needing a
  # fourth round is a new finding, not a round count.
  @terminate_rounds 3

  @doc """
  `drain_own_or_warn/2` plus a terminal step: children of `test_pid` that are
  STILL alive when the drain deadline passes are terminated — but only while
  the sandbox `owner_pid` is still alive.

  `test_pid` is the ownership key (the `:"$callers"` filter, exactly as in
  `await_own_supervised_writes/2`); `owner_pid` is the sandbox owner agent the
  caller is about to stop. `opts` are the drain's own options; an explicit
  `:timeout` there is respected as-is, while the default is this function's
  own `#{@quiesce_drain_default_ms}` ms rather than the wait-only drain's
  5 s — see `@quiesce_drain_default_ms` above for why.

  ## Why the terminal step exists at all

  `await_own_supervised_writes/2` waits for children to EXIT. A legitimate
  child can have no exit inside any teardown-shaped deadline. The measured one
  is the architect gate's lifecycle edge (task 01a0d265 stage 2):
  `Platform.Tasks.run_architect_edge/1` spawns the edge runner on
  `Platform.TaskSupervisor` fire-and-forget; the runner parks in a `receive`
  waiting for the gate to resolve — a human timescale, `Lifecycle.step_timeout_ms/0`
  ships 30 minutes — while its watcher child polls the gate row once per
  second through the test's sandbox owner. When the test finishes first the
  owner exits, and every client still inside a query dies as
  `owner #PID<…> exited — Client #PID<…> is still using a connection from
  owner`: one pool connection withheld per event. The scoped drain alone does
  not prevent this — the baseline full-suite log for task 01a0d265 shows 14
  such events attributable to the edge in a run where ConnCase's caller-scoped
  drain was already wired in, because no wait outlasts a 30-minute budget.

  Terminating the client BEFORE the owner exits is what that error is defined
  against: `DBConnection` returns a connection whose client died to the
  still-alive owner silently, while an owner that dies under a live client is
  the disconnect event this module exists to prevent. So the order is: drain
  (in-flight writes land inside the still-open sandbox transaction), then
  terminate the leftovers, then — in the caller — `Sandbox.stop_owner/1`.

  ## Why the termination is gated on the owner being alive

  If the owner is already gone when the drain gives up, the disconnect has
  already happened and a termination would save no connection — it would only
  destroy whatever those children had left to record.
  `PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest` DEPENDS on that: its
  owner is stopped by the test body on purpose, its orphans are parked on the
  ownership proxy's wait queue at that moment, and their readings are the
  case's measurements. So: owner alive → drain, terminate, report; owner gone
  → the same timeout warning `drain_own_or_warn/2` gives, and nothing more.

  ## Scope — unchanged from `drain_own_or_warn/2`

  Only children whose `:"$callers"` chain names `test_pid` are ever waited on
  or terminated. A concurrent module's children are never visible to this
  call, which is what makes it admissible from `async: true` cases AND from
  the shared-mode branch — where async children legitimately keep running and
  the unconditional drain's own moduledoc records why that branch must not
  widen to them.
  """
  @spec quiesce_own_or_warn(pid(), pid(), keyword()) :: :ok
  def quiesce_own_or_warn(test_pid, owner_pid, opts \\ [])
      when is_pid(test_pid) and is_pid(owner_pid) do
    opts = Keyword.put_new(opts, :timeout, @quiesce_drain_default_ms)

    case await_own_supervised_writes(test_pid, opts) do
      :ok ->
        :ok

      {:timeout, active} ->
        if Process.alive?(owner_pid) do
          killed = terminate_remaining(test_pid, @terminate_rounds, 0)

          case await_own_supervised_writes(test_pid, timeout: @terminate_confirm_ms) do
            :ok ->
              Logger.warning(
                "[SandboxHelpers] terminated #{killed} supervised child(ren) started " <>
                  "by #{inspect(test_pid)} — still running when the drain deadline " <>
                  "passed with the sandbox owner alive. A client that dies before " <>
                  "its owner returns the connection instead of leaking it past " <>
                  "teardown. See Platform.SandboxHelpers's moduledoc " <>
                  "(quiesce_own_or_warn/3)."
              )

            {:timeout, left} ->
              Logger.warning(
                "[SandboxHelpers] terminated #{killed} supervised child(ren) started " <>
                  "by #{inspect(test_pid)} but #{left} still running — a child this " <>
                  "drain can neither see nor stop is holding a connection the owner " <>
                  "is about to release. See Platform.SandboxHelpers's moduledoc " <>
                  "(quiesce_own_or_warn/3)."
              )
          end
        else
          # The owner was stopped by the test body (the beyond-drain
          # construction) before this teardown ran. The disconnect has already
          # happened; terminating the parked children now would only destroy
          # the readings that construction exists to record. Report exactly as
          # the wait-only drain does and leave them be.
          warn_drain_gave_up(test_pid, active)
        end

        :ok
    end
  end

  # Snapshot this owner's children, terminate every one, confirm, and look
  # again — each round covers a grandchild spawned between an earlier snapshot
  # and its parent's death. The count is children TERMINATED, not children
  # that existed: a pid that died on its own between snapshot and terminate
  # costs nothing and reports nothing.
  defp terminate_remaining(test_pid, rounds_left, killed) when rounds_left > 0 do
    own = own_children(test_pid)

    if own == [] do
      killed
    else
      Enum.each(own, &terminate_one/1)
      await_own_supervised_writes(test_pid, timeout: @terminate_confirm_ms)
      terminate_remaining(test_pid, rounds_left - 1, killed + length(own))
    end
  end

  defp terminate_remaining(_test_pid, 0, killed), do: killed

  defp terminate_one(pid) do
    try do
      Task.Supervisor.terminate_child(Platform.TaskSupervisor, pid)
    catch
      # A supervisor that is not running (trimmed test supervision trees) exits
      # the call; a pid that already exited is handled by the loop above, not
      # here. Neither is a finding worth crashing a teardown over.
      :exit, _reason -> :ok
    end
  end

  defp started_by?(pid, owner_pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, :"$callers", 0) do
          {_key, callers} when is_list(callers) -> owner_pid in callers
          _other -> false
        end

      nil ->
        false
    end
  end

  defp poll(count_fun, deadline) do
    case count_fun.() do
      0 ->
        :ok

      active ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, active}
        else
          Process.sleep(@poll_interval_ms)
          poll(count_fun, deadline)
        end
    end
  end
end
