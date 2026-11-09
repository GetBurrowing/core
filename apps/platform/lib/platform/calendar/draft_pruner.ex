defmodule Platform.Calendar.DraftPruner do
  @moduledoc """
  Retention for `calendar_drafts` (task 01a1b8a5 stage 5). A daily
  `send_after` GenServer whose work is the synchronous
  `Platform.Calendar.Draft.prune_expired/1`, which tests call directly.

  Disabled in `config/test.exs` (`:start_calendar_draft_pruner false`).
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
      {:ok, deleted} = Platform.Calendar.Draft.prune_expired()
      if deleted > 0, do: Logger.info("[calendar_draft_pruner] deleted #{deleted} draft(s)")
    rescue
      error ->
        Logger.error(
          "[calendar_draft_pruner] sweep crashed: " <>
            Exception.format(:error, error, __STACKTRACE__)
        )
    end

    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
