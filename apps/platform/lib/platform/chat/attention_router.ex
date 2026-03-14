defmodule Platform.Chat.AttentionRouter do
  @moduledoc """
  Routes attention signals to chat participants based on their configured mode.

  ## Attention modes

    * `"active"`    — always notified when any message is posted in the space.
    * `"mention"`   — notified only when `@display_name`, `@participant_id`, or a
                      configured keyword appears in the message content.
    * `"heartbeat"` — signals accumulate in memory; drain with `flush/1` on the
                      participant's next heartbeat poll.

  ## Integration

  `AttentionRouter` is supervised and starts automatically via `Platform.Application`.
  It attaches a `:telemetry` handler on `[:platform, :chat, :message_posted]` and
  processes each new message automatically.

  You may also call `route/1` directly (e.g. in tests or imperative flows).

  ## PubSub events

  For `:active` and `:mention` decisions, broadcasts on the space topic
  (`Platform.Chat.PubSub.space_topic/1`):

      {:attention_needed, %{
        participant_id: binary(),
        reason: :active | :mention,
        message_id: binary(),
        space_id:   binary()
      }}

  `:heartbeat` signals are stored internally and are NOT broadcast until flushed.

  ## Heartbeat draining

      pending = Platform.Chat.AttentionRouter.pending(participant_id)
      # => [%{space_id: …, message_id: …, reason: :heartbeat, participant_id: …}]

      {:ok, flushed} = Platform.Chat.AttentionRouter.flush(participant_id)
      # => {:ok, [%{…}]}   — clears pending signals for the participant
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Platform.Chat.{Message, Participant}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  @handler_id "platform-chat-attention-router"
  @table :chat_attention_heartbeat

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously route attention for `message`.

  Looks up all active participants in the message's space, applies the per-mode
  routing decision, broadcasts `:attention_needed` PubSub events for `:active`
  and `:mention` recipients, and queues `:heartbeat` signals in ETS.

  Returns the list of routing decisions (one map per notified participant).
  """
  @spec route(Message.t()) :: {:ok, [%{participant_id: binary(), reason: atom()}]}
  def route(%Message{} = message) do
    GenServer.call(__MODULE__, {:route, message})
  end

  @doc """
  Return pending heartbeat signals for `participant_id` without clearing them.
  """
  @spec pending(binary()) :: [map()]
  def pending(participant_id) do
    GenServer.call(__MODULE__, {:pending, participant_id})
  end

  @doc """
  Flush and clear all pending heartbeat signals for `participant_id`.

  Returns `{:ok, signals}` where `signals` is the list that was pending.
  """
  @spec flush(binary()) :: {:ok, [map()]}
  def flush(participant_id) do
    GenServer.call(__MODULE__, {:flush, participant_id})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :bag, :protected, read_concurrency: true])
    attach_telemetry()
    Logger.debug("[AttentionRouter] started, ETS table=#{inspect(table)}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:route, message}, _from, state) do
    decisions = do_route(message)
    {:reply, {:ok, decisions}, state}
  end

  @impl true
  def handle_call({:pending, participant_id}, _from, state) do
    items =
      @table
      |> :ets.lookup(participant_id)
      |> Enum.map(fn {_key, signal} -> signal end)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:flush, participant_id}, _from, state) do
    items =
      @table
      |> :ets.lookup(participant_id)
      |> Enum.map(fn {_key, signal} -> signal end)

    :ets.delete(@table, participant_id)
    {:reply, {:ok, items}, state}
  end

  @impl true
  def handle_info({:telemetry_message_posted, %{message_id: message_id}}, state) do
    case Repo.get(Message, message_id) do
      %Message{} = msg -> do_route(msg)
      nil -> Logger.warning("[AttentionRouter] message not found: #{message_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    detach_telemetry()
    :ok
  end

  # ── Telemetry integration ───────────────────────────────────────────────────

  defp attach_telemetry do
    :telemetry.attach(
      @handler_id,
      [:platform, :chat, :message_posted],
      &__MODULE__.handle_telemetry_event/4,
      %{}
    )
  end

  defp detach_telemetry do
    :telemetry.detach(@handler_id)
  rescue
    _ -> :ok
  end

  @doc false
  # Called in the telemetry dispatcher process — must not raise.
  # Forwards to the GenServer so routing runs with ETS write access.
  def handle_telemetry_event([:platform, :chat, :message_posted], _measurements, metadata, _cfg) do
    send(__MODULE__, {:telemetry_message_posted, metadata})
  rescue
    error ->
      Logger.error(
        "[AttentionRouter] telemetry handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  # ── Core routing logic ──────────────────────────────────────────────────────

  defp do_route(%Message{space_id: space_id, id: message_id, participant_id: author_id} = message) do
    participants = active_participants(space_id)

    # Exclude the message author — they don't need attention for their own post.
    recipients = Enum.reject(participants, &(&1.id == author_id))

    decisions =
      Enum.flat_map(recipients, fn participant ->
        case decide(participant, message) do
          nil -> []
          reason -> [%{participant_id: participant.id, reason: reason}]
        end
      end)

    Enum.each(decisions, fn %{participant_id: pid, reason: reason} ->
      signal = %{
        participant_id: pid,
        reason: reason,
        message_id: message_id,
        space_id: space_id
      }

      case reason do
        :heartbeat ->
          :ets.insert(@table, {pid, signal})

        _ ->
          ChatPubSub.broadcast(space_id, {:attention_needed, signal})
      end

      emit_attention_telemetry(signal)
    end)

    decisions
  end

  # ── Per-participant decision ─────────────────────────────────────────────────

  defp decide(%Participant{attention_mode: "active"}, _message), do: :active

  defp decide(%Participant{attention_mode: "mention"} = participant, message) do
    if mentioned?(participant, message), do: :mention, else: nil
  end

  defp decide(%Participant{attention_mode: "heartbeat"}, _message), do: :heartbeat

  defp decide(_participant, _message), do: nil

  # ── Mention detection ────────────────────────────────────────────────────────

  defp mentioned?(%Participant{} = p, %Message{content: content}) when is_binary(content) do
    name_match = not is_nil(p.display_name) and String.contains?(content, "@#{p.display_name}")
    id_match = String.contains?(content, "@#{p.id}")

    # Support user-configured keywords in attention_config["keywords"]
    keywords = get_in(p.attention_config, ["keywords"]) || []
    keyword_match = Enum.any?(keywords, &String.contains?(content, &1))

    name_match or id_match or keyword_match
  end

  defp mentioned?(_participant, _message), do: false

  # ── Query helpers ───────────────────────────────────────────────────────────

  defp active_participants(space_id) do
    from(p in Participant, where: p.space_id == ^space_id and is_nil(p.left_at))
    |> Repo.all()
  end

  # ── Telemetry emission ───────────────────────────────────────────────────────

  defp emit_attention_telemetry(%{
         participant_id: pid,
         reason: reason,
         message_id: mid,
         space_id: sid
       }) do
    :telemetry.execute(
      [:platform, :chat, :attention_routed],
      %{system_time: System.system_time()},
      %{space_id: sid, message_id: mid, recipient_id: pid, reason: reason}
    )
  end
end
