defmodule Platform.GameStream.NativeReconciler do
  @moduledoc "Periodic durable Play reconciliation; survives web/core restarts."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_), do: {:ok, schedule()}
  @impl true
  def handle_info(:tick, _) do
    if Platform.GameStream.enabled?() and
         Application.get_env(:game_stream, :native_reconcile, true),
       do: Platform.GameStream.NativeSessions.tick()

    {:noreply, schedule()}
  end

  defp schedule, do: Process.send_after(self(), :tick, 10_000)
end
