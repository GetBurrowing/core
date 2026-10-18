defmodule PlatformWeb.RuntimeChannel do
  @moduledoc """
  Phoenix Channel for external agent runtimes.

  Handles bidirectional communication: incoming replies and tool calls
  from the runtime, outgoing attention signals and context updates.
  """
  use Phoenix.Channel

  require Logger

  alias Platform.Analytics.UsageEvent
  alias Platform.Chat
  alias Platform.Chat.ReplyContext
  alias Platform.Chat.ReplyFailure
  alias Platform.Federation
  alias Platform.Federation.McpContent
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolCall
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue

  @valid_client_products ~w(openclaw claude_channel hermes_channel)

  # Every event core itself handles above. A frame for one of these that no
  # clause matched is malformed, not unowned, so it is dropped silently rather
  # than logged as an event no extension serves. Guarded against the
  # `handle_in/3` clauses by `test/platform/extensions_test.exs`.
  @core_events ~w(pong meeting_join_ack meeting_say_ack meeting_transcript_ack intent_delivered reply reply_chunk typing tool_call reply_with_media execution_event meeting_leave usage_event)

  @doc false
  # Read by `Platform.Extensions.validate/0` (an extension may not claim one).
  def core_events, do: @core_events

  @unowned_text "no installed extension owns this event; further unowned frames on this " <>
                  "channel are dropped silently"

  # Bounds on the declared capability set in `client_info.features`.
  #
  # `features` arrives from a client-supplied join payload and lands in a
  # jsonb column, so an unbounded list is a free row-bloat vector for any
  # party that can complete a handshake. Entries over the byte cap are
  # dropped individually (a hostile entry must not take a legitimate one
  # with it) and the list is truncated after sorting, so which entries
  # survive is deterministic.
  #
  # Deliberately NOT an allowlist of known feature names: capabilities are
  # an open set that grows every time a client ships something, and an
  # allowlist would mean every new client capability needs a server deploy
  # before it could be reported. These bounds are the abuse surface cap.
  @max_client_features 32
  @max_client_feature_bytes 64

  # Max byte size of a client-declared `build` identifier (a plugin commit
  # sha, or a release string). A full sha is 40 bytes and a semver-ish tag
  # is well under that, so 64 — the same bound as a feature name — is
  # generous. Same rationale as above: this is an abuse-surface cap on
  # free text we did not author, not a format check.
  #
  # An over-long value is REJECTED to nil, never truncated. A truncated
  # sha is still a syntactically valid sha, so truncating would
  # manufacture a plausible-looking identifier that points at no commit.
  # Absent is honest; wrong-but-well-formed is not.
  @max_client_build_bytes 64

  # Max byte size of a client-declared `build_error` — the client's own
  # short reason why it could NOT resolve its build (no .git, missing stamp
  # file). Unlike `build`, an over-long value is TRUNCATED (at a UTF-8
  # boundary), not rejected: a truncated reason is still a true statement,
  # whereas dropping it would demote a client that honestly said "I tried
  # and could not" to one that "predates the contract" — the exact
  # distinction `AgentRuntime.client_build_status/1` exists to keep.
  @max_client_build_error_bytes 200

  # How often to re-affirm this runtime's presence from the live channel
  # process. Belt-and-suspenders against RuntimePresence Agent crashes /
  # hot-reloads that would otherwise leave the map permanently empty.
  # 30s matches the Phoenix Socket transport heartbeat cadence — same
  # order of magnitude, no meaningful load.
  @presence_retrack_interval_ms 30_000

  @impl true
  def join("runtime:" <> runtime_id, params, socket) do
    if runtime_id == socket.assigns.runtime_id do
      {client_info, declared?} = resolve_client_info(params)
      socket = assign(socket, :client_info, client_info)

      # Load the row ONCE and stash it. It drives the last_connected_at
      # touch, the client_info persist and the connect log line below, and
      # — via the `:runtime` assign — the bundle-scoped `capabilities`
      # push in handle_info(:send_capabilities, _). A nil here means the
      # row vanished between RuntimeSocket.connect/3 and join/3; the join
      # still succeeds (unchanged semantics) but the capabilities push
      # fails closed to an empty set.
      runtime = Federation.get_runtime(socket.assigns.runtime_pk)
      socket = assign(socket, :runtime, runtime)

      # Ensure the runtime's agent has a last_connected_at timestamp
      if runtime do
        Platform.Agents.AgentRuntime.changeset(runtime, %{
          last_connected_at: DateTime.utc_now()
        })
        |> Platform.Repo.update()

        # Persist client_info only when the joining runtime actually
        # declared something. Legacy bridges that connect without a
        # client_info payload stay "unknown"/absent so we can tell the
        # difference between "they explicitly said unknown" and "we
        # haven't heard from them yet".
        if declared? do
          persist_client_info(runtime, client_info)
        end

        agent_name =
          case runtime.agent_id && Platform.Repo.get(Platform.Agents.Agent, runtime.agent_id) do
            %{name: name} -> name
            _ -> nil
          end

        Logger.info(
          "[RuntimeChannel] runtime connected: runtime_id=#{runtime_id} " <>
            "agent=#{inspect(agent_name)} client_product=#{client_info.product}"
        )
      end

      RuntimePresence.track(runtime_id)

      :telemetry.execute(
        [:platform, :federation, :runtime_connected],
        %{system_time: System.system_time()},
        %{runtime_id: runtime_id}
      )

      # Notify the task board so the watcher can re-dispatch to this runtime
      Platform.Tasks.broadcast_board({:runtime_reconnected, runtime_id})

      # Drain anything that was dead-lettered while this runtime was away
      # (task 019fa56b-ca2d stage 3). A `cast`, so join/3 never blocks on a
      # Repo read — and deliberately here in join/3 rather than beside the
      # 30-second `:presence_retrack` self-heal. Scheduling a drain there would
      # re-drain every connected runtime twice a minute, forever.
      Platform.Federation.DeadLetterReplay.schedule(runtime_id)

      # Push capabilities after join completes (push/3 not allowed during join/3)
      send(self(), :send_capabilities)

      # Periodically re-affirm presence from this live channel process.
      # `track/1` only runs at join time; if the RuntimePresence Agent crashes
      # or is hot-reloaded, the map resets to %{} but every live channel process
      # keeps running (transport heartbeats keep the socket alive, so no
      # rejoin fires). Without this retrack, receive-only runtimes (which
      # never emit an inbound frame that would touch/1) stay presence-empty
      # forever, and AgentResponder.dispatch_to_external dead-letters DMs
      # and @mentions to them.
      schedule_presence_retrack()

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info(:send_capabilities, socket) do
    # Advertise only what this runtime may actually call. Previously this
    # pushed the entire catalogue regardless of `tool_profile`, so the
    # advertised surface and the (HTTP-side) authorized surface disagreed.
    # `ToolAuthorization.effective_tools/1` is the same function
    # `MCPController`'s `tools/list` maps over, so for a given runtime the two
    # transports advertise the same tool NAMES.
    #
    # NAMES, not CONTENT — and that distinction cost a ticket. The `push/3`
    # below ships each definition map WHOLE, so a WS runtime reads all four
    # prose fields (`description`, `returns`, `limitations`, `when_to_use`) as
    # separate keys. `MCPController.to_mcp_tool/1` projects onto the MCP tool
    # object, a closed schema with no key for the other three, and until
    # `Platform.Federation.ToolDoc.render_description/1` landed (task
    # 01a08a0c) it dropped them outright: identical names, a quarter of the
    # prose. The two transports agree on content only since that renderer, and
    # they agree by REACHABILITY, not by shape — WS still carries the fields as
    # separate keys while MCP carries them folded into `description`. That
    # residual asymmetry is named here on purpose: this comment previously
    # ended "the two transports now advertise identically for a given
    # runtime", and that unqualified sentence is why three dropped fields
    # stayed invisible. Both halves are pinned by
    # `test/security/transport_capability_parity_test.exs`.
    #
    # Fail closed on a missing row: an absent runtime gets an empty set,
    # never the full surface.
    {tools, external?} =
      case socket.assigns[:runtime] do
        nil ->
          {[], false}

        runtime ->
          {ToolAuthorization.effective_tools(runtime),
           ToolAuthorization.external_principal?(runtime)}
      end

    push(socket, "capabilities", %{tools: tools, tool_count: length(tools)})

    # Emitted so a surprise shrink in prod is observable directly rather
    # than inferred from a log grep.
    :telemetry.execute(
      [:platform, :federation, :capabilities_pushed],
      %{tool_count: length(tools)},
      %{runtime_id: socket.assigns.runtime_id, external: external?}
    )

    send(self(), :send_spaces_manifest)
    {:noreply, socket}
  end

  def handle_info(:send_spaces_manifest, socket) do
    agent_id = socket.assigns[:agent_id]

    if agent_id do
      spaces = Chat.list_spaces_for_agent(agent_id)

      payload =
        Enum.map(spaces, fn s ->
          %{id: s.id, name: s.name, kind: s.kind}
        end)

      push(socket, "spaces_manifest", %{spaces: payload})
    end

    {:noreply, socket}
  end

  def handle_info(:presence_retrack, socket) do
    # `touch/1`, not `track/1`: this fires every 30s for the life of the
    # connection, and `track/1` is an unconditional whole-entry overwrite that
    # would rewrite `connected_at` on every tick — making it a rolling 30s
    # clock rather than the session start. `touch/1` upserts when the entry is
    # missing (the Agent-crash case this self-heal exists for) and otherwise
    # advances only `last_seen_at`. Task 01a06d03-e5d5-7001-aba3-703cfd232b9d.
    RuntimePresence.touch(socket.assigns.runtime_id)
    schedule_presence_retrack()
    {:noreply, socket}
  end

  # Deliberately `touch/1` and NOT `prove/2`. A heartbeat evidences a live
  # socket and nothing else: every runtime that is connected at all sends
  # one, so proving a capability here would mark every cell observed for
  # every runtime, forever, and destroy the only signal that discriminates
  # a stale build from a current one.
  @impl true
  def handle_in("pong", _payload, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    {:noreply, socket}
  end

  @impl true
  def handle_in("meeting_join_ack", %{"room_name" => room_name} = payload, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    agent_id = socket.assigns[:agent_id]
    status = Map.get(payload, "status", "joined")

    Logger.info(
      "[RuntimeChannel] meeting_join_ack: agent=#{inspect(agent_id)} room=#{room_name} status=#{status}"
    )

    :telemetry.execute(
      [:platform, :meetings, :agent_join_ack],
      %{system_time: System.system_time()},
      %{agent_id: agent_id, room_name: room_name, status: status}
    )

    # The receipt has to reach the SCREEN, not just the log (task 01a0554f).
    # Until this call, a `status: "error"` ack was logged here and dropped,
    # while `PlatformWeb.MeetingLive` went on showing "… is joining the
    # meeting." Core held the disproof of its own flash and never used it.
    #
    # Still fire-and-forget, in the shape of the two acks either side of it:
    # a receipt that cannot be landed is not something the runtime can act
    # on, so nothing is pushed back down the socket.
    Meetings.record_agent_join_ack(agent_id, room_name, status)

    {:noreply, socket}
  end

  # The receipt for a `meeting_say` dispatch (task 01a06672 stage 2). Same
  # shape as the join ack above, with one difference worth naming: the log
  # line carries the utterance id and never the text. The text is already in
  # core's hands (`Platform.Meetings.SayRegistry`), and a spoken sentence is
  # not something to duplicate into the log stream.
  #
  # The whole payload is handed over rather than picked apart here, so the
  # keys a worker may send (`status`, `duration_s`, `error`) are read in one
  # place — `Meetings.record_agent_say_ack/2` — and the waiting caller in
  # `Meetings.say/4` is what this receipt is for. Fire-and-forget, like the
  # join ack: nothing is pushed back down the socket.
  @impl true
  def handle_in("meeting_say_ack", %{"utterance_id" => utterance_id} = payload, socket) do
    # Gated on the OUTCOME the ack reports, not on its arrival (task
    # 01a06f53). The inbound-frame reasoning is sound and unchanged: this is
    # a frame the runtime sent, so it is evidence and not a claim. But what
    # an ack evidences unconditionally is "the worker is connected and ran
    # the say-ack code path" — which is liveness, and `touch/1` is what
    # liveness is for. Proving the capability off arrival alone turned
    # `meeting_voice` green from an ack whose own `status` said the utterance
    # FAILED: found live 2026-09-05, where three says returned `no_ack`, the
    # worker was never joined to the LiveKit room, `federation_status`
    # reported the capability proven, and the human heard nothing.
    #
    # `prove/2` advances `last_seen_at` exactly as `touch/1` does, so the two
    # branches are the same presence write plus or minus the capability
    # stamp; neither rewrites `connected_at`.
    if Meetings.say_ack_spoken?(payload) do
      RuntimePresence.prove(socket.assigns.runtime_id, "meeting_voice")
    else
      RuntimePresence.touch(socket.assigns.runtime_id)
    end

    agent_id = socket.assigns[:agent_id]

    Logger.info(
      "[RuntimeChannel] meeting_say_ack: agent=#{inspect(agent_id)} " <>
        "utterance=#{utterance_id} room=#{Map.get(payload, "room_name")} " <>
        "status=#{Map.get(payload, "status", "unknown")}"
    )

    Meetings.record_agent_say_ack(agent_id, payload)

    {:noreply, socket}
  end

  # The receipt for a `meeting_transcript` frame (task 01a06dfb stage 2).
  #
  # This is the ONLY thing that can prove `meeting_transcript`. Core
  # broadcasts the transcript frame outbound from
  # `Meetings.deliver_transcript_segment/2` and, until this ack existed,
  # never heard anything back — so a plugin older than `63229eb`, which
  # drops the frame in silence while sending a byte-identical
  # `client_info`, was indistinguishable from one that heard the room.
  # Stamping the proof at the broadcast site would be core certifying its
  # own outbound send; the comment there says so, and
  # `transcript_delivery_test.exs` holds it.
  #
  # `prove/2` rather than `touch/1`, for the same reason as the say ack
  # above: `prove/2` advances `last_seen_at` exactly as `touch/1` does and
  # additionally stamps the capability, so it replaces the touch rather
  # than accompanying it.
  #
  # Fire-and-forget in the shape of the acks around it. The payload also
  # carries `room_name` and `build` (the plugin's package.json version);
  # both are logged and neither is persisted here, and nothing is pushed
  # back down the socket.
  @impl true
  def handle_in("meeting_transcript_ack", %{"segment_id" => segment_id} = payload, socket)
      when is_binary(segment_id) do
    RuntimePresence.prove(socket.assigns.runtime_id, "meeting_transcript")

    Logger.info(
      "[RuntimeChannel] meeting_transcript_ack: agent=#{inspect(socket.assigns[:agent_id])} " <>
        "segment=#{segment_id} room=#{Map.get(payload, "room_name")} " <>
        "build=#{Map.get(payload, "build", "unknown")}"
    )

    {:noreply, socket}
  end

  # The delivery receipt for a meeting intent (task 019ff292 stage 2).
  #
  # Send this at the moment the intent is SURFACED TO THE AGENT'S LOOP,
  # not when the bytes land on the socket. The distinction is the whole
  # point: an agent mid-turn on unrelated work cannot act on a dispatch
  # that arrived ninety seconds ago, and before this receipt existed
  # every one of those milliseconds came out of the responder's own ack
  # window. Receipting on socket arrival would restore that defect while
  # looking like a fix.
  #
  # Deliberately does NOT change the row's status: the responder has
  # read the dispatch, not accepted it. `intent_ack` is still the thing
  # that says what the responder is doing about it.
  #
  # Fire-and-forget in the same shape as `meeting_join_ack` — a receipt
  # the queue cannot land (the row already timed out, the meeting ended)
  # is logged, not pushed back. There is nothing the runtime could do
  # with the error that it will not learn from `intent_ack` anyway.
  @impl true
  def handle_in("intent_delivered", %{"intent_id" => intent_id}, socket)
      when is_binary(intent_id) do
    RuntimePresence.touch(socket.assigns.runtime_id)

    case IntentQueue.locate(intent_id) do
      {:ok, meeting_id} ->
        log_intent_delivered(intent_id, IntentQueue.mark_delivered(meeting_id, intent_id))

      {:error, :not_found} ->
        Logger.debug(
          "[RuntimeChannel] intent_delivered for an unknown intent — intent_id=#{intent_id}"
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("reply", %{"space_id" => space_id, "content" => content} = params, socket) do
    # Proven at the top of the clause, before the participant check below:
    # the capability under test is "this build can emit a chat reply", and a
    # well-formed inbound `reply` frame settles that whether or not the agent
    # turns out to be a participant of the space it named.
    RuntimePresence.prove(socket.assigns.runtime_id, "chat_reply")

    # Track which space this agent is actively replying in for NodeContext
    if agent_id = socket.assigns[:agent_id] do
      Platform.Federation.NodeContext.set_space(agent_id, space_id)
    end

    case authorize_space_write(socket, space_id) do
      {:error, error_map} ->
        # Kept for older bridges that only listen for the out-of-band event.
        # It carries no correlation to the push that caused it, which is why
        # the `{:reply, {:error, ...}}` below exists alongside it.
        push(socket, "error", %{error: error_map.error})
        {:reply, {:error, error_map}, socket}

      {:ok, participant_id} ->
        # Stop typing indicator when reply arrives
        Platform.Chat.PubSub.broadcast_agent_typing(space_id, participant_id, false)

        # Optional reply annotations (task 01a0d8de). Invalid ones are dropped
        # and reported in the ack; the message itself always posts.
        {reply_additions, dropped} = ReplyContext.normalize(params, space_id, participant_id)

        case Chat.post_message(%{
               space_id: space_id,
               participant_id: participant_id,
               content_type: "text",
               content: content,
               metadata:
                 Map.merge(
                   %{
                     "source" => "external_runtime",
                     "runtime_id" => socket.assigns.runtime_id
                   },
                   reply_additions
                 )
             }) do
          {:ok, message} ->
            # Refresh active agent mutex timeout on successful reply
            Platform.Chat.ActiveAgentStore.set_active(space_id, participant_id)

            {:reply, {:ok, reply_ack(message.id, space_id, dropped)}, socket}

          {:error, changeset} ->
            error_map = %{
              error: "Failed to post message: #{inspect(changeset_errors(changeset))}",
              recoverable: false
            }

            push(socket, "error", %{error: error_map.error})
            {:reply, {:error, error_map}, socket}
        end
    end
  end

  @impl true
  def handle_in(
        "reply_chunk",
        %{"space_id" => space_id, "chunk_id" => chunk_id, "text" => text, "done" => done},
        socket
      ) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    # Turn activity for the no-reply watchdog (task 01a10322 stage 7).
    ReplyFailure.Watchdog.activity(socket.assigns[:agent_id])

    case authorize_space_write(socket, space_id) do
      {:error, error_map} ->
        push(socket, "error", %{error: error_map.error})
        {:reply, {:error, error_map}, socket}

      {:ok, agent_participant_id} ->
        Platform.Chat.PubSub.broadcast(
          space_id,
          {:agent_reply_chunk,
           %{
             space_id: space_id,
             chunk_id: chunk_id,
             text: text,
             done: done,
             participant_id: agent_participant_id
           }}
        )

        # A chunk is an ephemeral PubSub broadcast with no persisted row, so
        # there is no message_id to hand back — a bare `:ok` is the whole ack.
        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("typing", %{"space_id" => space_id, "typing" => typing}, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    # Turn activity for the no-reply watchdog (task 01a10322 stage 7).
    ReplyFailure.Watchdog.activity(socket.assigns[:agent_id])

    case authorize_space_write(socket, space_id) do
      {:error, error_map} ->
        push(socket, "error", %{error: error_map.error})
        {:reply, {:error, error_map}, socket}

      {:ok, agent_participant_id} ->
        # `typing` is raw client input; the producer takes a boolean, so
        # anything that is not literally `true` is "stopped".
        Platform.Chat.PubSub.broadcast_agent_typing(
          space_id,
          agent_participant_id,
          typing == true
        )

        # Ephemeral broadcast, nothing persisted: no message_id exists to return.
        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in(
        "tool_call",
        %{"call_id" => call_id, "tool" => tool, "args" => args},
        socket
      )
      when is_map(args) do
    require Logger
    runtime_id = socket.assigns.runtime_id

    Logger.info(
      "[RuntimeChannel] tool_call received: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id}"
    )

    RuntimePresence.touch(runtime_id)
    # Turn activity for the no-reply watchdog (task 01a10322 stage 7).
    ReplyFailure.Watchdog.activity(socket.assigns[:agent_id])

    case Federation.get_runtime(socket.assigns.runtime_pk) do
      # A vanished row denies. Fail closed, never fall through to execution.
      nil -> deny_tool_call(tool, call_id, socket)
      runtime -> execute_tool_call(tool, args, call_id, runtime, socket)
    end

    {:noreply, socket}
  end

  def handle_in("tool_call", %{"call_id" => call_id, "tool" => tool, "args" => args}, socket) do
    require Logger

    Logger.warning(
      "[RuntimeChannel] tool_call #{tool} received non-map args (#{inspect(args)}), " <>
        "expected a map with tool parameters"
    )

    push(socket, "tool_result", %{
      call_id: call_id,
      status: "error",
      error: %{
        error: "Invalid args: expected a map with tool parameters, got #{inspect(args)}"
      }
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "reply_with_media",
        %{"space_id" => space_id, "content" => content, "attachments" => attachments} = params,
        socket
      )
      when is_list(attachments) do
    alias Platform.Chat.AttachmentStorage

    # The authorization check is deliberately the OUTER gate: the
    # attachment-size branch sits strictly inside the `{:ok, _}` arm so an
    # unauthorized caller never learns whether its payload was within limits.
    case authorize_space_write(socket, space_id) do
      {:error, error_map} ->
        # Kept for older bridges that only listen for the out-of-band event.
        push(socket, "error", %{error: error_map.error})
        {:reply, {:error, error_map}, socket}

      {:ok, agent_participant_id} ->
        if not attachments_within_limits?(attachments) do
          error_map = %{
            error: "Attachment size limits exceeded (10MB per file, 25MB total)",
            recoverable: false
          }

          push(socket, "error", %{error: error_map.error})
          {:reply, {:error, error_map}, socket}
        else
          # Stop typing indicator
          Platform.Chat.PubSub.broadcast_agent_typing(space_id, agent_participant_id, false)

          # Decode and persist each attachment
          attachment_results =
            Enum.map(attachments, fn att ->
              with {:ok, data} <- Base.decode64(att["data"] || ""),
                   tmp_path = write_temp_file(data),
                   {:ok, stored} <-
                     AttachmentStorage.persist_upload(
                       tmp_path,
                       att["filename"],
                       att["content_type"]
                     ) do
                File.rm(tmp_path)
                {:ok, stored}
              else
                _error -> {:error, :attachment_failed}
              end
            end)

          # Filter successful attachments
          attachment_attrs =
            attachment_results
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, attrs} -> attrs end)

          message_content = content || ""

          {reply_additions, dropped} =
            ReplyContext.normalize(params, space_id, agent_participant_id)

          case Chat.post_message_with_attachments(
                 %{
                   space_id: space_id,
                   participant_id: agent_participant_id,
                   content_type: "text",
                   content: message_content,
                   metadata:
                     Map.merge(
                       %{
                         "source" => "external_runtime",
                         "runtime_id" => socket.assigns.runtime_id,
                         "has_media" => true
                       },
                       reply_additions
                     )
                 },
                 attachment_attrs
               ) do
            {:ok, message, _attachments} ->
              # Refresh active agent mutex timeout on successful reply
              Platform.Chat.ActiveAgentStore.set_active(space_id, agent_participant_id)

              {:reply, {:ok, reply_ack(message.id, space_id, dropped)}, socket}

            {:error, reason} ->
              error_map = %{
                error: "Failed to post message: #{inspect(reason)}",
                recoverable: false
              }

              push(socket, "error", %{error: error_map.error})
              {:reply, {:error, error_map}, socket}
          end
        end
    end
  end

  @impl true
  def handle_in("execution_event", params, socket) when is_map(params) do
    RuntimePresence.touch(socket.assigns.runtime_id)

    attrs =
      params
      |> Map.put("runtime_id", socket.assigns.runtime_id)
      |> Map.put_new("occurred_at", DateTime.utc_now() |> DateTime.to_iso8601())

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, event} ->
        push(socket, "execution_event_ack", %{
          idempotency_key: event.idempotency_key,
          status: "ok"
        })

      {:error, reason} ->
        push(socket, "execution_event_ack", %{
          idempotency_key: Map.get(attrs, "idempotency_key"),
          status: "error",
          error: inspect(reason)
        })
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("meeting_leave", %{"room_name" => room_name}, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    agent_id = socket.assigns[:agent_id]

    Logger.info("[RuntimeChannel] meeting_leave: agent=#{inspect(agent_id)} room=#{room_name}")

    :telemetry.execute(
      [:platform, :meetings, :agent_leave],
      %{system_time: System.system_time()},
      %{agent_id: agent_id, room_name: room_name}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in("usage_event", params, socket) when is_map(params) do
    Logger.info("[RuntimeChannel] usage_event received: #{inspect(Map.keys(params))}")

    # Enrich with agent_id from the socket if not provided
    attrs =
      params
      |> Map.put_new("agent_id", socket.assigns[:agent_id])
      |> sanitize_uuid_fields(socket.assigns.runtime_id)

    case Platform.Analytics.record_usage_event(attrs) do
      {:ok, event} ->
        Logger.info("[RuntimeChannel] usage_event recorded: #{event.id}")

      {:error, changeset} ->
        Logger.warning("[RuntimeChannel] usage_event failed: #{inspect(changeset.errors)}")
    end

    {:noreply, socket}
  end

  # ── Extension frames (ADR 0055; Play's since task 01a0db5f stage 2) ──
  #
  # Every event no clause above matched. One an extension owns
  # (`Platform.Extensions.runtime_event_owner/1`) goes to that extension,
  # which checks, e.g., that the SENDING runtime speaks only for its own
  # session. One no extension owns, or one whose owner answers `{:inert,
  # text}` (installed but switched off), is logged ONCE per channel process
  # per owner (a runtime that keeps sending must not flood the log) and
  # dropped; the channel stays joined. A malformed frame for one of core's
  # own events (`@core_events`) is dropped silently, as it always was.
  def handle_in(event, payload, socket) when is_map(payload) do
    case Platform.Extensions.runtime_event_owner(event) do
      nil ->
        if event in @core_events,
          do: {:noreply, socket},
          else: {:noreply, log_dropped_event(socket, :unowned, event, @unowned_text)}

      extension ->
        RuntimePresence.touch(socket.assigns.runtime_id)

        case extension.handle_runtime_event(event, socket.assigns.runtime_id, payload) do
          {:inert, text} ->
            {:noreply, log_dropped_event(socket, extension, event, text)}

          result ->
            log_runtime_event_result(event, result)
            {:noreply, socket}
        end
    end
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  defp log_intent_delivered(intent_id, {:ok, %{delivered_at: delivered_at}}) do
    Logger.info(
      "[RuntimeChannel] intent_delivered: intent_id=#{intent_id} " <>
        "delivered_at=#{inspect(delivered_at)}"
    )
  end

  defp log_intent_delivered(intent_id, {:error, reason}) do
    Logger.info(
      "[RuntimeChannel] intent_delivered could not be landed — intent_id=#{intent_id} " <>
        "reason=#{inspect(reason)}"
    )
  end

  @impl true
  def terminate(_reason, socket) do
    runtime_id = socket.assigns.runtime_id
    RuntimePresence.untrack(runtime_id)

    # Every extension hears that this runtime went away (a play host that
    # goes away fails its session). Always `:ok`, never raises, including
    # when an extension's own processes have already stopped.
    Platform.Extensions.runtime_disconnected(runtime_id)

    Logger.info("[RuntimeChannel] runtime disconnected: runtime_id=#{runtime_id}")

    :telemetry.execute(
      [:platform, :federation, :runtime_disconnected],
      %{system_time: System.system_time()},
      %{runtime_id: runtime_id}
    )

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp log_dropped_event(socket, owner, event, text) do
    logged = socket.assigns[:dropped_events_logged] || MapSet.new()

    if MapSet.member?(logged, owner) do
      socket
    else
      # `warning`, not `info`: a runtime sending frames this install does not
      # serve is a misconfiguration an operator should see, and it is logged
      # at most once per channel process per owner.
      Logger.warning(
        "[RuntimeChannel] #{event} from runtime_id=#{socket.assigns.runtime_id} dropped: #{text}"
      )

      assign(socket, :dropped_events_logged, MapSet.put(logged, owner))
    end
  end

  defp log_runtime_event_result(event, {:error, reason}) do
    Logger.info("[RuntimeChannel] #{event} dropped: #{inspect(reason)}")
  end

  defp log_runtime_event_result(_event, _ok), do: :ok

  # `usage_event` payloads come from external runtimes we do not control, and
  # every `:binary_id` field on `UsageEvent` is OPTIONAL — only `model`,
  # `provider` and `session_key` are required. Cost/usage accounting is the
  # entire point of that table, so one malformed identifier must not destroy
  # an otherwise-valid record: null the offending field, keep the event.
  #
  # Observed live: `space_id: "higgins"` (a slug) from runtime
  # `home-openclaw`. Before this, that payload raised inside
  # `Repo.insert` and killed the channel process.
  #
  # The Logger.warning is load-bearing. Nulling a value the client supplied
  # IS data loss, and silent coercion is exactly how a client-side bug
  # survives indefinitely. Warn level, naming the runtime, the field and the
  # offending value, so whoever owns that runtime can fix the sender.
  defp sanitize_uuid_fields(attrs, runtime_id) do
    Enum.reduce(UsageEvent.uuid_fields(), attrs, fn field, acc ->
      key = Atom.to_string(field)

      case Map.get(acc, key) do
        nil ->
          acc

        value ->
          if UsageEvent.valid_uuid?(value) do
            acc
          else
            Logger.warning(
              "[RuntimeChannel] usage_event #{key}=#{inspect(value)} is not a valid UUID; " <>
                "recording event with #{key}=nil (runtime_id=#{runtime_id})"
            )

            Map.put(acc, key, nil)
          end
      end
    end)
  end

  # `tool_call` goes through `ToolCall.invoke/4` (task 01a114a8 stage 1),
  # the same path `MCPController` uses: `ToolAuthorization.authorize/2`, then
  # `ToolArguments.dispatch/3`, then the ledger row. Only the FRAMING of each
  # outcome lives here.
  #
  # The runtime row is read FRESH on every call (in `handle_in/3` above)
  # rather than reusing the join-time `:runtime` assign, which is an
  # advertisement snapshot only. openclaw sockets stay joined for days (the
  # channel re-tracks presence every 30s precisely because connections
  # outlive process restarts), so a cached grant would let a capability
  # revoked in Control Center keep working until the runtime happened to
  # reconnect. The cost is one primary-key `Repo.get` plus the indexed
  # `Repo.exists?` inside `Tenancy.external_user?/1`: exactly what the HTTP
  # path already pays per request. The handler context is built from that
  # fresh row too (`ToolCall.build_context/2`).
  defp execute_tool_call(tool, args, call_id, runtime, socket) do
    runtime_id = socket.assigns.runtime_id
    start_time = System.monotonic_time(:millisecond)

    result = ToolCall.invoke(tool, args, runtime)
    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, data} ->
        Logger.info(
          "[RuntimeChannel] tool_result ok: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id} elapsed=#{elapsed}ms"
        )

        # Drop the `/mcp`-only image-block marker (task 01a0fcfa). This
        # transport has no image blocks: the openclaw plugin JSON-stringifies
        # `result` into one text block, so the marker would only leak a
        # reserved key. `data_base64` stays, so an eligible image's payload
        # equals the handler's pre-marker map.
        push(socket, "tool_result", %{
          call_id: call_id,
          status: "ok",
          result: McpContent.strip(data)
        })

      {:error, :forbidden} ->
        deny_tool_call(tool, call_id, socket)

      {:error, error} ->
        Logger.warning(
          "[RuntimeChannel] tool_result error: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id} elapsed=#{elapsed}ms error=#{inspect(error)}"
        )

        push(socket, "tool_result", %{call_id: call_id, status: "error", error: error})
    end
  end

  # Denial frame shape is load-bearing: the message MUST sit at `error.error`
  # as a string, because openclaw-suite-channel's suite-client.ts rejects with
  # `payload.error?.error || "Tool call failed"`. Any other shape reaches the
  # agent as the useless generic string. `ToolAuthorization.deny_message/1`
  # is the same call `MCPController` makes for the same refusal, so both
  # transports produce identical, greppable operator-facing text — and the
  # `code` field stays `"forbidden"` for both denial shapes, unchanged, since
  # no client should be keying different behavior off it.
  defp deny_tool_call(tool, call_id, socket) do
    runtime_id = socket.assigns.runtime_id
    reason = ToolAuthorization.deny_reason(tool)
    reason_tag = deny_reason_tag(reason)

    Logger.warning(
      "[RuntimeChannel] tool_call denied: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id} reason=#{reason_tag}"
    )

    :telemetry.execute(
      [:platform, :federation, :tool_call_denied],
      %{system_time: System.system_time()},
      %{runtime_id: runtime_id, tool: tool, reason: reason_tag}
    )

    push(socket, "tool_result", %{
      call_id: call_id,
      status: "error",
      error: %{error: ToolAuthorization.deny_message(tool), code: "forbidden"}
    })
  end

  # Telemetry-only projection of `ToolAuthorization.deny_reason/1` down to
  # the bare atom the `[:platform, :federation, :tool_call_denied]` metadata
  # carries — the suggestion (if any) is in the message text, not here.
  defp deny_reason_tag(:forbidden), do: :forbidden
  defp deny_reason_tag({:unknown_tool, _suggestion}), do: :unknown_tool

  defp schedule_presence_retrack do
    Process.send_after(self(), :presence_retrack, @presence_retrack_interval_ms)
  end

  @max_attachment_size 10 * 1024 * 1024
  @max_total_size 25 * 1024 * 1024

  defp attachments_within_limits?(attachments) do
    sizes =
      Enum.map(attachments, fn att ->
        # Base64 data size ≈ 3/4 of encoded string length
        byte_size(att["data"] || "")
      end)

    Enum.all?(sizes, &(&1 <= div(@max_attachment_size * 4, 3))) and
      Enum.sum(sizes) <= div(@max_total_size * 4, 3)
  end

  defp write_temp_file(data) do
    tmp_path = Path.join(System.tmp_dir!(), "runtime-upload-#{Ecto.UUID.generate()}")
    File.write!(tmp_path, data)
    tmp_path
  end

  # Authorize an agent-originated WRITE into `space_id`.
  #
  # The lookup itself is delegated to `get_agent_participant_id/2`. The refusal
  # map is built by `ToolSurface.space_write_denied/1`, the single definition
  # shared with the ToolSurface read gate, send_media and react, so a caller sees
  # one wording (and the offending id) whichever transport it used.
  # The ok-ack of `reply` / `reply_with_media`. `dropped` is added ONLY when a
  # reply annotation was refused, so a frame without the new keys gets exactly
  # the ack shape it got before task 01a0d8de.
  defp reply_ack(message_id, space_id, []), do: %{message_id: message_id, space_id: space_id}

  defp reply_ack(message_id, space_id, dropped),
    do: %{message_id: message_id, space_id: space_id, dropped: dropped}

  defp authorize_space_write(socket, space_id) do
    case get_agent_participant_id(socket, space_id) do
      nil ->
        {:error, ToolSurface.space_write_denied(space_id)}

      participant_id ->
        {:ok, participant_id}
    end
  end

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp get_agent_participant_id(socket, space_id) do
    agent_id = socket.assigns[:agent_id]

    if is_nil(agent_id) or is_nil(space_id) do
      nil
    else
      case Chat.get_agent_participant(space_id, agent_id) do
        %Chat.Participant{id: id} -> id
        _ -> nil
      end
    end
  end

  # Resolve params["client_info"] into a normalized {info, declared?} pair.
  #
  # `declared?` is true iff the joining client supplied a `client_info`
  # map at all. We use it to skip persistence for legacy bridges so the
  # row's metadata stays untouched (more honest signal than persisting a
  # bogus "unknown" they never sent).
  defp resolve_client_info(params) do
    case params do
      %{"client_info" => %{} = ci} ->
        product =
          case Map.get(ci, "product") do
            p when p in @valid_client_products -> p
            _ -> "unknown"
          end

        version =
          case Map.get(ci, "version") do
            v when is_binary(v) -> v
            _ -> nil
          end

        raw_build = Map.get(ci, "build")
        build = normalize_build(raw_build)

        {%{
           product: product,
           version: version,
           build: build,
           build_error: resolve_build_error(build, raw_build, Map.get(ci, "build_error")),
           started_at: normalize_started_at(Map.get(ci, "started_at")),
           features: normalize_features(Map.get(ci, "features"))
         }, true}

      _ ->
        {%{
           product: "unknown",
           version: nil,
           build: nil,
           build_error: nil,
           started_at: nil,
           features: []
         }, false}
    end
  end

  # Why this runtime has no build, or nil.
  #
  #   * a usable `build` was declared  => nil. A reported build carries no
  #     error, whatever else the client sent.
  #   * the client sent its own `build_error` => that reason, bounded.
  #   * the client sent a `build` core could not accept (not a non-empty
  #     binary, or over the byte cap) and no reason of its own => a
  #     core-authored reason. The client IS on the build contract and tried;
  #     reporting it as "not_reported" (predates the contract) would be false.
  #   * otherwise nil — the client said nothing about its build at all.
  defp resolve_build_error(build, _raw_build, _raw_error) when is_binary(build), do: nil

  defp resolve_build_error(nil, raw_build, raw_error) do
    case normalize_build_error(raw_error) do
      nil when not is_nil(raw_build) ->
        "core rejected client_info.build: not a non-empty string of at most " <>
          "#{@max_client_build_bytes} bytes"

      error ->
        error
    end
  end

  # Normalize a client-declared build error into a bounded binary, or nil.
  # Non-binaries, blank strings and invalid UTF-8 degrade to nil rather than
  # raising — a hostile payload must not be a denial of service on the
  # handshake. See @max_client_build_error_bytes for why this truncates.
  defp normalize_build_error(error) when is_binary(error) do
    trimmed = String.trim(error)

    if trimmed != "" and String.valid?(trimmed),
      do: truncate_utf8(trimmed, @max_client_build_error_bytes),
      else: nil
  end

  defp normalize_build_error(_), do: nil

  defp truncate_utf8(string, max) when byte_size(string) <= max, do: string
  defp truncate_utf8(string, max), do: drop_partial_codepoint(binary_part(string, 0, max))

  defp drop_partial_codepoint(bin) do
    if String.valid?(bin),
      do: bin,
      else: drop_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # Normalize a client-declared build identifier — the plugin commit sha or
  # release string that says WHICH build of the client is running — into a
  # bounded binary, or nil.
  #
  # Non-binaries (a number, a map, nil), the empty string, and anything over
  # @max_client_build_bytes all degrade to nil rather than raising: like
  # `features`, a hostile payload here must not be a denial of service on
  # the handshake.
  #
  # WHAT A BUILD HAS TO BE for this to be worth anything: a constant baked
  # into the client bundle at BUILD time, so it names the code actually
  # loaded in the process. A client that computes it at join time by reading
  # disk (`git rev-parse`, a file read) reports what is CHECKED OUT, not what
  # is running — it would report the new sha for a process that never
  # restarted, which is one of the two failure modes this task exists to
  # expose. Core cannot enforce that from here; it is a contract on the
  # client, stated so the receiving side is not read as a guarantee.
  defp normalize_build(build) when is_binary(build) do
    if build != "" and byte_size(build) <= @max_client_build_bytes, do: build, else: nil
  end

  defp normalize_build(_), do: nil

  # Parse a client-declared PROCESS start time (ISO8601) into a UTC
  # `DateTime`, or nil.
  #
  # This is a different fact from every timestamp already on the row.
  # Presence `connected_at` and `agent_runtimes.last_connected_at` are
  # CONNECTION ages: they reset on every socket blip while the OS process
  # keeps running, which is exactly why a long-lived process on a stale
  # build reads as freshly started. `started_at` is the age of the process
  # itself, so "has this runtime picked up the build we shipped?" becomes
  # answerable. Both must survive; neither substitutes for the other.
  #
  # There is deliberately NO `DateTime.utc_now()` fallback on a parse
  # failure. A fabricated process-start time is strictly WORSE than an
  # absent one: nil renders as "unknown", while a synthesized now() renders
  # as "just restarted" — the precise false reassurance this field exists
  # to prevent. `DateTime.from_iso8601/1` already normalizes a non-UTC
  # offset to UTC, so no further shifting is needed (and no tz database is
  # required).
  #
  # `build` and `started_at` cover two failure modes, and neither field
  # covers both:
  #
  #   (a) the client checkout is BEHIND the shipped fix. `build` catches
  #       this, provided it is baked in at build time (see normalize_build/1).
  #   (b) the checkout is current but the process was never restarted, so the
  #       old code is still resident. ONLY `started_at` catches this: a
  #       process that started before the fix landed cannot be running it,
  #       whatever is on disk. No version, feature list, or disk read can
  #       detect (b) at all.
  #
  # READ THIS BEFORE RENDERING `started_at` ANYWHERE. The two modes are NOT
  # mutually exclusive, so `started_at` is a ONE-WAY test and must never be
  # displayed as if it answered "is this runtime current?" on its own:
  #
  #   * started_at EARLIER than the fix  => REFUTES freshness. Sound. The
  #     process cannot be running code that did not exist when it booted.
  #   * started_at LATER than the fix    => proves NOTHING. Unsound.
  #
  # Measured counterexample (2026-09-04, a second host): a runtime process
  # started 2026-09-03 21:06, six hours AFTER plugin commit 63229eb merged
  # upstream at 15:07Z, and still could not hear a meeting — its local
  # checkout was behind, so a post-merge restart loaded July code. "Restarted
  # after the fix landed" is therefore not evidence of having the fix.
  # Inferring freshness from a recent `started_at` reproduces exactly the
  # false-positive this ticket exists to kill, one level up.
  #
  # So `build` is the LOAD-BEARING field: it names the code actually loaded.
  # `started_at` is a qualifier on `build`, not a substitute for it, and is
  # kept because it is the only thing that detects (b) — a stale process
  # whose checkout has since been updated, where `build` (baked in at build
  # time) still honestly reports the OLD sha but nothing else says why.
  #
  # Corollary for anything server-side: core cannot resolve the sha itself.
  # The plugin checkout has no fixed path across hosts (observed at both
  # `~/projects/claude-code-suite-channel` and
  # `~/.local/share/suite/claude-code-suite-channel`), and reading disk would
  # report what is CHECKED OUT rather than what is RUNNING anyway. It has to
  # arrive in the handshake, which is what this function receives.
  defp normalize_started_at(started_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, %DateTime{} = dt, _utc_offset} -> dt
      _ -> nil
    end
  end

  defp normalize_started_at(_), do: nil

  # Normalize a client-declared capability list into a bounded, sorted,
  # deduplicated list of binaries. Anything that is not a list — a map,
  # nil, a bare string, a list of integers — degrades to `[]` rather than
  # raising: a hostile capability payload must not be a denial of service
  # on the handshake.
  defp normalize_features(features) when is_list(features) do
    features
    |> Enum.filter(fn
      feature when is_binary(feature) ->
        feature != "" and byte_size(feature) <= @max_client_feature_bytes

      _ ->
        false
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_client_features)
  end

  defp normalize_features(_), do: []

  defp persist_client_info(runtime, %{
         product: product,
         version: version,
         build: build,
         build_error: build_error,
         started_at: started_at,
         features: features
       }) do
    payload = %{
      "client_info" => %{
        "product" => product,
        "version" => version,
        # `build` and `started_at` together answer "is the capability we
        # shipped actually loaded in this process?" — which `version`
        # alone cannot, because a plugin release only takes effect when
        # the client process restarts.
        #
        # Both are written unconditionally, including as nil, and both
        # follow the replace-not-merge rule described below: a process
        # that rejoins on an older build must LOSE its newer claim.
        #
        # `started_at` is stored as an ISO8601 string (jsonb has no
        # timestamp type); `AgentRuntime.client_started_at/1` parses it
        # back. It is the CLIENT PROCESS start time and is deliberately
        # NOT the same fact as `last_seen_at` below, presence
        # `connected_at`, or the `last_connected_at` column — those are
        # connection ages and reset on a reconnect that never restarted
        # anything.
        "build" => build,
        # Why there is no `build` (client-reported, or core's rejection of an
        # unusable one); nil whenever `build` is set. Same replace-not-merge
        # rule: a rejoin that reports a build clears a prior error, and a
        # rejoin that reports an error LOSES the prior build.
        # `AgentRuntime.client_build_status/1` reads the pair.
        "build_error" => build_error,
        "started_at" => started_at && DateTime.to_iso8601(started_at),
        # `features` is ALWAYS written, including as `[]`.
        #
        # `Federation.update_metadata/2` is shallow at the top level, so
        # setting "client_info" REPLACES the whole nested map. A runtime
        # that downgrades to a build without the capability and rejoins
        # therefore loses its recorded claim. That is CORRECT, not a bug:
        # it genuinely no longer has the capability.
        #
        # Do NOT "fix" this by deep-merging to preserve `features` — that
        # would let a stale claim outlive the build that earned it, which
        # destroys the only property this record exists to provide. The
        # separate case of a legacy client that sends no `client_info` at
        # all is handled by the `declared?` gate in join/3, which skips
        # this write entirely so "never told us" stays distinguishable
        # from "told us it lacks the feature".
        "features" => features,
        "last_seen_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    case Federation.update_metadata(runtime, payload) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("[RuntimeChannel] failed to persist client_info: #{inspect(reason)}")

        :ok
    end
  end
end
