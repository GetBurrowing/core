defmodule Platform.Meetings.SayRegistry do
  @moduledoc """
  In-flight `meeting_say` utterances, keyed on `utterance_id` (task 01a06672
  stage 1).

  ## Why the text is held here and not carried by the ack

  `Platform.Meetings.say/4` broadcasts the text to the agent's runtime and
  waits for a `meeting_say_ack`. When the ack says `"spoken"`, core posts the
  text into the room's chat space so the transcript shows what the agent
  said. If the ack carried the text, the chat row would be written from
  whatever the runtime sent BACK — any connected runtime could echo an ack
  with arbitrary content and have it posted under the agent's name. So the
  ack carries only the id, and the text that gets posted is the text core
  itself dispatched, looked up here. A forged ack for an id that was never
  dispatched finds nothing and posts nothing; an ack from a different agent
  than the one that spoke is refused by the `agent_id` stored alongside.

  ## Storage

  ETS, one row per utterance, owned by this GenServer for the table's
  lifecycle only — inserts, lookups and deletes are direct from the caller's
  process, in the shape of `Platform.Meetings.PressWindow`. The table dies
  with the owner, which is correct: an utterance that was in flight across a
  restart has no ack coming that core could still trust.

  ## Expiry

  `say/4` deletes its own entry on every ack it receives, and
  `record_agent_say_ack/2` deletes on `"spoken"`. What is left behind is the
  `no_ack` case — the caller gave up waiting and the runtime never answered,
  or answered after the caller had gone. Those rows are swept every
  `sweep_interval_ms/0` once older than `ttl_ms/0`. Five minutes is well past
  the 15-second default ack window, so a late ack that still arrives inside
  it can still post; one later than that is a receipt for an utterance
  nobody is listening for.
  """

  use GenServer

  @table :meeting_say_registry

  # Entries older than this are swept. Chosen to cover any late ack that
  # the 15 s default rendezvous would have missed, with margin.
  @ttl_ms 5 * 60_000

  # How often the sweep runs. Rows are tiny; this only bounds how long a
  # dead entry can linger past its ttl.
  @sweep_interval_ms 60_000

  @type entry :: %{
          text: String.t(),
          room_id: binary(),
          room_name: String.t(),
          space_id: binary(),
          agent_id: binary(),
          inserted_at_ms: integer()
        }

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # A supervisor restart that raced the old owner's exit.
        :ok
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.monotonic_time(:millisecond) - @ttl_ms)
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # ── Tunables ───────────────────────────────────────────────────────────────

  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @spec sweep_interval_ms() :: pos_integer()
  def sweep_interval_ms, do: @sweep_interval_ms

  # ── API ────────────────────────────────────────────────────────────────────

  @doc """
  Record an utterance that is about to be dispatched. Called by `say/4`
  BEFORE the broadcast, so an ack can never arrive for an id that is not
  yet registered.
  """
  @spec put(binary(), map()) :: :ok
  def put(utterance_id, %{text: _, room_id: _, room_name: _, space_id: _, agent_id: _} = entry)
      when is_binary(utterance_id) do
    row = Map.put(entry, :inserted_at_ms, System.monotonic_time(:millisecond))
    true = :ets.insert(@table, {utterance_id, row})
    :ok
  end

  @spec get(binary()) :: entry() | nil
  def get(utterance_id) when is_binary(utterance_id) do
    case :ets.lookup(@table, utterance_id) do
      [{^utterance_id, entry}] -> entry
      [] -> nil
    end
  end

  def get(_other), do: nil

  @spec delete(binary()) :: :ok
  def delete(utterance_id) when is_binary(utterance_id) do
    :ets.delete(@table, utterance_id)
    :ok
  end

  def delete(_other), do: :ok

  @doc """
  Drop every entry inserted at or before `cutoff_ms` (monotonic). Public so a
  test can drive the sweep without waiting a minute. Returns the count
  removed.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(cutoff_ms) when is_integer(cutoff_ms) do
    :ets.select_delete(@table, [
      {{:_, %{inserted_at_ms: :"$1"}}, [{:"=<", :"$1", cutoff_ms}], [true]}
    ])
  end
end
