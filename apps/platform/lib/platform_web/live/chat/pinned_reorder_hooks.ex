defmodule PlatformWeb.ChatLive.PinnedReorderHooks do
  @moduledoc """
  Desktop reorder of the pinned conversations (task 01a1557b, Burrow
  redesign 25). Attached from `ChatListHooks.attach/1`, the same lifecycle
  hook shape (ADR 0035).

  Only the CONVERSATION run of Pinned reorders: task rows keep recency and
  every other section keeps recency (`Partials.ChatList` `## Order`). The
  order lives in the existing `chat_pinned_spaces` preference, written
  through `Sidebar.move_pinned_space/3`; other sessions of the user converge
  on the existing `:sidebar_changed` broadcast.

  Owns:

    * `"move_pinned_row"` `%{"space_id", "to_position"}`: `to_position` is
      the 0-based position in the RENDERED conversation run after the move
      (`ChatLive.pinned_conversation_entries/2`), an integer or an integer
      string. Translated to the stored list with
      `PinnedSpaces.destination_index/3`, so ids the list does not render
      keep their place.
    * `"move_pinned_step"` `%{"space_id", "direction" => "up" | "down"}`: the
      same move by one place.
    * `"undo_pinned_order"`: restores the list from before the burst's first
      move with `Sidebar.restore_pinned_order/2`, but only while the stored
      list still equals the one this session last wrote. If another tab or
      device changed pins inside the window it writes nothing and says so.
    * `{:pinned_undo_expired, ref}`: ends the burst when `ref` is current; a
      stale ref is ignored.
    * `@pinned_undo`: `nil | %{previous: ids, written: ids, ref: reference()}`.
      The first accepted move of a burst snapshots the stored list before
      writing; later moves keep that snapshot and replace `written` and `ref`.
      Every accepted move re-arms a `undo_ms/0` timer.
    * `@pinned_announcement`: `nil | String.t()`, "<name> moved to position
      <n> of <count>" with the row's DISPLAYED name (masked while names are
      masked, the person's name for a DM).

  A move is IGNORED (no write, no broadcast, no undo state, no announcement)
  when the id is not in the rendered conversation run (unpinned, a task
  space, the Agents space, unknown), when the position is not an integer in
  `0..count-1` or equals the current one, and when the session has no user
  row.

  Every message and event it does not own continues with `{:cont, socket}`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat.PinnedSpaces
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Sidebar
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.Partials.ChatList

  @undo_ms 5_000

  @doc "How long a burst's undo stays available, in milliseconds."
  def undo_ms, do: @undo_ms

  @doc "Seed `@pinned_undo` and `@pinned_announcement` and attach the handlers."
  def attach(socket) do
    socket
    |> assign(:pinned_undo, nil)
    |> assign(:pinned_announcement, nil)
    |> attach_hook(:pinned_reorder_events, :handle_event, &handle_event/3)
    |> attach_hook(:pinned_reorder_info, :handle_info, &handle_info/2)
  end

  @doc """
  Where `space_id` sits in the rendered conversation run, as
  `%{index: n, count: m}` (0-based), or nil when it is not a pinned
  conversation (unpinned, a task space, the Agents space, unknown, or nil).
  The desktop row menu reads it to offer and disable Move up / Move down.
  """
  def move_position(_pinned_conversations, _pinned_task_spaces, nil), do: nil

  def move_position(pinned_conversations, pinned_task_spaces, space_id) do
    pinned_conversations
    |> ChatLive.pinned_conversation_entries(pinned_task_spaces)
    |> Enum.find_value(fn
      %{space: %{id: ^space_id}, move_index: index, move_count: count} ->
        %{index: index, count: count}

      _ ->
        nil
    end)
  end

  defp handle_event("move_pinned_row", %{"space_id" => id, "to_position" => n}, socket)
       when is_binary(id) do
    {:halt, move(socket, id, fn _current -> parse_position(n) end)}
  end

  defp handle_event("move_pinned_step", %{"space_id" => id, "direction" => dir}, socket)
       when is_binary(id) do
    step =
      case dir do
        "up" -> -1
        "down" -> 1
        _ -> nil
      end

    # The row menu's Move up / Move down push this; the menu closes with the
    # click whether or not the move is accepted.
    socket = move(socket, id, fn current -> step && current + step end)
    {:halt, assign(socket, :row_actions_space_id, nil)}
  end

  defp handle_event("undo_pinned_order", _params, socket), do: {:halt, undo(socket)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:pinned_undo_expired, ref}, socket) do
    case socket.assigns[:pinned_undo] do
      %{ref: ^ref} -> {:halt, assign(socket, :pinned_undo, nil)}
      _ -> {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp parse_position(n) when is_integer(n), do: n

  defp parse_position(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_position(_), do: nil

  # `target_fun` maps the row's current position to the requested one (nil
  # when the request means nothing).
  defp move(socket, id, target_fun) do
    run = conversation_run(socket.assigns)
    count = length(run)

    with %{move_index: current} = entry <- Enum.find(run, &(&1.space.id == id)),
         to when is_integer(to) and to >= 0 and to < count and to != current <-
           target_fun.(current),
         user_id when is_binary(user_id) <- socket.assigns[:user_id],
         stored = Sidebar.list_pinned_space_ids(user_id),
         rendered = run |> Enum.map(& &1.space.id) |> List.delete(id) |> List.insert_at(to, id),
         index when is_integer(index) <- PinnedSpaces.destination_index(stored, id, rendered),
         {:ok, _} <- Sidebar.move_pinned_space(user_id, id, index) do
      written = Sidebar.list_pinned_space_ids(user_id)
      ChatPubSub.broadcast_sidebar_changed_from(user_id, self())

      socket
      |> ChatLive.recompute_pinned()
      |> arm_undo(stored, written)
      |> assign(
        :pinned_announcement,
        "#{shown_name(socket, entry)} moved to position #{to + 1} of #{count}"
      )
    else
      _ -> socket
    end
  end

  defp arm_undo(socket, stored, written) do
    ref = make_ref()
    Process.send_after(self(), {:pinned_undo_expired, ref}, @undo_ms)

    previous =
      case socket.assigns[:pinned_undo] do
        %{previous: previous} -> previous
        _ -> stored
      end

    assign(socket, :pinned_undo, %{previous: previous, written: written, ref: ref})
  end

  defp undo(socket) do
    user_id = socket.assigns[:user_id]

    case socket.assigns[:pinned_undo] do
      %{previous: previous, written: written} when is_binary(user_id) ->
        if Sidebar.list_pinned_space_ids(user_id) == written do
          _ = Sidebar.restore_pinned_order(user_id, previous)
          ChatPubSub.broadcast_sidebar_changed_from(user_id, self())

          socket
          |> ChatLive.recompute_pinned()
          |> assign(:pinned_undo, nil)
          |> assign(:pinned_announcement, "Pinned order restored")
        else
          socket
          |> assign(:pinned_undo, nil)
          |> assign(:pinned_announcement, "Pinned order changed elsewhere, undo unavailable")
        end

      _ ->
        socket
    end
  end

  defp conversation_run(assigns) do
    ChatLive.pinned_conversation_entries(
      assigns.channel_sections.pinned,
      assigns.pinned_task_spaces
    )
  end

  # The name the row shows: the unmasked row name through the same mask.
  defp shown_name(socket, %{kind: kind, space: space}) do
    name = ChatList.row_name(kind, space, socket.assigns[:list_identities] || %{})
    ChatLive.masked_space_name(socket.assigns, name)
  end
end
