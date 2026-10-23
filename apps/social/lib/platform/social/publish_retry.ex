defmodule Platform.Social.PublishRetry do
  @moduledoc """
  Re-publishes approved posts that `Platform.Social.RateLimit` refused, once
  their window has ended (task 01a165f1, stage 2). Core has no job runner
  (no Oban), so this is Social's, shaped like `RateLimit`'s sweep: a
  `Process.send_after/3` timer.

  Every `config :social, :publish_retry, interval_ms: 60_000` it selects
  approved posts with `refused_reason = "rate_limited"` and
  `retry_after <= now`, oldest `retry_after` first, and calls
  `Platform.Social.Publishing.publish_post/2` for each, then re-renders the
  post's approval card. ONLY `rate_limited` is retried automatically: every
  other refusal needs a human to fix the cause and retry
  (`Publishing.retry_publish/3`).

  Idempotent: `publish_post/2` locks the row `FOR UPDATE` and its guard
  re-reads the status, so a double sweep, or two nodes sweeping at once,
  publish a post once. A second rate limit just writes a new `retry_after`.
  All state is in the database, so a restart loses nothing.

  `interval_ms: :infinity` sets no timer (test config: tests start their own
  instance with `start_supervised!/1` and call `sweep_now/1`).
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social.{Account, Approvals, Post, Profile, Publishing}

  @default_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Runs one sweep now, in the server, and answers the publish results as
  `[{post_id, result}]`, oldest `retry_after` first.
  """
  @spec sweep_now(GenServer.server()) :: [{Ecto.UUID.t(), term()}]
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now, :infinity)

  @doc "The posts due a retry at `now`: `[{org_id, post_id}]`, oldest `retry_after` first."
  @spec due(DateTime.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def due(now \\ DateTime.utc_now()) do
    Repo.all(
      from(po in Post,
        join: a in Account,
        on: a.id == po.account_id,
        join: p in Profile,
        on: p.id == a.profile_id,
        where:
          po.status == "approved" and po.refused_reason == "rate_limited" and
            po.retry_after <= ^now,
        order_by: [asc: po.retry_after, asc: po.id],
        select: {p.org_id, po.id}
      )
    )
  end

  @doc false
  def interval_ms(opts \\ []) do
    Keyword.get_lazy(opts, :interval_ms, fn ->
      :social
      |> Application.get_env(:publish_retry, [])
      |> Keyword.get(:interval_ms, @default_interval_ms)
    end)
  end

  @impl true
  def init(opts) do
    state = %{interval_ms: interval_ms(opts)}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state), do: {:reply, sweep(), state}

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule(state)
    {:noreply, state}
  end

  defp sweep do
    for {org_id, post_id} <- due() do
      result = retry(org_id, post_id)
      Approvals.rerender_latest(post_id)
      {post_id, result}
    end
  rescue
    error ->
      Logger.warning("[Social.PublishRetry] sweep failed: #{Exception.message(error)}")
      []
  end

  defp retry(org_id, post_id) do
    Publishing.publish_post(org_id, post_id)
  rescue
    error ->
      Logger.warning(
        "[Social.PublishRetry] post #{post_id} retry raised: #{Exception.message(error)}"
      )

      {:error, :raised}
  end

  defp schedule(%{interval_ms: :infinity}), do: :ok

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :sweep, ms)
end
