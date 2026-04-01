defmodule Platform.Chat.AttentionRouter do
  @moduledoc """
  Routes attention signals to chat participants based on the active-agent mutex
  (ADR 0027) and per-participant notification preferences.

  ## Routing logic (agents)

  1. **Execution spaces** — `log_only` messages are silently skipped.
  2. **DM spaces** — always route to the single agent participant (`:directed`).
  3. **Single @mention** — set mentioned agent as active (mutex) and route.
  4. **Multi @mention** — route to all mentioned agents, clear the mutex.
  5. **No mention + active agent** — route to the mutex holder, refresh timeout.
  6. **Execution spaces + no active** — route to the assigned task agent.
  7. **No mention + no active + watch ON + primary agent** — activate and route.
  8. **No mention + no active + watch OFF** — silence (empty list).

  ## Human participant routing

  Per-participant `attention_mode` is preserved:
    * `"active"` / `"all"` — always notified.
    * `"mention"` — notified only when @mentioned.
    * `"heartbeat"` — queued in ETS; drain with `flush/1`.

  ## PubSub

  Broadcasts `{:attention_needed, signal}` for every non-heartbeat decision.

  ## Heartbeat draining

      pending = Platform.Chat.AttentionRouter.pending(participant_id)
      {:ok, flushed} = Platform.Chat.AttentionRouter.flush(participant_id)
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AgentResponder, Message, Participant, Presence, Space}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tasks.Task, as: TaskRecord

  @handler_id "platform-chat-attention-router"
  @table :chat_attention_heartbeat

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously route attention for `message`.

  Returns the list of routing decisions (one map per notified participant).
  """
  @spec route(Message.t()) :: {:ok, [%{participant_id: binary(), reason: atom()}]}
  def route(%Message{} = message) do
    GenServer.call(__MODULE__, {:route, message})
  end

  @doc "Return pending heartbeat signals for `participant_id` without clearing them."
  @spec pending(binary()) :: [map()]
  def pending(participant_id) do
    GenServer.call(__MODULE__, {:pending, participant_id})
  end

  @doc "Flush and clear all pending heartbeat signals for `participant_id`."
  @spec flush(binary()) :: {:ok, [map()]}
  def flush(participant_id) do
    GenServer.call(__MODULE__, {:flush, participant_id})
  end

  @doc """
  Resolve the effective attention mode for an agent in a space.

  ADR 0027: always returns the kind-based default.
  """
  @spec resolve_attention_mode(Space.t(), Participant.t()) :: String.t()
  def resolve_attention_mode(%Space{} = space, _participant) do
    default_for_kind(space.kind)
  end

  defp default_for_kind("channel"), do: "on_mention"
  defp default_for_kind("dm"), do: "directed"
  defp default_for_kind("group"), do: "collaborative"
  defp default_for_kind("execution"), do: "directed"
  defp default_for_kind(_), do: "on_mention"

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

  # ── Core routing logic (ADR 0027 — mutex-based) ────────────────────────────

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

    # Exclude the message author
    recipients = Enum.reject(participants, &(&1.id == author_id))

    agent_recipients = Enum.filter(recipients, &(&1.participant_type == "agent"))
    human_recipients = Enum.reject(recipients, &(&1.participant_type == "agent"))

    # ── Agent routing (mutex-based) ──────────────────────────────────────────

    agent_decisions = route_agents(space, message, agent_recipients)

    # ── Human participant routing (unchanged) ────────────────────────────────

    human_decisions =
      Enum.flat_map(human_recipients, fn participant ->
        case decide_human(participant, message) do
          nil -> []
          reason -> [%{participant_id: participant.id, reason: reason}]
        end
      end)

    decisions = human_decisions ++ agent_decisions

    # Determine which participants are currently online via presence.
    online_user_ids = space_id |> Presence.list_space() |> Map.keys() |> MapSet.new()

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

  # ── Mutex-based agent routing (ADR 0027) ────────────────────────────────────

  defp route_agents(%Space{kind: "dm"}, _message, agent_recipients) do
    # DM spaces: always route to the agent participant directly
    Enum.map(agent_recipients, fn p ->
      %{participant_id: p.id, reason: :directed}
    end)
  end

  defp route_agents(%Space{} = space, %Message{} = message, agent_recipients) do
    # Build roster lookup for role validation
    roster = Chat.list_space_agents(space.id)
    roster_by_agent_id = Map.new(roster, fn sa -> {sa.agent_id, sa} end)

    # Find which agents are @-mentioned in this message
    mentioned_agents =
      Enum.filter(agent_recipients, fn participant ->
        mentioned?(participant, message) and
          case Map.get(roster_by_agent_id, participant.participant_id) do
            %{role: role} when role in ["principal", "member"] -> true
            # Agent is a participant but NOT in roster — block mention (ADR 0027)
            nil -> roster == []
            _ -> false
          end
      end)

    case length(mentioned_agents) do
      0 ->
        route_no_mention(space, message, agent_recipients)

      1 ->
        # Single @mention → set as active agent (mutex)
        [agent_p] = mentioned_agents
        ActiveAgentStore.set_active(space.id, agent_p.id)
        [%{participant_id: agent_p.id, reason: :mention}]

      _multi ->
        # Multi @mention → route to all, clear mutex
        ActiveAgentStore.clear_active(space.id)

        Enum.map(mentioned_agents, fn p ->
          %{participant_id: p.id, reason: :multi_mention}
        end)
    end
  end

  # No @mention — check mutex, then execution fallback/watch, then silence
  defp route_no_mention(
         %Space{kind: "execution"} = space,
         %Message{participant_id: author_id},
         agent_recipients
       ) do
    case execution_assignee_participant(space) do
      {:ok, %Participant{id: assignee_participant_id}}
      when assignee_participant_id == author_id ->
        ActiveAgentStore.set_active(space.id, assignee_participant_id)
        []

      {:ok, %Participant{id: assignee_participant_id}} ->
        reason =
          if ActiveAgentStore.get_active(space.id) == assignee_participant_id and
               Enum.any?(agent_recipients, &(&1.id == assignee_participant_id)) do
            :active_agent
          else
            :watch
          end

        ActiveAgentStore.set_active(space.id, assignee_participant_id)
        [%{participant_id: assignee_participant_id, reason: reason}]

      _ ->
        route_execution_active_or_watch(space, agent_recipients)
    end
  end

  defp route_no_mention(%Space{} = space, _message, agent_recipients) do
    case ActiveAgentStore.get_active(space.id) do
      nil ->
        # No active agent — check watch mode
        route_watch(space, agent_recipients)

      active_participant_id ->
        # Active agent exists — verify participant is still in the recipients
        # (they may be absent if they're the message author, which is fine —
        # don't clear the mutex in that case)
        if Enum.any?(agent_recipients, &(&1.id == active_participant_id)) do
          # Refresh the timeout
          ActiveAgentStore.set_active(space.id, active_participant_id)
          [%{participant_id: active_participant_id, reason: :active_agent}]
        else
          # Active agent not in recipients — check whether they're still an
          # active (non-left) participant in the space.  If they are, they are
          # simply the message author and we skip routing for this message.
          # If they're NOT an active participant any more (left_at is set or
          # record deleted), the mutex is stale — clear it and fall through to
          # watch-mode so the feedback still reaches an agent.
          still_active =
            Repo.exists?(
              from(p in Participant,
                where: p.id == ^active_participant_id and is_nil(p.left_at)
              )
            )

          if still_active do
            # Author is still present — skip routing for this message.
            []
          else
            # Stale mutex — clear and fall through to watch routing.
            ActiveAgentStore.clear_active(space.id)
            route_watch(space, agent_recipients)
          end
        end
    end
  end

  defp route_execution_active_or_watch(%Space{} = space, agent_recipients) do
    case ActiveAgentStore.get_active(space.id) do
      nil ->
        route_watch(space, agent_recipients)

      active_participant_id ->
        if Enum.any?(agent_recipients, &(&1.id == active_participant_id)) do
          ActiveAgentStore.set_active(space.id, active_participant_id)
          [%{participant_id: active_participant_id, reason: :active_agent}]
        else
          still_active =
            Repo.exists?(
              from(p in Participant,
                where: p.id == ^active_participant_id and is_nil(p.left_at)
              )
            )

          if still_active do
            []
          else
            ActiveAgentStore.clear_active(space.id)
            route_watch(space, agent_recipients)
          end
        end
    end
  end

  defp execution_assignee_participant(%Space{} = space) do
    with task_id when is_binary(task_id) <- execution_space_task_id(space),
         %TaskRecord{assignee_type: "agent", assignee_id: agent_id} when is_binary(agent_id) <-
           Repo.get(TaskRecord, task_id) do
      Chat.ensure_agent_participant(space.id, agent_id, attention_mode: "all")
    else
      _ -> {:error, :no_execution_assignee}
    end
  end

  defp execution_space_task_id(%Space{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "task_id") || Map.get(metadata, :task_id)
  end

  defp execution_space_task_id(_space), do: nil

  defp route_watch(
         %Space{watch_enabled: true, primary_agent_id: primary_agent_id} = space,
         agent_recipients
       )
       when is_binary(primary_agent_id) and primary_agent_id != "" do
    # Find the participant record for the primary agent
    primary_participant =
      Enum.find(agent_recipients, fn p -> p.participant_id == primary_agent_id end)

    if primary_participant do
      ActiveAgentStore.set_active(space.id, primary_participant.id)
      [%{participant_id: primary_participant.id, reason: :watch}]
    else
      # Primary agent not in space as participant — silence
      []
    end
  end

  defp route_watch(_space, _agent_recipients), do: []

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

  # ── Human participant decision (unchanged) ─────────────────────────────────

  defp decide_human(%Participant{attention_mode: "all"}, _message), do: :all
  defp decide_human(%Participant{attention_mode: "active"}, _message), do: :active

  defp decide_human(%Participant{attention_mode: "mention"} = participant, message) do
    if mentioned?(participant, message), do: :mention, else: nil
  end

  defp decide_human(%Participant{attention_mode: "heartbeat"}, _message), do: :heartbeat
  defp decide_human(_participant, _message), do: nil

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
