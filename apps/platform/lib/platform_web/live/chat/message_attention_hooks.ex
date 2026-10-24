defmodule PlatformWeb.ChatLive.MessageAttentionHooks do
  @moduledoc """
  Lifecycle hook module for "Get someone's attention" (redesign rung 12,
  task 01a1557a-a30a stage 2): a member asks agents or people to look at an
  already-sent message without editing it. The server side is
  `Platform.Chat.add_message_attention/4` (stage 1).

  Attached by `PlatformWeb.ChatLive.MessageActionsHooks.attach/1`, so it
  runs from `ChatLive.mount/3` without a line in `chat_live.ex` (its code
  lines are ratcheted).

  ## Assigns owned

    * `:open_message_attention` — nil when the picker is closed, else
      `%{message_id, own?, title, preview, query, suggestions, added}` for
      `Partials.Overlays.message_attention_sheet/1` (the phone sheet and the
      desktop popover, from this ONE assign).

  ## Events

    * `open_message_attention` {message-id} — from the sheet row, the tap
      pill's +@ and the "+@ add someone" button. The message must be live
      and in the active space.
    * `close_message_attention`
    * `attention_query` {query} — the picker's own search field. It re-runs
      rung 10's `MentionsHooks.build_suggestions/3`.
    * `add_message_attention` {message-id, ids} — calls ONLY
      `Chat.add_message_attention({:user, user_id}, active_space.id, …)`.
      The space id is the socket's, never a param, and the writer authorizes
      the actor, so a forged id from another space or a non-member's socket
      is refused and nothing renders. Added: the toast "@<Name> notified".
      A refused summon reuses the mention path's refused-summon notice.

  ## Info

    * `{:message_attention_changed, msg}` — broadcast by the writer on the
      space topic to every viewer (the actor included). The row is
      reinserted through `MessagesHooks.reinsert_stream_message/2`, which
      re-reads the attention, so each viewer renders its own copy of the
      added line. An open picker on that message refreshes its "added".
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.Message
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.MessagesHooks

  @doc "Attach the attention handlers. Called from `MessageActionsHooks.attach/1`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:open_message_attention, nil)
    |> attach_hook(:message_attention_events, :handle_event, &handle_event/3)
    |> attach_hook(:message_attention_info, :handle_info, &handle_info/2)
  end

  defp handle_event("open_message_attention", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    case active_space_message(socket, msg_id) do
      %Message{} = msg -> {:halt, open(socket, msg, "")}
      nil -> {:halt, assign(socket, :open_message_attention, nil)}
    end
  end

  defp handle_event("open_message_attention", _params, socket), do: {:halt, socket}

  defp handle_event("close_message_attention", _params, socket),
    do: {:halt, assign(socket, :open_message_attention, nil)}

  defp handle_event("attention_query", %{"query" => query}, socket) when is_binary(query) do
    with %{message_id: msg_id} <- socket.assigns[:open_message_attention],
         %Message{} = msg <- active_space_message(socket, msg_id) do
      {:halt, open(socket, msg, query)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("attention_query", _params, socket), do: {:halt, socket}

  defp handle_event("add_message_attention", %{"message-id" => msg_id, "ids" => ids}, socket)
       when is_binary(msg_id) and is_list(ids) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id],
         {:ok, result} <-
           Chat.add_message_attention({:user, user_id}, space_id, msg_id, ids) do
      {:halt, socket |> assign(:open_message_attention, nil) |> report(msg_id, result)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("add_message_attention", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:message_attention_changed, %Message{} = msg}, socket) do
    case socket.assigns[:active_space] do
      %{id: space_id} when space_id == msg.space_id ->
        rendered = socket.assigns[:rendered_message_ids] || MapSet.new()

        socket =
          if MapSet.member?(rendered, msg.id),
            do: MessagesHooks.reinsert_stream_message(socket, msg.id),
            else: socket

        {:halt, refresh_open(socket, msg)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Picker state ──────────────────────────────────────────────────────

  defp open(socket, %Message{} = msg, query) do
    viewer = socket.assigns[:current_participant]
    own? = viewer != nil and msg.participant_id == viewer.id

    assign(socket, :open_message_attention, %{
      message_id: msg.id,
      own?: own?,
      title: if(own?, do: "Get someone's attention", else: "Ask someone to look"),
      preview: preview(msg, socket),
      query: query,
      suggestions: suggestions(socket, msg, query),
      added: added_principals(socket, msg.id)
    })
  end

  defp refresh_open(socket, %Message{id: id} = msg) do
    case socket.assigns[:open_message_attention] do
      %{message_id: ^id, query: query} -> open(socket, msg, query)
      _ -> socket
    end
  end

  @doc """
  The picker's rows: rung 10's suggestions for `query`, minus the `@here`
  sentinel, the message's author and the viewer (none of them can be asked
  to look; the writer drops them too).
  """
  @spec suggestions(Phoenix.LiveView.Socket.t(), Message.t(), String.t()) :: [map()]
  def suggestions(socket, %Message{} = msg, query) do
    participants = socket.assigns[:participants_map] || %{}
    excluded = excluded_principals(participants, msg, socket)

    query
    |> MentionsHooks.build_suggestions(participants,
      external?: socket.assigns[:external?] == true,
      user_id: socket.assigns[:user_id],
      addable_agents: socket.assigns[:mention_addable_agents] || []
    )
    |> Enum.reject(fn s ->
      s[:participant_type] == "broadcast" or MapSet.member?(excluded, s[:principal_id])
    end)
  end

  defp excluded_principals(participants, %Message{} = msg, socket) do
    author = participants |> Map.get(msg.participant_id, %{}) |> Map.get(:principal_id)
    [author, socket.assigns[:user_id]] |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # Principal ids already asked to look at the message, for the "added"
  # marks. Attention rows name chat participants; the picker's rows name
  # principals, so map through `@participants_map`.
  defp added_principals(socket, msg_id) do
    participants = socket.assigns[:participants_map] || %{}

    msg_id
    |> Chat.list_message_attention()
    |> Enum.flat_map(fn a ->
      case Map.get(participants, a.participant_id) do
        %{principal_id: pid} when is_binary(pid) -> [pid]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  # The masters' one-line preview (mobile 1387): the text, else "<n>
  # image(s)", else "message".
  defp preview(%Message{content: content} = msg, socket) do
    case content && String.trim(content) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        case image_count(msg, socket) do
          0 -> "message"
          1 -> "1 image"
          n -> "#{n} images"
        end
    end
  end

  defp image_count(%Message{id: id}, socket) do
    socket.assigns
    |> Map.get(:attachments_map, %{})
    |> Map.get(id, [])
    |> Enum.count(fn a -> String.starts_with?(to_string(Map.get(a, :content_type)), "image/") end)
  end

  # ── After a pick ──────────────────────────────────────────────────────

  defp report(socket, msg_id, %{added: added, refused: refused}) do
    socket
    |> toast_added(added)
    |> notify_refused(msg_id, refused)
  end

  defp toast_added(socket, []), do: socket

  defp toast_added(socket, added) do
    names = added |> Enum.map(&"@#{&1.display_name}") |> Enum.join(", ")
    put_flash(socket, :info, "#{names} notified")
  end

  # A refused summon reads exactly as a refused @mention does: the same
  # `{:mention_summon_refused, msg_id, names}` the post path sends its
  # author, handled (and rendered under the message) by `MessagesHooks`.
  defp notify_refused(socket, _msg_id, []), do: socket

  defp notify_refused(socket, msg_id, agents) do
    send(self(), {:mention_summon_refused, msg_id, Enum.map(agents, &(&1.name || &1.slug))})
    socket
  end

  defp active_space_message(socket, msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         %Message{deleted_at: nil, space_id: ^space_id} = msg <-
           Chat.get_message(msg_id, scope: socket.assigns[:external_scope]) do
      msg
    else
      _ -> nil
    end
  end
end
