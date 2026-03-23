defmodule Platform.Chat.AttentionRouter do
  @moduledoc """
  Routes attention signals to chat participants based on space-level attention
  policy and per-agent engagement state.

  ## Space-level attention modes (resolved via `resolve_attention_mode/2`)

    * `"on_mention"`    — agent responds only when @mentioned (default for channels)
    * `"collaborative"` — like on_mention but with sticky engagement (default for groups)
    * `"directed"`      — agent responds to ALL messages (default for DMs)

  When `space.agent_attention` is `nil`, the mode falls back to a conversation-type
  default: channels → on_mention, DMs → directed, groups → collaborative.

  ## Per-participant modes (human participants)

    * `"active"`    — always notified when any message is posted in the space.
    * `"mention"`   — notified only when @mentioned or keyword-matched.
    * `"heartbeat"` — signals accumulate in memory; drain with `flush/1`.

  ## Sticky engagement

  After an @mention triggers an agent reply, the agent enters "engaged" state.
  While engaged, subsequent messages are routed to the agent without requiring
  @mention. Engagement expires after a configurable timeout (default 10 min).

  ## Silencing

  Natural language patterns (e.g. "quiet", "shut up", "that's all") cause the
  agent to enter "silenced" state. The agent will not respond until re-mentioned
  or the silence timeout expires.

  ## Integration

  `AttentionRouter` is supervised and starts automatically via `Platform.Application`.
  It attaches a `:telemetry` handler on `[:platform, :chat, :message_posted]` and
  processes each new message automatically.

  You may also call `route/1` directly (e.g. in tests or imperative flows).

  ## PubSub events

  For `:active`, `:mention`, `:directed`, and `:sticky` decisions, broadcasts on
  the space topic (`Platform.Chat.PubSub.space_topic/1`):

      {:attention_needed, %{
        participant_id: binary(),
        reason: :active | :mention | :directed | :sticky,
        message_id: binary(),
        space_id:   binary()
      }}

  `:heartbeat` signals are stored internally and are NOT broadcast until flushed.

  ## Heartbeat draining

      pending = Platform.Chat.AttentionRouter.pending(participant_id)
      {:ok, flushed} = Platform.Chat.AttentionRouter.flush(participant_id)
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{AgentResponder, Message, Participant, Presence, Space, SpaceAgent}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  @handler_id "platform-chat-attention-router"
  @table :chat_attention_heartbeat

  # Sticky engagement timeout: 10 minutes
  @engagement_timeout_seconds 600

  # Silence timeout for NLP-triggered silences (30 minutes, same as UI button)
  @nlp_silence_timeout_seconds 1800

  # Silence patterns require clear dismissal intent — avoid common words like
  # "stop", "leave", "enough" that appear in normal conversation and cause
  # accidental silencing.
  @silence_patterns [
    ~r/\b(shut up|back off|be quiet|hush|shush|go away)\b/i,
    ~r/\b(only when i ask|only when mentioned|mentions only)\b/i,
    ~r/\bthat'?s? (all|enough|it)\b/i,
    ~r/\b(thanks?\s+(zip|that'?s?\s+all))\b/i,
    ~r/\byou'?re? dismissed\b/i,
    ~r/\bquiet\s+(down|please|now)\b/i
  ]

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously route attention for `message`.

  Loads the space to resolve the effective attention mode, checks for silencing
  patterns, applies per-participant routing decisions, broadcasts PubSub events,
  and queues heartbeat signals in ETS.

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
  """
  @spec flush(binary()) :: {:ok, [map()]}
  def flush(participant_id) do
    GenServer.call(__MODULE__, {:flush, participant_id})
  end

  @doc """
  Resolve the effective attention mode for an agent in a space.

  If the space has an explicit `agent_attention` value, use it.
  Otherwise fall back to the conversation-type default.
  """
  @spec resolve_attention_mode(Space.t(), Participant.t()) :: String.t()
  def resolve_attention_mode(%Space{} = space, _participant) do
    case space.agent_attention do
      nil -> default_for_kind(space.kind)
      mode -> mode
    end
  end

  defp default_for_kind("channel"), do: "on_mention"
  defp default_for_kind("dm"), do: "directed"
  defp default_for_kind("group"), do: "collaborative"
  defp default_for_kind("execution"), do: "directed"
  defp default_for_kind(_), do: "on_mention"

  @doc "Check if a message content matches any silence patterns."
  @spec silence_detected?(String.t() | nil) :: boolean()
  def silence_detected?(nil), do: false

  def silence_detected?(content) when is_binary(content) do
    Enum.any?(@silence_patterns, &Regex.match?(&1, content))
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

  # Drain call used in tests to flush any pending telemetry handle_info messages
  # before the Ecto sandbox is released.
  @impl true
  def handle_call(:__drain__, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:telemetry_message_posted, %{message_id: message_id}}, state) do
    try do
      case Repo.get(Message, message_id) do
        %Message{} = msg -> do_route(msg)
        nil -> Logger.warning("[AttentionRouter] message not found: #{message_id}")
      end
    rescue
      error ->
        Logger.debug("[AttentionRouter] skipping telemetry route (#{Exception.message(error)})")
    catch
      :exit, reason ->
        Logger.debug("[AttentionRouter] skipping telemetry route (exit: #{inspect(reason)})")
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
  def handle_telemetry_event([:platform, :chat, :message_posted], _measurements, metadata, _cfg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:telemetry_message_posted, metadata})
    end
  rescue
    error ->
      Logger.error(
        "[AttentionRouter] telemetry handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  # ── Core routing logic ──────────────────────────────────────────────────────

  defp do_route(%Message{space_id: space_id, id: message_id, participant_id: author_id} = message) do
    space = Repo.get(Space, space_id)

    unless space do
      Logger.warning("[AttentionRouter] space not found: #{space_id}")
      return_empty()
    end

    # Execution spaces: log_only messages skip attention routing entirely
    if space && space.kind == "execution" && message.log_only do
      return_empty()
    end

    participants = active_participants(space_id)

    # Exclude the message author — they don't need attention for their own post.
    recipients = Enum.reject(participants, &(&1.id == author_id))

    # Check for silencing before routing to agents
    agent_recipients = Enum.filter(recipients, &(&1.participant_type == "agent"))
    human_recipients = Enum.reject(recipients, &(&1.participant_type == "agent"))

    # If the message matches a silence pattern, silence all agents and skip routing
    if silence_detected?(message.content) do
      Enum.each(agent_recipients, fn agent_p ->
        until = DateTime.add(DateTime.utc_now(), @nlp_silence_timeout_seconds, :second)
        Chat.silence_agent(space_id, agent_p.id, until)

        ChatPubSub.broadcast(
          space_id,
          {:agent_silenced,
           %{
             participant_id: agent_p.id,
             space_id: space_id
           }}
        )
      end)
    end

    # Determine which participants are currently online via presence.
    # Presence tracks by user_id, so build a set of user_ids that are online,
    # then we'll check participant.participant_id (which is the user_id for human participants).
    online_user_ids = space_id |> Presence.list_space() |> Map.keys() |> MapSet.new()

    # Route human participants using existing per-participant mode
    human_decisions =
      Enum.flat_map(human_recipients, fn participant ->
        case decide_human(participant, message) do
          nil -> []
          reason -> [%{participant_id: participant.id, reason: reason}]
        end
      end)

    # Route agent participants using roster (if available) or legacy participant routing
    agent_decisions =
      if silence_detected?(message.content) do
        # Don't route to agents when silencing
        []
      else
        roster = Chat.list_space_agents(space_id)
        route_agents_with_roster(space, message, agent_recipients, roster)
      end

    decisions = human_decisions ++ agent_decisions

    # Preload message author display name for notification body.
    author = Enum.find(participants, &(&1.id == author_id))
    sender_name = if author, do: author.display_name || "Someone", else: "Someone"

    # Build a lookup from participant record ID → participant for online checks
    participant_by_id = Map.new(participants, fn p -> {p.id, p} end)

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
          AgentResponder.maybe_dispatch(signal)

          # Send web push to offline participants.
          # Presence tracks by user_id (participant.participant_id), not participant record ID.
          participant = Map.get(participant_by_id, pid)
          user_id = if participant, do: participant.participant_id, else: pid

          unless MapSet.member?(online_user_ids, user_id) do
            maybe_send_push(pid, sender_name, message)
          end
      end

      emit_attention_telemetry(signal)
    end)

    decisions
  end

  # ── Roster-aware agent routing ──────────────────────────────────────────────

  # No roster entries — fall back to legacy participant-based routing
  defp route_agents_with_roster(space, message, agent_recipients, []) do
    Enum.flat_map(agent_recipients, fn participant ->
      case decide_agent(space, participant, message) do
        nil -> []
        reason -> [%{participant_id: participant.id, reason: reason}]
      end
    end)
  end

  # Roster exists — use roster rules for routing
  defp route_agents_with_roster(space, message, agent_recipients, roster) do
    # Build lookup: agent_id -> SpaceAgent entry
    roster_by_agent_id = Map.new(roster, fn sa -> {sa.agent_id, sa} end)

    # Detect which rostered agents are @-mentioned
    mentioned_agents =
      Enum.filter(agent_recipients, fn participant ->
        mentioned?(participant, message)
      end)

    cond do
      # @-mentions present — route to mentioned agents that are in roster
      mentioned_agents != [] ->
        Enum.flat_map(mentioned_agents, fn participant ->
          case Map.get(roster_by_agent_id, participant.participant_id) do
            %SpaceAgent{role: "dismissed"} ->
              # Re-invite dismissed agent on @-mention
              Chat.reinvite_space_agent(space.id, participant.participant_id)
              [%{participant_id: participant.id, reason: :mention}]

            %SpaceAgent{role: role} when role in ["principal", "member"] ->
              [%{participant_id: participant.id, reason: :mention}]

            nil ->
              # Agent not in roster — no delivery
              []
          end
        end)

      # No @-mentions — route to principal agent (if one exists and has a participant)
      true ->
        principal = Enum.find(roster, &(&1.role == "principal"))

        if principal do
          # Find the participant record for the principal agent
          principal_participant =
            Enum.find(agent_recipients, &(&1.participant_id == principal.agent_id))

          if principal_participant do
            case decide_agent(space, principal_participant, message) do
              nil -> []
              reason -> [%{participant_id: principal_participant.id, reason: reason}]
            end
          else
            []
          end
        else
          # No principal — no default routing
          []
        end
    end
  end

  defp return_empty, do: []

  defp maybe_send_push(participant_id, sender_name, %Message{content: content}) do
    body = if is_binary(content), do: String.slice(content, 0, 200), else: ""

    Task.start(fn ->
      Platform.Push.send_notification(participant_id, %{
        title: "#{sender_name} in Suite",
        body: body,
        url: "/chat"
      })
    end)
  rescue
    _ -> :ok
  end

  # ── Human participant decision (unchanged from original) ───────────────────

  defp decide_human(%Participant{attention_mode: "all"}, _message), do: :all
  defp decide_human(%Participant{attention_mode: "active"}, _message), do: :active

  defp decide_human(%Participant{attention_mode: "mention"} = participant, message) do
    if mentioned?(participant, message), do: :mention, else: nil
  end

  defp decide_human(%Participant{attention_mode: "heartbeat"}, _message), do: :heartbeat
  defp decide_human(_participant, _message), do: nil

  # ── Agent participant decision (space-level policy + engagement) ────────────

  defp decide_agent(%Space{} = space, %Participant{} = participant, %Message{} = message) do
    mode = resolve_attention_mode(space, participant)
    attention_state = Chat.get_attention_state(space.id, participant.id)
    is_mentioned = mentioned?(participant, message)

    # Check if engaged and not expired
    engaged? = engaged_and_active?(attention_state)

    # Check if silenced
    silenced? = silenced?(attention_state)

    cond do
      # If silenced: only respond to direct @mention (which also unsilences)
      silenced? and is_mentioned ->
        Chat.unsilence_agent(space.id, participant.id)

        ChatPubSub.broadcast(
          space.id,
          {:agent_unsilenced,
           %{
             participant_id: participant.id,
             space_id: space.id
           }}
        )

        :mention

      silenced? ->
        nil

      # Directed mode: always route (no @mention needed)
      mode == "directed" ->
        :directed

      # Sticky engagement: treat as directed when engaged
      engaged? ->
        :sticky

      # Mention detected: route with :mention reason
      is_mentioned ->
        :mention

      # Default: no routing
      true ->
        nil
    end
  end

  defp engaged_and_active?(nil), do: false

  defp engaged_and_active?(%{state: "engaged", engaged_since: engaged_since})
       when not is_nil(engaged_since) do
    timeout = DateTime.add(engaged_since, @engagement_timeout_seconds, :second)
    DateTime.compare(DateTime.utc_now(), timeout) == :lt
  end

  defp engaged_and_active?(%{state: "engaged"}), do: true
  defp engaged_and_active?(_), do: false

  defp silenced?(nil), do: false

  defp silenced?(%{state: "silenced", silenced_until: nil}), do: true

  defp silenced?(%{state: "silenced", silenced_until: until}) when not is_nil(until) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  defp silenced?(_), do: false

  # ── Mention detection ────────────────────────────────────────────────────────

  defp mentioned?(%Participant{} = p, %Message{content: content}) when is_binary(content) do
    downcased = String.downcase(content)

    name_match =
      is_binary(p.display_name) and p.display_name != "" and
        String.contains?(downcased, "@#{String.downcase(p.display_name)}")

    id_match = String.contains?(downcased, "@#{String.downcase(p.id)}")

    # Support user-configured keywords in attention_config["keywords"]
    keywords = get_in(p.attention_config, ["keywords"]) || []

    keyword_match =
      Enum.any?(keywords, fn keyword ->
        is_binary(keyword) and keyword != "" and
          String.contains?(downcased, String.downcase(keyword))
      end)

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
