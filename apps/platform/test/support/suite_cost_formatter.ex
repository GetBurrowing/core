defmodule Platform.SuiteCostFormatter do
  @moduledoc """
  An ExUnit formatter that prints the slowest tests and slowest modules of a
  run WITHOUT changing how the run executes (task 01a17ac3).

  ## Why not `--slowest`

  ExUnit's own `slowest:` / `slowest_modules:` options force `trace: true`,
  and trace forces `max_cases: 1` and an `:infinity` timeout. That holds
  whether they arrive on the `mix test` command line or through
  `ExUnit.configure/1` in `test_helper.exs`, and a later
  `ExUnit.configure(trace: false)` does not undo it. A slowest list taken that
  way is a list of SERIAL timings for a suite that CI runs concurrently: every
  async module's wall time is measured without the contention it really runs
  under, and the run's total wall time is the serial sum, not the job's.
  Measuring the suite's cost that way measures a different quantity.

  This formatter only listens. It is attached alongside the configured
  formatters, so `max_cases`, `trace` and timeouts are whatever the run was
  given.

  ## What it reports

  Lines are prefixed so a job log can be grepped:

    * `[suite-cost] test` - the N slowest tests: time in ms (ExUnit's own
      per-test time, which includes `setup`), async flag, file:line, module,
      name.
    * `[suite-cost] module` - the N slowest modules by wall time from
      `module_started` to `module_finished` (includes `setup_all` and the
      module's own concurrency), plus the summed test time, async flag and
      test count.
    * `[suite-cost] summary` - total module wall time split by async flag,
      and ExUnit's own `run`/`async`/`load` times.

  Enabled from `test/test_helper.exs` only when `CI` is set.
  """

  use GenServer

  @top_tests 100
  @top_modules 50

  @impl true
  def init(_opts) do
    {:ok, %{tests: [], started: %{}, modules: %{}}}
  end

  @impl true
  def handle_cast({:module_started, %ExUnit.TestModule{name: name}}, state) do
    {:noreply, put_in(state.started[name], System.monotonic_time(:microsecond))}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{name: name, file: file}}, state) do
    now = System.monotonic_time(:microsecond)
    wall = now - Map.get(state.started, name, now)

    entry =
      state.modules
      |> Map.get(name, %{sum: 0, count: 0, async: nil})
      |> Map.merge(%{wall: wall, file: file})

    {:noreply, put_in(state.modules[name], entry)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    async = Map.get(test.tags, :async)
    row = {test.time, async, test.tags[:file], test.tags[:line], test.module, test.name}

    modules =
      Map.update(
        state.modules,
        test.module,
        %{sum: test.time, count: 1, async: async},
        fn m -> %{m | sum: m.sum + test.time, count: m.count + 1, async: async} end
      )

    {:noreply, %{state | tests: [row | state.tests], modules: modules}}
  end

  def handle_cast({:suite_finished, times_us}, state) do
    print(state, times_us)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp print(state, times_us) do
    root = File.cwd!()

    state.tests
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(@top_tests)
    |> Enum.each(fn {time, async, file, line, module, name} ->
      IO.puts(
        "[suite-cost] test\t#{ms(time)}\t#{async_label(async)}\t" <>
          "#{Path.relative_to(to_string(file), root)}:#{line}\t#{inspect(module)}\t#{name}"
      )
    end)

    modules = Enum.filter(state.modules, fn {_name, m} -> Map.has_key?(m, :wall) end)

    modules
    |> Enum.sort_by(fn {_name, m} -> m.wall end, :desc)
    |> Enum.take(@top_modules)
    |> Enum.each(fn {name, m} ->
      IO.puts(
        "[suite-cost] module\t#{ms(m.wall)}\t#{ms(m.sum)}\t#{async_label(m.async)}\t" <>
          "#{m.count}\t#{Path.relative_to(to_string(m.file), root)}\t#{inspect(name)}"
      )
    end)

    {sync_wall, async_wall} =
      Enum.reduce(modules, {0, 0}, fn {_name, m}, {s, a} ->
        if m.async == true, do: {s, a + m.wall}, else: {s + m.wall, a}
      end)

    IO.puts(
      "[suite-cost] summary\tmodules=#{length(modules)}\ttests=#{length(state.tests)}" <>
        "\tsync_module_wall_ms=#{ms(sync_wall)}\tasync_module_wall_ms=#{ms(async_wall)}" <>
        "\trun_ms=#{ms(times_us[:run])}\tasync_ms=#{ms(times_us[:async])}" <>
        "\tload_ms=#{ms(times_us[:load])}"
    )
  end

  defp ms(nil), do: "nil"
  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)

  defp async_label(true), do: "async"
  defp async_label(false), do: "sync"
  defp async_label(_), do: "unknown"
end
