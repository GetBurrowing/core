defmodule Platform.SupportAccess.JunkLimit do
  @moduledoc """
  Per-client-IP limit on grant requests that fail signature verification
  (task 01a1b362 stage 1). Unsigned junk is not audited, only logged and
  limited: past `Config.junk_rate_per_hour/0` failures from one IP in the
  current hour, that IP gets 429 before its body is read. One ETS counter
  per `{ip, hour}`, owned by this GenServer for the table's lifecycle (the
  `Platform.Feedback.BrokerRateLimit` shape). Per node, lost on restart.
  """
  use GenServer

  @table :support_grant_junk
  @window_ms 3_600_000
  @sweep_interval_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether `ip` is under `limit` failures this hour."
  @spec allowed?(term(), pos_integer(), integer()) :: boolean()
  def allowed?(ip, limit, now_ms \\ System.system_time(:millisecond)) do
    case :ets.lookup(@table, {ip, div(now_ms, @window_ms)}) do
      [{_, count}] -> count < limit
      [] -> true
    end
  end

  @doc "Counts one failure for `ip`."
  @spec count(term(), integer()) :: :ok
  def count(ip, now_ms \\ System.system_time(:millisecond)) do
    bucket = {ip, div(now_ms, @window_ms)}
    :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0})
    :ok
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
