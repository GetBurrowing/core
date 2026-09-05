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

  ## The say ledger (task 01a06672 stage 2)

  A SECOND table, `:meeting_say_ledger`, owned by the same process and swept
  on the same schedule. It is what `Platform.Meetings.say/4`'s reply budget
  counts against, and it exists because neither of the obvious stores can
  count:

    * this registry's own rows are DELETED on ack, by `say/4` and by
      `record_agent_say_ack/2`, so a spoken utterance vanishes from it;
    * chat messages are only written on a `"spoken"` ack, so a `no_ack`
      say would be free.

  Ledger rows are written by `say/4` once the budget has passed and are
  deleted only when the broadcast itself fails — never on ack — so every
  ACCEPTED say counts, whatever happened to it afterwards. Two row shapes
  share the table:

    * `{utterance_id, %{room_id, room_name, agent_id, at_ms}}` — one
      accepted say. `at_ms` is monotonic milliseconds.
    * `{{:last_human, room_name}, at_ms}` — when a human last spoke in the
      room, written by `deliver_transcript_segment/2` for every FINAL human
      segment persisted. An absent key means no human has spoken since the
      table was created, and every ledger say in the room counts toward the
      agent-chain rule.

  Both shapes age out under `ttl_ms/0`; five minutes comfortably covers the
  one-minute rate window, and a `last_human` marker that old is stale by
  definition (any say rows it would have fenced off are gone too).
  """

  use GenServer

  @table :meeting_say_registry
  @ledger :meeting_say_ledger

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
    for table <- [@table, @ledger] do
      case :ets.info(table) do
        :undefined ->
          :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

        _ ->
          # A supervisor restart that raced the old owner's exit.
          :ok
      end
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    sweep(cutoff)
    ledger_sweep(cutoff)
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

  # ── Say ledger ─────────────────────────────────────────────────────────────

  @doc """
  Record an ACCEPTED say. `entry.at_ms` is supplied by the caller (monotonic
  milliseconds) rather than stamped here, so a test can backdate a row.
  """
  @spec ledger_put(binary(), %{
          room_id: binary(),
          room_name: String.t(),
          agent_id: binary(),
          at_ms: integer()
        }) :: :ok
  def ledger_put(utterance_id, %{room_id: _, room_name: _, agent_id: _, at_ms: at_ms} = entry)
      when is_binary(utterance_id) and is_integer(at_ms) do
    true = :ets.insert(@ledger, {utterance_id, entry})
    :ok
  end

  @doc """
  Forget a say that was accepted but never went out (`say/4`'s
  `:broadcast_failed` branch). Not called on ack.
  """
  @spec ledger_delete(binary()) :: :ok
  def ledger_delete(utterance_id) when is_binary(utterance_id) do
    :ets.delete(@ledger, utterance_id)
    :ok
  end

  def ledger_delete(_other), do: :ok

  @doc """
  Accepted says by `agent_id` in the room `room_id` (the Room UUID) strictly
  after `since_ms`. The rate rule.
  """
  @spec ledger_count_since(binary(), binary(), integer()) :: non_neg_integer()
  def ledger_count_since(room_id, agent_id, since_ms) when is_integer(since_ms) do
    :ets.select_count(@ledger, [
      {{:"$1", %{room_id: room_id, agent_id: agent_id, at_ms: :"$2"}},
       [{:is_binary, :"$1"}, {:>, :"$2", since_ms}], [true]}
    ])
  end

  @doc """
  The earliest `at_ms` among `agent_id`'s accepted says in `room_id`
  strictly after `since_ms`, or `nil` when there are none.

  Task 01a06e07 stage 2: lets a caller compute WHEN the rate window
  (`ledger_count_since/3`'s window) next has room, without exposing the
  raw ledger rows to something that only needs one number.
  """
  @spec ledger_oldest_since(binary(), binary(), integer()) :: integer() | nil
  def ledger_oldest_since(room_id, agent_id, since_ms) when is_integer(since_ms) do
    matches =
      :ets.select(@ledger, [
        {{:"$1", %{room_id: room_id, agent_id: agent_id, at_ms: :"$2"}},
         [{:is_binary, :"$1"}, {:>, :"$2", since_ms}], [:"$2"]}
      ])

    case matches do
      [] -> nil
      at_ms_list -> Enum.min(at_ms_list)
    end
  end

  @doc """
  Accepted says in the room `room_name` by ANY agent strictly after
  `since_ms`; `nil` counts every row for the room. The agent-chain rule.
  """
  @spec ledger_count_room_since(String.t(), integer() | nil) :: non_neg_integer()
  def ledger_count_room_since(room_name, nil) do
    :ets.select_count(@ledger, [
      {{:"$1", %{room_name: room_name}}, [{:is_binary, :"$1"}], [true]}
    ])
  end

  def ledger_count_room_since(room_name, since_ms) when is_integer(since_ms) do
    :ets.select_count(@ledger, [
      {{:"$1", %{room_name: room_name, at_ms: :"$2"}},
       [{:is_binary, :"$1"}, {:>, :"$2", since_ms}], [true]}
    ])
  end

  @doc """
  Note that a human's FINAL segment landed in `room_name` at `at_ms`
  (monotonic). Overwrites: only the most recent one matters.
  """
  @spec note_human_segment(String.t(), integer()) :: :ok
  def note_human_segment(room_name, at_ms) when is_binary(room_name) and is_integer(at_ms) do
    true = :ets.insert(@ledger, {{:last_human, room_name}, at_ms})
    :ok
  end

  @doc """
  When a human last spoke in `room_name`, or `nil` if no human segment has
  been noted (or the note has aged out). The `nil` is load-bearing: the
  caller treats it as "every say counts", not as "just now".
  """
  @spec last_human_at(String.t()) :: integer() | nil
  def last_human_at(room_name) when is_binary(room_name) do
    case :ets.lookup(@ledger, {:last_human, room_name}) do
      [{{:last_human, ^room_name}, at_ms}] -> at_ms
      [] -> nil
    end
  end

  @doc """
  Drop every ledger row (say rows and `last_human` markers alike) at or
  before `cutoff_ms`. Public for the same reason `sweep/1` is.
  """
  @spec ledger_sweep(integer()) :: non_neg_integer()
  def ledger_sweep(cutoff_ms) when is_integer(cutoff_ms) do
    says =
      :ets.select_delete(@ledger, [
        {{:"$1", %{at_ms: :"$2"}}, [{:is_binary, :"$1"}, {:"=<", :"$2", cutoff_ms}], [true]}
      ])

    markers =
      :ets.select_delete(@ledger, [
        {{{:last_human, :_}, :"$1"}, [{:"=<", :"$1", cutoff_ms}], [true]}
      ])

    says + markers
  end
end
