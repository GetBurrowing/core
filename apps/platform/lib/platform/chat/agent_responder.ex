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
  alias Platform.Federation.{DeadLetters, RuntimePresence, ToolSurface}
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

      cond do
        # Cron / responsibility-triggered system_event with no chat surface.
        # The Responsibilities.Router builds these signals without
        # participant/message/space, so the chat-context dispatch paths
        # would nil-deref. Route to a runtime-broadcast-only path.
        is_nil(context.message) ->
          dispatch_system_event(signal, context)

        context.agent.runtime_type == "external" ->
          Logger.info("[AgentResponder] dispatching to external runtime")
          dispatch_to_external(signal, context)

        true ->
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
      {:agent_typing, %{space_id: space_id, participant_id: agent_participant_id, typing: true}}
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
      {:agent_typing, %{space_id: space_id, participant_id: agent_participant_id, typing: false}}
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
      {:agent_typing, %{space_id: space_id, participant_id: agent_participant_id, typing: true}}
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

          # Counted, never replayed. The chat envelope is DERIVED at dispatch
          # time from a ContextPlane bundle, a 12-message history snapshot and
          # the live tool surface; storing it would let a replay deliver a
          # stale context bundle hours later. The correct fix is to rebuild
          # from the persisted `message_id` at replay time, which is a
          # different design and a different task — so the row is written
          # terminal, with `payload: nil` and the refusal recorded as its
          # reason rather than discovered later by a policy that has nothing
          # to inspect.
          _ =
            DeadLetters.record(%{
              runtime_id: runtime.runtime_id,
              runtime_pk: runtime.id,
              agent_id: context.agent.id,
              agent_slug: context.agent.slug,
              space_id: space_id,
              source: "chat",
              payload: nil,
              disposition: "dropped_policy",
              reason: "chat_payload_not_replayable",
              occurred_at: DateTime.utc_now()
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

          trigger_attachments =
            context.message.id
            |> List.wrap()
            |> Chat.list_attachments_for_messages()
            |> Map.get(context.message.id, [])
            |> serialize_attachments()

          payload = %{
            signal: build_external_signal(signal, space_id, context.agent),
            message: %{
              content: context.user_message,
              author: author_name,
              attachments: trigger_attachments
            },
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

  # Cron / responsibility-triggered system_event. The Responsibilities.Router
  # (`Platform.Responsibilities.Router.build_native_signal/4`) constructs
  # signals without chat-context keys — only `reason: :system_event` and a
  # metadata map carrying `agent_id`, `responsibility_key`, `feature`,
  # `trigger_kind`, `agent_slug`, the rendered `prompt`, and any scalar
  # `task_id` / `plan_id` / `stage_id` / `project_id`. `metadata` is kept
  # whole here so new Router-side keys reach the runtime without a second
  # edit. Load the target agent and hand back a
  # chat-less context; downstream `dispatch_system_event/2` routes the
  # broadcast to the agent's runtime with a bare `%{signal: ...}` envelope.
  defp load_context(%{reason: :system_event, metadata: %{agent_id: agent_id} = metadata} = signal)
       when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        {:ok,
         %{
           signal: signal,
           agent: agent,
           agent_participant: nil,
           message: nil,
           user_message: nil,
           history: [],
           responsibility_key: Map.get(metadata, :responsibility_key),
           metadata: metadata
         }}

      _ ->
        Logger.warning(
          "[AgentResponder] system_event dispatch skipped — agent #{inspect(agent_id)} not found " <>
            "(responsibility=#{inspect(Map.get(metadata, :responsibility_key))})"
        )

        {:error, :ignore}
    end
  end

  # Any other signal shape (missing chat keys, missing metadata.agent_id) is
  # unroutable. Log-and-ignore so a malformed signal never crashes the
  # responder pipeline again.
  defp load_context(signal) do
    Logger.warning(
      "[AgentResponder] load_context ignoring signal with unroutable shape: " <>
        inspect(Map.take(signal, [:reason, :participant_id, :message_id, :space_id, :metadata]))
    )

    {:error, :ignore}
  end

  # ── System-event dispatch (cron / webhook / event_topic responsibility fires) ─

  # For federated / external-runtime agents (Higgins's runtime shape), broadcast
  # the responsibility fire to the agent's runtime channel with a bare
  # `%{signal: ...}` envelope — mirrors `Federation.dispatch_scribe_attention/2`
  # so the runtime side has a single well-known payload shape for
  # chat-less attention signals.
  defp dispatch_system_event(
         _signal,
         %{agent: %Agent{runtime_type: "external", runtime_id: runtime_pk} = agent} = context
       )
       when is_binary(runtime_pk) do
    responsibility_key = context[:responsibility_key]

    case Platform.Federation.get_runtime(runtime_pk) do
      nil ->
        Logger.warning(
          "[AgentResponder] system_event dispatch skipped — runtime #{runtime_pk} not found " <>
            "(agent=#{agent.slug} responsibility=#{inspect(responsibility_key)})"
        )

        {:error, :runtime_not_found}

      runtime ->
        broadcast_system_event(runtime, agent, context)
    end
  end

  defp dispatch_system_event(_signal, %{agent: %Agent{slug: slug} = agent} = context) do
    # Built-in / no-runtime agent: cron fires against these flow through the
    # deterministic responsibility handler path (e.g.
    # `Handlers.Dreaming.handle_output/3`) after `ExternalAgents.Dispatcher`
    # returns — chat-triggered dispatch doesn't apply. Log-and-skip so the
    # native dispatcher path stays a strict no-op instead of crashing.
    Logger.info(
      "[AgentResponder] built-in agent #{slug} received system_event " <>
        "responsibility=#{inspect(context[:responsibility_key])} runtime_type=#{inspect(agent.runtime_type)} — " <>
        "chat-context dispatch skipped"
    )

    :ok
  end

  defp broadcast_system_event(runtime, %Agent{} = agent, context) do
    topic = "runtime:#{runtime.runtime_id}"
    responsibility_key = context[:responsibility_key]

    # Built ONCE, before the presence branch, so what the dead-letter ledger
    # stores is byte-identical to what we would have put on the wire. Building
    # it separately inside each branch is how a replay ends up delivering
    # something subtly different from the fire it claims to be.
    payload = agent |> build_system_event_signal(context) |> build_system_event_payload()

    if RuntimePresence.online?(runtime.runtime_id) do
      Logger.info(
        "[AgentResponder] broadcasting system_event to #{topic} " <>
          "responsibility=#{inspect(responsibility_key)} agent=#{agent.slug}"
      )

      case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
        :ok ->
          :telemetry.execute(
            [:platform, :federation, :delivery_success],
            %{system_time: System.system_time()},
            %{runtime_id: runtime.runtime_id, agent_id: agent.id}
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "[AgentResponder] system_event broadcast failed to #{topic}: #{inspect(reason)}"
          )

          {:error, :broadcast_failed}
      end
    else
      Logger.error(
        "[AgentResponder] DEAD LETTER: runtime #{runtime.runtime_id} not in presence — " <>
          "system_event for agent #{agent.slug} responsibility=#{inspect(responsibility_key)} unreachable (topic=#{topic})"
      )

      metadata = context[:metadata] || %{}
      subject = DeadLetters.derive_subject(metadata)

      # The envelope is the point. Before this, the recorded map named the
      # failure (`runtime_id`, `reason`, `timestamp`) but not the work, so a
      # dead letter could be counted and never replayed.
      _ =
        DeadLetters.record(%{
          runtime_id: runtime.runtime_id,
          runtime_pk: runtime.id,
          agent_id: agent.id,
          agent_slug: agent.slug,
          space_id: nil,
          source: "system_event",
          responsibility_key: responsibility_key,
          feature: Map.get(metadata, :feature),
          trigger_kind: Map.get(metadata, :trigger_kind),
          subject_type: subject.subject_type,
          subject_id: subject.subject_id,
          payload: payload,
          reason: :runtime_offline,
          disposition: "pending",
          occurred_at: DateTime.utc_now()
        })

      :telemetry.execute(
        [:platform, :federation, :delivery_failed],
        %{system_time: System.system_time()},
        %{
          runtime_id: runtime.runtime_id,
          agent_id: agent.id,
          reason: :runtime_offline
        }
      )

      {:error, :runtime_offline}
    end
  end

  # ENVELOPE-RECORD 2/3 — system_event attention envelope
  # DECIDED: the native system_event envelope is BARE — `%{signal: signal}`, in
  #   every case. No `message`, no `history`, no `context`. `signal.prompt` is
  #   the sole named interface for the body.
  # WHY: a `message` key WAS considered here — mirroring `message.content` from
  #   `signal.prompt` so a client reading the chat shape would find the body
  #   without changing — and was deliberately not shipped. The body already has
  #   a named interface on this path: `signal.prompt`, lifted to the signal root
  #   by `build_system_event_signal/2` precisely so a federated runtime does not
  #   have to dig into `metadata` for it. Emitting both would give the server
  #   two ways to say one thing, and the next client written against this
  #   envelope would read whichever one it happened to find first. That two
  #   independently written clients both typed `message` as REQUIRED is evidence
  #   of a shared error — each encoded the only shape it had seen — not of the
  #   contract; both are converging on root-first resolution.
  # WHAT WOULD RETIRE THIS: the condition that justified declining the shim is
  #   that a client silently DROPS this envelope and swallows the throw, so a
  #   server-side mirror would have been papering over an invisible client
  #   defect. Once `019fa618-ca92` has landed and the client's error-swallowing
  #   is closed, that is no longer true, and "should the server also emit
  #   `message`?" becomes a legitimately reopenable question to be decided on
  #   its merits — deliberately, not as a merge side effect.
  # RETIREMENT STATUS 2026-07-31: MET — `019fa618-ca92` has landed. The sibling
  #   repo `openclaw-suite-channel` is at v0.6.9 (`429dfd5`), which contains fix
  #   commit `3f014a1`; its `dist/src/inbound.js` now reads
  #   `const author = payload.message?.author;` — optional-chained, where it
  #   previously read `payload.message.author` bare — and
  #   `openclaw-gateway.service` has been running that build since
  #   2026-07-31 12:40:00 CDT. What that task superseded is the REASON FOR
  #   DECLINING THE SHIM. It did not supersede this contract.
  #   THE GUARD STAYS. `build_system_event_payload/1` still returns
  #   `%{signal: signal}`, and the assertions in the sibling record below are
  #   unchanged by the task that stamped this line. A met condition makes the
  #   question askable; it does not answer it. Retiring the guard is a separate
  #   decision requiring its own argument and its own ticket — annotating a
  #   guard is not retiring one.
  # SIBLING RECORDS:
  #   1/3 core:apps/platform/test/platform/chat/agent_responder_system_event_payload_test.exs § describe "site 3 — broadcast_system_event/3" (019fa56b-c5ef)
  #   3/3 claude-code-suite-channel:src/attention.ts § makeEmitAttention (019fa618-c860)
  defp build_system_event_payload(signal), do: %{signal: signal}

  # FINDING 2026-07-27 (019fa510 stage 3) — CLOSED 2026-07-31, see the end of
  # this block. Read the paragraphs below as history: they describe the openclaw
  # client as it behaved on 2026-07-27, NOT as it behaves today. They are kept
  # rather than deleted because they are this decision's provenance and the
  # log-line forensics in them are reusable the next time an envelope goes quiet.
  #
  # Confirmed at the time against live logs on both sides: the envelope this
  # builds WAS DROPPED by the openclaw client, silently.
  #
  # `%{signal: build_system_event_signal(...)}` carries no `message` key, and
  # the openclaw client READ `payload.message.author` with no optional
  # chaining. That THREW
  # `TypeError: Cannot read properties of undefined (reading 'author')`, which
  # the client's channel layer SWALLOWED into one generic `attention handler
  # error` line. The agent never woke. This signal also lifts neither
  # `space_id` nor `task_id`, so even a client that survived that line would
  # reply into `"unknown"`.
  #
  # Evidence: every `attention handler error` line on the client side PAIRED to
  # the second with a `broadcasting system_event` line here, and no
  # `[suite-inbound]` line FOLLOWED any of them.
  #
  # The apparent counter-evidence was a different population. The surviving
  # `[suite-inbound] reason=system_event` lines exist, but every one carries
  # Higgins's system space — they come from `HistorianDispatcher`, which posts a
  # real chat message and so travels the `dispatch_to_external/2` path WITH a
  # `message` key. The two are distinguishable in this module's own log:
  # `respond called with reason=system_event signal=%{}` is the native fire that
  # DIED, `signal=%{space_id: ..., message_id: ...}` is the chat fire that LIVED.
  # Zero `space=unknown` lines existed in the whole journal, which was the proof
  # that no native envelope had ever reached the client's post-line-70 logging.
  #
  # `memory.daily_summary` / `memory.dreaming` outcomes survived this only
  # because they are still dual-written by the legacy scheduler path (see
  # `Platform.Responsibilities.CutoverMonitor`). Removing that shim before the
  # envelope is fixed would silence Higgins outright.
  #
  # CLOSED 2026-07-31 by `019fa618-ca92`. `openclaw-suite-channel` is at v0.6.9
  # (`429dfd5`), which contains fix commit `3f014a1`; `dist/src/inbound.js` now
  # reads `const author = payload.message?.author;` — optional-chained — and
  # `openclaw-gateway.service` has run that build since 2026-07-31 12:40:00 CDT.
  # The silent drop described above no longer occurs. The ENVELOPE CONTRACT IS
  # UNCHANGED by that closure — see the record above `build_system_event_payload/1`,
  # which states why the guard stays and what retiring it would require.
  defp build_system_event_signal(%Agent{} = agent, context) do
    metadata = context[:metadata] || %{}

    %{
      reason: :system_event,
      agent_id: agent.id,
      agent_slug: agent.slug
    }
    |> maybe_put(:responsibility_key, context[:responsibility_key])
    |> maybe_put(:feature, Map.get(metadata, :feature))
    |> maybe_put(:trigger_kind, Map.get(metadata, :trigger_kind))
    # The Router renders the responsibility's prompt (when its provider
    # implements `build_prompt/1`) and stashes it under `metadata.prompt`.
    # Lift it to the top level too so a federated runtime can read
    # `signal.prompt` without digging — mirrors :feature / :trigger_kind.
    # Omitted entirely when there's no rendered prompt.
    |> maybe_put(:prompt, Map.get(metadata, :prompt))
    |> lift_correlation_ids(metadata)
    |> Map.put(:metadata, metadata)
  end

  # Scalar correlation ids, lifted from `metadata` to the top level of the
  # signal — and left in `metadata` too, so no existing consumer is broken.
  #
  # Identical to `Platform.Responsibilities.Router.native_trigger_scalar_keys/0`
  # by construction (a test pins the two lists equal), because a divergence is
  # exactly the class of bug this fixes: the CHAT path already lifts `task_id`
  # in `build_external_signal/3`, this path lifted nothing, and both clients
  # encoded the chat shape. `maybe_put/3` drops nils, so a fire with no task
  # context still sends no `task_id` key rather than a nil one.
  #
  # `space_id` IS DELIBERATELY ABSENT, and must stay absent.
  # `claude-code-suite-channel`'s `src/attention.ts` pins the space a pending
  # permission prompt gets answered in from the TOP-LEVEL `signal.space_id`
  # ONLY, while resolving a mere reply target more permissively from metadata.
  # Replying is safe; re-pinning is not. A background responsibility fire that
  # lifted its own `space_id` here would silently move a live approval prompt
  # to a space nobody is watching. Adding `space_id` to this list would defeat
  # a client-side guard the client cannot defend itself against.
  @correlation_id_keys [:task_id, :plan_id, :stage_id, :project_id]

  @doc false
  # Exposed so the envelope test can pin this list against the Router's
  # whitelist rather than restating it and drifting.
  def correlation_id_keys, do: @correlation_id_keys

  defp lift_correlation_ids(signal, metadata) do
    Enum.reduce(@correlation_id_keys, signal, fn key, acc ->
      maybe_put(acc, key, Map.get(metadata, key))
    end)
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

    candidates =
      space_id
      |> Chat.list_messages(opts)
      |> Enum.reject(&(&1.id == message.id))
      |> Enum.sort_by(& &1.inserted_at, fn left, right ->
        DateTime.compare(left, right) != :gt
      end)

    attachments_by_msg =
      candidates
      |> Enum.map(& &1.id)
      |> Chat.list_attachments_for_messages()

    Enum.flat_map(candidates, fn item ->
      attachments = serialize_attachments(Map.get(attachments_by_msg, item.id, []))

      case history_message(item, agent_participant_id, attachments) do
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
         agent_id,
         attachments
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

      %{role: role, content: history_content(trimmed, message, role), attachments: attachments}
    end
  end

  defp history_message(_message, _agent_id, _attachments), do: nil

  defp serialize_attachments(attachments) do
    Enum.map(attachments, fn a ->
      %{
        url: "/chat/attachments/#{a.id}",
        content_type: a.content_type,
        byte_size: a.byte_size,
        filename: a.filename
      }
    end)
  end

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
