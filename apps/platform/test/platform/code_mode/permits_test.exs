defmodule Platform.CodeMode.PermitsTest do
  @moduledoc """
  Task 01a17b0b stage 1: the node-wide native guest gate. Permits never
  exceed the size, hand off in arrival order, come back when a holder dies
  (once its Store is idle), and the wait for one is charged to the run's
  wall budget.
  """

  # async: false: the Runtime tests below occupy the node's real gate.
  use ExUnit.Case, async: false

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Permits
  alias Platform.CodeMode.Runtime

  defp start_gate(size) do
    name = :"permits_test_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Permits, name: name, size: size}, id: name))
    name
  end

  defp far, do: System.monotonic_time(:millisecond) + 60_000

  # A process that takes a permit from `gate`, reports it, and holds it
  # until told to release (or is killed).
  defp holder(gate, tag, deadline \\ nil) do
    test = self()

    spawn(fn ->
      result = Permits.acquire(gate, deadline || far())
      send(test, {tag, result})

      receive do
        :release ->
          {:ok, permit} = result
          Permits.release(gate, permit)
      end
    end)
  end

  # Poll `fun` every 10 ms until it is truthy or `ms` have passed.
  defp wait_for(fun, ms \\ 3_000) do
    cond do
      fun.() ->
        true

      ms <= 0 ->
        false

      true ->
        receive do
        after
          10 -> wait_for(fun, ms - 10)
        end
    end
  end

  describe "native_workers/2" do
    test "is the processor count with no cgroup quota" do
      assert Permits.native_workers(10, {:error, :enoent}) == 10
      assert Permits.native_workers(10, {:ok, "max 100000\n"}) == 10
    end

    test "is capped by a cgroup v2 quota, floored like Rust" do
      assert Permits.native_workers(10, {:ok, "400000 100000\n"}) == 4
      assert Permits.native_workers(10, {:ok, "450000 100000\n"}) == 4
      assert Permits.native_workers(2, {:ok, "400000 100000\n"}) == 2
      assert Permits.native_workers(10, {:ok, "50000 100000\n"}) == 1
    end

    test "ignores an unreadable quota" do
      assert Permits.native_workers(6, {:ok, "garbage"}) == 6
    end

    test "the node's gate is one fewer than the workers, at least one" do
      assert Permits.status().size == max(1, Permits.native_workers() - 1)
      assert Permits.configured_size() == Permits.status().size
    end
  end

  test "permits never exceed the size" do
    gate = start_gate(2)
    pids = for i <- 1..6, do: holder(gate, {:h, i})

    granted =
      for _ <- 1..2 do
        assert_receive {{:h, i}, {:ok, _}}, 1_000
        i
      end

    refute_receive {{:h, _}, _}, 200
    assert %{held: 2, waiting: 4} = Permits.status(gate)

    # Release one at a time: each release admits exactly one waiter.
    Enum.reduce(1..4, granted, fn _, [first | rest] ->
      send(Enum.at(pids, first - 1), :release)
      assert_receive {{:h, next}, {:ok, _}}, 1_000
      refute_receive {{:h, _}, _}, 50
      assert Permits.status(gate).held == 2
      rest ++ [next]
    end)
  end

  test "freed permits go to waiters in arrival order" do
    gate = start_gate(1)
    first = holder(gate, :first)
    assert_receive {:first, {:ok, _}}

    waiters =
      for i <- 1..4 do
        pid = holder(gate, {:w, i})
        assert wait_for(fn -> Permits.status(gate).waiting == i end)
        pid
      end

    send(first, :release)

    for {pid, i} <- Enum.with_index(waiters, 1) do
      assert_receive {{:w, ^i}, {:ok, _}}, 1_000
      send(pid, :release)
    end

    assert wait_for(fn -> Permits.status(gate) == %{size: 1, held: 0, waiting: 0} end)
  end

  test "a holder that dies returns its permit, and a dead waiter leaves the queue" do
    gate = start_gate(1)
    first = holder(gate, :first)
    assert_receive {:first, {:ok, _}}

    dead_waiter = holder(gate, :dead)
    assert wait_for(fn -> Permits.status(gate).waiting == 1 end)
    Process.exit(dead_waiter, :kill)
    assert wait_for(fn -> Permits.status(gate).waiting == 0 end)

    _live = holder(gate, :live)
    assert wait_for(fn -> Permits.status(gate).waiting == 1 end)

    Process.exit(first, :kill)
    assert_receive {:live, {:ok, _}}, 1_000
    refute_received {:dead, _}
  end

  test "a waiter still queued at its deadline gets a timeout" do
    gate = start_gate(1)
    _first = holder(gate, :first)
    assert_receive {:first, {:ok, _}}

    started = System.monotonic_time(:millisecond)
    _late = holder(gate, :late, started + 200)
    assert_receive {:late, {:error, :timeout}}, 1_000
    assert System.monotonic_time(:millisecond) - started >= 200
    assert %{held: 1, waiting: 0} = Permits.status(gate)
  end

  describe "Runtime.run on the node's gate" do
    # Take every permit of the node's gate from helper processes.
    defp occupy_all do
      size = Permits.status().size
      pids = for i <- 1..size, do: holder(Permits, {:occupy, i})
      for i <- 1..size, do: assert_receive({{:occupy, ^i}, {:ok, _}}, 1_000)
      pids
    end

    test "a run holds a permit while its guest runs, and returns it when idle" do
      test = self()
      limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}

      runner =
        spawn(fn ->
          Runtime.run("while(true){}", nil,
            limits: limits,
            wall_ms: 1_500,
            on_store: fn store -> send(test, {:store, store}) end
          )
        end)

      assert_receive {:store, store}, 5_000
      assert Permits.status().held == 1

      # The caller dies mid-run: the permit stays until the Store is idle.
      Process.exit(runner, :kill)
      assert Permits.status().held == 1
      _ = Wasmex.StoreOrCaller.get_fuel(store)
      assert wait_for(fn -> Permits.status().held == 0 end)
    end

    test "a run that never gets a permit times out at its wall deadline without running" do
      pids = occupy_all()
      test = self()
      started = System.monotonic_time(:millisecond)

      assert {:error, "timeout", _} =
               Runtime.run("1 + 1", nil,
                 wall_ms: 300,
                 on_store: fn _ -> send(test, :store_created) end
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 300 and elapsed < 800
      refute_received :store_created

      Enum.each(pids, &send(&1, :release))
      assert wait_for(fn -> Permits.status().held == 0 end)
    end

    test "the permit wait is charged to the run's wall budget" do
      pids = occupy_all()
      limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}
      wall_ms = 1_000
      wait_ms = 400
      test = self()

      run =
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)

          outcome =
            Runtime.run("while(true){}", nil,
              limits: limits,
              wall_ms: wall_ms,
              on_store: fn _ -> send(test, :running) end
            )

          {outcome, System.monotonic_time(:millisecond) - started}
        end)

      refute_receive :running, wait_ms
      send(hd(pids), :release)
      assert_receive :running, 1_000

      {outcome, elapsed} = Task.await(run, 10_000)
      assert {:error, "timeout", _} = outcome

      # Uncharged, the run would end no earlier than wait + wall + 500 ms
      # grace (1_900 ms). Charged, it ends by wall + grace plus setup.
      assert elapsed < wall_ms + 500 + 200,
             "run took #{elapsed} ms for a #{wall_ms} ms wall after a #{wait_ms} ms permit wait"

      Enum.each(tl(pids), &send(&1, :release))
      assert wait_for(fn -> Permits.status().held == 0 end)
    end
  end
end
