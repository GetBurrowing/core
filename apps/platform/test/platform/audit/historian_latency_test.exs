defmodule Platform.Audit.HistorianLatencyTest do
  @moduledoc """
  Task 019f5bc4 stage 4 — proves the async bridging path added in stage 2
  keeps `:telemetry.execute/3` p99 latency under 1ms even at 10k events.

  Guards against a future accidental regression to synchronous
  `Platform.Audit.record/1` on the caller thread.

  ## Sandbox note (corrected 2026-07-26, task 019f9d80 stage 3)

  This note previously read: "Each spawned Task under
  `Platform.TaskSupervisor` is NOT in this test's DataCase sandbox owner
  chain, so their `Repo.insert` will raise `DBConnection.OwnershipError`.
  That is expected and swallowed by the handler's rescue clause."

  **Every clause of that was wrong**, and believing it is what hid the
  real behaviour. This module is `async: false`, so `Platform.DataCase`
  puts the sandbox in `{:shared, self()}` mode and the spawned children
  *do* inherit this test's connection. Their `Repo.insert` succeeds. No
  `OwnershipError` is raised and the rescue never fires.

  What actually happens is the opposite problem. `Task.Supervisor.start_child`
  gives the children no lifecycle tie to this process, and 10 000 of them
  cannot drain against one shared connection as fast as this loop emits:
  measured, **10 011 children are still alive at the moment the emit loop
  returns**. Left alone, this test's owner then exits and DBConnection
  kills the connection under all of them mid-`INSERT`.

  `Platform.DataCase`'s `on_exit` now waits for them
  (`Platform.SandboxHelpers.await_supervised_writes/1`) before the
  connection is released, which costs this module a couple of seconds of
  teardown and costs quiescent modules nothing. The wait is deliberately
  NOT inside the measured region below — it must not, and does not,
  affect the p99 this test asserts.

  The point of this test remains caller-visible emit latency, not durable
  persistence; persistence is exercised by `Platform.Audit.HistorianAuditTest`
  and by the drain cases in `telemetry_handler_test.exs`.
  """

  use Platform.DataCase, async: false

  alias Platform.Audit.TelemetryHandler

  @sample_size 10_000
  @p99_budget_us 1_000

  setup do
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)

    :ok
  end

  test "historian window_dispatched emit p99 stays under 1ms across #{@sample_size} events" do
    workspace_id = Ecto.UUID.generate()

    measurements = %{token_count: 100, window_index: 1, day_bytes: 100}

    metadata = %{
      corpus: :pages,
      oversize: false,
      workspace_id: workspace_id,
      resource_type: "workspace",
      resource_id: workspace_id,
      action: "window_dispatched",
      actor_type: "system"
    }

    # JIT warmup — first few hundred emits pay the interpreter→native
    # compile cost and skew the p99 tail if included in the sample.
    for _ <- 1..500 do
      :telemetry.execute([:platform, :historian, :window_dispatched], measurements, metadata)
    end

    samples =
      for _ <- 1..@sample_size do
        t0 = System.monotonic_time(:microsecond)

        :telemetry.execute(
          [:platform, :historian, :window_dispatched],
          measurements,
          metadata
        )

        System.monotonic_time(:microsecond) - t0
      end

    sorted = Enum.sort(samples)
    p50 = Enum.at(sorted, div(@sample_size, 2))
    p95 = Enum.at(sorted, div(@sample_size * 95, 100))
    p99 = Enum.at(sorted, div(@sample_size * 99, 100))

    # Log for future baseline shifts — captured in the ExUnit output so
    # a reviewer can eyeball the trend across CI runs.
    IO.puts(
      "\nhistorian emit latency (µs) over #{@sample_size} events: " <>
        "p50=#{p50} p95=#{p95} p99=#{p99}"
    )

    assert p99 < @p99_budget_us,
           "p99 #{p99}µs exceeded #{@p99_budget_us}µs budget — handler may have regressed " <>
             "to sync dispatch. p50=#{p50} p95=#{p95}"
  end
end
