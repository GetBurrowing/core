defmodule Platform.Memory.Insights.Purger do
  @moduledoc """
  Expiry for `memory_insights`. Task `01a13867-3213-7001-a128-6b4c6b34283f`,
  stage 1. Mirrors `Platform.Prototypes.Purger`: an hourly `send_after`
  GenServer whose work is a synchronous `sweep/1` tests call directly.

  A sweep hard-DELETEs every `memory_insights` row whose `expires_at` is
  before now, WHATEVER its state: an acted-on insight leaves its artefact
  behind, not its row. It never touches `memory_insight_verdicts`, which are
  durable.

  This is the purge `memory_proposals` never had: `Proposals.expire_stale/0`
  had no caller, so proposals past their TTL stayed `pending` forever.

  Disabled in `config/test.exs` (`:start_insight_purger false`).
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Memory.Insight
  alias Platform.Repo

  @tick_interval_ms 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run one sweep synchronously. Returns `{:ok, deleted_count}`.

  Options: `:now` (a `DateTime`, default now) for tests.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()}
  def sweep(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {deleted, _} = Repo.delete_all(from(i in Insight, where: i.expires_at < ^now))

    if deleted > 0 do
      Logger.info("[insight_purger] deleted #{deleted} expired insight(s)")

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.Memory.Insights.topic(),
        {:memory_insights, :purged, deleted}
      )
    end

    {:ok, deleted}
  end

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      {:ok, _} = sweep()
    rescue
      error ->
        Logger.error(
          "[insight_purger] sweep crashed: " <> Exception.format(:error, error, __STACKTRACE__)
        )
    end

    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
