defmodule Platform.Federation.Peers.NonceCache do
  @moduledoc """
  The replay cache for signed peer envelopes (task 01a0d90f stage 3, ADR 0054
  section 2).

  One ETS row per `{peer_install_id, nonce}`, owned by this GenServer purely
  for the table's lifecycle, the same shape as `Platform.Meetings.PressWindow`.
  `check_and_record/4` runs in the caller's process (the inbox request) and is
  never serialised through the server; the insert is `:ets.insert_new/2`, so
  two concurrent deliveries of one nonce cannot both be recorded as fresh.

  ## Expiry equals the timestamp window

  A row expires when the envelope that carried it would fall out of the
  `Envelope` timestamp window anyway: `expires_at = max(ts, now) + window`.
  Keying the expiry on `ts` (not on arrival) matters for a future-dated
  envelope: one stamped `now + 299 s` stays acceptable by timestamp until
  `now + 599 s`, so its nonce must be held that long. The sweep runs every
  `sweep_interval_ms/0` and deletes expired rows; a row past `expires_at`
  that the sweep has not reached yet is treated as absent.

  ## The bound, stated as scope

  This cache covers replays **that reach this node while this process has
  been up for the envelope's whole window**, and nothing else:

    * **It is ephemeral by design.** A restart wipes it. After a restart, an
      envelope captured within the last window can be re-delivered and pass
      the nonce check. What stops it doing harm is idempotency: the envelope
      `id` and the handshake handlers' state checks here, and the
      `(peer_id, remote_message_id)` unique message link in stage 5, make a
      re-delivery a no-op. Once the envelope's `ts` is outside the window, the
      timestamp check refuses it whatever this cache holds.
    * **It is per node.** Two nodes each hold their own table, so a replay
      sent to a different node than the original passes the nonce check
      there. v1 installs are single node. A multi-node install needs a shared
      nonce store (or accepts a per-node replay window, still bounded by
      idempotency).
  """

  use GenServer

  @table :federation_peer_nonces
  @window_ms 300_000
  @sweep_interval_ms 60_000

  @doc "The replay window in milliseconds; equals `Envelope`'s timestamp window."
  def window_ms, do: @window_ms

  @doc false
  def sweep_interval_ms, do: @sweep_interval_ms

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records `nonce` for `peer_install_id`. Returns `:ok` the first time a
  nonce is seen inside its window and `{:error, :replayed_nonce}` after.

  `ts_ms` is the envelope's timestamp and `now_ms` the receiver's clock, both
  unix milliseconds.
  """
  @spec check_and_record(String.t(), String.t(), integer(), integer()) ::
          :ok | {:error, :replayed_nonce}
  def check_and_record(peer_install_id, nonce, ts_ms, now_ms) do
    key = {peer_install_id, nonce}
    expires_at = max(ts_ms, now_ms) + @window_ms

    if :ets.insert_new(@table, {key, expires_at}) do
      :ok
    else
      case :ets.lookup(@table, key) do
        [{^key, old_expiry}] when old_expiry <= now_ms ->
          # Expired but not yet swept: the old envelope is outside its
          # window, so this nonce is fresh again. Delete exactly that expired
          # row, then insert_new: of two concurrent callers only one insert
          # can succeed.
          _ = :ets.select_delete(@table, [{{key, old_expiry}, [], [true]}])

          if :ets.insert_new(@table, {key, expires_at}),
            do: :ok,
            else: {:error, :replayed_nonce}

        _ ->
          {:error, :replayed_nonce}
      end
    end
  end

  @doc """
  Counts one `relationship.propose` descriptor fetch in the current hour and
  returns the hour's count so far, this one included.

  This is the fetch-volume cap that `Platform.Federation.Peers.Inbound`
  checks before re-fetching an UNKNOWN proposer's `.well-known`. The
  recorded-proposal cap alone cannot bound fetches, because a proposal whose
  fetch or binding fails records nothing. It lives in this table for the same
  lifecycle (ephemeral, per node) and rows are 3-tuples
  `{{:propose_fetches, hour}, count, expires_at}` so the nonce sweep, which
  matches 2-tuples, never touches them.
  """
  @spec count_propose_fetch(integer()) :: pos_integer()
  def count_propose_fetch(now_ms) do
    hour = div(now_ms, 3_600_000)
    key = {:propose_fetches, hour}
    :ets.update_counter(@table, key, {2, 1}, {key, 0, (hour + 1) * 3_600_000})
  end

  @doc "Deletes every row. Tests use it to model a restart."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Deletes rows whose expiry is at or before `now_ms`. Returns the count."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms \\ System.system_time(:millisecond)) do
    :ets.select_delete(@table, [
      {{:_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]},
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]}
    ])
  end

  @doc false
  def size, do: :ets.info(@table, :size)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
