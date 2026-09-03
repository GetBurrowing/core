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
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolAuthorization
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue

  @valid_client_products ~w(openclaw claude_channel)

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
      # OTHER `RuntimePresence.track/1` call, which is the 30-second
      # `:presence_retrack` self-heal. Scheduling a drain there would re-drain
      # every connected runtime twice a minute, forever.
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
    # pushed the entire catalogue regardless of `allowed_bundles`, so the
    # advertised surface and the (HTTP-side) authorized surface disagreed.
    # `ToolAuthorization.effective_tools/1` is the same function
    # `MCPController`'s `tools/list` maps over, so the two transports now
    # advertise identically for a given runtime.
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
    RuntimePresence.track(socket.assigns.runtime_id)
    schedule_presence_retrack()
    {:noreply, socket}
  end

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
    RuntimePresence.touch(socket.assigns.runtime_id)
    agent_id = socket.assigns[:agent_id]

    Logger.info(
      "[RuntimeChannel] meeting_say_ack: agent=#{inspect(agent_id)} " <>
        "utterance=#{utterance_id} room=#{Map.get(payload, "room_name")} " <>
        "status=#{Map.get(payload, "status", "unknown")}"
    )

    Meetings.record_agent_say_ack(agent_id, payload)

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
  def handle_in("reply", %{"space_id" => space_id, "content" => content}, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)

    # Track which space this agent is actively replying in for NodeContext
    if agent_id = socket.assigns[:agent_id] do
      Platform.Federation.NodeContext.set_space(agent_id, space_id)
    end

    agent_participant_id = get_agent_participant_id(socket, space_id)

    case agent_participant_id do
      nil ->
        push(socket, "error", %{error: "Agent is not a participant in this space"})
        {:noreply, socket}

      participant_id ->
        # Stop typing indicator when reply arrives
        Platform.Chat.PubSub.broadcast(
          space_id,
          {:agent_typing, %{space_id: space_id, participant_id: participant_id, typing: false}}
        )

        Chat.post_message(%{
          space_id: space_id,
          participant_id: participant_id,
          content_type: "text",
          content: content,
          metadata: %{
            "source" => "external_runtime",
            "runtime_id" => socket.assigns.runtime_id
          }
        })

        # Refresh active agent mutex timeout on successful reply
        Platform.Chat.ActiveAgentStore.set_active(space_id, participant_id)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_in(
        "reply_chunk",
        %{"space_id" => space_id, "chunk_id" => chunk_id, "text" => text, "done" => done},
        socket
      ) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    agent_participant_id = get_agent_participant_id(socket, space_id)

    if agent_participant_id do
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
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("typing", %{"space_id" => space_id, "typing" => typing}, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
    agent_participant_id = get_agent_participant_id(socket, space_id)

    if agent_participant_id do
      Platform.Chat.PubSub.broadcast(
        space_id,
        {:agent_typing,
         %{space_id: space_id, participant_id: agent_participant_id, typing: typing}}
      )
    end

    {:noreply, socket}
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

    case authorize_tool_call(tool, socket) do
      :ok -> execute_tool_call(tool, args, call_id, socket)
      {:error, :forbidden} -> deny_tool_call(tool, call_id, socket)
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
        %{"space_id" => space_id, "content" => content, "attachments" => attachments},
        socket
      )
      when is_list(attachments) do
    alias Platform.Chat.AttachmentStorage

    agent_participant_id = get_agent_participant_id(socket, space_id)

    cond do
      is_nil(agent_participant_id) ->
        push(socket, "error", %{error: "Agent is not a participant in this space"})
        {:noreply, socket}

      not attachments_within_limits?(attachments) ->
        push(socket, "error", %{
          error: "Attachment size limits exceeded (10MB per file, 25MB total)"
        })

        {:noreply, socket}

      true ->
        # Stop typing indicator
        Platform.Chat.PubSub.broadcast(
          space_id,
          {:agent_typing,
           %{space_id: space_id, participant_id: agent_participant_id, typing: false}}
        )

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

        Chat.post_message_with_attachments(
          %{
            space_id: space_id,
            participant_id: agent_participant_id,
            content_type: "text",
            content: message_content,
            metadata: %{
              "source" => "external_runtime",
              "runtime_id" => socket.assigns.runtime_id,
              "has_media" => true
            }
          },
          attachment_attrs
        )

        # Refresh active agent mutex timeout on successful reply
        Platform.Chat.ActiveAgentStore.set_active(space_id, agent_participant_id)

        {:noreply, socket}
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

    Logger.info("[RuntimeChannel] runtime disconnected: runtime_id=#{runtime_id}")

    :telemetry.execute(
      [:platform, :federation, :runtime_disconnected],
      %{system_time: System.system_time()},
      %{runtime_id: runtime_id}
    )

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # `usage_event` payloads come from external runtimes we do not control, and
  # every `:binary_id` field on `UsageEvent` is OPTIONAL — only `model`,
  # `provider` and `session_key` are required. Cost/usage accounting is the
  # entire point of that table, so one malformed identifier must not destroy
  # an otherwise-valid record: null the offending field, keep the event.
  #
  # Observed live: `space_id: "higgins"` (a slug) from runtime
  # `rowan-home-openclaw`. Before this, that payload raised inside
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

  # Authorization gate for `tool_call`. Reads the grant FRESH on every call
  # rather than reusing the join-time `:runtime` assign, which is an
  # advertisement snapshot only.
  #
  # openclaw sockets stay joined for days (the channel re-tracks presence
  # every 30s precisely because connections outlive process restarts), so a
  # cached grant would let a capability revoked in Control Center keep
  # working until the runtime happened to reconnect — a worse failure mode
  # than the bug this closes. The cost is one primary-key `Repo.get` plus
  # the indexed `Repo.exists?` inside `Tenancy.external_user?/1`: exactly
  # what the HTTP path already pays per request.
  #
  # A vanished row denies. Fail closed, never fall through to execution.
  defp authorize_tool_call(tool, socket) do
    case Federation.get_runtime(socket.assigns.runtime_pk) do
      nil -> {:error, :forbidden}
      runtime -> ToolAuthorization.authorize(tool, runtime)
    end
  end

  defp execute_tool_call(tool, args, call_id, socket) do
    runtime_id = socket.assigns.runtime_id
    start_time = System.monotonic_time(:millisecond)

    space_id = Map.get(args, "space_id")
    agent_participant_id = get_agent_participant_id(socket, space_id)

    context = %{
      space_id: space_id,
      agent_id: socket.assigns[:agent_id],
      agent_participant_id: agent_participant_id,
      runtime_id: runtime_id
    }

    # `ToolArguments.dispatch/3`, not `ToolSurface.execute/3` — the same gate
    # `MCPController` runs, from the same module, so the two federation
    # transports cannot refuse the same malformed call differently.
    # `authorize_tool_call/2` has already run above; argument policy never
    # front-runs capability policy.
    result = ToolArguments.dispatch(tool, args, context)
    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, data} ->
        Logger.info(
          "[RuntimeChannel] tool_result ok: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id} elapsed=#{elapsed}ms"
        )

        push(socket, "tool_result", %{call_id: call_id, status: "ok", result: data})

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
  # agent as the useless generic string. The wording matches the `-32001`
  # message MCPController returns for the same refusal so both transports
  # produce identical, greppable operator-facing text.
  defp deny_tool_call(tool, call_id, socket) do
    runtime_id = socket.assigns.runtime_id

    Logger.warning(
      "[RuntimeChannel] tool_call denied: tool=#{tool} call_id=#{call_id} runtime=#{runtime_id} reason=forbidden"
    )

    :telemetry.execute(
      [:platform, :federation, :tool_call_denied],
      %{system_time: System.system_time()},
      %{runtime_id: runtime_id, tool: tool, reason: :forbidden}
    )

    push(socket, "tool_result", %{
      call_id: call_id,
      status: "error",
      error: %{error: "tool '#{tool}' not in allowed bundles", code: "forbidden"}
    })
  end

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

        {%{
           product: product,
           version: version,
           features: normalize_features(Map.get(ci, "features"))
         }, true}

      _ ->
        {%{product: "unknown", version: nil, features: []}, false}
    end
  end

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

  defp persist_client_info(runtime, %{product: product, version: version, features: features}) do
    payload = %{
      "client_info" => %{
        "product" => product,
        "version" => version,
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
