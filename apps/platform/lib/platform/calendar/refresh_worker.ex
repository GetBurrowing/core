defmodule Platform.Calendar.RefreshWorker do
  @moduledoc "Bounded background refresh, one owner subscription per tick."
  use GenServer
  import Ecto.Query
  alias Platform.Calendar.{Subscription, Subscriptions}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -1800)

    row =
      Platform.Repo.one(
        from(s in Subscription,
          where: is_nil(s.attempted_at) or s.attempted_at < ^cutoff,
          order_by: [asc_nulls_first: s.attempted_at, asc: s.id],
          limit: 1
        )
      )

    if row, do: Subscriptions.refresh_row(row)
    Process.send_after(self(), :tick, 10_000)
    {:noreply, state}
  rescue
    DBConnection.OwnershipError ->
      Process.send_after(self(), :tick, 60_000)
      {:noreply, state}
  end
end
