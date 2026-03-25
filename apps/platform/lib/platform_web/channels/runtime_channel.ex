defmodule PlatformWeb.RuntimeChannel do
  @moduledoc """
  Phoenix Channel for external agent runtimes.

  Handles bidirectional communication: incoming replies and tool calls
  from the runtime, outgoing attention signals and context updates.
  """
  use Phoenix.Channel

  require Logger

  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolSurface

  @impl true
  def join("runtime:" <> runtime_id, _params, socket) do
    if runtime_id == socket.assigns.runtime_id do
      # Ensure the runtime's agent has a last_connected_at timestamp
      if runtime = Federation.get_runtime(socket.assigns.runtime_pk) do
        Platform.Agents.AgentRuntime.changeset(runtime, %{
          last_connected_at: DateTime.utc_now()
        })
        |> Platform.Repo.update()

        agent_name =
          case runtime.agent_id && Platform.Repo.get(Platform.Agents.Agent, runtime.agent_id) do
            %{name: name} -> name
            _ -> nil
          end

        Logger.info(
          "[RuntimeChannel] runtime connected: runtime_id=#{runtime_id} agent=#{inspect(agent_name)}"
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

      # Push capabilities after join completes (push/3 not allowed during join/3)
      send(self(), :send_capabilities)

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info(:send_capabilities, socket) do
    tools = ToolSurface.tool_definitions()
    push(socket, "capabilities", %{tools: tools, tool_count: length(tools)})
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

  @impl true
  def handle_in("pong", _payload, socket) do
    RuntimePresence.touch(socket.assigns.runtime_id)
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
          {:agent_typing, %{participant_id: participant_id, typing: false}}
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
        {:agent_typing, %{participant_id: agent_participant_id, typing: typing}}
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
    RuntimePresence.touch(socket.assigns.runtime_id)
    space_id = Map.get(args, "space_id")
    agent_participant_id = get_agent_participant_id(socket, space_id)

    context = %{
      space_id: space_id,
      agent_id: socket.assigns[:agent_id],
      agent_participant_id: agent_participant_id
    }

    result = ToolSurface.execute(tool, args, context)

    case result do
      {:ok, data} ->
        push(socket, "tool_result", %{call_id: call_id, status: "ok", result: data})

      {:error, error} ->
        push(socket, "tool_result", %{call_id: call_id, status: "error", error: error})
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
          {:agent_typing, %{participant_id: agent_participant_id, typing: false}}
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
  def handle_in("usage_event", params, socket) when is_map(params) do
    require Logger
    Logger.info("[RuntimeChannel] usage_event received: #{inspect(Map.keys(params))}")

    # Enrich with agent_id from the socket if not provided
    attrs =
      params
      |> Map.put_new("agent_id", socket.assigns[:agent_id])

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
      case Chat.ensure_agent_participant(space_id, agent_id) do
        {:ok, participant} -> participant.id
        _ -> nil
      end
    end
  end
end
