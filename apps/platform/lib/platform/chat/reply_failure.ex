defmodule Platform.Chat.ReplyFailure do
  @moduledoc """
  A visible notice when an agent could not reply to a message addressed to it
  (task 01a10322 stage 1).

  Before this, every failure branch in `Platform.Chat.AgentResponder` ended in
  a log line: the person who asked saw nothing, and could not tell a slow agent
  from a stopped one. `notify/2` posts ONE `content_type: "system"` message
  into the space, authored by the space's system participant, with metadata

      %{"kind" => "reply_failure", "agent_id" => ..., "message_id" => ...,
        "cause" => "needs_login" | "stopped" | "crashed" | "offline" | "unknown"}

  and the two lines of copy from the design canvas
  (01a10325-8f2d-7001-b858-b92639451ceb), verbatim:

    * line 1: "<Name> couldn't reply to this message."
    * line 2, by cause: see `cause_line/2`.

  ## Callers

  `AgentResponder` calls it from the built-in `{:error, _}` branch and its
  fallthrough, and from the external `:no_runtime` and `:runtime_offline`
  branches.

  A native agent can also fail AFTER the dispatch was delivered: its runtime
  is connected, but Claude Code's first turn fails (an invalid API key). The
  delivery is remembered (`remember_delivery/1`), and when the agent host
  then reports the agent `needs_login` or `crashed`,
  `Platform.AgentHost.Reconciler` calls `notify_pending/1`, which posts the
  notice for that message if the agent has not answered it (stage 7).

  A native agent can also fail with NOTHING observable: a turn that ends
  without `burrow_reply`, or a key that went bad after the agent worked, so
  the dev channel drops the message and no turn runs (stage 7 round 2, gate
  cases 7008 and 7009). `remember_delivery/1` therefore also arms
  `Platform.Chat.ReplyFailure.Watchdog`, which calls `no_response/1` when the
  agent neither replies nor shows turn activity inside its window.

  ## Typing

  `notify/2` also clears the agent's typing indicator in that space, whether
  or not a notice is posted (it may be deduped): the agent is not replying,
  so "<Name> is thinking…" under the notice would contradict it (stage 7).

  ## Not routed

  The notice is not a conversational turn and must never wake an agent:
  `Platform.Chat.AttentionRouter` returns no decisions for a message that
  `notice?/1` recognises. Without that exit, an un-addressed system message in
  a channel whose active-agent mutex is held by the failed agent would be
  routed straight back to it as `:active_agent`.

  ## Dedupe

  At most one notice per `(agent_id, message_id)`, and at most one per agent
  inside the dedupe window (`REPLY_FAILURE_NOTICE_DEDUPE_S`, default 300 s,
  read per call). The state is ephemeral (`Platform.Chat.ReplyFailure.Dedupe`,
  ETS, per node): a restart may let one extra notice through, which is the
  cheaper failure.

  A standing fact on a broadcast is told once per space per day (task
  01a215fb stage 2). When `context.reason` is `:multi_mention` and the cause
  is `:stopped` or `:offline`, nothing is posted (`:deduped`) if this agent
  already has a "stopped" or "offline" notice in this space inside the
  standing window (`REPLY_FAILURE_STANDING_NOTICE_S`, default 86_400 s, read
  per call; 0 turns the rule off). Without it, every post that names a
  handful of parked agents got one notice per agent once the delivery queue's
  TTL ran out, and two such posts nine minutes apart (past the 300 s window)
  put fourteen notices in one channel. A parked agent is not news the second
  time. The rule never applies to a single addressed message (`:mention`,
  `:directed`, `:reply`), so a person who names one stopped agent is told
  every time, nor to `needs_login`, `crashed` or `unknown`, which are
  failures rather than standing facts. The check reads the notice rows, not
  ETS, so a restart or a second node cannot post the day's notice twice.

  ## Declined chat (task 01a1b20f)

  An agent with `accepts_chat: false` is single-purpose: it answers
  responsibility dispatches, not people. `chat_declined/1` tells the person
  who addressed it with ONE line, "<Name> doesn't take chat messages.",
  posted the same way and with the same `kind`, so `notice?/1` and the
  router's exit cover it too. Its metadata `cause` is `"chat_declined"`.

  It is deduped per `(agent_id, message_id)` only. The per-agent window
  does not apply: the opt-out is a standing fact, not a failure storm, and a
  second person addressing the agent a minute later must still be told. The
  claim is an ETS `insert_new` (two concurrent dispatches of one message
  cannot both post), backed by a lookup of an existing notice row for that
  message, so a restart or a second node does not post a second one either.
  """

  require Logger

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Message, Space}
  alias Platform.Chat.ReplyFailure.{Dedupe, Watchdog}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @kind "reply_failure"
  @chat_declined_cause "chat_declined"

  # Routing reasons that mean a person addressed this agent (an @mention, a
  # DM, a reply to its message). Only these are watched for a missing reply:
  # an ambient delivery (`:active_agent`, `:watch`) reaches the agent because
  # it holds the channel, and saying nothing to "Bingo" or a pasted link is
  # the right answer, not a failure (legacy-pie, 2026-11-16..18: every
  # "Something went wrong before Butter could reply" sat under a message
  # nobody had addressed to Butter).
  @addressed_reasons [:mention, :directed, :multi_mention, :reply]
  @causes ~w(needs_login stopped crashed offline unknown)a
  @default_dedupe_s 300
  @default_standing_notice_s 86_400
  # Causes that describe how an agent stands, not a failure of this message.
  @standing_causes ~w(stopped offline)

  @type cause :: :needs_login | :stopped | :crashed | :offline | :unknown

  @doc "The causes a notice can carry."
  @spec causes() :: [cause()]
  def causes, do: @causes

  @doc """
  Post the reply-failure notice for `agent` and the unanswered `message`,
  given the `reason` the dispatch failed with.

  Returns `{:ok, notice}`, `:deduped` when a notice for this agent was already
  posted for this message or inside the window, `:skipped` in a system-event
  space (`kind: "system"`, e.g. the Historian's dispatch space), where no
  person is waiting for the reply, or `{:error, reason}`. Never
  raises: a failure to post a notice must not turn into a failure to handle
  the dispatch.
  """
  @spec notify(%{agent: Agent.t(), message: Message.t()}, term()) ::
          {:ok, Message.t()} | :deduped | :skipped | {:error, term()}
  def notify(%{agent: %Agent{} = agent, message: %Message{} = message} = context, reason) do
    result =
      if system_event_space?(message.space_id) do
        :skipped
      else
        cause = cause_for(agent, reason)

        cond do
          standing_notice_posted?(context, agent, message, cause) ->
            :deduped

          Dedupe.claim(agent.id, message.id, dedupe_window_ms()) == :ok ->
            post(agent, message, cause, detail(reason))

          true ->
            :deduped
        end
      end

    # Whatever happened to the notice, this agent is not replying to this
    # message, so its typing indicator goes.
    stop_typing(context_participant(context), message)
    result
  rescue
    error ->
      Logger.warning(
        "[ReplyFailure] could not post notice for agent=#{agent.id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  def notify(_context, _reason), do: {:error, :invalid_context}

  # A broadcast (`:multi_mention`) that would tell the space a standing fact
  # it was already told today: see "## Dedupe" in the moduledoc.
  defp standing_notice_posted?(
         %{reason: :multi_mention},
         %Agent{id: agent_id},
         %Message{space_id: space_id},
         cause
       ) do
    window_ms = standing_window_ms()

    if window_ms > 0 and Atom.to_string(cause) in @standing_causes do
      since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

      Repo.exists?(
        from(m in Message,
          where:
            m.space_id == ^space_id and m.content_type == "system" and is_nil(m.deleted_at) and
              fragment("?->>'kind'", m.metadata) == ^@kind and
              fragment("?->>'agent_id'", m.metadata) == ^agent_id and
              fragment("?->>'cause'", m.metadata) in ^@standing_causes and
              m.inserted_at >= ^since
        )
      )
    else
      false
    end
  end

  defp standing_notice_posted?(_context, _agent, _message, _cause), do: false

  @doc """
  Post the one-line notice that `context`'s agent does not take chat
  messages (`accepts_chat: false`), for the message that addressed it.

  Returns `{:ok, notice}`, `:deduped` when this agent's notice for this
  message already exists, `:skipped` in a system-event space, or
  `{:error, reason}`. Never raises. Clears the agent's typing indicator
  either way.
  """
  @spec chat_declined(%{agent: Agent.t(), message: Message.t()}) ::
          {:ok, Message.t()} | :deduped | :skipped | {:error, term()}
  def chat_declined(%{agent: %Agent{} = agent, message: %Message{} = message} = context) do
    result =
      cond do
        system_event_space?(message.space_id) -> :skipped
        Dedupe.claim_message(agent.id, message.id) == :duplicate -> :deduped
        chat_declined_posted?(agent, message) -> :deduped
        true -> post_chat_declined(agent, message)
      end

    stop_typing(context_participant(context), message)
    result
  rescue
    error ->
      Logger.warning(
        "[ReplyFailure] could not post chat_declined notice for agent=#{agent.id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  def chat_declined(_context), do: {:error, :invalid_context}

  @doc "The text of the declined-chat notice."
  @spec chat_declined_line(String.t()) :: String.t()
  def chat_declined_line(name), do: "#{name} doesn't take chat messages."

  @doc "True for a declined-chat notice (see `chat_declined/1`)."
  @spec chat_declined?(Message.t() | map()) :: boolean()
  def chat_declined?(%{metadata: %{"cause" => @chat_declined_cause}} = message),
    do: notice?(message)

  def chat_declined?(_), do: false

  # The durable half of the dedupe: the notice row itself, keyed by the
  # agent and the message it answers. Survives a restart and a second node,
  # which the ETS claim does not.
  defp chat_declined_posted?(%Agent{id: agent_id}, %Message{id: message_id, space_id: space_id}) do
    Repo.exists?(
      from(m in Message,
        where:
          m.space_id == ^space_id and m.content_type == "system" and is_nil(m.deleted_at) and
            fragment("?->>'kind'", m.metadata) == ^@kind and
            fragment("?->>'cause'", m.metadata) == ^@chat_declined_cause and
            fragment("?->>'agent_id'", m.metadata) == ^agent_id and
            fragment("?->>'message_id'", m.metadata) == ^message_id
      )
    )
  end

  defp post_chat_declined(%Agent{} = agent, %Message{} = message) do
    post_system_line(message, chat_declined_line(agent.name), %{
      "kind" => @kind,
      "agent_id" => agent.id,
      "message_id" => message.id,
      "cause" => @chat_declined_cause
    })
  end

  @doc "The routing reasons that mean a person addressed the agent."
  @spec addressed_reasons() :: [atom()]
  def addressed_reasons, do: @addressed_reasons

  @doc "Whether `reason` means a person addressed the agent (`addressed_reasons/0`)."
  @spec addressed_reason?(term()) :: boolean()
  def addressed_reason?(reason), do: reason in @addressed_reasons

  @doc """
  Remember that `context`'s message was delivered to the agent's runtime, so
  a failure the agent host observes afterwards can still be reported for it
  (`notify_pending/1`). Only the last delivery per agent is kept, for
  `Dedupe.pending_ttl_ms/0`.

  The no-reply watchdog is armed only when `context.reason` says a person
  addressed the agent (`addressed_reason?/1`); an ambient delivery is
  remembered for the host-observed path but never watched.
  """
  @spec remember_delivery(map()) :: :ok
  def remember_delivery(%{agent: %Agent{id: agent_id}, message: %Message{} = message} = context) do
    :ok =
      Dedupe.put_pending(agent_id, %{
        message_id: message.id,
        agent_participant_id: context_participant(context)
      })

    _ = Watchdog.arm(context)
    :ok
  end

  def remember_delivery(_context), do: :ok

  @doc """
  Post the notice for the message last delivered to `agent_id`'s runtime,
  when the agent host has just observed the agent unable to reply
  (`needs_login` or `crashed`).

  Nothing is posted when no delivery is pending (none in the last
  `Dedupe.pending_ttl_ms/0`, or it was already consumed), or when the agent
  has posted in that space since the message, or for an agent that is not
  observed in one of those states. Returns what `notify/2` returns, or `:none`.
  """
  @spec notify_pending(binary()) ::
          {:ok, Message.t()} | :deduped | :skipped | :none | {:error, term()}
  def notify_pending(agent_id) when is_binary(agent_id) do
    # `agent_id` arrives in the agent host's `agent.state` payload.
    with %{state: state} when state in [:needs_login, :crashed] <- AgentHost.status(agent_id),
         %{message_id: message_id} = pending <- Dedupe.take_pending(agent_id),
         {:ok, agent, message} <- unanswered(agent_id, message_id) do
      notify(
        %{agent: agent, message: message, agent_participant_id: pending[:agent_participant_id]},
        :observed
      )
    else
      _ -> :none
    end
  rescue
    error ->
      Logger.warning(
        "[ReplyFailure] notify_pending failed for agent=#{agent_id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  def notify_pending(_agent_id), do: :none

  @doc """
  The no-reply watchdog's verdict for one delivered message
  (`Platform.Chat.ReplyFailure.Watchdog`): the agent neither replied nor
  showed turn activity inside the window.

  If the agent has still not answered, the agent host is asked whether the
  agent's API key works (`Platform.AgentHost.check_auth/2`). A rejected key
  is `needs_login` (and the host reports the agent `needs_login`, which tags
  its row). Otherwise the cause is what the host observes, else `unknown`.
  Exactly one notice per message and per agent window, through `notify/2`,
  which also clears "<Name> is thinking…".

  BUSY IS NOT A FAILURE: when the key is not rejected and the agent's
  runtime still has a heartbeat (`runtime_alive?/1`), no notice is posted.
  The agent is in the middle of something else and Claude Code delivers the
  message when that turn ends, so the space is told "<Agent> is busy"
  (`{:busy, busy}`, see `busy_info/2`) and the watchdog keeps watching. A
  watch with `final: true` (the busy cap) posts the notice regardless.

  Returns what `notify/2` returns, `{:busy, busy}`, or `:none` when the
  message was answered (or is gone).
  """
  @spec no_response(map()) ::
          {:ok, Message.t()}
          | {:busy, map()}
          | :deduped
          | :skipped
          | :none
          | {:error, term()}
  def no_response(%{agent_id: agent_id, message_id: message_id} = watch) do
    case unanswered(agent_id, message_id) do
      {:ok, agent, message} ->
        reason =
          cond do
            # Asked once, at the first verdict; a busy re-check does not
            # make the host test the key every window.
            match?(%{}, watch[:busy]) -> :no_response
            match?({:ok, :rejected}, AgentHost.check_auth(agent)) -> :auth_rejected
            true -> :no_response
          end

        if reason == :no_response and watch[:final] != true and runtime_alive?(agent) do
          busy(agent, message, watch)
        else
          Logger.warning(
            "[ReplyFailure] no reply from native agent=#{agent_id} to message=#{message_id}: #{reason}"
          )

          notify(
            %{agent: agent, message: message, agent_participant_id: watch[:agent_participant_id]},
            reason
          )
        end

      _ ->
        if match?(%{}, watch[:busy]),
          do: clear_busy(watch[:agent_participant_id], watch[:space_id])

        :none
    end
  rescue
    error ->
      Logger.warning(
        "[ReplyFailure] no_response failed for agent=#{inspect(agent_id)}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  def no_response(_watch), do: :none

  @doc """
  True when `agent`'s runtime is connected and has a heartbeat
  (`Platform.Federation.RuntimePresence.heartbeat?/1`). False for an agent
  with no runtime.
  """
  @spec runtime_alive?(Agent.t() | nil) :: boolean()
  def runtime_alive?(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{runtime_id: runtime_id} when is_binary(runtime_id) ->
        RuntimePresence.heartbeat?(runtime_id)

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def runtime_alive?(_agent), do: false

  @doc """
  The busy state for `agent`, which has had `message` (delivered at
  `delivered_at`) waiting on it: `%{state: "busy", activity, since,
  agent_name}`. `activity` is what the agent was last seen doing
  (`Watchdog.current_activity/1`) as a phrase, or nil; `since` is when that
  run of work started, else when the message was delivered.
  """
  @spec busy_info(Agent.t(), DateTime.t() | nil) :: map()
  def busy_info(%Agent{} = agent, delivered_at \\ nil) do
    activity = Watchdog.current_activity(agent.id)

    since =
      case activity do
        %{since: %DateTime{} = since} -> since
        _ -> delivered_at || DateTime.utc_now()
      end

    %{state: "busy", activity: activity_phrase(activity), since: since, agent_name: agent.name}
  end

  @doc "The phrase for an activity record, or nil. See `busy_info/2`."
  @spec activity_phrase(map() | nil) :: String.t() | nil
  def activity_phrase(%{task_id: task_id} = activity) when is_binary(task_id) do
    case task_title(task_id) do
      title when is_binary(title) -> "working on “#{title}”"
      _ -> activity_phrase(%{activity | task_id: nil})
    end
  end

  def activity_phrase(%{tool: tool}) when is_binary(tool), do: "using #{tool}"

  def activity_phrase(%{space_id: space_id}) when is_binary(space_id) do
    case Chat.get_space(space_id) do
      # A channel's name is not private to its members' agents the way a DM's
      # participants are; a DM is named generically.
      %Space{kind: "channel", name: name} when is_binary(name) -> "replying in ##{name}"
      %Space{} -> "replying in another conversation"
      _ -> nil
    end
  end

  def activity_phrase(_activity), do: nil

  defp task_title(task_id) do
    if Platform.UUID.valid?(task_id) do
      case Repo.get(Platform.Tasks.Task, task_id) do
        %{title: title} when is_binary(title) and title != "" -> title
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp busy(%Agent{} = agent, %Message{} = message, watch) do
    busy = busy_info(agent, watch[:delivered_at])
    participant_id = watch[:agent_participant_id]

    if is_binary(participant_id) do
      # Busy replaces "thinking": the agent is not working on THIS message yet.
      _ = ChatPubSub.broadcast_agent_typing(message.space_id, participant_id, false)
      _ = ChatPubSub.broadcast_agent_busy(message.space_id, participant_id, busy)
    end

    Logger.info(
      "[ReplyFailure] native agent=#{agent.id} is busy (runtime connected); message=#{message.id} waits"
    )

    {:busy, busy}
  end

  defp clear_busy(participant_id, space_id)
       when is_binary(participant_id) and is_binary(space_id) do
    _ = ChatPubSub.broadcast_agent_busy(space_id, participant_id, nil)
    :ok
  end

  defp clear_busy(_participant_id, _space_id), do: :ok

  @doc """
  True when `agent_id` has not answered `message_id` (and both exist). For
  the delivery queue, which skips a redelivery the agent no longer needs.
  """
  @spec unanswered?(binary(), binary()) :: boolean()
  def unanswered?(agent_id, message_id), do: match?({:ok, _, _}, unanswered(agent_id, message_id))

  @doc """
  A message held for an offline runtime (`Platform.Federation.DeliveryQueue`)
  that the runtime did not come back for inside the queue's TTL: the notice
  it would have got at dispatch, cause `runtime_offline`. Nothing is posted
  when the agent answered after all, or when its runtime is up again (the
  watchdog owns a delivered message).
  """
  @spec undelivered(map()) ::
          {:ok, Message.t()} | :deduped | :skipped | :none | {:error, term()}
  def undelivered(%{agent_id: agent_id, message_id: message_id} = entry) do
    with {:ok, agent, message} <- unanswered(agent_id, message_id),
         false <- runtime_alive?(agent) do
      notify(
        %{
          agent: agent,
          message: message,
          agent_participant_id: entry[:agent_participant_id],
          reason: get_in(entry, [:signal, :reason])
        },
        :runtime_offline
      )
    else
      _ -> :none
    end
  end

  def undelivered(_entry), do: :none

  @doc """
  For a native agent the agent host observes as `needs_login`, the cause to
  report INSTEAD of dispatching: its runtime may be connected, but Claude
  Code cannot run a turn, so the message would get no reply and no notice.
  Nil for every other agent and state.
  """
  @spec refuse_dispatch_cause(Agent.t()) :: cause() | nil
  def refuse_dispatch_cause(%Agent{} = agent) do
    case AgentHost.status(agent) do
      %{state: :needs_login} -> :needs_login
      _ -> nil
    end
  end

  def refuse_dispatch_cause(_agent), do: nil

  # The agent and message of a delivery, when the agent has not answered it.
  # `agent_id` may come off the agent host's channel payload, so it is checked
  # before it reaches Agent's strict UUIDv7 PK; `message_id` is always read
  # back from a delivery `remember_delivery/1` recorded off a loaded message.
  defp unanswered(agent_id, message_id) when is_binary(agent_id) and is_binary(message_id) do
    with true <- Platform.UUID.valid?(agent_id),
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         %Message{} = message <- Repo.get(Message, message_id),
         false <- answered?(agent, message) do
      {:ok, agent, message}
    else
      _ -> :none
    end
  end

  defp unanswered(_agent_id, _message_id), do: :none

  defp answered?(%Agent{id: agent_id}, %Message{space_id: space_id, inserted_at: at}) do
    Repo.exists?(
      from(m in Message,
        where:
          m.space_id == ^space_id and m.author_agent_id == ^agent_id and m.inserted_at > ^at and
            is_nil(m.deleted_at)
      )
    )
  end

  defp context_participant(%{agent_participant: %{id: id}}) when is_binary(id), do: id
  defp context_participant(%{agent_participant_id: id}) when is_binary(id), do: id
  defp context_participant(_context), do: nil

  defp stop_typing(nil, _message), do: :ok

  defp stop_typing(participant_id, %Message{space_id: space_id}) do
    _ = ChatPubSub.broadcast_agent_typing(space_id, participant_id, false)
    # Nor busy, nor queued: the notice is the last word on this message.
    _ = ChatPubSub.broadcast_agent_busy(space_id, participant_id, nil)
    :ok
  end

  @doc """
  The cause a dispatch failure reads as.

  For a native agent, what the install's agent host last observed decides it
  (`Platform.AgentHost.status/1`, stage 2): `needs_login`, `crashed` and
  `stopped` read as themselves. With no observation, a native runtime that is
  offline because it was told to stop is `:stopped`.

  An external (federated) runtime that is offline is `:offline`, whatever its
  `desired_state` says (task 01a215fb). Its `desired_state` records no
  decision: the schema defaults it to "stopped" and
  `Platform.Agents.NativeAgents.set_desired_state/2` refuses any runtime the
  install does not manage, so a parked runtime and one that dropped a minute
  ago read the same. What is observable is only that it has not connected,
  so the line says that and not "stopped".

  Everything else is `:unknown`, including an install-managed runtime that
  should be running, `:no_runtime`, and a delivered dispatch that got no
  reply.
  """
  @spec cause_for(Agent.t(), term()) :: cause()
  # The agent host just found the agent's API key rejected (stage 7 round 2):
  # that is the cause, whatever state it last reported.
  def cause_for(%Agent{}, :auth_rejected), do: :needs_login

  def cause_for(%Agent{} = agent, reason) do
    case observed_cause(agent) do
      nil -> fallback_cause(agent, reason)
      cause -> cause
    end
  end

  def cause_for(_agent, _reason), do: :unknown

  defp observed_cause(agent) do
    case AgentHost.status(agent) do
      %{state: state} when state in [:needs_login, :crashed, :stopped] -> state
      _ -> nil
    end
  end

  defp fallback_cause(agent, :runtime_offline) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{managed_by: "install", desired_state: "stopped"} -> :stopped
      %AgentRuntime{managed_by: managed_by} when managed_by != "install" -> :offline
      _ -> :unknown
    end
  end

  defp fallback_cause(_agent, _reason), do: :unknown

  @doc "Line 1 of the notice, the same for every cause."
  @spec headline(String.t()) :: String.t()
  def headline(name), do: "#{name} couldn't reply to this message."

  @doc "Line 2 of the notice, by cause."
  @spec cause_line(cause(), String.t()) :: String.t()
  def cause_line(:needs_login, name), do: "#{name}'s Claude login has expired."
  def cause_line(:stopped, name), do: "#{name} is stopped."
  def cause_line(:crashed, name), do: "#{name} stopped unexpectedly while replying."
  def cause_line(:offline, name), do: "#{name} is offline."
  def cause_line(_unknown, name), do: "Something went wrong before #{name} could reply."

  @doc "True for a reply-failure notice. `AttentionRouter` never routes one."
  @spec notice?(Message.t() | map()) :: boolean()
  def notice?(%{content_type: "system", metadata: %{"kind" => @kind}}), do: true
  def notice?(_), do: false

  @doc """
  The standing-fact window in milliseconds, read per call from
  `config :platform, :reply_failure_standing_notice_s` (default one day).
  0 turns the broadcast rule off (see "## Dedupe").
  """
  @spec standing_window_ms() :: non_neg_integer()
  def standing_window_ms do
    case Application.get_env(
           :platform,
           :reply_failure_standing_notice_s,
           @default_standing_notice_s
         ) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds * 1000
      _ -> @default_standing_notice_s * 1000
    end
  end

  @doc """
  The dedupe window in milliseconds, read per call from
  `config :platform, :reply_failure_notice_dedupe_s`.
  """
  @spec dedupe_window_ms() :: non_neg_integer()
  def dedupe_window_ms do
    case Application.get_env(:platform, :reply_failure_notice_dedupe_s, @default_dedupe_s) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds * 1000
      _ -> @default_dedupe_s * 1000
    end
  end

  # System-event spaces (`kind: "system"`) carry machine dispatches to one
  # agent, such as the Historian's; nobody there asked a question.
  defp system_event_space?(space_id) do
    match?(%Space{kind: "system"}, Chat.get_space(space_id))
  end

  # Why the notice was posted, beyond its cause, for whoever reads the row's
  # metadata later. Only the watchdog's verdicts carry one.
  defp detail(:no_response), do: "no_response"
  defp detail(:auth_rejected), do: "auth_rejected"
  defp detail(_reason), do: nil

  defp post(%Agent{} = agent, %Message{} = message, cause, detail) do
    post_system_line(
      message,
      headline(agent.name) <> "\n" <> cause_line(cause, agent.name),
      %{
        "kind" => @kind,
        "agent_id" => agent.id,
        "message_id" => message.id,
        "cause" => Atom.to_string(cause)
      }
      |> maybe_put("detail", detail)
    )
  end

  # Every notice is a `system` message from the space's system participant,
  # in the thread of the message it answers.
  defp post_system_line(%Message{} = message, content, metadata) do
    with {:ok, system} <- ExecutionSpace.ensure_system_participant(message.space_id) do
      Chat.post_message(%{
        space_id: message.space_id,
        thread_id: message.thread_id,
        participant_id: system.id,
        content_type: "system",
        content: content,
        metadata: metadata
      })
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
