# Guards the WIRING, not the helper: that `PlatformWeb.ConnCase`'s `async: true`
# teardown actually calls the scoped drain before `Sandbox.stop_owner/1`.
#
# `Platform.SandboxHelpersScopedDrainTest` pins what
# `await_own_supervised_writes/2` does. Nothing there notices if ConnCase stops
# calling it — delete the call and every one of those tests stays green, because
# they call the helper directly. This file closes that: it asserts an OBSERVABLE
# CONSEQUENCE of the call, from an `async: true` ConnCase case, so removing the
# call from `conn_case.ex` turns it red.
#
# The consequence chosen is deliberately the smallest one that can only be
# produced by the drain: a supervised child that touches the Repo AFTER its test
# body has returned is served rather than orphaned. Before the drain the sandbox
# owner was torn down as soon as the body returned, so that child's `Repo` call
# raised `DBConnection.OwnershipError`; with the drain the owner is held until
# the child exits, so it succeeds.
#
# Deliberately NOT measured here: `:telemetry.list_handlers/1`, the audit row
# count, or the failure class. Those belong to
# `conn_case_supervised_orphan_test.exs`, which characterises the defect the
# drain exists to remove. This file only answers "is the drain wired in", and a
# bare `SELECT 1` liveness probe answers that without importing the audit path's
# failure modes into the diagnosis.
#
# No blocker process, on purpose. A construction that holds the single sandbox
# connection for seconds starves the very write this file expects to SUCCEED —
# DBConnection drops a queued request after its `:queue_target` /
# `:queue_interval` budget (50 ms / 1000 ms by default), which arrives as a
# `DBConnection.ConnectionError` raise and reads as "the drain did not work"
# when in fact the construction did not let it. Measured while building stage 2
# of task 01a08b49; recorded here because the mistake is easy to repeat.
defmodule PlatformWeb.ConnCaseScopedDrainTest do
  use PlatformWeb.ConnCase, async: true

  @outcome_key {:conn_case_scoped_drain, :outcome}

  # Comfortably past the return of the test body, so the child's Repo call
  # cannot land while the body is still running — the whole question is whether
  # the owner is still there afterwards.
  @after_body_ms 150

  test "an async ConnCase test's own supervised child is still served after the body returns",
       %{conn: conn} do
    assert %Plug.Conn{} = conn

    :persistent_term.put(@outcome_key, :never_ran)

    {:ok, child} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        Process.sleep(@after_body_ms)

        outcome =
          try do
            case Platform.Repo.query("SELECT 1") do
              {:ok, %{rows: [[1]]}} ->
                :served

              # MEASURED: this is the shape an un-drained orphan produces —
              # `Repo.query/2` RETURNS the ownership error rather than raising
              # it, so a test that only looked for a raise would report
              # "unexpected" and bury the diagnosis.
              {:error, %DBConnection.OwnershipError{}} ->
                :orphaned

              other ->
                {:unexpected, inspect(other, limit: 8)}
            end
          rescue
            error -> {:raise, error.__struct__, Exception.message(error)}
          catch
            :exit, reason -> {:exit, inspect(reason, limit: 8)}
          end

        :persistent_term.put(@outcome_key, outcome)
      end)

    assert Process.alive?(child)

    # Positive control — the child has NOT done its work yet at the moment this
    # body returns. Without this the assertion in the observation module could
    # be satisfied by a child that finished while the test was still running,
    # which the drain plays no part in.
    assert :persistent_term.get(@outcome_key) == :never_ran,
           "the child reported before the test body returned, so this file is not " <>
             "measuring teardown at all"
  end
end

defmodule PlatformWeb.ConnCaseScopedDrainObservationTest do
  @moduledoc """
  Reads the outcome recorded by `PlatformWeb.ConnCaseScopedDrainTest`.

  `async: false` on purpose: the outcome is written during that module's
  teardown, after its test process is dead, so there is no point inside the
  test body at which it can be asserted. ExUnit runs every asynchronous module
  before any synchronous one, and this still polls with a deadline rather than
  resting on that ordering.
  """
  use ExUnit.Case, async: false

  @outcome_key {:conn_case_scoped_drain, :outcome}
  @deadline_ms 15_000

  setup_all do
    on_exit(fn -> :persistent_term.erase(@outcome_key) end)
    :ok
  end

  test "ConnCase's async teardown drains the test's own supervised writers" do
    assert await_outcome() == :served,
           """
           An `async: true` ConnCase test's own supervised child was NOT served after
           the test body returned. Got: #{inspect(await_outcome(), limit: 8)}

           `:orphaned` (a returned `DBConnection.OwnershipError`) means the sandbox
           owner was gone before the child reached the Repo — i.e.
           `PlatformWeb.ConnCase`'s `on_exit` is no longer calling
           `Platform.SandboxHelpers.drain_own_or_warn/2` on its `async: true` branch,
           or is calling it AFTER `Sandbox.stop_owner/1`. That is the orphan of task
           01a089ee / 01a08b49: the child's write is destroyed and, on the audit path,
           the resulting process exit detaches "platform-audit-telemetry" for the
           whole VM. This exact reading was measured by deleting the call (mutation
           M2 of stage 2).

           `{:raise, DBConnection.ConnectionError, _}` means the child WAS still owned
           but could not get the connection inside DBConnection's queue budget —
           check whether something in this run holds the sandbox connection for
           longer than `:queue_interval`.
           """
  end

  defp await_outcome do
    do_await(System.monotonic_time(:millisecond) + @deadline_ms)
  end

  defp do_await(deadline) do
    case :persistent_term.get(@outcome_key, :ABSENT) do
      :ABSENT ->
        flunk("""
        No outcome recorded.

        PlatformWeb.ConnCaseScopedDrainTest must run in the SAME BEAM as this module
        — it is what produces the outcome. Run the whole file, not this module alone.
        """)

      :never_ran ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("the supervised child never reported within #{@deadline_ms}ms")
        else
          Process.sleep(10)
          do_await(deadline)
        end

      outcome ->
        outcome
    end
  end
end
