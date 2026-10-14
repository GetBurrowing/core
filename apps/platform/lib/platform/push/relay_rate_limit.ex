defmodule Platform.Push.RelayRateLimit do
  @moduledoc """
  Per-install fixed-window rate limit for the push relay (task 01a1261e
  stage 2): at most `limit` notification items per install per minute
  (`config :platform, :push_relay_server, rate_per_minute:`, default 1,200).

  One ETS counter per `{install_id, minute}`, owned by this GenServer purely
  for the table's lifecycle (the `Federation.Peers.NonceCache` shape).
  `check/3` runs in the caller (the relay request) and is never serialised
  through the server; `:ets.update_counter/4` makes concurrent requests
  count correctly. A refused batch is refunded, so a 429 does not consume
  the window. Per node and lost on restart, by design: the limit protects
  the provider quotas from one runaway install, it is not an audit.
  """
  use GenServer

  @table :push_relay_rate
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
