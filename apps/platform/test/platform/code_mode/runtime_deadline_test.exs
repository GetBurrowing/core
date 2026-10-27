defmodule Platform.CodeMode.RuntimeDeadlineTest do
  use ExUnit.Case, async: false

  alias Platform.CodeMode.{Limits, Permits, Runtime}

  setup_all do
    {:ok, _} = Runtime.compiled()
    :ok
  end

  test "a cold gate prepares the artifact before admitting requests" do
    key = {Runtime, :compiled}
    previous = :persistent_term.get(key)
    :persistent_term.erase(key)
    on_exit(fn -> :persistent_term.put(key, previous) end)

    start_supervised!({Permits, name: __MODULE__.ColdGate})
    assert {_engine, _module} = :persistent_term.get(key)
    assert {:ok, %{result: 2}} = Runtime.run("1 + 1", nil, wall_ms: 100)
  end

  test "an interrupted guest returns within its deadline plus 50 ms" do
    limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}
    wall_ms = 500
    started = System.monotonic_time(:millisecond)

    assert {:error, "timeout", _} =
             Runtime.run("while (true) {}", nil, limits: limits, wall_ms: wall_ms)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= wall_ms
    assert elapsed <= wall_ms + 50, "interrupted guest returned after #{elapsed} ms"
  end

  test "native setup and an earlier caller deadline spend the same wall budget" do
    limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}
    wall_ms = 500
    started = System.monotonic_time(:millisecond)
    deadline = started + wall_ms
    Process.sleep(100)

    assert {:error, "timeout", _} =
             Runtime.run("while (true) {}", nil,
               limits: limits,
               wall_ms: wall_ms,
               deadline_ms: deadline,
               on_store: fn _store -> Process.sleep(120) end
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= wall_ms
    assert elapsed <= wall_ms + 50, "setup escaped the deadline: returned after #{elapsed} ms"
  end
end
