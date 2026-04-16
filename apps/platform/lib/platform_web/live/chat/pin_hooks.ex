defmodule PlatformWeb.ChatLive.PinHooks do
  @moduledoc """
  Lifecycle hook module for the Pins feature in `PlatformWeb.ChatLive`.

  See ADR 0035. Pins has distributed UI (topbar button, panel overlay,
  inline per-message pin button) so it lives as a LifecycleHook, not a
  LiveComponent. This module owns:

    * Assigns: `:pins`, `:show_pins`, `:pinned_message_ids`
    * Events:  `"pin_toggle"`, `"pin_panel_toggle"`
    * Info:    `{:pin_added, pin}`, `{:pin_removed, %{message_id: ...}}`

  PubSub subscription is handled by the parent LiveView's
  `ChatPubSub.subscribe(space_id)` call — pin messages are broadcast on
  the shared space topic, so no separate subscription is needed.

  ## Usage

      # In ChatLive.mount/3, after initial assigns:
      socket = PlatformWeb.ChatLive.PinHooks.attach(socket)

      # In ChatLive.handle_params/3, after the active_space is resolved:
      socket = PlatformWeb.ChatLive.PinHooks.load_for_space(socket, space.id)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat

  @doc """
  Attach Pin handlers to the socket. Call from `ChatLive.mount/3`.

  Sets default assigns and registers `:handle_event` / `:handle_info`
  hooks that pattern-match the Pin-namespace events and PubSub messages.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:pins, [])
    |> assign(:show_pins, false)
    |> assign(:pinned_message_ids, MapSet.new())
    |> attach_hook(:pin_events, :handle_event, &handle_event/3)
    |> attach_hook(:pin_info, :handle_info, &handle_info/2)
  end

  @doc """
  Load pins for a space. Call from `ChatLive.handle_params/3` after the
  active space is resolved.
  """
  @spec load_for_space(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def load_for_space(socket, space_id) do
    pins = Chat.list_pins(space_id)
    pinned_message_ids = MapSet.new(pins, & &1.message_id)

    socket
    |> assign(:pins, pins)
    |> assign(:show_pins, false)
    |> assign(:pinned_message_ids, pinned_message_ids)
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("pin_toggle", %{"message_id" => msg_id, "space_id" => space_id}, socket) do
    handle_event("pin_toggle", %{"message-id" => msg_id, "space-id" => space_id}, socket)
  end

  defp handle_event("pin_toggle", %{"message-id" => msg_id, "space-id" => space_id}, socket) do
    with participant when not is_nil(participant) <- socket.assigns.current_participant do
      if MapSet.member?(socket.assigns.pinned_message_ids, msg_id) do
        Chat.unpin_message(space_id, msg_id)
      else
        Chat.pin_message(%{
          space_id: space_id,
          message_id: msg_id,
          pinned_by: participant.id
        })
      end
    end

    {:halt, socket}
  end

  defp handle_event("pin_panel_toggle", _params, socket) do
    {:halt, assign(socket, :show_pins, !socket.assigns.show_pins)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:pin_added, pin}, socket) do
    pins = socket.assigns.pins ++ [pin]
    pinned_message_ids = MapSet.put(socket.assigns.pinned_message_ids, pin.message_id)

    {:halt,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)}
  end

  defp handle_info({:pin_removed, %{message_id: msg_id}}, socket) do
    pins = Enum.reject(socket.assigns.pins, &(&1.message_id == msg_id))
    pinned_message_ids = MapSet.delete(socket.assigns.pinned_message_ids, msg_id)

    {:halt,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
