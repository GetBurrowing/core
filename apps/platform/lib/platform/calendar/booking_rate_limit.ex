defmodule Platform.Calendar.BookingRateLimit do
  @moduledoc "Per-node public booking attempt limits. Atomic counters expire every minute."
  use GenServer

  @table :calendar_booking_rate
  @window_ms 60_000
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Count `items` against `install_id`'s current window. Returns `:ok`, or
  `{:error, :rate_limited}` (nothing counted) when the batch would exceed
  `limit`.
  """
  @spec check(String.t(), non_neg_integer(), pos_integer(), integer()) ::
          :ok | {:error, :rate_limited}
  def check(install_id, items, limit, now_ms \\ System.system_time(:millisecond)) do
    key = {install_id, div(now_ms, @window_ms)}
    count = :ets.update_counter(@table, key, {2, items}, {key, 0})

    if count > limit do
      :ets.update_counter(@table, key, {2, -items})
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    current = div(System.system_time(:millisecond), @window_ms)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
