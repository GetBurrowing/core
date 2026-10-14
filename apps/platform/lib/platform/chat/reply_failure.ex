defmodule Platform.Chat.ReplyFailure do
  @moduledoc """
  A visible notice when an agent could not reply to a message addressed to it
  (task 01a10322 stage 1).

  Before this, every failure branch in `Platform.Chat.AgentResponder` ended in
  a log line: the person who asked saw nothing, and could not tell a slow agent
  from a stopped one. `notify/2` posts ONE `content_type: "system"` message
  into the space, authored by the space's system participant, with metadata

      %{"kind" => "reply_failure", "agent_id" => ..., "message_id" => ...,
        "cause" => "needs_login" | "stopped" | "crashed" | "unknown"}

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
  without `suite_reply`, or a key that went bad after the agent worked, so
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
  """

  require Logger

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Message, Space}
  alias Platform.Chat.ReplyFailure.{Dedupe, Watchdog}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @kind "reply_failure"
  @causes ~w(needs_login stopped crashed unknown)a
  @default_dedupe_s 300

  @type cause :: :needs_login | :stopped | :crashed | :unknown

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

        case Dedupe.claim(agent.id, message.id, dedupe_window_ms()) do
          :ok -> post(agent, message, cause, detail(reason))
          :duplicate -> :deduped
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

  @doc """
  Remember that `context`'s message was delivered to the agent's runtime, so
  a failure the agent host observes afterwards can still be reported for it
  (`notify_pending/1`). Only the last delivery per agent is kept, for
  `Dedupe.pending_ttl_ms/0`.
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

  Returns what `notify/2` returns, or `:none` when the message was answered
  (or is gone).
  """
  @spec no_response(map()) ::
          {:ok, Message.t()} | :deduped | :skipped | :none | {:error, term()}
  def no_response(%{agent_id: agent_id, message_id: message_id} = watch) do
    case unanswered(agent_id, message_id) do
      {:ok, agent, message} ->
        reason =
          case AgentHost.check_auth(agent) do
            {:ok, :rejected} -> :auth_rejected
            _ -> :no_response
          end

        Logger.warning(
          "[ReplyFailure] no reply from native agent=#{agent_id} to message=#{message_id}: #{reason}"
        )

        notify(
          %{agent: agent, message: message, agent_participant_id: watch[:agent_participant_id]},
          reason
        )

      _ ->
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
    :ok
  end

  @doc """
  The cause a dispatch failure reads as.

  For a native agent, what the install's agent host last observed decides it
  (`Platform.AgentHost.status/1`, stage 2): `needs_login`, `crashed` and
  `stopped` read as themselves. With no observation, a native runtime that is
  offline because it was told to stop is `:stopped`. Everything else is
  `:unknown`.
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
  def cause_line(_unknown, name), do: "Something went wrong before #{name} could reply."

  @doc "True for a reply-failure notice. `AttentionRouter` never routes one."
  @spec notice?(Message.t() | map()) :: boolean()
  def notice?(%{content_type: "system", metadata: %{"kind" => @kind}}), do: true
  def notice?(_), do: false

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
    with {:ok, system} <- ExecutionSpace.ensure_system_participant(message.space_id) do
      Chat.post_message(%{
        space_id: message.space_id,
        thread_id: message.thread_id,
        participant_id: system.id,
        content_type: "system",
        content: headline(agent.name) <> "\n" <> cause_line(cause, agent.name),
        metadata:
          %{
            "kind" => @kind,
            "agent_id" => agent.id,
            "message_id" => message.id,
            "cause" => Atom.to_string(cause)
          }
          |> maybe_put("detail", detail)
      })
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
