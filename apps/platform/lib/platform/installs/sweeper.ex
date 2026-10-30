defmodule Platform.Installs.Sweeper do
  @moduledoc """
  Hourly purge of hand-overs left unacknowledged for 7 days
  (`Platform.Installs.expire_handovers/1`, task 01a10315 stage 2): we do not
  keep a customer's root key around because nobody came back for it.
  `Process.send_after/3` ticks, the shape of `Platform.Calendar.BookingRateLimit`'s
  sweep; core has no job queue.
  """
  use GenServer

  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, :timer.hours(1))
    send(self(), :sweep)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      case Platform.Installs.expire_handovers() do
        0 -> :ok
        n -> Logger.info("[installs] purged #{n} expired hand-over(s)")
      end
    rescue
      exception ->
        Logger.error("[installs] hand-over sweep raised #{inspect(exception.__struct__)}")
    end

    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end
end
