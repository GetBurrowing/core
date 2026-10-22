defmodule Platform.Chat.AttentionRouter do
  @moduledoc """
  Routes attention signals to chat participants based on the active-agent mutex
  (ADR 0027) and per-participant notification preferences.

  ## Routing logic (agents)

  0. **Untrusted inbound** (`metadata["source"]` is `"email_inbound"` or
     `"federation_inbound"`) — no agent decision in any space kind, ahead of
     every rule below. See `untrusted_inbound?/1`.
  1. **Execution spaces** — `log_only` messages are silently skipped.
  2. **DM spaces** — always route to the single agent participant (`:directed`).
  3. **Single @mention** — set mentioned agent as active (mutex) and route.
  4. **Multi @mention** — route to all mentioned agents, clear the mutex.
  5. **No mention + active agent** — route to the mutex holder, refresh timeout.
  6. **Execution spaces + no active** — route to the assigned task agent.
  7. **No mention + no active** — silence (empty list). The mutex is the only
     thing that can arm an agent for un-addressed messages; there is no
     `watch_enabled`/`primary_agent_id` fallback (removed — it silently
     reopened the eye the user had just closed).

  ## Human participant routing

  Per-participant `attention_mode` is preserved:
    * `"active"` / `"all"` — always notified.
    * `"mention"` — notified only when @mentioned.
    * `"heartbeat"` — queued in ETS; drain with `flush/1`.

  ## Notification level (task 01a1557a-e538 stage 1)

  Each person also holds ONE notification level
  (`Platform.Accounts.notification_level/1`, stored in `users.preferences`):

  | level | label | effect |
  |---|---|---|
  | `"all"` | All messages | every channel message also yields `:all` for you, which pushes while you are not present in that space |
  | `"mentions"` (default) | Mentions and direct messages | today's routing, unchanged |
  | `"direct"` | Only direct mentions | only `chat_mention` pushes. DMs, at-here, task, review, meeting and admission alerts are suppressed. VoIP calls still ring. Inbox rows are unaffected |

  ### Gate order for a human recipient

  Every gate that decides whether a person is interrupted runs in this order.
  A new gate EXTENDS this list at its slot; it is never added beside it.

  1. **The per-space `attention_mode`**, applied by `decide_human_in_space/3`
     (`"all"`, `"active"`, `"mention"`, `"heartbeat"`, plus the DM rule).
  2. **The user notification level.** Its "all" floor runs here, right after
     step 1: a recipient step 1 left undecided whose level is `"all"` gets
     `:all` (levels are read once per message, `Accounts.notification_levels/1`).
     Its "direct" gate runs at delivery, in `Platform.Push.permitted?/2`,
     because it must also cover the alerts that never pass through this
     router (task, review, meeting and admission pushes).
  3. **Mute**: the reserved slot for per-channel Off/mute (task 01a14a91).
     No mute state exists yet. When it lands it goes HERE, after the level,
     so a muted space silences even an `"all"`-level person, and it extends
     this order rather than adding a separate gate.

  The `@[here]` branch below bypasses step 1 and the "all" floor (it already
  notifies everyone); the "direct" gate in `Platform.Push` still applies to
  its `chat_message` pushes. Presence (`send_push?/2`) is applied after all
  three, per decision.

  ## @[here] broadcast (ADR 0037 + Stage 2 of @here notifications)

  When the message content contains the literal `@[here]` sentinel, the
  router bypasses `decide_human/2` entirely and emits one decision per
  human recipient (sender excluded) with reason `:here`. This overrides
  per-participant `attention_mode`, so `"mention"` and `"heartbeat"`
  recipients alike receive a live notification. Agent routing is
  unchanged — `@[here]` does not wake the active-agent mutex.

  ## PubSub

  Broadcasts `{:attention_needed, signal}` for every non-heartbeat decision.

  ## Decision reasons (free atoms — extend as new flows land)

    * `:directed`, `:mention`, `:multi_mention`, `:active_agent`, `:watch`
      — agent routing outcomes.
    * `:all`, `:active`, `:mention`, `:heartbeat` — per-participant human
      routing outcomes from `decide_human/2`.
    * `:here` — channel-wide broadcast from `@[here]` fan-out.

  ## Heartbeat draining

      pending = Platform.Chat.AttentionRouter.pending(participant_id)
      {:ok, flushed} = Platform.Chat.AttentionRouter.flush(participant_id)
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Platform.Access.AgentWake
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AgentResponder, Message, Participant, Presence, Space}
  alias Platform.Chat.MentionIdentity
  alias Platform.Chat.ReplyFailure
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Task, as: TaskRecord

  @handler_id "platform-chat-attention-router"
  @relayed_events [[:platform, :chat, :message_posted]]
  @table :chat_attention_heartbeat

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The telemetry events this router consumes. It attaches to each and to its
  `Platform.Role.Relay` twin, so a message posted on a clustered web node is
  routed here, once (task 01a155a6 stage 3).
  """
  @spec relayed_events() :: [:telemetry.event_name()]
  def relayed_events, do: @relayed_events

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
    Platform.Role.Relay.attach_many(
      @handler_id,
      @relayed_events,
      &__MODULE__.handle_telemetry_event/4,
      %{}
    )
  end

  defp detach_telemetry do
    Platform.Role.Relay.detach_many(@handler_id)
  rescue
    _ -> :ok
  end

  @doc false
  def handle_telemetry_event([:platform, :role_relay | event], measurements, metadata, cfg),
    do: handle_telemetry_event(event, measurements, metadata, cfg)

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

  # The two early exits are a `cond`, not bare `unless`/`if` statements.
  #
  # From #84 (906c8bd0, 2026-03-23) until task 01a0e266 they were written as
  # `unless space do ... return_empty() end` and
  # `if space && space.kind == "execution" && message.log_only do ... end`.
  # Elixir has no early return: each block's value was discarded and routing
  # carried on. Consequences, both measured by the task 01a0e266 review:
  #
  #   * every `ExecutionSpace.post_log/3` (router status lines, "Dispatch
  #     withheld", "Heartbeat suppressed", the architecture-escalation digest,
  #     the payload-amendment notice, ...) reached `route_no_mention/3`, which
  #     added the task's assignee as an `attention_mode: "all"` participant
  #     and woke it through `AgentResponder` — the opposite of rule 1 above
  #     and of every caller that chose `post_log` precisely so as NOT to wake
  #     the assignee (see `Platform.Tasks.ArchitectureRejection`'s digest);
  #   * a message whose space row is gone fell through to `route_agents/3`,
  #     whose `%Space{}` head raised `FunctionClauseError`.
  #
  # Both are pinned in `attention_router_test.exs` ("execution spaces").
  defp do_route(%Message{space_id: space_id} = message) do
    space = Repo.get(Space, space_id)

    cond do
      is_nil(space) ->
        Logger.warning("[AttentionRouter] space not found: #{space_id}")
        return_empty()

      # Execution spaces: log_only messages skip attention routing entirely
      space.kind == "execution" and message.log_only == true ->
        return_empty()

      # A reply-failure notice (task 01a10322 stage 1) is a system row about
      # an agent that could not answer. It is never a turn: routing it would
      # hand it to the active-agent mutex holder, which is usually the agent
      # that just failed. See `Platform.Chat.ReplyFailure.notice?/1`.
      ReplyFailure.notice?(message) ->
        return_empty()

      true ->
        route_in_space(space, message)
    end
  end

  defp route_in_space(
         %Space{} = space,
         %Message{space_id: space_id, id: message_id, participant_id: author_id} = message
       ) do
    participants = active_participants(space_id)

    # Exclude the message author
    recipients = Enum.reject(participants, &(&1.id == author_id))

    # Task 01a1386e-45a5 stage 2 (RBAC stack member 7): an agent ALREADY a
    # participant of a space its owner, or its own grants, may not read is
    # never woken here, by a mention, the mutex or the execution-assignee
    # fallback. Decided once per routed message (`wake_gate/2`).
    wake = wake_gate(space, participants)

    agent_recipients =
      recipients
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> Enum.filter(&wake.may_wake?.(&1.participant_id))

    # Task 019f671f Stage 3: filter archived-user participants out of the
    # human recipient list so attention routing (mentions, @[here] fan-out,
    # `decide_human/2`, PubSub broadcast, push) is transparently silenced
    # for them. The `chat_participants` row survives — that's intentional
    # so past-message author snapshots still resolve in the transcript via
    # `presence_hooks`' `include_archived: true` participant-map build.
    # Agent recipients are UNaffected: archival is a user-only lifecycle.
    # `mentioned?/2` is deliberately NOT touched; mention detection stays
    # symmetric so parsing invariants remain stable — the archived user is
    # dropped here, one level up.
    active_user_participant_ids =
      space_id
      |> Chat.list_active_user_participant_ids()
      |> MapSet.new()

    human_recipients =
      recipients
      |> Enum.reject(&(&1.participant_type == "agent"))
      |> Enum.filter(&MapSet.member?(active_user_participant_ids, &1.id))

    # ── Agent routing (mutex-based) ──────────────────────────────────────────

    agent_decisions = route_agents(space, message, agent_recipients, wake)

    # ── Human participant routing ────────────────────────────────────────────
    #
    # `@[here]` overrides per-participant `attention_mode` so every human
    # recipient (sender already excluded above) gets a `:here` decision,
    # including heartbeat-mode recipients who normally never receive a live
    # ping. The per-recipient `:here` list is naturally de-duplicated even
    # if the message contains multiple `@[here]` tokens, because we iterate
    # human_recipients exactly once.
    #
    # Named mentions in the SAME message must still produce their own
    # `:mention` decisions — `@[here] @[Alex]` is one broadcast PLUS one
    # named ping. We layer the `:mention` decisions on top of the `:here`
    # broadcast (Alex intentionally appears twice — once `:here`, once
    # `:mention`). We only layer the `:mention` reason — non-mention
    # reasons (`:all`, `:active`, `:heartbeat`) stay suppressed under
    # `@[here]` so the broadcast remains the single override behaviour
    # for those modes (no double-ping, no ETS heartbeat queue entry).

    human_decisions =
      if mention_scan_enabled?(message) and here_mention?(message.content) do
        here_decisions =
          Enum.map(human_recipients, fn p ->
            %{participant_id: p.id, reason: :here}
          end)

        named_mention_decisions =
          Enum.flat_map(human_recipients, fn participant ->
            if mentioned?(participant, message) do
              [%{participant_id: participant.id, reason: :mention}]
            else
              []
            end
          end)

        here_decisions ++ named_mention_decisions
      else
        # Gate 2 of the order in the moduledoc: the per-user notification
        # level, read ONCE per message for every human recipient.
        levels = human_notification_levels(human_recipients)

        Enum.flat_map(human_recipients, fn participant ->
          space
          |> decide_human_in_space(participant, message)
          |> apply_level_floor(participant, levels)
          |> case do
            nil -> []
            reason -> [%{participant_id: participant.id, reason: reason}]
          end
        end)
      end

    decisions = human_decisions ++ agent_decisions

    # Determine which participants are currently online via presence.
    online_user_ids = space_id |> Presence.list_space() |> Map.keys() |> MapSet.new()

    # Preload message author display name for notification body.
    # The author participant itself (task 01a111bb): the push carries its
    # display name AND its participant type/id, so the iOS Notification
    # Service Extension can name the sender. "Someone" when unresolved.
    author = Enum.find(participants, &(&1.id == author_id))
    sender = author || "Someone"

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

          if send_push?(reason, MapSet.member?(online_user_ids, user_id)) do
            maybe_send_push(participant || pid, sender, message, reason, space)
          end
      end

      emit_attention_telemetry(signal)
    end)

    decisions
  end

  # ── Mutex-based agent routing (ADR 0027) ────────────────────────────────────

  # Role-scoped system dispatches bind to the ROLE HOLDER, never to whoever
  # happens to be armed in the space. This clause must stay ahead of every
  # activity-based branch below (DM, mention, mutex) — those all route by who
  # spoke last, which is the wrong question for a dispatch whose whole
  # identity is "the agent currently holding role X".
  #
  # The sibling MENTION leg of this same leak was closed by `skip_mention_scan`
  # (see `mention_scan_enabled?/1`); this is the MUTEX leg. A misroute here is
  # silent — page writes are role-gated at the tool boundary, so a wrong
  # recipient produces no error, just a dispatch the intended holder never saw.
  #
  # Deliberately role-KEY driven, never a per-role branch: the guard has to
  # hold for every key in `Platform.Roles.Role` (ADR 0043's security guard and
  # ADR 0044's architect included) the moment they stamp the metadata.
  #
  # Untrusted inbound (email, task 01a0cf21 stage 3; peer federation, task
  # 01a0d90f stage 5) is checked FIRST, ahead of the role-scoped branch and
  # of every activity branch: an `email_inbound` or `federation_inbound`
  # message is untrusted outside text and yields NO agent decision — no
  # :directed (DM), no :mention / :multi_mention, no :active_agent to the
  # mutex holder (ADR 0027 rule 5), no execution-assignee fallback, and it
  # never touches `ActiveAgentStore`. Its metadata also carries
  # `skip_mention_scan`, and `Platform.Mail.Inbound` escapes every `@[` in
  # the content; this clause is what holds when an agent is already armed.
  # A later step may emit its own reason for addressed mail (e.g.
  # `:email_addressed`); it must be a deliberate new branch here, not a
  # fall-through into activity routing. Human routing is unchanged.
  defp route_agents(%Space{} = space, %Message{} = message, agent_recipients, wake) do
    cond do
      untrusted_inbound?(message) ->
        []

      role_key = role_scoped_dispatch_role(message) ->
        route_role_scoped(space, message, agent_recipients, role_key)

      true ->
        route_agents_by_activity(space, message, agent_recipients, wake)
    end
  end

  # The registry's read permission for a chat space (`Platform.Access.Registry`).
  @chat_read "chat.read"

  # Task 01a1386e-45a5 stage 2. The wake decision for this ONE routed
  # message, memoized: `Platform.Access.AgentWake.denied/3` is asked once
  # for every agent participant and the execution task's assignee, including
  # an assignee not yet in the space. This is one `EXISTS` query with no
  # grants, or none when there are no candidate agents.
  defp wake_gate(%Space{id: space_id} = space, participants) do
    assignee_id = execution_assignee_agent_id(space)

    known =
      participants
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> MapSet.new(& &1.participant_id)

    known = if assignee_id, do: MapSet.put(known, assignee_id), else: known

    refused = AgentWake.denied(MapSet.to_list(known), @chat_read, {:space, space_id})

    may_wake? = fn agent_id ->
      if MapSet.member?(known, agent_id) do
        not MapSet.member?(refused, agent_id)
      else
        not MapSet.member?(AgentWake.denied([agent_id], @chat_read, {:space, space_id}), agent_id)
      end
    end

    %{may_wake?: may_wake?, execution_assignee_id: assignee_id}
  end

  defp execution_assignee_agent_id(%Space{kind: "execution"} = space) do
    with task_id when is_binary(task_id) <- execution_space_task_id(space),
         true <- Platform.UUID.valid?(task_id),
         %TaskRecord{assignee_type: "agent", assignee_id: agent_id}
         when is_binary(agent_id) <- Repo.get(TaskRecord, task_id) do
      agent_id
    else
      _ -> nil
    end
  end

  defp execution_assignee_agent_id(_space), do: nil

  @untrusted_inbound_sources ~w(email_inbound federation_inbound)

  @doc """
  True for a message whose text came from OUTSIDE this install and was posted
  by a system participant on its behalf: `metadata["source"]` is
  `"email_inbound"` (the Email module's inbound poller, task 01a0cf21
  stage 3) or `"federation_inbound"` (a peer install's shared-space message,
  `Platform.Federation.Peers.Ingest`, task 01a0d90f stage 5). Such a message
  never produces an agent routing decision, and never fires a chat-pattern
  responsibility (`Platform.Responsibilities.Router`).
  """
  @spec untrusted_inbound?(Message.t()) :: boolean()
  def untrusted_inbound?(%Message{metadata: %{"source" => source}})
      when source in @untrusted_inbound_sources,
      do: true

  def untrusted_inbound?(_), do: false

  @doc "The `metadata[\"source\"]` values `untrusted_inbound?/1` recognises."
  @spec untrusted_inbound_sources() :: [String.t()]
  def untrusted_inbound_sources, do: @untrusted_inbound_sources

  defp route_role_scoped(%Space{} = space, %Message{} = message, agent_recipients, role_key) do
    case Roles.agent_id_for_role(role_key) do
      nil ->
        refuse_role_scoped(space, message, role_key, :role_unfilled)

      agent_id ->
        participant = Chat.get_agent_participant(space.id, agent_id)

        # Deliberately NOT touching `ActiveAgentStore` on any branch here: a
        # role-scoped system dispatch is not a conversational turn and must
        # neither arm the role holder nor disarm whoever is already armed.
        if participant && Enum.any?(agent_recipients, &(&1.id == participant.id)) do
          [%{participant_id: participant.id, reason: :role_scoped}]
        else
          refuse_role_scoped(space, message, role_key, :role_holder_not_in_space)
        end
    end
  end

  # An unfilled (or absent) role holder must refuse by NAME rather than degrade
  # into an arbitrary recipient. Silence and "delivered to the wrong agent" are
  # indistinguishable downstream otherwise.
  defp refuse_role_scoped(%Space{} = space, %Message{} = message, role_key, reason) do
    Logger.warning(
      "[AttentionRouter] refusing role-scoped dispatch for role #{inspect(role_key)} " <>
        "(#{reason}) on message #{message.id}"
    )

    :telemetry.execute(
      [:platform, :chat, :role_scoped_dispatch, :refused],
      %{system_time: System.system_time()},
      %{
        role_key: role_key,
        reason: reason,
        space_id: space.id,
        message_id: message.id
      }
    )

    []
  end

  defp route_agents_by_activity(%Space{kind: "dm"}, _message, agent_recipients, _wake) do
    # DM spaces: always route to the agent participant directly
    Enum.map(agent_recipients, fn p ->
      %{participant_id: p.id, reason: :directed}
    end)
  end

  defp route_agents_by_activity(%Space{} = space, %Message{} = message, agent_recipients, wake) do
    # Build roster lookup for role validation
    roster = Chat.list_space_agents(space.id)
    roster_by_agent_id = Map.new(roster, fn sa -> {sa.agent_id, sa} end)

    # Find which agents are @-mentioned in this message
    mentioned_agents =
      Enum.filter(agent_recipients, fn participant ->
        # The roster entry already carries the preloaded agent
        # (`Chat.list_space_agents/1`), so slug matching adds no query here.
        roster_entry = Map.get(roster_by_agent_id, participant.participant_id)

        mentioned?(participant, message, agent: roster_entry && roster_entry.agent) and
          case roster_entry do
            %{role: role} when role in ["principal", "member"] -> true
            # Agent is a participant but NOT on the space roster — never
            # mention-route it (ADR 0027). This clause previously read
            # `nil -> roster == []`, which routed a mention to an off-roster
            # agent whenever the roster happened to be empty: an
            # "everyone is allowed because nobody is listed" fallback, which is
            # the opposite of what an allow-list means. Task 01a0ac64 stage 3.
            nil -> false
            _ -> false
          end
      end)

    case length(mentioned_agents) do
      0 ->
        route_no_mention(space, message, agent_recipients, wake)

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

  # No @mention — check mutex, then the execution task-assignee fallback,
  # then silence
  defp route_no_mention(
         %Space{kind: "execution"} = space,
         %Message{participant_id: author_id},
         agent_recipients,
         wake
       ) do
    case execution_assignee_participant(space, wake) do
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
        route_execution_active_agent(space, agent_recipients)
    end
  end

  defp route_no_mention(%Space{} = space, _message, agent_recipients, _wake) do
    case ActiveAgentStore.get_active(space.id) do
      nil ->
        # No active agent — the eye is closed, so nobody hears this (ADR 0027).
        # There is deliberately no fallback: arming an agent here would reopen
        # the eye the user just closed.
        []

      active_participant_id ->
        # Active agent exists — verify participant is still in the recipients
        # (they may be absent if they're the message author, which is fine —
        # don't clear the mutex in that case)
        if Enum.any?(agent_recipients, &(&1.id == active_participant_id)) do
          # Refresh the timeout
          ActiveAgentStore.set_active(space.id, active_participant_id)
          [%{participant_id: active_participant_id, reason: :active_agent}]
        else
          # Active agent not in recipients — check whether they're still a
          # participant in the space (post-ADR-0038 the row either exists or
          # has been hard-deleted). If they are, they're the message author
          # and we skip routing. If the row is gone, the mutex is stale —
          # clear it and fall silent.
          still_active =
            Repo.exists?(from(p in Participant, where: p.id == ^active_participant_id))

          if still_active do
            # Author is still present — skip routing for this message.
            []
          else
            # Stale mutex — clear it. Nobody is armed now, so nobody hears
            # this message.
            ActiveAgentStore.clear_active(space.id)
            []
          end
        end
    end
  end

  defp route_execution_active_agent(%Space{} = space, agent_recipients) do
    case ActiveAgentStore.get_active(space.id) do
      nil ->
        []

      active_participant_id ->
        if Enum.any?(agent_recipients, &(&1.id == active_participant_id)) do
          ActiveAgentStore.set_active(space.id, active_participant_id)
          [%{participant_id: active_participant_id, reason: :active_agent}]
        else
          still_active =
            Repo.exists?(from(p in Participant, where: p.id == ^active_participant_id))

          if still_active do
            []
          else
            ActiveAgentStore.clear_active(space.id)
            []
          end
        end
    end
  end

  # Task 01a1386e-45a5 stage 2: an assignee the wake gate refuses is neither
  # added to the space nor woken; the fallback falls through to the mutex
  # branch exactly as for a task with no agent assignee.
  defp execution_assignee_participant(%Space{} = space, wake) do
    with agent_id when is_binary(agent_id) <- wake.execution_assignee_id,
         true <- wake.may_wake?.(agent_id) do
      Chat.add_agent_participant(space.id, agent_id, attention_mode: "all")
    else
      _ -> {:error, :no_execution_assignee}
    end
  end

  defp execution_space_task_id(%Space{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "task_id") || Map.get(metadata, :task_id)
  end

  defp execution_space_task_id(_space), do: nil

  defp return_empty, do: []

  # `recipient` is the `%Participant{}` row when the caller resolved one (it
  # already holds `participant_by_id`, so this costs no query), otherwise the
  # bare `chat_participants.id`.
  defp maybe_send_push(recipient, sender, %Message{} = message, reason, %Space{} = space) do
    # Skip in test env. The spawned Task races with Ecto sandbox teardown:
    # when a test finishes, its Repo connection owner exits, and an
    # in-flight `Repo.all(Subscription)` inside this Task raises a
    # `DBConnection.ConnectionError` — loud, and sometimes cascades into
    # failures on other tests sharing the pool. Tests don't exercise push
    # (no subscriptions, no VAPID keys), so short-circuiting here costs
    # nothing and eliminates the flake. The notification itself is built by
    # `push_notification/5` (pure apart from one branding-row read for the
    # app name), which tests call directly.
    if not (Application.get_env(:platform, :env) == :test and
              notifications_module() == Platform.Notifications) and
         push_recipient_may_read?(recipient, space.id) do
      send = fn ->
        attachments = if blank?(message.content), do: message_attachments(message.id), else: []

        notification =
          push_notification(
            sender,
            message,
            reason,
            space,
            attachments,
            push_conversation_name(space, recipient)
          )

        deliver_push(recipient, notification)
      end

      if Application.get_env(:platform, :env) == :test do
        if notifications_module() != Platform.Notifications, do: send.()
      else
        Task.start(send)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp push_recipient_may_read?(
         %Participant{participant_type: "user", participant_id: user_id},
         space_id
       ) do
    user = Platform.Repo.get(Platform.Accounts.User, user_id)

    is_nil(user) or
      Platform.Access.check(Platform.Access.Scope.for_user(user), "chat.read", {:space, space_id}) ==
        :ok
  end

  defp push_recipient_may_read?(participant_id, space_id) when is_binary(participant_id) do
    if Platform.UUID.valid?(participant_id) do
      Participant
      |> Platform.Repo.get(participant_id)
      |> push_recipient_may_read?(space_id)
    else
      true
    end
  end

  defp push_recipient_may_read?(_, _), do: true

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  @doc """
  Build the push notification for one routing decision (task 01a10882): kind
  `chat_mention` for `:mention`, `chat_message` otherwise, titled
  `{Author} in {Space}`, deep-linked to
  `/chat/<Chat.space_path_segment/1>?message=<id>` (a DM has no slug, so a
  raw `space.slug` linked to `/chat`, the first channel), carrying the
  space and message ids both transports route on. `attachments` are
  `%{content_type, filename}` maps, read only when the message has no text.

  `sender` is the author's `%Participant{}` (task 01a111bb), whose
  `participant_type` / `participant_id` become the notification's
  `author_type` / `author_id`, or a bare display name, which carries no
  author identity.

  It makes two reads: the branding row for the install's app name (the
  title of a space with no name; task 01a120c5 stage 3), and the author's
  own row for the sender avatar (task 01a12773 stage 2; the `agents` row for
  an agent author, the `users` row for a user, none for a bare name). Both
  are plain reads, so tests can assert the exact notification without the
  push `Task`, which short-circuits under `:test`.

  The avatar (`sender_avatar/1`) is `author_avatar_url` plus
  `author_avatar_tone`:

    * agent: the bearer-gated app route on THIS install,
      `https://<install_host>/api/app/agents/<agent_id>/avatar`, with the
      stored `?v=` cache token copied verbatim, or nil when the agent has no
      avatar. Tone `"agent"`.
    * user: when the picture the chat renders is the user's own absolute
      https `users.avatar_url`, the bearer-gated app route on THIS install,
      `https://<install_host>/api/app/users/<user_id>/avatar?v=<hash>`
      (`Platform.Accounts.UserAvatarCache.push_url/1`), which serves that
      picture at a size both apps accept (they drop a body over 256 KB); nil
      while a fetch of it is remembered as failed. A participant's own
      absolute https `avatar_url` that differs from the user's is still
      carried verbatim (the route only ever fetches `users.avatar_url`).
      Anything else is nil. Tone is the chat's palette index for the same
      seed (`Platform.Avatars`), `"0".."7"`.

  A failure resolving the avatar never costs the push: it yields a nil url.
  """
  @spec push_notification(
          Participant.t() | String.t(),
          Message.t(),
          atom(),
          Space.t(),
          [map()],
          String.t() | nil
        ) ::
          Platform.Push.Notification.t()
  def push_notification(
        sender,
        %Message{} = message,
        reason,
        %Space{} = space,
        attachments,
        conversation_name \\ nil
      ) do
    {sender_name, author_type, author_id} = sender_identity(sender)
    {avatar_url, avatar_tone} = sender_avatar(sender)

    Platform.Push.Notification.chat(%{
      reason: reason,
      author: sender_name,
      author_type: author_type,
      author_id: author_id,
      author_avatar_url: avatar_url,
      author_avatar_tone: avatar_tone,
      space_name: space.name,
      space_kind: space.kind,
      conversation_name: conversation_name,
      space_path: Platform.Chat.space_path_segment(space),
      space_id: space.id,
      message_id: message.id,
      content: message.content,
      attachments: attachments,
      # The install's product name for the title of a space with no name (a
      # DM or unnamed group): read once here, at the router boundary, so
      # `Notification.chat_title/4` stays pure (task 01a120c5 stage 3).
      app_name: Platform.Branding.app_name()
    })
  end

  defp sender_identity(%Participant{} = p),
    do: {p.display_name || "Someone", p.participant_type, p.participant_id}

  defp sender_identity(name) when is_binary(name), do: {name, nil, nil}
  defp sender_identity(_), do: {"Someone", nil, nil}

  # `{author_avatar_url, author_avatar_tone}`; see push_notification/6.
  defp sender_avatar(%Participant{participant_type: "agent"} = p) do
    stored =
      [p]
      |> Chat.agent_avatar_map_for_participants()
      |> Map.values()
      |> List.first()

    {agent_push_avatar_url(p.participant_id, stored), "agent"}
  rescue
    _ -> {nil, "agent"}
  end

  defp sender_avatar(%Participant{participant_type: "user"} = p) do
    user = sender_user(p.participant_id)
    tone = p |> Platform.Avatars.user_seed(user) |> Platform.Avatars.fallback_tone()
    {user_push_avatar_url(p, user), Integer.to_string(tone)}
  rescue
    _ -> {nil, nil}
  end

  defp sender_avatar(_sender), do: {nil, nil}

  # The participant's own picture wins, as in the chat. When that is (or
  # falls back to) the user's own `avatar_url`, the push names the app route
  # that serves it sized for the apps; with no install host the url goes
  # verbatim, as before the route existed.
  defp user_push_avatar_url(%Participant{} = p, user) do
    own = absolute_https_url(user && user.avatar_url)

    case absolute_https_url(p.avatar_url) do
      override when is_binary(override) and override != own ->
        override

      _ when is_binary(own) ->
        if Platform.Push.Notification.install_host() in [nil, ""],
          do: own,
          else: Platform.Accounts.UserAvatarCache.push_url(user)

      _ ->
        nil
    end
  end

  defp sender_user(user_id) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id), do: Repo.get(Platform.Accounts.User, user_id)
  end

  defp sender_user(_), do: nil

  # The stored agent url is `/agents/<id>/avatar?v=<token>` (session-gated);
  # the app can only present its bearer, so the push names the bearer route
  # on this install's own host. The `?v=` query is copied verbatim so the
  # client's cache key changes when the bytes do.
  defp agent_push_avatar_url(agent_id, stored)
       when is_binary(agent_id) and is_binary(stored) do
    case Platform.Push.Notification.install_host() do
      host when is_binary(host) and host != "" ->
        base = "https://#{host}/api/app/agents/#{agent_id}/avatar"

        case URI.parse(stored).query do
          query when is_binary(query) and query != "" -> base <> "?" <> query
          _ -> base
        end

      _ ->
        nil
    end
  end

  defp agent_push_avatar_url(_agent_id, _stored), do: nil

  # Passed through verbatim (trimmed), never re-serialised.
  defp absolute_https_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp absolute_https_url(_), do: nil

  @doc """
  The recipient's label for `space`, carried as the notification's
  `space_name` (Android's MessagingStyle conversation title, task 01a10d8e).

  A DM or an unnamed group has a NULL `chat_spaces.name`, so `space.name`
  alone left the conversation untitled. Those take the label the web chat
  sidebar shows the recipient (`Chat.display_name_for_space/3`, the same
  helper `GET /api/app/spaces` uses). A named space, or a recipient that is
  not a resolved user participant, keeps `space.name`. Queries participants
  only for DMs and groups.
  """
  @spec push_conversation_name(Space.t(), Participant.t() | String.t() | nil) :: String.t() | nil
  def push_conversation_name(
        %Space{kind: kind} = space,
        %Participant{participant_type: "user", participant_id: user_id}
      )
      when kind in ["dm", "group"] and is_binary(user_id) do
    if kind == "group" and is_binary(space.name) and space.name != "" do
      space.name
    else
      Chat.display_name_for_space(space, Chat.list_participants(space.id), user_id)
    end
  rescue
    # A naming failure must never cost the push itself.
    _ -> space.name
  end

  def push_conversation_name(%Space{name: name}, _recipient), do: name

  defp blank?(content) when is_binary(content), do: String.trim(content) == ""
  defp blank?(_), do: true

  defp message_attachments(message_id) when is_binary(message_id) do
    from(a in Platform.Chat.Attachment,
      where: a.message_id == ^message_id,
      order_by: [asc: a.inserted_at],
      select: %{content_type: a.content_type, filename: a.filename}
    )
    |> Repo.all()
  end

  defp message_attachments(_), do: []

  # A user-typed recipient is addressed as a USER: `Push.send_to_user/2`
  # resolves their devices across every conversation they're in and delivers
  # once per distinct endpoint. Enabling notifications is a per-DEVICE act that
  # happens in whichever conversation is open, so the per-membership path
  # reached that device only for messages in that one conversation and sent
  # nothing anywhere else (task 019ffd19). Applied to every routing reason, not
  # only `:mention` — `:all`, `:here`, `:watch`, `:directed` and `:active` all
  # lost the same devices, and the endpoint dedup makes the wider resolution
  # quieter than the old one, never noisier.
  #
  # Agent-typed and unresolved recipients keep `send_notification/2`:
  # `participant.participant_id` holds an AGENT id on an agent row, and the
  # user-scoped resolution filters `participant_type == "user"`.
  defp deliver_push(%Participant{participant_type: "user", participant_id: user_id}, payload)
       when is_binary(user_id) do
    if notifications_module() == Platform.Notifications do
      Platform.Push.send_to_user(user_id, payload)
    else
      notifications_module().fan_out_to_user(user_id, payload)
    end
  end

  defp deliver_push(%Participant{id: participant_id}, payload) do
    Platform.Push.send_notification(participant_id, payload)
  end

  defp deliver_push(participant_id, payload) when is_binary(participant_id) do
    Platform.Push.send_notification(participant_id, payload)
  end

  @doc """
  Decide whether a routing decision earns a web push, given the recipient's
  presence in the space.

  Presence means a connected LiveView socket, which a minimised window and a
  background tab both satisfy. Suppressing on presence alone therefore drops
  the notification for someone who is not looking at the screen. A direct
  `:mention` is addressed at one person and pushes regardless of presence.

  Every other reason keeps the presence gate. `:active`, `:all`, `:watch`,
  `:directed`, `:here` and `:heartbeat` fire on ambient room activity, so
  pushing them to a connected socket would notify on each message.

  `online?` comes from `Presence.list_space/1` at the call site; the function
  itself is pure so tests can exercise every reason without a presence
  process or a push subscription.
  """
  @spec send_push?(atom(), boolean()) :: boolean()
  def send_push?(:mention, _online?), do: true
  def send_push?(_reason, online?), do: not online?

  @doc """
  Build the push-notification title for a given sender + routing reason.

  The push itself now names the space (`push_notification/5`, task 01a10882);
  this is that title with no space, which reads `in {app name}`: the
  install's `Platform.Branding.app_name/0` (task 01a120c5 stage 3), unless
  the caller passes `app_name` explicitly.

  For `:here` broadcasts, surface the `@here` context so the recipient knows
  they were pinged as part of a channel-wide blast (not a direct mention or
  ambient activity). All other reasons reuse the default
  `"<sender> in <app name>"` form — keeping push behaviour stable for the
  existing `:mention`, `:all`, `:active`, `:directed`, `:watch`, etc. paths.

  With `app_name` given it is a pure helper; the two-argument form reads the
  branding row once. Exposed so tests can exercise the title shape without
  spawning the push `Task` (which short-circuits under `:test` env anyway).
  """
  @spec notification_title(String.t(), atom(), String.t() | nil) :: String.t()
  def notification_title(sender_name, reason, app_name \\ Platform.Branding.app_name()),
    do: Platform.Push.Notification.chat_title(sender_name, nil, reason, app_name)

  # ── Notification level floor (task 01a1557a-e538 stage 1) ─────────────────

  # `%{user_id => level}` for the human recipients that stored one, in ONE
  # query (`Accounts.notification_levels/1`). Everyone absent is at the
  # default, "mentions", which changes nothing here.
  defp human_notification_levels(human_recipients) do
    human_recipients
    |> Enum.map(& &1.participant_id)
    |> Platform.Accounts.notification_levels()
  end

  # A human the per-space mode left undecided gets `:all` when their level is
  # "all": the reason `attention_mode "all"` already produces, so every
  # downstream branch (PubSub, `send_push?/2`'s presence gate, the push) is
  # existing code. Any decided reason passes through untouched. "direct" is
  # not applied here: it is a delivery gate in `Platform.Push`.
  defp apply_level_floor(nil, %Participant{participant_id: user_id}, levels) do
    if Map.get(levels, user_id) == "all", do: :all, else: nil
  end

  defp apply_level_floor(reason, _participant, _levels), do: reason

  # ── Human participant decision (unchanged) ─────────────────────────────────

  # A DM is addressed to its other person by construction, so a human
  # recipient there attends to every message (`:all`), whatever their
  # per-membership mode, unless the mode already decided (heartbeat keeps its
  # queue). Before task 01a111bb stage 2 a DM participant in the default
  # "mention" mode got NO decision for an un-mentioned message, so an agent's
  # reply in a user-to-agent DM never pushed to the user. Burrow's AskAgent
  # timeout fallback relies on that reply arriving as an ordinary chat push.
  # `:all` is a human-only reason: AgentResponder does not route it, and
  # `send_push?/2` pushes it only to an offline recipient.
  defp decide_human_in_space(%Space{kind: "dm"}, participant, message),
    do: decide_human(participant, message) || :all

  defp decide_human_in_space(_space, participant, message),
    do: decide_human(participant, message)

  defp decide_human(%Participant{attention_mode: "all"}, _message), do: :all
  defp decide_human(%Participant{attention_mode: "active"}, _message), do: :active

  defp decide_human(%Participant{attention_mode: "mention"} = participant, message) do
    if mentioned?(participant, message), do: :mention, else: nil
  end

  defp decide_human(%Participant{attention_mode: "heartbeat"}, _message), do: :heartbeat
  defp decide_human(_participant, _message), do: nil

  # ── Mention detection ────────────────────────────────────────────────────────

  # ADR 0037: messages may contain `@[Display Name]` (bracketed, exact) and/or
  # legacy `@name` (substring). We scan both:
  #   1. Extract bracketed tokens — matched exactly, no prefix ambiguity.
  #   2. Strip bracketed tokens from the content; the remainder is the "legacy
  #      zone" where `@name` substring matching applies (covers pre-backfill
  #      messages and LLM-emitted mentions that skip brackets).
  # A single message may mix both forms (e.g. autocompleted `@[Alex]` plus a
  # manually-typed `@alice`) — both route correctly, and `@Alex` substring
  # inside `@[Alex]` does not leak into the legacy check.
  @doc """
  True iff `participant` is @-mentioned in `message`'s content per ADR 0037.

  Matches the bracketed form `@[Display Name]`, the legacy `@name` substring
  form, the participant's id, and any user-configured `attention_config["keywords"]`.
  Used both internally by the routing pipeline and externally by
  `Platform.Chat.eligible_edit_recipients_for_message/1` (Policy 1 narrow
  notification scoping for the editable-messages contract).
  """
  @spec mentioned?(Participant.t(), Message.t()) :: boolean()
  def mentioned?(participant, message), do: mentioned?(participant, message, [])

  @doc """
  `mentioned?/2` with options.

    * `:agent` — the `%Platform.Agents.Agent{}` behind an agent participant
      (or `nil` when there is none). When given, it is used as-is and no
      query runs; when absent, an agent participant's agent is looked up.

  An agent participant is additionally mentioned when a bracketed token names
  its agent per `Platform.Chat.MentionIdentity.agent_named?/2` — the same rule
  the summon path uses, so a token that summons an agent also routes to it.
  User participants are matched on display name only.
  """
  @spec mentioned?(Participant.t(), Message.t(), keyword()) :: boolean()
  def mentioned?(%Participant{} = p, %Message{content: content} = message, opts)
      when is_binary(content) and is_list(opts) do
    if mention_scan_enabled?(message) do
      downcased = String.downcase(content)
      {bracketed_tokens, legacy_zone} = extract_bracketed_tokens(downcased)

      name_match =
        Enum.any?(mention_names(p), fn name ->
          name_mention?(String.downcase(name), bracketed_tokens, legacy_zone)
        end) or agent_identity_mention?(p, bracketed_tokens, opts)

      id_match = id_mention?(String.downcase(p.id), bracketed_tokens, legacy_zone)

      # Support user-configured keywords in attention_config["keywords"]
      keywords = get_in(p.attention_config, ["keywords"]) || []

      keyword_match =
        Enum.any?(keywords, fn keyword ->
          is_binary(keyword) and keyword != "" and
            String.contains?(downcased, String.downcase(keyword))
        end)

      name_match or id_match or keyword_match
    else
      false
    end
  end

  def mentioned?(_participant, _message, _opts), do: false

  # Bracketed tokens only: see `Platform.Chat.MentionIdentity` for why slugs
  # are never offered to the legacy substring zone.
  defp agent_identity_mention?(_participant, [], _opts), do: false

  defp agent_identity_mention?(%Participant{participant_type: "agent"} = p, tokens, opts) do
    agent =
      case Keyword.fetch(opts, :agent) do
        {:ok, agent} -> agent
        :error -> lookup_agent(p.participant_id)
      end

    case agent do
      %Platform.Agents.Agent{} -> MentionIdentity.agent_named?(agent, tokens)
      _ -> false
    end
  end

  defp agent_identity_mention?(_participant, _tokens, _opts), do: false

  @doc """
  True unless the message opts out of mention scanning via
  `metadata["skip_mention_scan"]`.

  System-event pipelines that post messages embedding raw chat activity
  (Historian digest posts, meeting-summary rebroadcasts, RBAC-scoped
  external-chat excerpt shares) can stamp `"skip_mention_scan" => true`
  on the message metadata so quoted `@[Name]` tokens in the embedded
  content don't fire real mention notifications for every named
  participant.

  Applies to both `@[here]` broadcast fanout and per-participant named
  mention routing — anything derived from parsing message content for
  `@[Name]` structure. Non-mention routing paths (`:directed`, `:watch`,
  `:active_agent`, per-participant `attention_mode`) are unaffected: the
  intended recipient of the system-event message still gets their
  regular routing decision from being an actual participant in the
  target space.

  Root cause this defends against: `AttentionRouter.extract_mention_tokens/1`
  scans raw message content with a simple regex — it has no code-fence
  awareness, no way to know a `@[Name]` inside a quoted digest chunk is
  a historical reference rather than a live mention. Historian posts
  routinely embed 20+ real `@[Name]` tokens from the last 24h of chat;
  every one of those turned into a `:multi_mention` notification for
  the named agent (surfaced 2026-07-10 when the operator noticed Dalton was
  receiving Historian dispatches meant for Higgins).
  """
  @spec mention_scan_enabled?(Message.t()) :: boolean()
  def mention_scan_enabled?(%Message{metadata: metadata}) do
    Map.get(metadata || %{}, "skip_mention_scan") != true
  end

  def mention_scan_enabled?(_), do: true

  @doc """
  Return the role key a message is scoped to, or `nil` for ordinary messages.

  A system dispatch that only makes sense for the holder of a given role
  stamps `metadata["role_scoped_dispatch"]` with that role's key. Agent
  routing binds such a message to the role holder instead of running it
  through the activity-based (mention / mutex) branches, which would hand it
  to whoever happened to speak last.

  Blank strings are treated as absent so a stamping bug degrades to ordinary
  routing rather than to a refusal against the empty role key.
  """
  @spec role_scoped_dispatch_role(Message.t()) :: binary() | nil
  def role_scoped_dispatch_role(%Message{metadata: metadata}) do
    case Map.get(metadata || %{}, "role_scoped_dispatch") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          role_key -> role_key
        end

      _ ->
        nil
    end
  end

  def role_scoped_dispatch_role(_), do: nil

  @doc """
  Extract ADR 0037 `@[Display Name]` bracketed mention tokens from content.

  Returns `{tokens, legacy_zone}` where:
    * `tokens` is the list of display-name strings captured between brackets,
      filtered to exclude broadcast sentinels (e.g. `here`) so they cannot
      accidentally match a participant whose display name is the sentinel
    * `legacy_zone` is the original content with all bracketed forms stripped
      (including broadcast sentinels), suitable for the legacy `@name`
      substring check.

  Public so `Chat.post_message` can use the same parser to resolve
  mention-based reinvites without duplicating the regex.

  For typed access to broadcast tokens (`@[here]`), use
  `extract_mention_tokens/1`.
  """
  @spec extract_bracketed_tokens(String.t()) :: {[String.t()], String.t()}
  def extract_bracketed_tokens(content) when is_binary(content) do
    tokens =
      content
      |> extract_mention_tokens()
      |> Enum.flat_map(fn
        %{kind: :name, value: name} -> [name]
        %{kind: :broadcast} -> []
      end)

    legacy_zone = Regex.replace(~r/@\[([^\[\]]+)\]/, content, "")
    {tokens, legacy_zone}
  end

  def extract_bracketed_tokens(_), do: {[], ""}

  @doc """
  Extract typed `@[…]` mention tokens from content (ADR 0037 + @here).

  Returns a list of typed maps preserving source order. Each token is one of:

    * `%{kind: :name, value: "Alex Morgan"}` — an individual user/agent
      mention, captured as the raw bracketed string.
    * `%{kind: :broadcast, target: :here}` — the `@[here]` channel-wide
      sentinel.

  Matching is case-sensitive: only the lowercase literal `@[here]` is
  recognized as a broadcast. `@[Here]`, `@[HERE]`, and `@[hereish]` are
  treated as individual name tokens — that policy keeps the parser
  predictable and is intentionally deferred for later case-folding work.

  Whitespace inside the brackets is significant. `@[here ]` (trailing
  space) is a name token, not a broadcast, mirroring how display names
  treat whitespace.

  Multiple `@[here]` tokens in one message return multiple entries.
  De-duplication is the fan-out caller's responsibility, not the parser's.
  """
  @spec extract_mention_tokens(String.t()) :: [
          %{kind: :name, value: String.t()} | %{kind: :broadcast, target: :here}
        ]
  def extract_mention_tokens(content) when is_binary(content) do
    ~r/@\[([^\[\]]+)\]/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&classify_bracketed_token/1)
  end

  def extract_mention_tokens(_), do: []

  @doc """
  True iff `content` contains at least one `@[here]` broadcast sentinel.

  Thin wrapper over `extract_mention_tokens/1` — the per-message check
  the routing pipeline (and any future webhook/push surface) uses to
  decide whether to fan out to all human recipients.

  Case-sensitive and bracket-exact; see `extract_mention_tokens/1` for
  the matching policy.
  """
  @spec here_mention?(String.t() | nil | any()) :: boolean()
  def here_mention?(content) do
    content
    |> extract_mention_tokens()
    |> Enum.any?(&match?(%{kind: :broadcast, target: :here}, &1))
  end

  defp classify_bracketed_token("here"), do: %{kind: :broadcast, target: :here}
  defp classify_bracketed_token(name), do: %{kind: :name, value: name}

  # Names this participant answers to for @-mention purposes.
  #
  # `chat_participants.display_name` is a DENORMALISED CACHE of the principal's
  # name, not the identity itself. It is nullable, and every caller that reaches
  # `Platform.Chat.add_participant/2` directly (RPC channel creation, ad-hoc
  # console work) could historically omit it and silently write NULL. When that
  # happened for an agent, `@[Dalton]` produced NO `:mention` decision, NO
  # dispatch, and NO error anywhere — the message simply vanished.
  #
  # So mention identity keys on the PRINCIPAL. A blank participant name falls
  # back to the `agents` row and matches on both `name` and `slug`, because the
  # two are equally likely to be what a human or an LLM typed.
  #
  # The fallback query only runs for participants whose cached name is blank —
  # which the write-side resolution in `Platform.Chat.do_add_participant/2` and
  # the NULL backfill migration make vanishingly rare. It exists so a future
  # write path that reintroduces the hole degrades to "slightly slower" rather
  # than "silently undeliverable".
  #
  # Slug matching for agents with a cached name is NOT done here: it lives in
  # `agent_identity_mention?/3` via `Platform.Chat.MentionIdentity`, bracketed
  # tokens only (task 01a0fdfe). This list also feeds the legacy substring
  # zone, where a slug would make `x-agent` match inside `@x-agent-2`.
  @spec mention_names(Participant.t()) :: [String.t()]
  defp mention_names(%Participant{display_name: display_name})
       when is_binary(display_name) and display_name != "" do
    [display_name]
  end

  # `Platform.UUID.valid?/1` guard, not a rescue: `where: a.id == ^value` raises
  # the same `Ecto.Query.CastError` as `Repo.get/2` on a malformed id, and this
  # value reaches us from a participant row rather than from code. Degrading to
  # "no mention" is right; taking the routing pipeline down is not.
  defp mention_names(%Participant{participant_type: "agent", participant_id: agent_id}) do
    case lookup_agent(agent_id) do
      %Platform.Agents.Agent{name: name, slug: slug} ->
        Enum.filter([name, slug], &(is_binary(&1) and &1 != ""))

      nil ->
        []
    end
  end

  defp mention_names(_participant), do: []

  defp lookup_agent(agent_id) when is_binary(agent_id) do
    if Platform.UUID.valid?(agent_id) do
      Repo.one(from(a in Platform.Agents.Agent, where: a.id == ^agent_id))
    else
      nil
    end
  end

  defp lookup_agent(_agent_id), do: nil

  defp name_mention?(name, bracketed_tokens, legacy_zone) do
    name in bracketed_tokens or String.contains?(legacy_zone, "@#{name}")
  end

  defp id_mention?(id, bracketed_tokens, legacy_zone) do
    id in bracketed_tokens or String.contains?(legacy_zone, "@#{id}")
  end

  # ── Query helpers ───────────────────────────────────────────────────────────

  defp active_participants(space_id) do
    from(p in Participant, where: p.space_id == ^space_id)
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
