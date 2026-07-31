defmodule Platform.DataCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a database connection.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo

  using do
    quote do
      alias Platform.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Platform.AsyncAssertions
      import Platform.DataCase
    end
  end

  setup tags do
    # The sandbox connection is owned by a SEPARATE agent process, not by
    # the test process (task 019f9d80 stage 3). This is Ecto's documented
    # `start_owner!/stop_owner` shape and the change is load-bearing, not
    # cosmetic.
    #
    # With the previous `Sandbox.checkout(Repo)` form the TEST process was
    # the owner, and ExUnit runs `on_exit` callbacks in a different process
    # *after* the test process has already terminated. Measured: on_exit
    # observes `Process.alive?(test_pid) == false`, and a `Repo` call from
    # inside on_exit raises `DBConnection.OwnershipError` because the
    # connection went away with its owner.
    #
    # That makes every connection-dependent on_exit below a no-op — including
    # the AttentionRouter drain, which has been dead since it was written
    # despite its comment stating the opposite. Owning from an agent keeps
    # the connection alive until `stop_owner/1` runs at the END of the
    # on_exit chain, which is what those callbacks always assumed.
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])

    # `start_owner!/2` allows the calling process ONLY on its `shared: false`
    # branch (`sandbox.ex:459`); the shared branch just sets `{:shared, owner}`,
    # which lets the test process USE the connection but leaves it neither
    # owner nor allowed. 24 test files call
    # `Sandbox.allow(Repo, self(), some_pid)` and match on `:ok`, and
    # `DBConnection.Ownership.allow/4` takes an `owner_or_allowed` parent — so
    # without this the shared-mode half of the suite gets `:not_found` there.
    # Explicitly allowing the test process keeps `self()` a valid parent in
    # both modes and leaves every one of those call sites untouched.
    if not tags[:async], do: Sandbox.allow(Repo, owner, self())

    # Allow supervised GenServers that use Repo (e.g. AttentionRouter) to
    # share the test sandbox connection so telemetry-driven DB calls don't
    # raise DBConnection.OwnershipError. Parent is the owner agent — in
    # `async: true` the test process is itself only an *allowed* process, so
    # passing `self()` here would no longer name an owner.
    #
    # `Platform.Orchestration.TaskRouterWatcher` was removed from this list in
    # task 019fb978 stage 2. Allow-listing it here was never sufficient: the
    # allowance binds the watcher to THIS test's connection, and the watcher
    # is a global singleton subscribed to `tasks:board`, so the NEXT test's
    # broadcast reaches a process still bound to the previous — now dead —
    # connection. Measured at 145 ownership violations per full-suite run.
    # It is now gated off in test entirely (`:start_task_router_watcher`,
    # config/test.exs) and started per-case by the tests that need it.
    supervised_with_repo = [
      Platform.Chat.AttentionRouter,
      Platform.Agents.ContextBroker,
      Platform.Chat.ContextPlane,
      Platform.Responsibilities.Router
    ]

    Enum.each(supervised_with_repo, fn name ->
      if pid = Process.whereis(name) do
        Sandbox.allow(Repo, owner, pid)
      end
    end)

    # Drain the AttentionRouter's message queue before the sandbox is released.
    # A synchronous call guarantees any in-flight telemetry handle_info messages
    # have been fully processed (and their Repo calls completed) before the
    # sandbox owner exits and the connection is freed.
    #
    # Task 019f9d80 stage 3 extends the same callback, for the same reason, to
    # the OTHER kind of in-flight writer: fire-and-forget children spawned under
    # `Platform.TaskSupervisor` (the audit handler's async historian branch is
    # the high-volume one). Those have no lifecycle tie to the emitting process,
    # so without the wait the connection is torn down mid-`INSERT` — measured at
    # 10 011 live children at the end of `HistorianLatencyTest`'s emit loop.
    # Shared mode only; see `Platform.SandboxHelpers` for why `async: true` must
    # NOT drain.
    shared_mode? = not tags[:async]

    on_exit(fn ->
      for name <- [Platform.Chat.AttentionRouter, Platform.Chat.ContextPlane] do
        if pid = Process.whereis(name) do
          try do
            GenServer.call(pid, :__drain__, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end

      if shared_mode?, do: Platform.SandboxHelpers.drain_or_warn()

      # LAST. Everything above needs a live connection.
      Sandbox.stop_owner(owner)
    end)

    :ok
  end
end
