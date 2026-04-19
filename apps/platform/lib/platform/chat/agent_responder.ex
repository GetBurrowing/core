defmodule Platform.Chat.AgentResponder do
  @moduledoc """
  Handles native agent replies triggered by chat attention signals.

  Uses the existing attention routing layer as the trigger surface, then invokes
  the configured chat agent module (QuickAgent by default) and persists the
  reply back into chat as a normal agent-authored message.

  For external runtimes, dispatches attention signals via the RuntimeChannel
  instead of calling QuickAgent directly.

  ## Parallel dispatch (ADR 0027)

  When multiple agents are @-mentioned simultaneously, `dispatch_parallel/3`
  sends each agent the same frozen history snapshot so they can't see each
  other's responses. Uses `Task.Supervisor` for fault-isolated concurrency.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ContextPlane, Message, Participant}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation.{DeadLetterBuffer, RuntimePresence, ToolSurface}
  alias Platform.Repo
  alias Platform.Tasks.Task, as: TaskRecord

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

  @doc """
  Dispatch the same message to multiple agents concurrently with a frozen
  history snapshot. Each agent receives identical context so they cannot see
  each other's responses.

  `signals` is a list of attention signal maps (one per agent).
  `space` is the `%Space{}` struct for the conversation.
  `frozen_history` is a pre-built history list captured *before* dispatch.
  """
  @spec dispatch_parallel([map()], term(), list()) :: :ok
  def dispatch_parallel(signals, _space, frozen_history) when is_list(signals) do
    Task.Supervisor.async_stream_nolink(
      Platform.TaskSupervisor,
      signals,
      fn signal ->
        signal = Map.put(signal, :reason, :multi_mention)

        signal =
          Map.update(signal, :metadata, %{frozen_history: frozen_history}, fn meta ->
            Map.put(meta || %{}, :frozen_history, frozen_history)
          end)

        respond(signal)
      end,
      max_concurrency: 5,
      timeout: 60_000
    )
    |> Stream.each(fn
      {:ok, result} ->
        Logger.debug("[AgentResponder] parallel dispatch result: #{inspect(result)}")

      {:exit, reason} ->
        Logger.warning("[AgentResponder] parallel dispatch task exited: #{inspect(reason)}")
    end)
    |> Stream.run()

    :ok
  end

  @routable_reasons [
    :mention,
    :directed,
    :sticky,
    :active_agent,
    :watch,
    :multi_mention,
    :system_event
  ]

  @spec respond(map()) :: :ok | {:error, term()}
  def respond(%{reason: reason} = signal) when reason in @routable_reasons do
    Logger.info(
      "[AgentResponder] respond called with reason=#{reason} signal=#{inspect(Map.take(signal, [:participant_id, :message_id, :space_id]))}"
    )

    with {:ok, context} <- load_context(signal) do
      Logger.info(
        "[AgentResponder] context loaded, agent=#{context.agent.slug} runtime_type=#{context.agent.runtime_type} runtime_id=#{inspect(context.agent.runtime_id)}"
      )

      if context.agent.runtime_type == "external" do
        Logger.info("[AgentResponder] dispatching to external runtime")
        dispatch_to_external(signal, context)
      else
        dispatch_to_built_in(signal, context)
      end
    else
      {:error, :ignore} ->
        Logger.debug(
          "[AgentResponder] load_context returned :ignore for signal=#{inspect(Map.take(signal, [:participant_id, :message_id, :space_id]))}"
        )

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
    agent_participant_id = context.agent_participant.id
    runtime_id = context.agent.runtime_id

    # Show typing indicator immediately while the external runtime processes
    ChatPubSub.broadcast(
      space_id,
      {:agent_typing, %{participant_id: agent_participant_id, typing: true}}
    )

    if is_nil(runtime_id) do
      Logger.warning("[AgentResponder] external agent #{context.agent.id} has no runtime_id")
      {:error, :no_runtime}
    else
      runtime = Platform.Federation.get_runtime(runtime_id)

      if runtime do
        topic = "runtime:#{runtime.runtime_id}"

        # Pre-check: is the runtime actually connected?
        unless RuntimePresence.online?(runtime.runtime_id) do
          Logger.error(
            "[AgentResponder] DEAD LETTER: runtime #{runtime.runtime_id} not in presence — agent #{context.agent.slug} unreachable (topic=#{topic})"
          )

          DeadLetterBuffer.record(%{
            runtime_id: runtime.runtime_id,
            agent_id: context.agent.id,
            agent_slug: context.agent.slug,
            space_id: space_id,
            reason: :runtime_offline,
            timestamp: DateTime.utc_now()
          })

          :telemetry.execute(
            [:platform, :federation, :delivery_failed],
            %{system_time: System.system_time()},
            %{
              runtime_id: runtime.runtime_id,
              agent_id: context.agent.id,
              reason: :runtime_offline
            }
          )

          {:error, :runtime_offline}
        else
          bundle = ContextPlane.build_context_bundle(space_id)
          tools = ToolSurface.tool_definitions()

          author_participant = Chat.get_participant(context.message.participant_id)

          author_name =
            if author_participant, do: author_participant.display_name, else: "unknown"

          payload = %{
            signal: build_external_signal(signal, space_id, context.agent),
            message: %{content: context.user_message, author: author_name},
            history: context.history,
            context: bundle,
            tools: tools
          }

          Logger.info("[AgentResponder] broadcasting attention to #{topic}")

          case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
            :ok ->
              Logger.info("[AgentResponder] broadcast sent successfully to #{topic}")

              :telemetry.execute(
                [:platform, :federation, :delivery_success],
                %{system_time: System.system_time()},
                %{runtime_id: runtime.runtime_id, agent_id: context.agent.id}
              )

              :ok

            {:error, reason} ->
              Logger.error("[AgentResponder] broadcast failed to #{topic}: #{inspect(reason)}")

              {:error, :broadcast_failed}
          end
        end
      else
        Logger.warning("[AgentResponder] runtime #{runtime_id} not found")
        {:error, :runtime_not_found}
      end
    end
  end

  @doc """
  Placeholder for the legacy `[canvas:TYPE:TITLE]` regex tag path.

  Per ADR 0036 the `canvas.create` / `canvas.patch` / `canvas.describe` tools
  are the only sanctioned surface for agent-produced canvases. The regex tag
  path is disabled; agents that still emit tagged markers will have those
  tokens rendered literally in their reply. Remove the emission in agent
  prompts rather than reintroducing the tag parser.
  """
  @spec maybe_create_canvas(map(), binary() | any()) :: :ok
  def maybe_create_canvas(_context, _reply), do: :ok

  defp load_context(
         %{participant_id: participant_id, message_id: message_id, space_id: space_id} = signal
       ) do
    with %Participant{participant_type: "agent"} = participant <-
           Chat.get_participant(participant_id),
         %Message{} = message <- Chat.get_message(message_id),
         %Participant{} = author <- Chat.get_participant(message.participant_id),
         :ok <- check_agent_loop(author, participant_id, space_id),
         %Agent{} = agent <- Repo.get(Agent, participant.participant_id),
         %Participant{} = active_agent_participant <-
           Chat.get_agent_participant(space_id, agent),
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
      case history_message(item, agent_participant_id) do
        nil -> []
        entry -> [entry]
      end
    end)
  end

  # Author role + display name come off the message's author snapshot
  # (ADR 0038). We no longer need a live participants map — the whole
  # point of the snapshot is that dismissed/re-added authors still read
  # cleanly from the message row.
  defp history_message(
         %Message{content_type: "text", content: content} = message,
         agent_id
       )
       when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      nil
    else
      role =
        cond do
          message.participant_id == agent_id -> "assistant"
          message.author_participant_type == "agent" -> "assistant"
          true -> "user"
        end

      %{role: role, content: history_content(trimmed, message, role)}
    end
  end

  defp history_message(_message, _agent_id), do: nil

  defp history_content(content, %Message{author_display_name: name}, "user")
       when is_binary(name) and name != "" do
    "#{name}: #{content}"
  end

  defp history_content(content, _message, _role), do: content

  defp build_external_signal(signal, space_id), do: build_external_signal(signal, space_id, nil)

  defp build_external_signal(signal, space_id, agent) do
    {task_id, task_status} = execution_task_context(space_id)

    %{}
    |> Map.put(:reason, signal.reason)
    |> Map.put(:space_id, space_id)
    |> maybe_put(:task_id, task_id)
    |> maybe_put(:task_status, task_status)
    |> maybe_put(:agent_id, Map.get(agent || %{}, :id))
    |> maybe_put(:agent_slug, Map.get(agent || %{}, :slug))
  end

  defp execution_task_context(space_id) do
    with %Platform.Chat.Space{kind: "execution", metadata: metadata} <- Chat.get_space(space_id),
         task_id when is_binary(task_id) <-
           Map.get(metadata || %{}, "task_id") || Map.get(metadata || %{}, :task_id) do
      case Repo.get(TaskRecord, task_id) do
        %TaskRecord{status: status} -> {task_id, status}
        _ -> {task_id, nil}
      end
    else
      _ -> {nil, nil}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Agent-to-agent loop breaker: allow agent→agent mentions but prevent rapid
  # back-and-forth loops. If the author is an agent, we check a cooldown — the
  # receiving agent can only be triggered by another agent in the same space
  # once per @agent_cooldown_ms window. Human-authored messages always pass.
  @agent_cooldown_ms 30_000

  defp check_agent_loop(%Participant{participant_type: "agent"}, recipient_id, space_id) do
    table = agent_loop_table()
    key = {space_id, recipient_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, last_at}] when now - last_at < @agent_cooldown_ms ->
        Logger.info(
          "[AgentResponder] agent-to-agent cooldown active for #{recipient_id} in #{space_id}, skipping"
        )

        {:error, :agent_loop_cooldown}

      _ ->
        :ets.insert(table, {key, now})
        :ok
    end
  end

  defp check_agent_loop(_human_author, _recipient_id, _space_id), do: :ok

  defp agent_loop_table do
    case :ets.whereis(:agent_loop_cooldown) do
      :undefined -> :ets.new(:agent_loop_cooldown, [:named_table, :public, :set])
      ref -> ref
    end
  end

  defp chat_module do
    Application.get_env(:platform, :chat_agent_module, Platform.Agents.QuickAgent)
  end

  defp dispatch_mode do
    Application.get_env(:platform, :chat_agent_dispatch_mode, :async)
  end
end
