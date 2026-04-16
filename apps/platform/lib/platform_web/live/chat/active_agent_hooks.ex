defmodule PlatformWeb.ChatLive.ActiveAgentHooks do
  @moduledoc """
  Lifecycle hook module for the Active Agent indicator in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Owns:

    * Assigns: `:active_agent_participant_id`, `:active_agent_name`
    * Events:  `"active_agent_clear"`
    * Info:    `{:active_agent_changed, space_id, agent_participant_id}`

  ## Cross-feature note (toggle_watch)

  `toggle_watch` is shown in the ActiveAgent UI region but its primary
  effect is on the Space (`watch_enabled` flag). The event stays on the
  parent LiveView as a coordinator — it updates `active_space` alongside
  activating/clearing the primary agent via `ActiveAgentStore`. This
  hook exposes no `toggle_watch` handler.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.ActiveAgentHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket =
        PlatformWeb.ChatLive.ActiveAgentHooks.resolve_for_space(
          socket, space.id, participants
        )
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Repo

  @doc "Attach ActiveAgent handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:active_agent_participant_id, nil)
    |> assign(:active_agent_name, nil)
    |> attach_hook(:active_agent_events, :handle_event, &handle_event/3)
    |> attach_hook(:active_agent_info, :handle_info, &handle_info/2)
  end

  @doc "Resolve the active agent for a space from `ActiveAgentStore` + space participants."
  @spec resolve_for_space(Phoenix.LiveView.Socket.t(), binary(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def resolve_for_space(socket, space_id, participants) do
    {participant_id, name} =
      case ActiveAgentStore.get_active(space_id) do
        nil -> {nil, nil}
        pid -> {pid, resolve_agent_name(pid, participants)}
      end

    socket
    |> assign(:active_agent_participant_id, participant_id)
    |> assign(:active_agent_name, name)
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("active_agent_clear", _params, socket) do
    if space = socket.assigns[:active_space] do
      ActiveAgentStore.clear_active(space.id)
    end

    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:active_agent_changed, _space_id, agent_participant_id}, socket) do
    participants = socket.assigns[:space_participants] || []
    name = resolve_agent_name(agent_participant_id, participants)

    {:halt,
     socket
     |> assign(:active_agent_participant_id, agent_participant_id)
     |> assign(:active_agent_name, name)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Name resolution ─────────────────────────────────────────────────

  defp resolve_agent_name(nil, _participants), do: nil

  defp resolve_agent_name(participant_id, participants) do
    case Enum.find(participants, &(&1.id == participant_id)) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_by_agent_id(agent_id)
      nil -> resolve_by_lookup(participant_id)
    end
  end

  defp resolve_by_agent_id(agent_id) do
    case Repo.get(Platform.Agents.Agent, agent_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Agent"
    end
  end

  defp resolve_by_lookup(participant_id) do
    case Chat.get_participant(participant_id) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_by_agent_id(agent_id)
      _ -> "Agent"
    end
  end
end
