defmodule Platform.Chat.ReplyFailure.Dedupe do
  @moduledoc """
  Dedupe state for `Platform.Chat.ReplyFailure` notices (task 01a10322
  stage 1).

  Owns the `:chat_reply_failure_notices` ETS table for its lifecycle only, the
  same shape as `Platform.Federation.Peers.NonceCache`. `claim/3` runs in the
  caller's process and is never serialised through the server. Its inserts are
  `:ets.insert_new/2`, so two concurrent failures for one agent cannot both
  claim the window.

  Two keys per notice:

    * `{:agent, agent_id}` expires after the dedupe window. While it is live,
      no further notice for that agent is posted, whatever the message.
    * `{:message, agent_id, message_id}` expires after `@message_ttl_ms`, so a
      re-dispatch of the same message after the window still posts nothing.

  A third key, `{:pending, agent_id}`, holds the LAST chat message delivered
  to an agent's runtime that has not yet been accounted for (stage 7, see
  `Platform.Chat.ReplyFailure.notify_pending/2`). It expires after
  `pending_ttl_ms/0` and is consumed by `take_pending/2`.

  ## The bound, stated as scope

  This covers repeat failures that reach THIS node while this process has been
  up, and nothing else. A restart wipes it, and a second node keeps its own
  table. Either lets one extra notice through, which is the cheaper failure
  than a lost one.
  """

  use GenServer

  @table :chat_reply_failure_notices
  @message_ttl_ms 24 * 60 * 60 * 1000
  @sweep_interval_ms 60_000
  @pending_ttl_ms 10 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Claim the right to post one notice for `agent_id` about `message_id`.

  Returns `:ok` exactly once per `(agent_id, message_id)` and at most once per
  agent inside `window_ms`; `:duplicate` otherwise.
  """
  @spec claim(binary(), binary(), non_neg_integer(), integer()) :: :ok | :duplicate
  def claim(agent_id, message_id, window_ms, now_ms \\ System.monotonic_time(:millisecond)) do
    message_key = {:message, agent_id, message_id}

    # Both keys are claimed with insert_new, so two concurrent failures for
    # ONE message (the host's needs_login report and the no-reply watchdog's
    # verdict, stage 7 round 2) cannot both post, even with a zero window.
    # A message claimed while the agent window was held stays claimed: at
    # most one notice per message, never a late second one.
    cond do
      not claim_key(message_key, now_ms + @message_ttl_ms, now_ms) ->
        :duplicate

      not claim_key({:agent, agent_id}, now_ms + window_ms, now_ms) ->
        :duplicate

      true ->
        :ok
    end
  end

  @doc "How long a delivered message stays pending: 10 minutes."
  @spec pending_ttl_ms() :: pos_integer()
  def pending_ttl_ms, do: @pending_ttl_ms

  @doc """
  Remember `pending` (a map of ids) as the last message delivered to
  `agent_id`'s runtime. Replaces any earlier one.
  """
  @spec put_pending(binary(), map(), integer()) :: :ok
  def put_pending(agent_id, pending, now_ms \\ System.monotonic_time(:millisecond))
      when is_binary(agent_id) and is_map(pending) do
    :ets.insert(@table, {{:pending, agent_id}, now_ms + @pending_ttl_ms, pending})
    :ok
  end

  @doc "Remove and return the live pending message for `agent_id`, or nil."
  @spec take_pending(binary(), integer()) :: map() | nil
  def take_pending(agent_id, now_ms \\ System.monotonic_time(:millisecond))
      when is_binary(agent_id) do
    case :ets.take(@table, {:pending, agent_id}) do
      [{_key, expires_at, pending}] when expires_at > now_ms -> pending
      _ -> nil
    end
  end

  @doc "Deletes every row. Tests use it to model a restart."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Deletes rows whose expiry is at or before `now_ms`. Returns the count."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms \\ System.monotonic_time(:millisecond)) do
    :ets.select_delete(@table, [
      {{:_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]},
      {{:_, :"$1", :_}, [{:"=<", :"$1", now_ms}], [true]}
    ])
  end

  # Inserts `key` unless a live row holds it. An expired row is replaced, and
  # of two concurrent callers replacing it only one insert_new succeeds.
  defp claim_key(key, expires_at, now_ms) do
    if :ets.insert_new(@table, {key, expires_at}) do
      true
    else
      case :ets.lookup(@table, key) do
        [{^key, old_expiry}] when old_expiry <= now_ms ->
          _ = :ets.select_delete(@table, [{{key, old_expiry}, [], [true]}])
          :ets.insert_new(@table, {key, expires_at})

        _ ->
          false
      end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
