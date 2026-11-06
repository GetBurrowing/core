defmodule Platform.Feedback.BrokerRateLimit do
  @moduledoc """
  Per-client-IP fixed-window rate limit for the feedback broker (task
  01a1a6a5 stage 3): at most `limit` requests per IP per hour
  (`config :platform, :feedback_broker_server, rate_per_hour:`, default
  `Platform.Feedback.BrokerServer.rate_per_hour/0`).

  One ETS counter per `{ip, hour}`, owned by this GenServer purely for the
  table's lifecycle (the `Platform.Push.RelayRateLimit` shape). `check/3`
  runs in the caller. A refused request is refunded. Per node and lost on
  restart, by design: the limit stops one caller flooding the broker; the
  database-backed caps in `Platform.Feedback.Submission` still apply.

  The key is `conn.remote_ip` AFTER `PlatformWeb.Plugs.RewriteRemoteIp`, so
  behind a trusted proxy (`TRUST_PROXY_HEADERS`) each client has its own
  bucket instead of every request sharing the proxy's.
  """
  use GenServer

  @table :feedback_broker_rate
  @window_ms 3_600_000
  @sweep_interval_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Count one request against `key`'s current window. Returns `:ok`, or
  `{:error, :rate_limited}` (nothing counted) when it would exceed `limit`.
  """
  @spec check(term(), pos_integer(), integer()) :: :ok | {:error, :rate_limited}
  def check(key, limit, now_ms \\ System.system_time(:millisecond)) do
    bucket = {key, div(now_ms, @window_ms)}
    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0})

    if count > limit do
      :ets.update_counter(@table, bucket, {2, -1})
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc "Seconds until the current window ends (the `retry-after` value)."
  @spec retry_after_seconds(integer()) :: pos_integer()
  def retry_after_seconds(now_ms \\ System.system_time(:millisecond)) do
    max(1, div(@window_ms - rem(now_ms, @window_ms) + 999, 1000))
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
