defmodule Platform.CodeMode.RuntimeContentionTest do
  @moduledoc """
  Task 01a17b0b stage 2: the wall limit holds end to end when more guests
  loop than wasmex has tokio workers.

  Wasmex 0.15.1 runs every guest and the engine's 10 ms epoch ticker on one
  tokio runtime sized to the host's parallelism. Oversubscribe it and,
  without `Platform.CodeMode.Permits`, the ticker starves: the interrupt
  lands late, a run returns `timeout` at its wall + grace while its guest
  keeps a worker for seconds more. This test asserts the LIMIT STATE of
  every run, not how long the test took:

    * it ends `fuel` or `timeout`;
    * its Store is idle within the runtime's 500 ms grace of the run
      returning (the guest was interrupted, not left spinning);
    * it returns within wall + grace (+ setup) of its own `Runtime.run`
      call; the permit wait is charged inside that wall.

  The guest count is sized from the same `Permits.native_workers/0` the
  gate uses, so it oversubscribes on every host. Fuel is set high so the
  wall deadline is the only bound under test.

  async: false by necessity: the guests occupy the node's real gate.
  """

  use ExUnit.Case, async: false

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Permits
  alias Platform.CodeMode.Runtime

  @wall_ms 1_000
  # Runtime's @timeout_grace_ms.
  @grace_ms 500
  # Store, instance and setup calls run under their own bound, outside
  # the wall; allow them this much on a loaded host.
  @setup_slack_ms 300
  # How long to watch a Store for idle before calling it still busy: well
  # past the grace, so a late interrupt shows as a number, not a hang.
  @probe_ms 3_000
  @collect_ms 15_000

  setup_all do
    {:ok, _} = Runtime.compiled()
    :ok
  end

  test "native_workers() + 2 looping guests all stop at their wall limit" do
    guests = Permits.native_workers() + 2
    limits = %{Limits.get() | fuel_per_ms: 1_000_000_000}

    runs =
      for i <- 1..guests do
        Task.async(fn ->
          me = self()
          started = System.monotonic_time(:millisecond)

          outcome =
            Runtime.run("while (true) {}", nil,
              limits: limits,
              wall_ms: @wall_ms,
              on_store: fn store -> send(me, {:store, store}) end
            )

          returned = System.monotonic_time(:millisecond)

          store =
            receive do
              {:store, store} -> store
            after
              0 -> nil
            end

          %{
            guest: i,
            outcome: outcome,
            ran: store != nil,
            took_ms: returned - started,
            idle_after_ms: idle_after(store, returned)
          }
        end)
      end

    # Collect for long past every bound below, so a run that is stuck (a
    # starved setup call blocks without limit) fails as a named run rather
    # than as a test timeout.
    collected = Task.yield_many(runs, @collect_ms)
    results = for {_task, {:ok, r}} <- collected, do: r
    crashed = for {_task, {:exit, reason}} <- collected, do: reason
    assert crashed == [], "runs crashed: #{inspect(crashed)}"

    stuck =
      for {{task, nil}, i} <- Enum.with_index(collected, 1) do
        Task.shutdown(task, :brutal_kill)
        i
      end

    report = Enum.map_join(results, "\n", &inspect/1)

    assert stuck == [],
           "guests #{inspect(stuck)} had not returned #{@collect_ms} ms after starting " <>
             "(wall #{@wall_ms})\n#{report}"

    for r <- results do
      assert {:error, kind, _} = r.outcome
      assert kind in ["fuel", "timeout"], "guest #{r.guest} ended #{kind}\n#{report}"

      assert is_integer(r.idle_after_ms) and r.idle_after_ms <= @grace_ms,
             "guest #{r.guest}'s Store was busy #{inspect(r.idle_after_ms)} ms after its run " <>
               "returned (grace #{@grace_ms} ms)\n#{report}"

      assert r.took_ms <= @wall_ms + @grace_ms + @setup_slack_ms,
             "guest #{r.guest} returned #{r.took_ms} ms after its run began " <>
               "(wall #{@wall_ms} + grace #{@grace_ms} + setup #{@setup_slack_ms})\n#{report}"
    end

    assert Enum.any?(results, & &1.ran)
    assert %{held: 0, waiting: 0} = wait_for_idle_gate()
  end

  # Milliseconds from `returned` until `store` is idle (its get_fuel probe
  # answers); 0 for a run that never got a permit and so made no Store.
  # Watched for @probe_ms, past which a guest is reported as still busy.
  defp idle_after(nil, _returned), do: 0

  defp idle_after(store, returned) do
    me = self()
    ref = make_ref()

    spawn(fn ->
      _ = Wasmex.StoreOrCaller.get_fuel(store)
      send(me, {ref, System.monotonic_time(:millisecond)})
    end)

    receive do
      {^ref, idle} -> idle - returned
    after
      @probe_ms -> {:still_busy_after_ms, @probe_ms}
    end
  end

  # The last permits come back on idle probes; give them the grace.
  defp wait_for_idle_gate(ms \\ @grace_ms) do
    status = Permits.status()

    if (status.held == 0 and status.waiting == 0) or ms <= 0 do
      status
    else
      receive do
      after
        10 -> wait_for_idle_gate(ms - 10)
      end
    end
  end
end
