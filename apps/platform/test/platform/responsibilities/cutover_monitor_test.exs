defmodule Platform.Responsibilities.CutoverMonitorTest do
  @moduledoc """
  Tests for the M8 stage 6 `Platform.Responsibilities.CutoverMonitor` —
  the GenServer that subscribes to router + dual-write telemetry events
  and produces the report the cutover decision is gated on.

  Each test starts its own monitor with a unique :name so the
  application singleton (disabled via `:start_cutover_monitor false` in
  `config/test.exs`) is never claimed.
  """
  use ExUnit.Case, async: false

  alias Platform.Responsibilities.CutoverMonitor

  defp unique_name do
    Module.concat([CutoverMonitor, "Inst#{System.unique_integer([:positive])}"])
  end

  defp start_monitor do
    name = unique_name()
    pid = start_supervised!({CutoverMonitor, name: name})
    {pid, name}
  end

  defp emit_router_fired(key, opts \\ []) do
    :telemetry.execute(
      [:platform, :responsibility, :fired],
      %{system_time: System.system_time()},
      %{
        key: key,
        feature: Keyword.get(opts, :feature, "memory"),
        dispatch_kind: Keyword.get(opts, :dispatch_kind, :external),
        agent_slug: Keyword.get(opts, :agent_slug, "scribe")
      }
    )
  end

  defp emit_dual_write(key, legacy_ok?, router_ok?) do
    :telemetry.execute(
      [:platform, :responsibilities, :dual_write],
      %{system_time: System.system_time()},
      %{
        key: key,
        legacy_result: if(legacy_ok?, do: :ok, else: {:error, :boom}),
        router_result: if(router_ok?, do: :ok, else: {:error, :boom}),
        legacy_ok?: legacy_ok?,
        router_ok?: router_ok?,
        workspace_id: nil
      }
    )
  end

  # Give the GenServer a moment to process forwarded telemetry messages.
  # The handler attach/send is synchronous from the perspective of the
  # telemetry callback, but the message lands in the mailbox; one ping
  # via a synchronous call after the emit guarantees the prior info
  # message has been drained.
  defp sync(name), do: CutoverMonitor.report(name)

  describe "report/1 with no events" do
    test "returns zero counters for every tracked key" do
      {_pid, name} = start_monitor()
      report = CutoverMonitor.report(name)

      assert report.as_of == Date.utc_today()

      Enum.each(CutoverMonitor.tracked_keys(), fn key ->
        assert %{router: 0, legacy: 0, divergence_count: 0} = Map.fetch!(report.keys, key)
      end)
    end
  end

  describe "router-fired events" do
    test "increment the :router counter for tracked keys" do
      {_pid, name} = start_monitor()

      emit_router_fired("memory.daily_summary")
      emit_router_fired("memory.daily_summary")
      emit_router_fired("memory.dreaming")
      _ = sync(name)

      report = CutoverMonitor.report(name)
      assert report.keys["memory.daily_summary"].router == 2
      assert report.keys["memory.dreaming"].router == 1
    end

    test "ignore untracked keys (e.g. meetings.summarize)" do
      {_pid, name} = start_monitor()

      emit_router_fired("meetings.summarize", feature: "meetings")
      _ = sync(name)

      report = CutoverMonitor.report(name)
      # Tracked keys remain zero — the meetings.* event is silently dropped.
      assert report.keys["memory.daily_summary"].router == 0
      assert report.keys["memory.dreaming"].router == 0
    end
  end

  describe "dual-write events" do
    test "increment :legacy when legacy_ok? is true and ignore router_ok? for that counter" do
      {_pid, name} = start_monitor()

      emit_dual_write("memory.daily_summary", true, true)
      emit_dual_write("memory.daily_summary", true, false)
      _ = sync(name)

      report = CutoverMonitor.report(name)
      # Two legacy successes.
      assert report.keys["memory.daily_summary"].legacy == 2
      # Router count comes from the :fired event, not dual_write, so it stays 0.
      assert report.keys["memory.daily_summary"].router == 0
    end

    test "increment divergence_count when exactly one path succeeded" do
      {_pid, name} = start_monitor()

      # both ok → no divergence
      emit_dual_write("memory.dreaming", true, true)
      # legacy ok, router failed → divergence
      emit_dual_write("memory.dreaming", true, false)
      # both failed → no divergence (they agreed)
      emit_dual_write("memory.dreaming", false, false)
      # router ok, legacy failed → divergence
      emit_dual_write("memory.dreaming", false, true)

      _ = sync(name)

      report = CutoverMonitor.report(name)
      assert report.keys["memory.dreaming"].divergence_count == 2
      # Legacy succeeded twice (the first two events).
      assert report.keys["memory.dreaming"].legacy == 2
    end

    test "router success + legacy success registers no divergence" do
      {_pid, name} = start_monitor()

      Enum.each(1..5, fn _ -> emit_dual_write("memory.daily_summary", true, true) end)
      _ = sync(name)

      report = CutoverMonitor.report(name)
      assert report.keys["memory.daily_summary"].divergence_count == 0
      assert report.keys["memory.daily_summary"].legacy == 5
    end
  end

  describe "combined router + dual-write traffic" do
    test "counts router fires (from :fired) and divergence (from :dual_write) independently" do
      {_pid, name} = start_monitor()

      # Simulate a real production minute: the scheduler fires the
      # historian, which dual-writes; the router fire succeeds on both
      # keys, so two :fired events also land.
      emit_dual_write("memory.daily_summary", true, true)
      emit_router_fired("memory.daily_summary")
      emit_dual_write("memory.dreaming", true, true)
      emit_router_fired("memory.dreaming")

      _ = sync(name)

      report = CutoverMonitor.report(name)
      assert report.keys["memory.daily_summary"].router == 1
      assert report.keys["memory.daily_summary"].legacy == 1
      assert report.keys["memory.daily_summary"].divergence_count == 0
      assert report.keys["memory.dreaming"].router == 1
      assert report.keys["memory.dreaming"].legacy == 1
      assert report.keys["memory.dreaming"].divergence_count == 0
    end
  end

  describe "reset/1" do
    test "drops all counters back to zero" do
      {_pid, name} = start_monitor()

      emit_router_fired("memory.daily_summary")
      emit_dual_write("memory.dreaming", true, false)
      _ = sync(name)

      assert :ok = CutoverMonitor.reset(name)

      report = CutoverMonitor.report(name)

      Enum.each(CutoverMonitor.tracked_keys(), fn key ->
        assert %{router: 0, legacy: 0, divergence_count: 0} = Map.fetch!(report.keys, key)
      end)
    end
  end
end
