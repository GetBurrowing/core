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

  ## Why only shared (non-`async`) tests

  In `:manual` mode a `Task.Supervisor` child is not in the owner chain
  at all — it has no connection to protect, and `Repo` calls from it
  raise `DBConnection.OwnershipError` (which the handler's existing
  `rescue` does cover). Worse, `async: true` modules run concurrently, so
  `Platform.TaskSupervisor`'s child set there belongs to *other* modules
  as much as to this one, and waiting on it would be waiting on an
  unrelated test. The drain is only meaningful, and only correct, for a
  shared-mode owner.
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

    poll(supervisor, System.monotonic_time(:millisecond) + timeout)
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

  defp poll(supervisor, deadline) do
    case active_children(supervisor) do
      0 ->
        :ok

      active ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, active}
        else
          Process.sleep(@poll_interval_ms)
          poll(supervisor, deadline)
        end
    end
  end
end
