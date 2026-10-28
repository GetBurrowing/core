defmodule Platform.Meetings.CompletionSweeper do
  @moduledoc "Retries persisted meeting completion runs after missing/offline roles or reconnects."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 30_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      Platform.Meetings.Completion.sweep()
    rescue
      error ->
        require Logger
        Logger.warning("Meeting completion retry failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :tick, 30_000)
    {:noreply, state}
  end
end
