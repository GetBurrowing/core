defmodule Platform.Sharing.UsageBatcher do
  @moduledoc """
  Sends the anonymous usage counts (task 01a1b678 stage 2).

  Owns the `Platform.Sharing.UsageEvents` counts table and attaches the
  collector in `init/1`, so the node that counts is the node that sends. Every
  `interval_ms` (`config :platform, Platform.Sharing.UsageBatcher`, default
  one hour) it flushes:

    1. reads `Platform.Sharing.enabled?(:usage_counts)` and sets the
       collector flag from it. Off drops every pending count and sends
       nothing;
    2. builds `UsageEvents.build_body/4` (scrubbed) for the window since the
       last successful send;
    3. refuses the batch when `UsageEvents.refusal/1` finds anything;
    4. POSTs it through `Platform.Feedback.GithubPublisher.Broker.post_usage/1`,
       to the same broker base every feedback submission uses. No host is
       written here.

  Each timed cycle also runs `Platform.Feedback.ShippedNotices.run/0`
  (task 01a1b678 stage 4), which checks this install's own filed
  fingerprints. It follows the feedback switch, not the usage-counts one.

  A failed POST keeps the counts and the window start, so the next flush
  carries them. A successful one subtracts exactly what it sent.

  Background child (`Platform.Role`): it has a timer that opens an outbound
  connection. `config :platform, :start_usage_batcher` is false in test and
  dev; tests start it with `start_supervised/1` and drive `flush/2`.
  """

  use GenServer

  require Logger

  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Sharing
  alias Platform.Sharing.UsageEvents

  @default_interval_ms :timer.hours(1)

  @type result ::
          {:sent, map()} | :off | :empty | {:refused, atom()} | {:error, term()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Flush now and return what happened. `opts[:inject_counts]` merges a raw
  map into the pending counts BEFORE the scrubber runs, so a test can prove
  the scrubber strips what the collector would never produce.
  """
  @spec flush(GenServer.server(), keyword()) :: result()
  def flush(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:flush, opts}, 30_000)

  @doc "The flush interval in ms, from config (`:manual` disables the timer)."
  @spec interval_ms() :: pos_integer() | :manual
  def interval_ms do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :interval_ms) do
      :manual -> :manual
      n when is_integer(n) and n > 0 -> n
      _ -> @default_interval_ms
    end
  end

  @impl true
  def init(opts) do
    :ok = UsageEvents.attach()
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    {:ok, %{interval: interval, window_start: now()}, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state) do
    UsageEvents.set_counting(switch_on?())
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call({:flush, opts}, _from, state) do
    {result, state} = do_flush(state, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = do_flush(state, [])
    # Same cycle (task 01a1b678 stage 4): this install's own shipped notices.
    _ = Platform.Feedback.ShippedNotices.run()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: UsageEvents.detach()

  defp do_flush(state, opts) do
    on? = switch_on?()
    UsageEvents.set_counting(on?)
    started = state.window_start
    ended = now()

    if on? do
      counts = Map.merge(UsageEvents.pending(), Keyword.get(opts, :inject_counts, %{}))
      body = UsageEvents.build_body(install_id(), started, DateTime.diff(ended, started), counts)
      send_body(body, state, ended)
    else
      {:off, %{state | window_start: ended}}
    end
  rescue
    error ->
      Logger.warning("[Sharing.UsageBatcher] flush failed: #{inspect(error.__struct__)}")
      {{:error, :exception}, state}
  end

  defp send_body(%{"counts" => counts}, state, ended) when map_size(counts) == 0,
    do: {:empty, %{state | window_start: ended}}

  defp send_body(body, state, ended) do
    case UsageEvents.refusal(body) do
      nil ->
        case Broker.post_usage(body) do
          :ok ->
            UsageEvents.subtract(body["counts"])
            {{:sent, body}, %{state | window_start: ended}}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      reason ->
        Logger.warning("[Sharing.UsageBatcher] batch refused: #{reason}")
        UsageEvents.subtract(body["counts"])
        {{:refused, reason}, %{state | window_start: ended}}
    end
  end

  defp switch_on? do
    Sharing.enabled?(:usage_counts)
  rescue
    _ -> false
  end

  defp install_id, do: to_string(Sharing.get().sharing_install_id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp schedule(:manual), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :flush, ms)
end
