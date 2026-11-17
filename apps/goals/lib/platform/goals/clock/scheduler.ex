defmodule Platform.Goals.Clock.Scheduler do
  @moduledoc "Background timer for the per-goal clock."
  use GenServer
  require Logger
  alias Platform.Goals.{Clock, Limits}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, Limits.tick_interval_ms())
    arm(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      Clock.tick(Clock.now())
    rescue
      error -> Logger.error("Goals scheduler failed: #{Exception.message(error)}")
    end

    arm(state.interval_ms)
    {:noreply, state}
  end

  defp arm(:manual), do: :ok
  defp arm(interval), do: Process.send_after(self(), :tick, interval)
end
