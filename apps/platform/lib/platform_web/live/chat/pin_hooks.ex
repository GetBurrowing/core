defmodule PlatformWeb.ChatLive.PinHooks do
  @moduledoc """
  Lifecycle hook module for the Pins feature in `PlatformWeb.ChatLive`.

  See ADR 0035. Pins has distributed UI (the space sheet's and the details
  panel's Pinned pages, the inline per-message pin button) so it lives as a
  LifecycleHook, not a LiveComponent. This module owns:

    * Assigns: `:pins`, `:pinned_message_ids`
    * Events:  `"pin_toggle"`

  The desktop pins drawer and its `pin_panel_toggle` / `:show_pins` were
  deleted in Burrow redesign 22 stage 4 (the details panel's Pinned page
  replaced them).
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
  alias PlatformWeb.ChatLive.MessagesHooks

  @doc """
  Attach Pin handlers to the socket. Call from `ChatLive.mount/3`.

  Sets default assigns and registers `:handle_event` / `:handle_info`
  hooks that pattern-match the Pin-namespace events and PubSub messages.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:pins, [])
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
    # No reinsert needed here: MessagesHooks.enter_space (called immediately
    # before this in chat_live.ex's space-enter pipeline) does
    # stream(:messages, ..., reset: true) which re-renders every row from
    # scratch. Re-rendering them again right after would be redundant.
    pins = Chat.list_pins(space_id)
    pinned_message_ids = MapSet.new(pins, & &1.message_id)

    socket
    |> assign(:pins, pins)
    |> assign(:pinned_message_ids, pinned_message_ids)
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("pin_toggle", %{"message_id" => msg_id, "space_id" => space_id}, socket) do
    handle_event("pin_toggle", %{"message-id" => msg_id, "space-id" => space_id}, socket)
  end

  defp handle_event("pin_toggle", %{"message-id" => msg_id, "space-id" => space_id}, socket) do
    # `space_id` is whatever the client sent. The authorization that makes that
    # safe lives in `Chat.pin_message/2` and `Chat.unpin_message/3`, NOT here,
    # so every future caller of those functions inherits it. Adding the check
    # in this hook instead would protect exactly one caller.
    #
    # `current_participant` is retained as an AFFORDANCE check — it answers
    # "is this session actually in a conversation" for the button that renders
    # here — and is no longer the authorization. It is membership of the space
    # being VIEWED, which is a different question from the one the write asks.
    actor = {:user, socket.assigns.user_id}

    with participant when not is_nil(participant) <- socket.assigns.current_participant do
      if MapSet.member?(socket.assigns.pinned_message_ids, msg_id) do
        Chat.unpin_message(actor, space_id, msg_id)
      else
        # `:pinned_by` is deliberately absent: `pin_message/2` derives it from
        # the participant it resolved in the TARGET space, so a pin can never
        # be attributed to a participant of the space the session is viewing.
        Chat.pin_message(actor, %{space_id: space_id, message_id: msg_id})
      end
    end

    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:pin_added, pin}, socket) do
    pins = socket.assigns.pins ++ [pin]
    pinned_message_ids = MapSet.put(socket.assigns.pinned_message_ids, pin.message_id)

    {:halt,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)
     |> MessagesHooks.reinsert_stream_messages(filtered_for_rendered(socket, [pin.message_id]),
       space_id: MessagesHooks.active_space_id(socket)
     )}
  end

  defp handle_info({:pin_removed, %{message_id: msg_id}}, socket) do
    pins = Enum.reject(socket.assigns.pins, &(&1.message_id == msg_id))
    pinned_message_ids = MapSet.delete(socket.assigns.pinned_message_ids, msg_id)

    {:halt,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)
     |> MessagesHooks.reinsert_stream_messages(filtered_for_rendered(socket, [msg_id]),
       space_id: MessagesHooks.active_space_id(socket)
     )}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # Filter message ids to those currently rendered in the :messages stream.
  # Prevents stream_reinsert_with_day_label from falling through to
  # stream_insert_with_day_label and silently INSERTING a non-DOM message
  # out-of-order — e.g. when another user pins a message older than the
  # current client's loaded chat window. See task 019e2740 (this batch)
  # for the architect-flagged hazard.
  defp filtered_for_rendered(socket, ids) do
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()
    Enum.filter(ids, &MapSet.member?(rendered, &1))
  end
end
