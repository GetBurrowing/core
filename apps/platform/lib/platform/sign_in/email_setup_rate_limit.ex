defmodule Platform.SignIn.EmailSetupRateLimit do
  @moduledoc "Bounded per-node counters for public first-sign-in requests. Email keys are hashed."
  use GenServer
  @table :sign_in_email_setup_rate
  @window 1800

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def request(ip, email) do
    with :ok <- count({:ip, ip}, 20), do: count({:email, :crypto.hash(:sha256, email)}, 3)
  end

  def verify(ip), do: count({:verify, ip}, 30)

  defp count(key, limit) do
    key = {key, div(System.system_time(:second), @window)}
    if :ets.info(@table, :size) >= 20_000 and not :ets.member(@table, key) do
      {:error, :rate_limited}
    else
      if :ets.update_counter(@table, key, {2, 1}, {key, 0}) <= limit,
        do: :ok, else: {:error, :rate_limited}
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    Process.send_after(self(), :sweep, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    window = div(System.system_time(:second), @window)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}])
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state}
  end
end
