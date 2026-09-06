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

  ## Delivered transcript frames (task 01a07400 stage 2)

  A THIRD table, `:meeting_transcript_frames`, owned by the same process and
  swept on the same schedule, holding one row per `{meeting_id, agent_id}`:

      {{meeting_id, agent_id}, %{meeting_id, room_name, segment_id, at_ms}}

  Written by `Platform.Meetings.TranscriptTelemetry.delivered/2` every time a
  final transcript segment is broadcast to that agent's brain runtime, and
  OVERWRITTEN each time — only the most recent frame is of interest.
  `take_delivered_frame/2` reads and removes it when the agent next dispatches
  a say in that room, which is what turns two independent events into one
  `response_ms` measurement.

  It lives here rather than in a store of its own for three reasons: the
  ceiling is the same `@ttl_ms` rather than a second number that can drift
  from it, the sweep is the same tick, and the lifetime rule is identical —
  a correlation that spanned a restart would be measuring against a frame
  this node has no other record of.

  This is diagnostic state and must not become durable. There is no schema,
  no migration and no Postgres table behind it: losing a row costs one
  measurement, and nothing reads it to make a decision.
  """

  use GenServer

  @table :meeting_say_registry
  @ledger :meeting_say_ledger
  @frames :meeting_transcript_frames

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
          inserted_at_ms: integer(),
          dispatched_at: DateTime.t()
        }

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    for table <- [@table, @ledger, @frames] do
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
    frames_sweep(cutoff)
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

  Two clocks are stamped here, and they are not interchangeable:

    * `inserted_at_ms` — monotonic milliseconds, what `sweep/1` ages rows
      against. Meaningless as a point in time and never leaves this module.
    * `dispatched_at` — wall clock UTC, the moment core handed the utterance
      to the agent's runtime. This is the ordering key
      `Platform.Meetings.post_spoken_utterance/2` stamps onto the chat
      message when the ack comes back (task 01a07401 stage 1), so a line
      whose ack was slow still sorts where it was said rather than where it
      was acknowledged. See that function for why dispatch time and not
      playback-start time.
  """
  @spec put(binary(), map()) :: :ok
  def put(utterance_id, %{text: _, room_id: _, room_name: _, space_id: _, agent_id: _} = entry)
      when is_binary(utterance_id) do
    row =
      Map.merge(entry, %{
        inserted_at_ms: System.monotonic_time(:millisecond),
        dispatched_at: DateTime.utc_now()
      })

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

  # ── Delivered transcript frames ────────────────────────────────────────────

  @doc """
  Note that a final transcript segment was broadcast to `agent_id`'s brain
  runtime in `meeting_id` (task 01a07400 stage 2). Overwrites any earlier
  row for the pair: only the most recent frame can be the one an agent is
  answering.

  `segment_id` is carried so the later `response_ms` can name the frame it
  was measured from — a number with no referent cannot be checked.
  """
  @spec note_delivered_frame(binary(), binary(), %{
          room_name: String.t(),
          segment_id: term()
        }) :: :ok
  def note_delivered_frame(meeting_id, agent_id, %{room_name: room_name, segment_id: segment_id})
      when is_binary(meeting_id) and is_binary(agent_id) and is_binary(room_name) do
    entry = %{
      meeting_id: meeting_id,
      room_name: room_name,
      segment_id: segment_id,
      at_ms: System.monotonic_time(:millisecond)
    }

    true = :ets.insert(@frames, {{meeting_id, agent_id}, entry})
    :ok
  end

  @doc """
  The most recent delivered frame for `agent_id` in `room_name`, REMOVED as
  it is read, or `nil` when there is none.

  Looked up by `{agent_id, room_name}` rather than by the key because
  `Platform.Meetings.say/4` knows the room it is speaking into and not which
  `meetings` row is live for it; the key stays `{meeting_id, agent_id}` so
  one agent cannot hold two competing marks for the same conversation.

  The removal is the point, not a tidy-up. A frame is answered at most once:
  without it, every say the agent made for the next five minutes would be
  reported as a response to a frame it had already answered, and an
  unprompted say would inherit a number from whatever was last said near it.
  `:ets.take/2` does the removal atomically, so two concurrent says race for
  the mark and exactly one of them wins it.
  """
  @spec take_delivered_frame(binary(), String.t()) :: map() | nil
  def take_delivered_frame(agent_id, room_name)
      when is_binary(agent_id) and is_binary(room_name) do
    @frames
    |> :ets.select([
      {{{:"$1", agent_id}, %{room_name: room_name, at_ms: :"$2"}}, [], [{{:"$1", :"$2"}}]}
    ])
    |> case do
      [] ->
        nil

      matches ->
        {meeting_id, _at_ms} = Enum.max_by(matches, fn {_meeting_id, at_ms} -> at_ms end)

        case :ets.take(@frames, {meeting_id, agent_id}) do
          [{_key, entry}] -> entry
          [] -> nil
        end
    end
  end

  def take_delivered_frame(_agent_id, _room_name), do: nil

  @doc """
  Drop every delivered-frame row at or before `cutoff_ms`. Public for the
  same reason `sweep/1` is.
  """
  @spec frames_sweep(integer()) :: non_neg_integer()
  def frames_sweep(cutoff_ms) when is_integer(cutoff_ms) do
    :ets.select_delete(@frames, [
      {{{:_, :_}, %{at_ms: :"$1"}}, [{:"=<", :"$1", cutoff_ms}], [true]}
    ])
  end
end
