defmodule Platform.Audit.HistorianLatencyTest do
  @moduledoc """
  Task 019f5bc4 stage 4 — proves the async bridging path added in stage 2
  keeps `:telemetry.execute/3` p99 latency under 1ms even at 10k events.

  Guards against a future accidental regression to synchronous
  `Platform.Audit.record/1` on the caller thread.

  ## Sandbox note

  Each spawned Task under `Platform.TaskSupervisor` is NOT in this test's
  DataCase sandbox owner chain, so their `Repo.insert` will raise
  `DBConnection.OwnershipError`. That is expected and swallowed by the
  handler's `rescue DBConnection.OwnershipError` clause
  (`telemetry_handler.ex:130`). The point of this test is caller-visible
  emit latency, not durable persistence — persistence is exercised by
  `Platform.Audit.HistorianAuditTest` (stage 3) and the stage-5 e2e cases.
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
