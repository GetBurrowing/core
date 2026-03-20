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
      end

      RuntimePresence.track(runtime_id)

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("reply", %{"space_id" => space_id, "content" => content}, socket) do
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

        # Enter/extend sticky engagement after successful reply
        Chat.engage_agent(
          space_id,
          participant_id,
          String.slice(content, 0, 200)
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("typing", %{"space_id" => space_id, "typing" => typing}, socket) do
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
  def handle_in("tool_call", %{"call_id" => call_id, "tool" => tool, "args" => args}, socket) do
    space_id = Map.get(args, "space_id")
    agent_participant_id = get_agent_participant_id(socket, space_id)

    context = %{
      space_id: space_id,
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

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    RuntimePresence.untrack(socket.assigns.runtime_id)
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

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
