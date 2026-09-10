# Pins the DETERMINISTIC consequence of `PlatformWeb.ConnCase` checking the
# sandbox connection out into the TEST PROCESS (`Sandbox.checkout/1`) rather
# than into a separate owner agent (`Sandbox.start_owner!/2`).
#
# ExUnit runs `on_exit` callbacks in a *different* process, *after* the test
# process has already terminated. Under `checkout` the test process IS the
# connection owner, so by the time any `on_exit` runs the connection has
# already been torn down with its owner. `Platform.DataCase` documents this
# at `test/support/data_case.ex:24-41` and already owns from an agent for
# exactly this reason; these modules assert the property ConnCase was missing.
#
# THE TWO MODES ASSERT DIFFERENT PROPERTIES, AND THAT IS NOT A SHORTCUT.
# Measured on this branch, both before and after the migration:
#
#   * SHARED mode (`async: false`) — `{:shared, owner}` lets *any* process
#     without its own checkout use the connection, so once the owner outlives
#     the test process the on_exit runner can read the Repo directly. Red
#     before the migration ("owner #PID<...> exited"), green after.
#
#   * MANUAL mode (`async: true`) — there is no sharing, and the on_exit
#     runner (`ExUnit.OnExitHandler`) is neither the owner nor an allowed
#     process, and ExUnit does not place it in the owner's `$callers` chain.
#     A *direct* Repo call from on_exit therefore raises
#     `DBConnection.OwnershipError` both BEFORE and AFTER this migration —
#     verified against `Platform.DataCase, async: true`, which has used the
#     `start_owner!` shape since task 019f9d80 and fails identically. That
#     hole belongs to ExUnit's on_exit runner, not to ConnCase, and migrating
#     ConnCase neither causes nor closes it.
#
# So the manual-mode case asserts what the migration ACTUALLY changes there:
# the connection now outlives the test process, so a process that was allowed
# on it and that survives the test body can still use it during the on_exit
# chain. Before the migration that survivor's connection died with the test
# process. This is the property the ticket cares about — a writer outliving
# the test — expressed deterministically instead of as a race.
#
# `Sandbox.stop_owner/1` runs LAST because ExUnit runs on_exit callbacks in
# reverse registration order and ConnCase's `setup` registers before any test
# body does. That ordering is load-bearing for the survivor cases below.

defmodule PlatformWeb.ConnCaseOwnerLifecycleTest do
  use PlatformWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  test "an on_exit callback can still read the Repo (shared mode)", %{conn: conn} do
    test_pid = self()

    on_exit(fn ->
      refute Process.alive?(test_pid),
             "expected the test process to be dead by the time on_exit runs; " <>
               "if it is alive this test is not measuring the owner lifecycle at all"

      assert is_integer(Platform.Repo.aggregate(Platform.Audit.Event, :count)),
             "an on_exit callback could not read the Repo"
    end)

    assert %Plug.Conn{} = conn
  end

  test "a survivor allowed on the connection can still read during on_exit (shared mode)", %{
    conn: conn
  } do
    test_pid = self()

    # Unlinked on purpose: a linked child dies with the test process and would
    # measure nothing.
    {:ok, survivor} = Agent.start(fn -> :ok end)
    assert :ok = Sandbox.allow(Platform.Repo, self(), survivor)

    on_exit(fn ->
      refute Process.alive?(test_pid)

      assert Process.alive?(survivor),
             "the survivor must outlive the test process for this to measure anything"

      count =
        Agent.get(survivor, fn _ -> Platform.Repo.aggregate(Platform.Audit.Event, :count) end)

      assert is_integer(count)

      Agent.stop(survivor)
    end)

    assert %Plug.Conn{} = conn
  end
end

defmodule PlatformWeb.ConnCaseOwnerLifecycleAsyncTest do
  use PlatformWeb.ConnCase, async: true

  alias Ecto.Adapters.SQL.Sandbox

  test "a survivor allowed on the connection can still read during on_exit (manual mode)", %{
    conn: conn
  } do
    test_pid = self()

    # Unlinked on purpose — the deterministic stand-in for the fire-and-forget
    # writers this ticket is about.
    {:ok, survivor} = Agent.start(fn -> :ok end)

    # `self()` is a valid `owner_or_allowed` parent in BOTH shapes: it is the
    # owner before the migration, and an allowed process after it, because
    # `start_owner!/2`'s `shared: false` branch allows its caller.
    assert :ok = Sandbox.allow(Platform.Repo, self(), survivor)

    on_exit(fn ->
      refute Process.alive?(test_pid),
             "expected the test process to be dead by the time on_exit runs; " <>
               "if it is alive this test is not measuring the owner lifecycle at all"

      assert Process.alive?(survivor),
             "the survivor must outlive the test process for this to measure anything"

      # Before the migration the connection was torn down with the test
      # process and this raises. After it, the owner agent is still alive:
      # ConnCase's own `stop_owner/1` has not run yet, because it was
      # registered first and on_exit runs in reverse order.
      count =
        Agent.get(survivor, fn _ -> Platform.Repo.aggregate(Platform.Audit.Event, :count) end)

      assert is_integer(count)

      Agent.stop(survivor)
    end)

    assert %Plug.Conn{} = conn
  end
end
