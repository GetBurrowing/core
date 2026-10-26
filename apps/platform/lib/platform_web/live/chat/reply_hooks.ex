defmodule PlatformWeb.ChatLive.ReplyHooks do
  @moduledoc """
  Lifecycle hook module for STARTING a main-log reply to an agent's message
  (task 01a174f5 stage 2). A main-log reply is an ordinary top-level message
  whose `metadata["reply_to_message_id"]` names the agent message it answers
  (stage 1, `Platform.Chat.ReplyTarget`); the attention router routes it to
  that agent and the answer lands in the main log, not in a thread.

  Attached by `PlatformWeb.ChatLive.MessageActionsHooks.attach/1`, so it
  runs from `ChatLive.mount/3` without a line in the ratcheted
  `chat_live.ex`.

  ## Assigns owned

    * `:reply_target` — nil, or `%{message_id, author, preview, agent_slot,
      space_id}` for the composer's 'Replying to <author>' chip
      (`Partials.Composer.reply_chip/1`). `space_id` is the space the target
      was set in: the send path and the chip use the target only while that
      space is the active one.

  ## Events

    * `start_reply` {message-id} — from the tap pill's Reply (agent messages
      only) and the sheet / popover 'Reply' row. Nothing the client sent but
      the id is used: the message is RE-READ with the viewer's
      `external_scope` and must be in the active space, not deleted,
      top-level and agent-authored (its participant's `participant_type` is
      `"agent"`, the rule `ReplyTarget.validate/3` applies at the write).
      Anything else is refused silently and the current target is kept.
      It never opens a thread. Focusing the composer is client-side
      (`JS.focus/1` chained on the button), so no hook JS is added.
    * `cancel_reply` — the chip's x and Escape (`phx-window-keydown` on the
      chip, rendered only while a target is set).

  ## Cleared

    * on `cancel_reply`;
    * on a successful main-composer send (`MessagesHooks`' `send_message`
      calls `clear/1`);
    * on entering a different space (`MessagesHooks.enter_space/3` and
      `enter_space_anchored/4` call `clear_unless_space/2`, both entry
      points of `ChatLive`'s space funnel).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.QuotedMessage

  @doc "Attach the reply handlers. Called from `MessageActionsHooks.attach/1`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:reply_target, nil)
    |> attach_hook(:reply_events, :handle_event, &handle_event/3)
  end

  @doc "Drop the reply target."
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: assign(socket, :reply_target, nil)

  @doc "Drop the reply target unless it was set in `space_id`."
  @spec clear_unless_space(Phoenix.LiveView.Socket.t(), binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def clear_unless_space(socket, space_id) do
    case socket.assigns[:reply_target] do
      %{space_id: ^space_id} -> socket
      _ -> clear(socket)
    end
  end

  @doc """
  The `:reply_to_message_id` for a main-composer send: the target's message
  id while its space is the active one, else nil. Thread sends never call
  this.
  """
  @spec reply_to_message_id(Phoenix.LiveView.Socket.t()) :: binary() | nil
  def reply_to_message_id(socket) do
    with %{message_id: id, space_id: space_id} <- socket.assigns[:reply_target],
         %{id: ^space_id} <- socket.assigns[:active_space] do
      id
    else
      _ -> nil
    end
  end

  defp handle_event("start_reply", %{"message-id" => msg_id}, socket) when is_binary(msg_id) do
    case reply_target(socket, msg_id) do
      %{} = target -> {:halt, assign(socket, :reply_target, target)}
      nil -> {:halt, socket}
    end
  end

  defp handle_event("start_reply", _params, socket), do: {:halt, socket}

  defp handle_event("cancel_reply", _params, socket), do: {:halt, clear(socket)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # The target, if `msg_id` names a live, top-level, agent-authored message
  # in the active space that the viewer's scope can read.
  defp reply_target(socket, msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         %Message{deleted_at: nil, thread_id: nil, space_id: ^space_id} = msg <-
           Chat.get_message(msg_id, scope: socket.assigns[:external_scope]),
         author_id when is_binary(author_id) <- msg.participant_id,
         %Participant{participant_type: "agent"} <- Chat.get_participant(author_id) do
      %{
        message_id: msg.id,
        space_id: space_id,
        author: PresenceHooks.sender_name(socket.assigns[:participants_map] || %{}, msg),
        preview: QuotedMessage.preview(msg.content),
        agent_slot:
          Platform.Agents.ColorPalette.slot_for(
            Map.get(socket.assigns[:agent_slots_map] || %{}, msg.participant_id)
          )
      }
    else
      _ -> nil
    end
  end
end
