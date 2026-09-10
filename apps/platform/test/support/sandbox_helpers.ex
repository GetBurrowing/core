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
  `drain_own_or_warn/2`) before `Sandbox.stop_owner/1`, which is what
  removes the orphan this module's opening section describes. Both
  directions of the filter are pinned by
  `Platform.SandboxHelpersScopedDrainTest`, in particular that a child
  started by a foreign process is NOT waited for — because "excludes
  everything" would satisfy a one-sided test and would silently reinstate
  the defect.

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
        Logger.warning(
          "[SandboxHelpers] #{active} supervised child(ren) started by " <>
            "#{inspect(owner_pid)} still running when the sandbox owner released " <>
            "its connection — their Repo writes will be killed mid-flight. " <>
            "See Platform.SandboxHelpers's moduledoc."
        )

        :ok
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
