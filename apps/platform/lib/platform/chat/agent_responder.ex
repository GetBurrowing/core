defmodule Platform.Chat.AgentResponder do
  @moduledoc """
  Handles native agent replies triggered by chat attention signals.

  Uses the existing attention routing layer as the trigger surface, then invokes
  the configured chat agent module (QuickAgent by default) and persists the
  reply back into chat as a normal agent-authored message.

  For external runtimes, dispatches attention signals via the RuntimeChannel
  instead of calling QuickAgent directly.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ContextPlane, Message, Participant}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @history_limit 12

  @spec maybe_dispatch(map()) :: :ok
  def maybe_dispatch(signal) when is_map(signal) do
    case dispatch_mode() do
      :sync ->
        _ = respond(signal)
        :ok

      _ ->
        Task.start(fn ->
          _ = respond(signal)
        end)

        :ok
    end
  end

  @routable_reasons [:mention, :directed, :sticky]

  @spec respond(map()) :: :ok | {:error, term()}
  def respond(%{reason: reason} = signal) when reason in @routable_reasons do
    with {:ok, context} <- load_context(signal) do
      if context.agent.runtime_type == "external" do
        dispatch_to_external(signal, context)
      else
        dispatch_to_built_in(signal, context)
      end
    else
      {:error, :ignore} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AgentResponder] skipped reply (load_context): #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("[AgentResponder] failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      {:error, error}
  end

  def respond(_signal), do: :ok

  # ── Built-in agent dispatch (original behavior) ─────────────────────

  defp dispatch_to_built_in(_signal, context) do
    space_id = context.message.space_id
    agent_participant_id = context.agent_participant.id

    ChatPubSub.broadcast(
      space_id,
      {:agent_typing, %{participant_id: agent_participant_id, typing: true}}
    )

    result =
      with {:ok, response} <-
             chat_module().chat(context.user_message,
               history: context.history,
               space_id: context.message.space_id,
               participant_id: context.agent_participant.id
             ),
           reply when is_binary(reply) <- Map.get(response, :content),
           trimmed_reply when trimmed_reply != "" <- String.trim(reply),
           {:ok, _message} <- persist_reply(context, trimmed_reply) do
        maybe_create_canvas(context, trimmed_reply)

        # Enter/extend sticky engagement after successful reply
        Chat.engage_agent(
          space_id,
          agent_participant_id,
          String.slice(context.user_message, 0, 200)
        )

        :ok
      else
        {:error, :ignore} ->
          :ok

        {:error, reason} ->
          Logger.warning("[AgentResponder] skipped reply: #{inspect(reason)}")
          {:error, reason}

        _ ->
          :ok
      end

    ChatPubSub.broadcast(
      space_id,
      {:agent_typing, %{participant_id: agent_participant_id, typing: false}}
    )

    result
  end

  # ── External runtime dispatch ───────────────────────────────────────

  defp dispatch_to_external(signal, context) do
    space_id = context.message.space_id
    runtime_id = context.agent.runtime_id

    if is_nil(runtime_id) do
      Logger.warning("[AgentResponder] external agent #{context.agent.id} has no runtime_id")
      {:error, :no_runtime}
    else
      runtime = Platform.Federation.get_runtime(runtime_id)

      if runtime do
        bundle = ContextPlane.build_context_bundle(space_id)
        tools = ToolSurface.tool_definitions()

        author_participant = Chat.get_participant(context.message.participant_id)
        author_name = if author_participant, do: author_participant.display_name, else: "unknown"

        payload = %{
          signal: %{reason: signal.reason},
          message: %{content: context.user_message, author: author_name},
          history: context.history,
          context: bundle,
          tools: tools
        }

        PlatformWeb.Endpoint.broadcast(
          "runtime:#{runtime.runtime_id}",
          "attention",
          payload
        )

        :ok
      else
        Logger.warning("[AgentResponder] runtime #{runtime_id} not found")
        {:error, :runtime_not_found}
      end
    end
  end

  @canvas_tag_pattern ~r/\[canvas:([a-zA-Z0-9_-]+):([^\]]+)\]/

  @doc """
  Parses `[canvas:TYPE:TITLE]` tags in the agent reply and creates matching
  canvases via `Platform.Chat.create_canvas_with_message/3`.

  Returns `:ok` regardless of outcome so callers don't need to handle errors.
  """
  @spec maybe_create_canvas(map(), binary()) :: :ok
  def maybe_create_canvas(context, reply) when is_binary(reply) do
    @canvas_tag_pattern
    |> Regex.scan(reply, capture: :all_but_first)
    |> Enum.each(fn [canvas_type, title] ->
      attrs = %{
        "canvas_type" => String.downcase(canvas_type),
        "title" => String.trim(title)
      }

      case Chat.create_canvas_with_message(
             context.message.space_id,
             context.agent_participant.id,
             attrs
           ) do
        {:ok, canvas, _message} ->
          Logger.info("[AgentResponder] created canvas #{canvas.id} (#{canvas_type}: #{title})")

        {:error, reason} ->
          Logger.warning("[AgentResponder] failed to create canvas: #{inspect(reason)}")
      end
    end)

    :ok
  end

  def maybe_create_canvas(_context, _reply), do: :ok

  defp load_context(
         %{participant_id: participant_id, message_id: message_id, space_id: space_id} = signal
       ) do
    with %Participant{participant_type: "agent"} = participant <-
           Chat.get_participant(participant_id),
         %Message{} = message <- Chat.get_message(message_id),
         %Participant{} = author <- Chat.get_participant(message.participant_id),
         false <- author.participant_type == "agent",
         %Agent{} = agent <- Repo.get(Agent, participant.participant_id),
         {:ok, active_agent_participant} <-
           Chat.ensure_agent_participant(space_id, agent, display_name: agent.name),
         history <- build_history(space_id, message, active_agent_participant.id) do
      {:ok,
       %{
         signal: signal,
         agent: agent,
         agent_participant: active_agent_participant,
         message: message,
         user_message: String.trim(message.content || ""),
         history: history
       }}
    else
      nil -> {:error, :ignore}
      true -> {:error, :ignore}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ignore}
    end
  end

  defp persist_reply(context, reply) do
    trigger = Atom.to_string(context.signal.reason)

    Chat.post_message(%{
      space_id: context.message.space_id,
      thread_id: context.message.thread_id,
      participant_id: context.agent_participant.id,
      content_type: "text",
      content: String.trim(reply),
      metadata: %{
        "source" => "agent_responder",
        "trigger" => trigger,
        "reply_to_message_id" => context.message.id,
        "agent_id" => context.agent.id
      }
    })
  end

  defp build_history(space_id, %Message{} = message, agent_participant_id) do
    participants =
      Chat.list_participants(space_id, include_left: true)
      |> Map.new(fn participant -> {participant.id, participant} end)

    opts =
      if is_binary(message.thread_id) do
        [thread_id: message.thread_id, limit: @history_limit]
      else
        [top_level_only: true, limit: @history_limit]
      end

    space_id
    |> Chat.list_messages(opts)
    |> Enum.reject(&(&1.id == message.id))
    |> Enum.sort_by(& &1.inserted_at, fn left, right -> DateTime.compare(left, right) != :gt end)
    |> Enum.flat_map(fn item ->
      case history_message(item, participants, agent_participant_id) do
        nil -> []
        entry -> [entry]
      end
    end)
  end

  defp history_message(
         %Message{content_type: "text", content: content} = message,
         participants,
         agent_id
       )
       when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      nil
    else
      participant = Map.get(participants, message.participant_id)

      role =
        if message.participant_id == agent_id, do: "assistant", else: history_role(participant)

      %{role: role, content: history_content(trimmed, participant, role)}
    end
  end

  defp history_message(_message, _participants, _agent_id), do: nil

  defp history_role(%Participant{participant_type: "agent"}), do: "assistant"
  defp history_role(_participant), do: "user"

  defp history_content(content, %Participant{display_name: name}, "user")
       when is_binary(name) and name != "" do
    "#{name}: #{content}"
  end

  defp history_content(content, _participant, _role), do: content

  defp chat_module do
    Application.get_env(:platform, :chat_agent_module, Platform.Agents.QuickAgent)
  end

  defp dispatch_mode do
    Application.get_env(:platform, :chat_agent_dispatch_mode, :async)
  end
end
