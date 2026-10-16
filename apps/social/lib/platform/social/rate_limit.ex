defmodule Platform.Social.RateLimit do
  @moduledoc """
  Per-account fixed-window publish limit (task 01a140a9, Social 2/7).

  The default, 25 publishes per hour per account, is the vendor's velocity
  cap (Zernio documents 25 posts/hour per account), so we refuse early
  instead of letting the vendor fail the post. Both numbers are read on
  every call from:

      config :social, :rate_limit, per_window: 25, window_ms: 3_600_000

  The SHAPE is copied from core's `Platform.Push.RelayRateLimit` (a module
  must not reuse that Push-specific server): one ETS counter per
  `{account_id, window}`, owned by this GenServer for the table's lifecycle
  only; `check/2` runs in the caller with `:ets.update_counter/4`, and a
  refused call is refunded so it counts nothing. Accounts are independent.
  Per node and lost on restart, by design.
  """
  use GenServer

  @table :social_publish_rate
  @default_per_window 25
  @default_window_ms 3_600_000
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one publish against `account_id`'s current window. `:ok`, or
  `{:error, :rate_limited}` with nothing counted.
  """
  @spec check(String.t(), integer()) :: :ok | {:error, :rate_limited}
  def check(account_id, now_ms \\ System.system_time(:millisecond)) do
    {limit, window_ms} = settings()
    key = {account_id, div(now_ms, window_ms)}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count > limit do
      :ets.update_counter(@table, key, {2, -1})
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  defp settings do
    config = Application.get_env(:social, :rate_limit, [])

    {Keyword.get(config, :per_window, @default_per_window),
     Keyword.get(config, :window_ms, @default_window_ms)}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_limit, window_ms} = settings()
    current = div(System.system_time(:millisecond), window_ms)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
