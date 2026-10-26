defmodule PlatformWeb.ChatLive.MessageActionsHooks do
  @moduledoc """
  Lifecycle hook module for the per-message actions surface (redesign rung
  9, task 01a1557a-9406 stage 2): the phone 'Message' bottom sheet and the
  desktop ⋯ popover, both rendered by
  `PlatformWeb.ChatLive.Partials.Overlays.message_actions_sheet/1` from the
  ONE assign below, so the two frames cannot disagree about which message
  is open.

  `attach/1` also attaches `MessageAttentionHooks` ("Get someone's
  attention", redesign rung 12), the picker the sheet's second row opens,
  and `ReplyHooks` (the main-log 'Reply' to an agent message, task 01a174f5
  stage 2), so neither needs a line in the ratcheted `chat_live.ex`.

  `open_message_actions` / `close_message_actions` were moved here from
  `ChatLive` in place; `delete_message` is new. Stage 3 added the reactors
  sheet and `open_inline_thread`.

  ## Assigns owned

    * `:open_message_actions_id` — nil when closed, else the message id.
    * `:open_message_actions_msg` — the message struct, re-read on open, so
      the rows can gate on author and content type at render.
    * `:open_message_actions_mine` — the emoji the viewer has already
      reacted with on that message (the quick strip's 'mine' state).
    * `:open_reactors` — nil when closed, else
      `%{message_id, emoji, reactors, extra_count}` for the 'Reacted <emoji>'
      sheet and popover (`Overlays.reactors_sheet/1`).

  ## Events

    * `open_message_actions` {id} — from the tap pill's ⋯, a long-press or
      a double-tap (`MessageGestures`).
    * `close_message_actions`
    * `delete_message` {message-id} — the server NEVER trusts the client
      for this: the message is re-read, must be in the active space and not
      already deleted, and `Chat.authorize_author/2` must pass for the
      viewer's `current_participant`. Anything else is refused silently.
      The row leaves the stream through the `{:message_deleted, msg}`
      broadcast `Chat.delete_message/1` sends, which `MessagesHooks`
      already handles for every viewer.
    * `open_reactors` {message-id, emoji} — a long-press on a reaction pill
      (`ReactorPopover`). The reactors are RE-READ from the database with
      `MessagesHooks.reaction_group/3`, the builder that renders the pills,
      and the message must be in the active space. Nothing the client sent
      but the two ids is used, so a forged or stale `data-reactors` JSON
      cannot reach the sheet. It closes the actions sheet, so one sheet is
      open at a time.
    * `close_reactors`
    * `open_inline_thread` {message-id} — Reply in thread (the tap pill's ↩
      and the sheet's row). It OPENS the inline thread and focuses its reply
      box through `MessagesHooks.expand_inline_thread/3`, and never collapses
      one that is already open: that is the thread chip's toggle. It
      replaced the `open_thread` alias of the toggle, deleted in place.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias Platform.Chat.Message
  alias PlatformWeb.ChatLive.MessageAttentionHooks
  alias PlatformWeb.ChatLive.MessagesHooks
  alias PlatformWeb.ChatLive.ReplyHooks

  @doc "Attach the message-actions handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> close()
    |> assign(:open_reactors, nil)
    |> attach_hook(:message_actions_events, :handle_event, &handle_event/3)
    |> MessageAttentionHooks.attach()
    |> ReplyHooks.attach()
  end

  defp handle_event("open_message_actions", %{"id" => msg_id}, socket) when is_binary(msg_id) do
    case Chat.get_message(msg_id) do
      %Message{deleted_at: nil} = msg ->
        {:halt,
         socket
         |> assign(:open_message_actions_id, msg.id)
         |> assign(:open_message_actions_msg, msg)
         |> assign(:open_message_actions_mine, mine(msg, socket.assigns[:current_participant]))}

      _ ->
        {:halt, close(socket)}
    end
  end

  defp handle_event("close_message_actions", _params, socket), do: {:halt, close(socket)}

  defp handle_event("delete_message", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    participant = socket.assigns[:current_participant]
    space = socket.assigns[:active_space]

    with %{id: space_id} <- space,
         %Message{deleted_at: nil, space_id: ^space_id} = msg <- Chat.get_message(msg_id),
         :ok <- Chat.authorize_author(msg, participant) do
      _ = Chat.delete_message(msg)
      {:halt, close(socket)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("delete_message", _params, socket), do: {:halt, socket}

  defp handle_event("open_reactors", %{"message-id" => msg_id, "emoji" => emoji}, socket)
       when is_binary(msg_id) and is_binary(emoji) do
    case active_space_message(socket, msg_id) do
      %Message{} = msg ->
        group = MessagesHooks.reaction_group(socket, msg.id, emoji)

        {:halt,
         socket
         |> close()
         |> assign(:open_reactors, %{
           message_id: msg.id,
           emoji: emoji,
           reactors: group.reactors,
           extra_count: group.extra_count
         })}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_event("open_reactors", _params, socket), do: {:halt, socket}

  defp handle_event("close_reactors", _params, socket),
    do: {:halt, assign(socket, :open_reactors, nil)}

  defp handle_event("open_inline_thread", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    case active_space_message(socket, msg_id) do
      %Message{} = msg -> {:halt, MessagesHooks.expand_inline_thread(socket, msg.id)}
      nil -> {:halt, socket}
    end
  end

  defp handle_event("open_inline_thread", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # The message, if it is live and in the space the viewer has open.
  defp active_space_message(socket, msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         %Message{deleted_at: nil, space_id: ^space_id} = msg <- Chat.get_message(msg_id) do
      msg
    else
      _ -> nil
    end
  end

  defp close(socket) do
    socket
    |> assign(:open_message_actions_id, nil)
    |> assign(:open_message_actions_msg, nil)
    |> assign(:open_message_actions_mine, MapSet.new())
  end

  defp mine(_msg, nil), do: MapSet.new()

  defp mine(%Message{id: id}, %{id: participant_id}) do
    id
    |> Chat.list_reactions()
    |> Enum.filter(&(&1.participant_id == participant_id))
    |> MapSet.new(& &1.emoji)
  end
end
