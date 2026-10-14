defmodule Platform.CodeMode.StoreTest do
  @moduledoc "Task 01a114a8 stage 2: suite_run's ephemeral ETS store and its bounds."

  use ExUnit.Case, async: false

  alias Platform.CodeMode.Store

  setup do
    Store.reset()
    on_exit(fn -> Store.reset() end)
    :ok
  end

  test "set, get and delete are scoped by agent, scope and key" do
    assert :ok = Store.set("agent-a", "runtime:r1", "k", ~s({"v":1}), nil)
    assert {:ok, ~s({"v":1})} = Store.get("agent-a", "runtime:r1", "k")
    assert {:ok, nil} = Store.get("agent-b", "runtime:r1", "k")
    assert {:ok, nil} = Store.get("agent-a", "session:s", "k")

    assert :ok = Store.delete("agent-a", "runtime:r1", "k")
    assert {:ok, nil} = Store.get("agent-a", "runtime:r1", "k")
    assert Store.usage("agent-a") == 0
  end

  test "a row past its TTL reads as absent before the sweep and is gone after it" do
    now = System.system_time(:millisecond)
    :ok = Store.set("agent-a", "s", "k", "1", 1_000)

    assert {:ok, "1"} = Store.get("agent-a", "s", "k", now)
    assert {:ok, nil} = Store.get("agent-a", "s", "k", now + 5_000)
    assert Store.sweep(now + 5_000) == 1
    assert Store.usage("agent-a") == 0
  end

  test "TTL defaults to 30 min and is capped at 6 h" do
    now = System.system_time(:millisecond)
    :ok = Store.set("agent-a", "s", "default", "1", nil)
    :ok = Store.set("agent-a", "s", "long", "1", 100 * 3_600_000)

    assert {:ok, "1"} = Store.get("agent-a", "s", "default", now + 29 * 60_000)
    assert {:ok, nil} = Store.get("agent-a", "s", "default", now + 31 * 60_000)
    assert {:ok, "1"} = Store.get("agent-a", "s", "long", now + 5 * 3_600_000)
    assert {:ok, nil} = Store.get("agent-a", "s", "long", now + 7 * 3_600_000)
  end

  test "a value over 256 KB is refused" do
    big = String.duplicate("x", 256 * 1024 + 1)
    assert {:error, "value_too_large", _} = Store.set("agent-a", "s", "k", big, nil)
    assert {:ok, nil} = Store.get("agent-a", "s", "k")
  end

  test "an agent holds at most 4 MB in total; overwriting reuses its bytes" do
    value = String.duplicate("x", 200 * 1024)

    for i <- 1..20, do: assert(:ok = Store.set("agent-a", "s", "k#{i}", value, nil))
    assert {:error, "store_full", _} = Store.set("agent-a", "s", "k21", value, nil)
    assert :ok = Store.set("agent-a", "s", "k1", value, nil)
    assert :ok = Store.set("agent-b", "s", "k21", value, nil)
  end

  test "keys are 1..256 byte strings" do
    assert {:error, "invalid_key", _} = Store.set("agent-a", "s", "", "1", nil)

    assert {:error, "invalid_key", _} =
             Store.set("agent-a", "s", String.duplicate("k", 257), "1", nil)
  end
end
