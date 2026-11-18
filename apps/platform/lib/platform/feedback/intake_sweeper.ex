defmodule Platform.Feedback.IntakeSweeper do
  @moduledoc """
  Periodic driver for `Platform.Feedback.Intake.retry_pending/1` (task
  01a1e670 stage 2), mirroring `Platform.Meetings.CandidateSweeper`.

  Every tick (default 5 minutes) it asks the intake to re-fetch and
  re-classify a bounded batch of due pending records. It does nothing while
  `Platform.Feedback.Policy.enabled?/0` is false, and the intake itself
  returns at once while the classifier has no usable model, so an install
  with no endpoint agent consumes no attempts.

  Started from `Platform.Application` behind `:start_feedback_intake_sweeper`
  (default true, false in test). Options: `:tick_interval_ms`, `:batch`,
  `:name`; `config :platform, Platform.Feedback.IntakeSweeper` supplies the
  same keys.
  """

  use GenServer

  require Logger

  alias Platform.Feedback.Intake
  alias Platform.Feedback.Policy

  @default_tick_interval_ms 300_000
  @default_batch 10

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Run one sweep now. Returns `:disabled` or `retry_pending/1`'s result."
  @spec sweep(keyword()) :: :disabled | {:ok, map()}
  def sweep(opts \\ []) do
    if Policy.enabled?(), do: Intake.retry_pending(opts), else: :disabled
  end

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    state = %{
      tick_interval_ms:
        Keyword.get(opts, :tick_interval_ms) ||
          Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms),
      batch: Keyword.get(opts, :batch) || Keyword.get(config, :batch, @default_batch)
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    # One bad record must not stop the sweep for every other record.
    try do
      sweep(batch: state.batch)
    rescue
      error ->
        Logger.error("[Feedback.IntakeSweeper] sweep raised error=#{inspect(error.__struct__)}")
    end

    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
