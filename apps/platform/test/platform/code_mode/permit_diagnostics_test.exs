defmodule Platform.CodeMode.PermitDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Platform.CodeMode.{PermitDiagnostics, Permits}

  test "reports held and drained gate states without exposing references" do
    assert %{held: 0, waiting: 0, size: size} = Permits.status()
    deadline = System.monotonic_time(:millisecond) + 5_000

    permits =
      for _ <- 1..size do
        assert {:ok, permit} = Permits.acquire(nil, deadline)
        permit
      end

    held =
      try do
        held = PermitDiagnostics.snapshot()
        assert held.gate.held == size
        assert held.gate.waiting == 0
        assert is_integer(held.workers)
        assert is_integer(held.at_ms)
        held
      after
        Enum.each(permits, &Permits.release/1)
      end

    drained = PermitDiagnostics.snapshot()
    assert drained.gate.held == 0
    output = capture_io(:stderr, fn -> PermitDiagnostics.report("control", held, drained) end)
    assert output =~ "held: #{size}"
    assert output =~ "held: 0"
    assert output =~ "timeout_phase=unknown"
  end
end
