defmodule Platform.Habits.Pruner do
  @moduledoc """
  Retention for `habit_signals` (`0061-learned-defaults.md` § 8). Task
  01a1b6a1 stage 2. A daily `send_after` GenServer whose work is the
  synchronous `Platform.Habits.prune_signals/1`, which tests call directly.

  Signals older than 6 × the owner's `half_life_days` are deleted; the
  `habit_patterns` row (the ladder state) is kept.

  Disabled in `config/test.exs` (`:start_habits_pruner false`).
  """

  use GenServer

  require Logger

  @tick_interval_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      {:ok, deleted} = Platform.Habits.prune_signals()
      if deleted > 0, do: Logger.info("[habits_pruner] deleted #{deleted} signal(s)")
    rescue
      error ->
        Logger.error(
          "[habits_pruner] sweep crashed: " <> Exception.format(:error, error, __STACKTRACE__)
        )
    end

    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
