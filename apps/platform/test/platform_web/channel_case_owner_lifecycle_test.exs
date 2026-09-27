# Pins that `PlatformWeb.ChannelCase` owns the sandbox connection from a
# SEPARATE agent, alive through the whole `on_exit` chain (task 01a0d4d6
# stage 1). Mirrors `conn_case_owner_lifecycle_test.exs`.
#
# Under the previous `Sandbox.checkout(Repo)` the TEST process was the owner.
# ExUnit runs `on_exit` after the test process has terminated, so the owner was
# already gone before ChannelCase's teardown barrier
# (`Platform.SandboxHelpers.settle_singletons/1`) could run — a
# `DeadLetterReplay` drain cast by `RuntimeChannel.join/3` then lost its
# connection mid-query. No barrier can fix that while the owner is the test.
#
# ORDER: ExUnit runs on_exit callbacks in reverse registration order and
# ChannelCase's `setup` registers before any test body does, so a callback
# registered here runs BEFORE ChannelCase's own. An owner alive here is alive
# when ChannelCase's barrier runs, because that barrier precedes
# `Sandbox.stop_owner/1` inside the same callback.

defmodule PlatformWeb.ChannelCaseOwnerLifecycleTest do
  use PlatformWeb.ChannelCase, async: false

  test "the sandbox owner is not the test process and is alive during on_exit", context do
    test_pid = self()
    owner = context[:sandbox_owner]

    assert is_pid(owner),
           "ChannelCase does not expose a :sandbox_owner — it is no longer owning the " <>
             "connection from a separate agent (Sandbox.start_owner!/2)"

    refute owner == test_pid,
           "the sandbox owner IS the test process, so it dies before any on_exit runs"

    on_exit(fn ->
      refute Process.alive?(test_pid),
             "expected the test process to be dead by the time on_exit runs; " <>
               "if it is alive this test is not measuring the owner lifecycle at all"

      assert Process.alive?(owner),
             "the sandbox owner was dead before ChannelCase's teardown barrier ran"
    end)
  end

  test "an on_exit callback can still read the Repo (shared mode)" do
    test_pid = self()

    on_exit(fn ->
      refute Process.alive?(test_pid)

      assert is_integer(Platform.Repo.aggregate(Platform.Audit.Event, :count)),
             "an on_exit callback could not read the Repo — the connection went " <>
               "away with the test process"
    end)
  end
end

defmodule PlatformWeb.ChannelCaseOwnerLifecycleAsyncTest do
  use PlatformWeb.ChannelCase, async: true

  alias Ecto.Adapters.SQL.Sandbox

  # Manual mode: the on_exit runner is neither owner nor allowed, so it cannot
  # read directly (see conn_case_owner_lifecycle_test.exs). What the owner agent
  # changes here is that an allowed process surviving the body can still use
  # the connection during on_exit.
  test "a survivor allowed on the connection can still read during on_exit (manual mode)" do
    test_pid = self()

    # Unlinked on purpose: a linked child dies with the test process.
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
  end
end
