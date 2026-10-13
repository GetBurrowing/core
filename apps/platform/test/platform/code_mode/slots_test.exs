defmodule Platform.CodeMode.SlotsTest do
  @moduledoc """
  Task 01a114a8 stage 2: a slot is freed when the run's wasm Store is idle,
  not when its caller gives up or dies.
  """

  use ExUnit.Case, async: false

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Runtime
  alias Platform.CodeMode.Slots

  test "per-runtime and node caps refuse at once" do
    limits = %{Limits.get() | per_runtime_concurrency: 1, global_concurrency: 2}
    rt = "slots-#{System.unique_integer([:positive])}"

    assert {:ok, a} = Slots.acquire(rt, limits)
    assert {:error, :runtime_busy} = Slots.acquire(rt, limits)
    assert {:ok, b} = Slots.acquire(rt <> "-2", limits)
    assert {:error, :node_busy} = Slots.acquire(rt <> "-3", limits)

    Slots.release(a)
    Slots.release(b)
    assert %{total: 0} = Slots.held()
  end

  # Task 01a1316b-aab0 stage 1: a second pool is the same module under a
  # second name, with its own caps and its own count.
  test "a named pool counts and caps independently of the agent pool" do
    name = :"slots_test_pool_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Slots, name: name}, id: name))

    limits = %{Limits.get() | per_runtime_concurrency: 1, global_concurrency: 1}
    key = "pool-#{System.unique_integer([:positive])}"

    assert {:ok, slot} = Slots.acquire(name, key, limits)
    assert %{total: 1, by_runtime: %{^key => 1}} = Slots.held(name)
    assert {:error, :runtime_busy} = Slots.acquire(name, key, limits)
    assert {:error, :node_busy} = Slots.acquire(name, key <> "-2", limits)

    # The default pool does not see it, and is not capped by it.
    refute Map.has_key?(Slots.held().by_runtime, key)
    assert {:ok, agent_slot} = Slots.acquire(key, limits)
    Slots.release(agent_slot)

    Slots.release(name, slot)
    assert %{total: 0} = Slots.held(name)
  end

  test "the canvas handler pool is started under its own name" do
    pool = Platform.Canvas.ScriptEngine.Slots
    assert is_pid(Process.whereis(pool))
    refute Process.whereis(pool) == Process.whereis(Slots)
    assert %{total: _} = Slots.held(pool)
  end

  test "a holder that dies mid-run keeps its slot until the Store is idle" do
    rt = "slots-#{System.unique_integer([:positive])}"
    test = self()
    # Fuel high enough that only the 1.5 s wall deadline stops the loop.
    limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}

    holder =
      spawn(fn ->
        {:ok, slot} = Slots.acquire(rt)

        Runtime.run("while(true){}", nil,
          limits: limits,
          wall_ms: 1_500,
          on_store: fn store ->
            Slots.attach_store(slot, store)
            send(test, :running)
          end
        )
      end)

    assert_receive :running, 5_000
    Process.sleep(200)
    started = System.monotonic_time(:millisecond)
    Process.exit(holder, :kill)

    Process.sleep(300)
    assert %{by_runtime: %{^rt => 1}} = Slots.held()

    wait_until(fn -> Slots.held().by_runtime[rt] == nil end, 5_000)
    freed_after = System.monotonic_time(:millisecond) - started

    # The native deadline is ~1.5 s after the run began (~200 ms before the
    # kill), so the slot cannot be free much sooner than ~1.1 s after it.
    assert freed_after >= 1_000
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
        true -> Process.sleep(25) && nil
      end
    end)
    |> Enum.find(& &1)
  end
end
