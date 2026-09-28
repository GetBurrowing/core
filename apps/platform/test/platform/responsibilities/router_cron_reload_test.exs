defmodule Platform.Responsibilities.RouterCronReloadTest do
  @moduledoc """
  Cron reload without restart, driven through the Router's clock seam
  (task 01a0e882 stage 1).

  Every test runs in simulated time: the Router is started with a
  `:now_fn` reading an Agent the test advances, and is stepped with
  `{:tick_at, t}` messages minute by minute, with `:sys.get_state/1` as
  the barrier. No `Process.sleep`, no wall clock. The simulated dates
  sit in 2030 so a Router that read the real clock instead of the seam
  would compute schedules nowhere near the simulated instants and the
  exact counts below would break.

  Fires are counted through `[:platform, :responsibility, :cron_fired]`
  filtered by key. Rows are inserted unassigned, so no agent is woken.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{Responsibility, Router}

  @hourly "0 * * * *"
  @cron_fired [:platform, :responsibility, :cron_fired]

  # ── fixtures (mirrors router_test.exs) ───────────────────────────────────

  defp unique_key(prefix \\ "cronreload") do
    "#{prefix}.verb_#{System.unique_integer([:positive])}"
  end

  defp insert!(overrides) do
    attrs =
      Map.merge(
        %{
          key: unique_key(),
          feature: "cronreload",
          trigger_kind: "cron",
          trigger_config: %{"expression" => @hourly},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "cronreload.v1",
          cost_profile: "low_freq_capable"
        },
        overrides
      )

    {:ok, row} = Responsibilities.create_responsibility(attrs)
    row
  end

  defp unique_name do
    Module.concat([Router, "CronReload#{System.unique_integer([:positive])}"])
  end

  # Starts the clock Agent first so start_supervised!/1 stops the Router
  # before the clock it reads.
  defp start_router(start_at) do
    clock = start_supervised!({Agent, fn -> start_at end}, id: {:clock, make_ref()})
    name = unique_name()

    pid =
      start_supervised!(
        {Router,
         name: name, check_interval_ms: :timer.hours(24), now_fn: fn -> Agent.get(clock, & &1) end}
      )

    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    %{pid: pid, name: name, clock: clock}
  end

  defp set_clock(%{clock: clock}, %DateTime{} = t), do: Agent.update(clock, fn _ -> t end)

  # Step minute boundaries in `(from, to]`, advancing the clock with each
  # tick so a reload issued afterwards reads the simulated instant.
  defp drive(router, %DateTime{} = from, %DateTime{} = to) do
    from
    |> Stream.iterate(&DateTime.add(&1, 60, :second))
    |> Stream.drop(1)
    |> Stream.take_while(&(DateTime.compare(&1, to) != :gt))
    |> Enum.each(&tick_at(router, &1))

    barrier(router)
  end

  defp tick_at(%{pid: pid} = router, %DateTime{} = t) do
    set_clock(router, t)
    send(pid, {:tick_at, t})
  end

  defp barrier(%{pid: pid}), do: :sys.get_state(pid)

  defp attach_counter(keys) do
    test_pid = self()
    handler_id = "cron-reload-test-#{System.unique_integer([:positive])}"
    wanted = MapSet.new(keys)

    :ok =
      :telemetry.attach(
        handler_id,
        @cron_fired,
        fn _event, _measurements, %{key: key, fired_at: at}, _config ->
          if MapSet.member?(wanted, key), do: send(test_pid, {:cron_fired, key, at})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Drains every counted fire for `key` received so far, in order.
  defp fires(key), do: collect(key, [])

  defp collect(key, acc) do
    receive do
      {:cron_fired, ^key, at} -> collect(key, [at | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp switch!(row, attrs) do
    {:ok, updated} = Responsibilities.update_responsibility(Repo.reload!(row), attrs)
    updated
  end

  defp cron_ids(%{pid: pid}) do
    pid |> :sys.get_state() |> get_in([:by_trigger, :cron]) |> Enum.map(& &1.id)
  end

  # Isolate the Router from any cron rows the test database was seeded
  # with; the sandbox rolls this back.
  setup do
    Repo.update_all(from(r in Responsibility, where: r.trigger_kind == "cron"),
      set: [enabled: false]
    )

    :ok
  end

  # ── hourly -> daily ──────────────────────────────────────────────────────

  describe "hourly row switched to daily" do
    test "daily after switch: exactly 2 fires over 48 h, both at 09:00 UTC; hourly control fires 48" do
      daily = insert!(%{})
      control = insert!(%{})
      attach_counter([daily.key, control.key])

      t0 = ~U[2030-01-07 00:00:30Z]
      router = start_router(t0)

      switch!(daily, %{trigger_config: %{"expression" => "0 9 * * *"}})
      assert :ok = Router.reload_cron(router.name)

      drive(router, ~U[2030-01-07 00:00:00Z], ~U[2030-01-09 00:00:00Z])

      assert fires(daily.key) == [~U[2030-01-07 09:00:00Z], ~U[2030-01-08 09:00:00Z]]

      control_fires = fires(control.key)
      assert length(control_fires) == 48
      assert Enum.all?(control_fires, &(&1.minute == 0 and &1.second == 0))
      assert control_fires == Enum.uniq(control_fires)

      assert Process.whereis(router.name) == router.pid
      assert Process.alive?(router.pid)
    end

    test "the PubSub-shaped message {:responsibilities_changed, :cron} also reloads" do
      daily = insert!(%{})
      control = insert!(%{})
      attach_counter([daily.key, control.key])

      router = start_router(~U[2030-01-07 00:00:30Z])

      switch!(daily, %{trigger_config: %{"expression" => "0 9 * * *"}})
      send(router.pid, {:responsibilities_changed, :cron})
      barrier(router)

      drive(router, ~U[2030-01-07 00:00:00Z], ~U[2030-01-08 00:00:00Z])

      assert fires(daily.key) == [~U[2030-01-07 09:00:00Z]]
      assert length(fires(control.key)) == 24
      assert Process.whereis(router.name) == router.pid
    end
  end

  # ── enabled: false ───────────────────────────────────────────────────────

  describe "disabled row" do
    test "leaves the cron bucket and never fires; the hourly control fires 24" do
      off = insert!(%{})
      control = insert!(%{})
      attach_counter([off.key, control.key])

      router = start_router(~U[2030-01-07 00:00:30Z])
      assert off.id in cron_ids(router)

      switch!(off, %{enabled: false})
      assert :ok = Router.reload_cron(router.name)

      state = :sys.get_state(router.pid)
      refute off.id in Enum.map(state.by_trigger.cron, & &1.id)
      refute Map.has_key?(state.cron_next_fire, off.id)
      assert control.id in Enum.map(state.by_trigger.cron, & &1.id)

      drive(router, ~U[2030-01-07 00:00:00Z], ~U[2030-01-08 00:00:00Z])

      assert fires(off.key) == []
      assert length(fires(control.key)) == 24
      assert Process.whereis(router.name) == router.pid
    end
  end

  # ── the switch instant ───────────────────────────────────────────────────

  describe "no double-fire at the switch" do
    test "hourly fires 10:00:00, switched to 0 10 * * * at 10:00:30: one fire each day" do
      row = insert!(%{})
      attach_counter([row.key])

      router = start_router(~U[2030-01-07 09:30:00Z])
      drive(router, ~U[2030-01-07 09:30:00Z], ~U[2030-01-07 10:00:00Z])
      assert fires(row.key) == [~U[2030-01-07 10:00:00Z]]

      set_clock(router, ~U[2030-01-07 10:00:30Z])
      switch!(row, %{trigger_config: %{"expression" => "0 10 * * *"}})
      assert :ok = Router.reload_cron(router.name)

      drive(router, ~U[2030-01-07 10:00:00Z], ~U[2030-01-08 10:00:00Z])

      assert fires(row.key) == [~U[2030-01-08 10:00:00Z]]
      assert Process.whereis(router.name) == router.pid
    end

    test "0 10 * * * switched to hourly at 09:59:30 fires exactly once at 10:00" do
      row = insert!(%{trigger_config: %{"expression" => "0 10 * * *"}})
      attach_counter([row.key])

      router = start_router(~U[2030-01-07 09:00:30Z])
      drive(router, ~U[2030-01-07 09:00:00Z], ~U[2030-01-07 09:59:00Z])
      assert fires(row.key) == []

      set_clock(router, ~U[2030-01-07 09:59:30Z])
      switch!(row, %{trigger_config: %{"expression" => @hourly}})
      assert :ok = Router.reload_cron(router.name)

      drive(router, ~U[2030-01-07 09:59:00Z], ~U[2030-01-07 10:59:00Z])

      assert fires(row.key) == [~U[2030-01-07 10:00:00Z]]
      assert Process.whereis(router.name) == router.pid
    end

    # The carried `cron_last_fire` is what stops a same-minute refire when
    # a recompute lands inside a minute that already fired. With a wall
    # clock that only moves forward the recompute always starts at the
    # NEXT minute, so the case needs the clock to step BACK across the
    # boundary (an NTP step): the reload reads 09:59:50 after a 10:00:00
    # fire, recomputes the switched row to 10:00:00 today, and the
    # 10:00:40 tick finds it due.
    test "cron_last_fire survives the reload: a clock step-back cannot refire the minute" do
      row = insert!(%{})
      attach_counter([row.key])

      router = start_router(~U[2030-01-07 09:30:00Z])
      drive(router, ~U[2030-01-07 09:30:00Z], ~U[2030-01-07 10:00:00Z])
      assert fires(row.key) == [~U[2030-01-07 10:00:00Z]]

      set_clock(router, ~U[2030-01-07 09:59:50Z])
      switch!(row, %{trigger_config: %{"expression" => "0 10 * * *"}})
      assert :ok = Router.reload_cron(router.name)

      tick_at(router, ~U[2030-01-07 10:00:40Z])
      barrier(router)
      assert fires(row.key) == []

      drive(router, ~U[2030-01-07 10:00:00Z], ~U[2030-01-08 10:00:00Z])
      assert fires(row.key) == [~U[2030-01-08 10:00:00Z]]
    end
  end

  # ── unchanged rows keep their schedule ───────────────────────────────────

  describe "reload leaves unchanged rows alone" do
    # A reload that lands after a row's due instant but before the tick
    # that fires it must not push that row to its NEXT slot: the kept
    # next_fire (10:00) is still due at the late 10:00:40 tick.
    test "an unchanged row's pending fire is kept across a reload of a sibling" do
      control = insert!(%{})
      other = insert!(%{})
      attach_counter([control.key])

      router = start_router(~U[2030-01-07 09:30:30Z])
      drive(router, ~U[2030-01-07 09:30:00Z], ~U[2030-01-07 09:59:00Z])
      before = :sys.get_state(router.pid).cron_next_fire[control.id]
      assert DateTime.compare(before, ~U[2030-01-07 10:00:00Z]) == :eq

      set_clock(router, ~U[2030-01-07 10:00:20Z])
      switch!(other, %{trigger_config: %{"expression" => "0 9 * * *"}})
      assert :ok = Router.reload_cron(router.name)
      assert :sys.get_state(router.pid).cron_next_fire[control.id] == before

      tick_at(router, ~U[2030-01-07 10:00:40Z])
      barrier(router)
      assert fires(control.key) == [~U[2030-01-07 10:00:40Z]]
    end
  end

  # ── the real tick reads the seam ─────────────────────────────────────────

  describe ":tick" do
    test "reads now through :now_fn, not the wall clock" do
      row = insert!(%{})
      attach_counter([row.key])

      router = start_router(~U[2030-01-07 09:59:30Z])
      set_clock(router, ~U[2030-01-07 10:00:00Z])
      send(router.pid, :tick)
      barrier(router)

      assert fires(row.key) == [~U[2030-01-07 10:00:00Z]]
    end
  end
end
