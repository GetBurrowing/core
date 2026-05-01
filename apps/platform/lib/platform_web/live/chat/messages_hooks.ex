defmodule PlatformWeb.ChatLive.MessagesHooks do
  @moduledoc """
  Lifecycle hook for MessageList + Threads + Reactions + Attachments +
  Drafts in `PlatformWeb.ChatLive`.

  See ADR 0035. These concerns share `:messages` stream, `:attachments_map`,
  `:thread_previews`, and `:inline_thread_messages`. Splitting them across
  separate hooks would require fan-out coordination for every PubSub event,
  so they live in one module together — honestly representing the domain as
  "chat messages, some with thread children."

  ## State shape

  Reactions live **on the stream item itself** via the `:reactions` virtual
  field on `Platform.Chat.Message`. Every `stream_insert` re-renders the
  item against a fresh, DB-derived reaction list — so reaction broadcasts
  are idempotent (duplicate delivery doesn't double-count), in-order (the
  DB is source of truth), and don't require parallel-map bookkeeping.

  Attachments still live in the parallel `:attachments_map` assign; the
  same refactor applies to them and is a follow-up.

  ## Assigns owned

    * `:messages` (stream — items are `%Message{}` enriched with `:reactions`)
    * `:attachments_map` — msg_id → [attachments]
    * `:reaction_picker_for` — msg_id | nil — when set, the picker popover is open for that message
    * `:reaction_picker_emojis` — curated emoji list shown in the picker
    * `:longpress_menu_for` — msg_id | nil — when set, the mobile quick-react popover (double-tap entry) is open for that message
    * `:compose_form`
    * `:thread_compose_form`
    * `:active_thread`
    * `:thread_messages`
    * `:thread_attachments_map`
    * `:thread_previews` — parent_msg_id → %{thread_id, reply_count, last_reply_at}
    * `:expanded_threads` — MapSet of parent_msg_ids with inline threads open
    * `:inline_thread_messages` — parent_msg_id → [thread messages]
    * `:highlighted_message_id`, `:highlighted_thread_message_id`
    * `:streaming_replies`
    * `:drafts` — space_id → compose text

  ## Events

    * Compose: `"send_message"`, `"compose_changed"` (+ draft save),
      `"open_lightbox"`, `"close_lightbox"`
    * Reactions: `"react"`, `"open_reaction_picker"`, `"close_reaction_picker"`
    * Threads: `"open_thread"`, `"close_thread"`, `"send_thread_message"`,
      `"toggle_inline_thread"`, `"send_inline_thread_message"`

  ## Info handled

    * `{:new_message, msg}` — three-destination dispatch (main stream,
      inline thread, thread previews) depending on msg shape
    * `{:message_updated, msg}`, `{:message_deleted, msg}`
    * `{:reaction_added, r}`, `{:reaction_removed, data}`
    * `{:agent_reply_chunk, %{...}}`

  ## Public helpers for cross-feature coordinators

    * `enter_space/3` — called from parent handle_params
    * `stream_insert_message/2` — used by `canvas_create` (parent)
    * `reset_thread_panel/1` — used by `canvas_open`, `canvas_create`
    * `open_thread_context/3` — used by `search_open_result` when target
      is in a thread
    * `set_highlight/2` — used by `search_open_result`
    * `set_highlight/3` — …with a thread message id too
    * `maybe_refresh/1` — compat shim; delegates to SearchHooks for now
    * `clear_draft/2` — used by send_message after successful post
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2, update: 3]

  import Phoenix.LiveView,
    only: [
      attach_hook: 4,
      push_event: 3,
      put_flash: 3,
      stream: 3,
      stream: 4,
      stream_delete: 3,
      stream_insert: 3,
      consume_uploaded_entries: 3,
      uploaded_entries: 2
    ]

  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias PlatformWeb.ChatLive.SearchHooks

  @message_limit 50

  # Expanded emoji list offered in the "+" picker popover. Keep curated —
  # full emoji-picker-element with search/skin tones is tracked for V2.
  @reaction_picker_emojis ~w(
    👍 👎 ❤️ 🔥 🎉 🚀 ✅ ❌
    😀 😂 😅 😊 😍 🤔 😮 😢
    🙏 👏 🙌 💪 👀 💡 ⭐ ✨
    🥳 🤯 💯 🫶 🤝 ☕ 🍕 🐛
  )

  @doc "Attach message/thread/reactions handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:attachments_map, %{})
    |> assign(:reaction_picker_for, nil)
    |> assign(:reaction_picker_emojis, @reaction_picker_emojis)
    |> assign(:longpress_menu_for, nil)
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
    |> assign(:thread_previews, %{})
    |> assign(:expanded_threads, MapSet.new())
    |> assign(:inline_thread_messages, %{})
    |> assign(:streaming_replies, %{})
    |> assign(:drafts, %{})
    |> assign_compose("")
    |> assign_thread_compose("")
    |> stream(:messages, [])
    |> attach_hook(:messages_events, :handle_event, &handle_event/3)
    |> attach_hook(:messages_info, :handle_info, &handle_info/2)
  end

  @doc """
  Load the message list + derived state for a newly-entered space.
  Returns the socket with all message-related assigns populated.
  Called from `ChatLive.handle_params/3` after the active_space is set.
  """
  @spec enter_space(Phoenix.LiveView.Socket.t(), map(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def enter_space(socket, space, participant) do
    messages = load_channel_messages(space.id)
    latest_message = List.last(messages)

    if participant && latest_message do
      Chat.mark_space_read(participant.id, latest_message.id)
    end

    enriched = enrich_messages_with_reactions(messages, socket)
    attachments_map = build_attachments_map(messages)
    thread_previews = Chat.thread_previews_for_messages(Enum.map(messages, & &1.id))

    socket
    |> assign(:attachments_map, attachments_map)
    |> assign(:reaction_picker_for, nil)
    |> assign(:longpress_menu_for, nil)
    |> assign(:thread_previews, thread_previews)
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
    |> assign(:expanded_threads, MapSet.new())
    |> assign(:inline_thread_messages, %{})
    |> assign(:streaming_replies, %{})
    |> stream(:messages, enriched, reset: true)
    |> restore_draft(space.id)
  end

  @doc """
  Insert a message into the stream and populate its attachments map
  entry. Used by `canvas_create` and `upload_send` coordinators.

  Enriches the message with its current reaction groups so the stream
  item carries everything the template needs — no :reactions_map lookup.
  """
  @spec stream_insert_message(Phoenix.LiveView.Socket.t(), map(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def stream_insert_message(socket, message, attachments \\ []) do
    enriched = enrich_with_reactions(message, socket)

    socket
    |> stream_insert(:messages, enriched)
    |> put_attachment_map_entry(message.id, attachments)
  end

  @doc "Clear the thread panel. Used by canvas_open and canvas_create."
  @spec reset_thread_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_thread_panel(socket) do
    socket
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
  end

  @doc """
  Expand an inline thread for a given parent message and pre-load the
  thread messages. Used by `search_open_result` on the parent when a
  search hit is inside a thread.
  """
  @spec open_thread_context(Phoenix.LiveView.Socket.t(), binary(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def open_thread_context(socket, parent_msg_id, thread_msgs) do
    socket
    |> update(:expanded_threads, &MapSet.put(&1, parent_msg_id))
    |> update(:inline_thread_messages, &Map.put(&1, parent_msg_id, thread_msgs))
    |> reinsert_stream_message(parent_msg_id)
  end

  @doc "Parent-visible helper to load thread messages for a thread id."
  @spec load_thread_messages(binary(), binary()) :: [map()]
  def load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
  end

  @doc "Persist a draft for a space — used when switching spaces."
  @spec save_draft(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def save_draft(socket, space_id) do
    text = socket.assigns.compose_form[:text].value || ""
    update(socket, :drafts, &Map.put(&1, space_id, text))
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("send_message", %{"compose" => %{"text" => content}}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_with_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          enriched = enrich_with_reactions(msg, socket)

          {:halt,
           socket
           |> stream_insert(:messages, enriched)
           |> put_attachment_map_entry(msg.id, attachments)
           |> assign_compose("")
           |> update(:drafts, &Map.delete(&1, space.id))}

        {:noop, socket} ->
          {:halt, socket}

        {:error, socket, reason} ->
          {:halt, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("compose_changed", %{"compose" => %{"text" => text}}, socket) do
    socket = assign_compose(socket, text)

    socket =
      case socket.assigns.active_space do
        %{id: space_id} -> update(socket, :drafts, &Map.put(&1, space_id, text))
        _ -> socket
      end

    {:halt, socket}
  end

  defp handle_event("compose_changed", _params, socket), do: {:halt, socket}

  defp handle_event("open_lightbox", %{"url" => url}, socket),
    do: {:halt, assign(socket, :lightbox_url, url)}

  defp handle_event("close_lightbox", _params, socket),
    do: {:halt, assign(socket, :lightbox_url, nil)}

  defp handle_event("open_reaction_picker", %{"message-id" => msg_id}, socket),
    do: {:halt, assign(socket, :reaction_picker_for, msg_id)}

  defp handle_event("close_reaction_picker", _params, socket),
    do: {:halt, assign(socket, :reaction_picker_for, nil)}

  defp handle_event("open_longpress_menu", %{"message_id" => msg_id}, socket),
    do: {:halt, assign(socket, :longpress_menu_for, msg_id)}

  defp handle_event("close_longpress_menu", _params, socket),
    do: {:halt, assign(socket, :longpress_menu_for, nil)}

  defp handle_event("react", %{"message-id" => msg_id, "emoji" => emoji}, socket),
    do: {:halt, socket |> react_to_message(msg_id, emoji) |> close_picker()}

  defp handle_event("open_thread", %{"message-id" => message_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)

  defp handle_event("open_thread", %{"message_id" => message_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)

  defp handle_event("close_thread", _params, socket) do
    {:halt,
     socket
     |> assign(:active_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:thread_attachments_map, %{})
     |> assign(:highlighted_thread_message_id, nil)}
  end

  defp handle_event(
         "send_thread_message",
         %{"thread_compose" => %{"text" => content}},
         socket
       ) do
    with thread when not is_nil(thread) <- socket.assigns.active_thread,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: thread.space_id,
        thread_id: thread.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_with_upload(socket, :thread_attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:halt,
           socket
           |> update(:thread_messages, &(&1 ++ [msg]))
           |> put_thread_attachment_map_entry(msg.id, attachments)
           |> assign_thread_compose("")}

        {:noop, socket} ->
          {:halt, socket}

        {:error, socket, reason} ->
          {:halt, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("toggle_inline_thread", %{"message_id" => msg_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket)

  defp handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket) do
    if MapSet.member?(socket.assigns.expanded_threads, msg_id) do
      socket =
        socket
        |> update(:expanded_threads, &MapSet.delete(&1, msg_id))
        |> update(:inline_thread_messages, &Map.delete(&1, msg_id))
        |> reinsert_stream_message(msg_id)

      {:halt, socket}
    else
      space = socket.assigns.active_space

      thread =
        Chat.get_thread_for_message(msg_id) ||
          case Chat.create_thread(space.id, %{parent_message_id: msg_id}) do
            {:ok, t} -> t
            {:error, _} -> nil
          end

      case thread do
        nil ->
          {:halt, put_flash(socket, :error, "Could not open thread.")}

        thread ->
          thread_msgs = load_thread_messages(space.id, thread.id)

          socket =
            socket
            |> update(:expanded_threads, &MapSet.put(&1, msg_id))
            |> update(:inline_thread_messages, &Map.put(&1, msg_id, thread_msgs))
            |> update(
              :thread_previews,
              &Map.put(&1, msg_id, %{
                thread_id: thread.id,
                reply_count: length(thread_msgs),
                last_reply_at: List.last(thread_msgs) && List.last(thread_msgs).inserted_at
              })
            )
            |> push_event("focus_inline_thread_compose", %{message_id: msg_id})
            |> reinsert_stream_message(msg_id)

          {:halt, socket}
      end
    end
  end

  defp handle_event(
         "send_inline_thread_message",
         %{"inline_thread_compose" => %{"text" => content, "message_id" => msg_id}},
         socket
       ) do
    content = String.trim(content || "")

    with true <- content != "",
         space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      {:ok, thread} = Chat.create_thread_for_message(space.id, msg_id)

      attrs = %{
        space_id: space.id,
        thread_id: thread.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      }

      case Chat.post_message(attrs, from_pid: self()) do
        {:ok, msg} ->
          {:halt,
           socket
           |> update(:inline_thread_messages, fn itm ->
             Map.update(itm, msg_id, [msg], &(&1 ++ [msg]))
           end)
           |> update(:thread_previews, fn tp ->
             preview =
               Map.get(tp, msg_id, %{thread_id: thread.id, reply_count: 0, last_reply_at: nil})

             Map.put(tp, msg_id, %{
               preview
               | reply_count: preview.reply_count + 1,
                 last_reply_at: msg.inserted_at
             })
           end)
           |> reinsert_stream_message(msg_id)}

        {:error, _reason} ->
          {:halt, put_flash(socket, :error, "Failed to send reply.")}
      end
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Info callbacks ────────────────────────────────────────────────────

  defp handle_info({:new_message, msg}, socket) do
    active_space = socket.assigns[:active_space]
    current_participant = socket.assigns[:current_participant]

    is_background_dm =
      is_nil(active_space) or msg.space_id != active_space.id

    is_own_message =
      current_participant && msg.participant_id == current_participant.id

    socket =
      if is_background_dm and not is_own_message do
        increment_unread(socket, msg.space_id)
      else
        streaming =
          socket.assigns.streaming_replies
          |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
          |> Map.new()

        assign(socket, :streaming_replies, streaming)
      end

    if is_nil(active_space) or msg.space_id != active_space.id do
      {:halt, socket}
    else
      streaming =
        socket.assigns.streaming_replies
        |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
        |> Map.new()

      socket = assign(socket, :streaming_replies, streaming)

      attachments = Chat.list_attachments(msg.id)

      if is_nil(msg.thread_id) && current_participant do
        Chat.mark_space_read(current_participant.id, msg.id)
      end

      if is_nil(msg.thread_id) do
        enriched = enrich_with_reactions(msg, socket)

        {:halt,
         socket
         |> stream_insert(:messages, enriched)
         |> put_attachment_map_entry(msg.id, attachments)
         |> SearchHooks.maybe_refresh()}
      else
        socket =
          if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
            socket
            |> update(:thread_messages, &(&1 ++ [msg]))
            |> put_thread_attachment_map_entry(msg.id, attachments)
          else
            socket
          end

        socket = maybe_update_inline_thread(socket, msg)

        {:halt, SearchHooks.maybe_refresh(socket)}
      end
    end
  end

  defp handle_info({:message_updated, msg}, socket) do
    attachments = Chat.list_attachments(msg.id)
    enriched = enrich_with_reactions(msg, socket)

    {:halt,
     socket
     |> stream_insert(:messages, enriched)
     |> put_attachment_map_entry(msg.id, attachments)
     |> SearchHooks.maybe_refresh()}
  end

  defp handle_info({:message_deleted, msg}, socket) do
    {:halt,
     socket
     |> stream_delete(:messages, msg)
     |> delete_attachment_map_entry(msg.id)
     |> delete_thread_attachment_map_entry(msg.id)
     |> SearchHooks.maybe_refresh()}
  end

  # `reinsert_stream_message/2` fetches fresh from the DB (now with
  # `deleted_at: nil`) and stream-inserts it. The chat template's
  # `:if={is_nil(msg.deleted_at)}` predicate then renders the row
  # again. Idempotent under duplicate delivery — DB is truth.
  defp handle_info({:message_restored, msg}, socket) do
    {:halt,
     socket
     |> reinsert_stream_message(msg.id)
     |> SearchHooks.maybe_refresh()}
  rescue
    e ->
      Logger.error("Message restore broadcast crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  # Reaction broadcasts just re-insert the affected message — `reinsert_stream_message/2`
  # fetches fresh from the DB and enriches with the current reaction groups, so the
  # stream item carries everything the template reads. Idempotent under duplicate
  # delivery (DB is truth), immune to out-of-order events.
  defp handle_info({:reaction_added, reaction}, socket) do
    {:halt, reinsert_stream_message(socket, reaction.message_id)}
  rescue
    e ->
      Logger.error("Reaction broadcast (added) crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  defp handle_info({:reaction_removed, data}, socket) do
    {:halt, reinsert_stream_message(socket, data.message_id)}
  rescue
    e ->
      Logger.error("Reaction broadcast (removed) crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  # LiveView streams render items once on insert and don't auto-refresh when
  # external assigns change. Inline canvas cards read `@canvases_by_id[msg.canvas_id]`,
  # so a canvas patch that only updates that assign leaves the stream item frozen
  # at its insert-time snapshot. Re-insert the referencing message(s) here so the
  # template re-renders with the updated canvas. `:cont` so CanvasHooks still runs
  # after us and refreshes `canvases_by_id` before the final diff is computed.
  defp handle_info({:canvas_updated, canvas}, socket) do
    socket =
      canvas.id
      |> Chat.list_message_ids_for_canvas()
      |> Enum.reduce(socket, &reinsert_stream_message(&2, &1))

    {:cont, socket}
  end

  defp handle_info(
         {:agent_reply_chunk,
          %{
            space_id: space_id,
            chunk_id: chunk_id,
            text: text,
            done: done,
            participant_id: participant_id
          }},
         socket
       ) do
    active_space_id =
      case socket.assigns[:active_space] do
        %{id: id} -> id
        _ -> nil
      end

    cond do
      space_id != active_space_id ->
        # BACKLOG #9 — privacy gate. ChatLive subscribes to every
        # accessible space at mount so unread-count badges work, but
        # agent reasoning chunks must only render in the space the
        # user is currently viewing. Without this guard, a chunk from
        # #general lands in the user's DM panel whenever they happen
        # to be viewing the DM. Subscribers still receive the event
        # (broadcast scope is unchanged); the render is gated.
        {:halt, socket}

      done ->
        {:halt, update(socket, :streaming_replies, &Map.delete(&1, chunk_id))}

      true ->
        entry = %{text: text, participant_id: participant_id}
        {:halt, update(socket, :streaming_replies, &Map.put(&1, chunk_id, entry))}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Internals ────────────────────────────────────────────────────────

  defp react_to_message(socket, msg_id, emoji) do
    with participant when not is_nil(participant) <- socket.assigns.current_participant do
      # DB is truth for "did this participant already react with this emoji".
      # Previously this read from :reactions_map — kept in sync locally but
      # vulnerable to stale state under duplicate delivery.
      Chat.toggle_reaction(msg_id, participant.id, emoji)
    end

    socket
  rescue
    e ->
      Logger.error("Reaction handler crashed: #{Exception.message(e)}")
      socket
  end

  defp close_picker(socket) do
    socket
    |> assign(:reaction_picker_for, nil)
    |> assign(:longpress_menu_for, nil)
  end

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
  end

  defp assign_thread_compose(socket, text) do
    assign(socket, :thread_compose_form, to_form(%{"text" => text}, as: :thread_compose))
  end

  defp restore_draft(socket, space_id) do
    draft = Map.get(socket.assigns.drafts, space_id, "")
    assign_compose(socket, draft)
  end

  defp load_channel_messages(space_id) do
    space_id
    |> Chat.list_messages(limit: @message_limit, top_level_only: true)
    |> Enum.reverse()
  end

  defp reinsert_stream_message(socket, msg_id) do
    case Chat.get_message(msg_id) do
      nil ->
        socket

      msg ->
        enriched = enrich_with_reactions(msg, socket)
        stream_insert(socket, :messages, enriched)
    end
  end

  defp maybe_update_inline_thread(socket, %{thread_id: thread_id} = msg)
       when is_binary(thread_id) do
    msg_id =
      Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
        if tid == thread_id, do: pmid
      end)

    if is_nil(msg_id) do
      socket
    else
      socket
      |> update(:inline_thread_messages, fn itm ->
        if MapSet.member?(socket.assigns.expanded_threads, msg_id) do
          Map.update(itm, msg_id, [msg], &(&1 ++ [msg]))
        else
          itm
        end
      end)
      |> update(:thread_previews, fn tp ->
        Map.update(tp, msg_id, nil, fn preview ->
          %{preview | reply_count: preview.reply_count + 1, last_reply_at: msg.inserted_at}
        end)
      end)
      |> reinsert_stream_message(msg_id)
    end
  end

  defp maybe_update_inline_thread(socket, _msg), do: socket

  # Cap on eagerly-hydrated reactor names per emoji. A message with more
  # reactors than this fills its :reactors list with the first N and
  # exposes the remainder via :extra_count so the UI can show
  # "and N others." 20 is a guess — tune if real data shows hot reactions
  # with many more participants.
  @reactor_list_cap 20

  # Bulk-enrich a list of messages with their current reaction groups.
  # Used when loading a space: one batched query, then group per message.
  defp enrich_messages_with_reactions(messages, socket) do
    my_id = socket.assigns[:current_participant] && socket.assigns.current_participant.id
    participants_map = socket.assigns[:participants_map] || %{}
    agent_ids = socket.assigns[:agent_participant_ids] || MapSet.new()

    raw = Chat.list_reactions_for_messages(Enum.map(messages, & &1.id))

    Enum.map(messages, fn msg ->
      reactions = Map.get(raw, msg.id, [])

      groups =
        reactions
        |> Enum.group_by(& &1.emoji)
        |> Enum.map(fn {emoji, rs} ->
          build_reaction_group(emoji, rs, my_id, participants_map, agent_ids)
        end)
        |> Enum.sort_by(& &1.emoji)

      %{msg | reactions: groups}
    end)
  end

  # Single-message enrichment. Used on every stream_insert (new message,
  # message updated, reaction added/removed) so the stream item always
  # carries the current reaction groups.
  defp enrich_with_reactions(msg, socket) do
    my_id = socket.assigns[:current_participant] && socket.assigns.current_participant.id
    participants_map = socket.assigns[:participants_map] || %{}
    agent_ids = socket.assigns[:agent_participant_ids] || MapSet.new()

    groups =
      msg.id
      |> Chat.list_reactions()
      |> Enum.group_by(& &1.emoji)
      |> Enum.map(fn {emoji, rs} ->
        build_reaction_group(emoji, rs, my_id, participants_map, agent_ids)
      end)
      |> Enum.sort_by(& &1.emoji)

    %{msg | reactions: groups}
  end

  # Build one `%{emoji, count, reacted_by_me, reactors, extra_count}` group
  # from an emoji and its raw `%Reaction{}` rows. Hydrates up to
  # @reactor_list_cap names via the live participants map, falls back to
  # the row's reactor snapshot (captured at write time, survives hard-
  # delete), then to `Chat.get_participant/1`, then to "Someone."
  defp build_reaction_group(emoji, raw_reactions, my_id, participants_map, agent_ids) do
    count = length(raw_reactions)
    participant_ids = Enum.map(raw_reactions, & &1.participant_id)

    reactors =
      raw_reactions
      |> Enum.take(@reactor_list_cap)
      |> Enum.map(fn r ->
        %{
          id: r.participant_id,
          name: resolve_reactor_name(r, participants_map),
          is_agent: reactor_is_agent?(r, agent_ids)
        }
      end)

    %{
      emoji: emoji,
      count: count,
      reacted_by_me: my_id in participant_ids,
      reactors: reactors,
      extra_count: max(0, count - @reactor_list_cap)
    }
  end

  # Live participants map wins (renames propagate). Row snapshot is the
  # fallback for hard-deleted / dismissed participants — it mirrors the
  # message author snapshot pattern from ADR 0038 but on `chat_reactions`.
  # No live-DB fallback: if both the live map AND the snapshot miss, we
  # return "Someone" rather than hit `Chat.get_participant/1` — that path
  # was an N+1 (fires once per reactor per emoji per message on every
  # render) and is only relevant for reactions created before the
  # `backfill_reactor_snapshots` migration landed. The backfill is
  # idempotent and runs back-to-back with the schema migration, so the
  # window is effectively sub-second; warn loudly if it somehow persists.
  defp resolve_reactor_name(%{participant_id: pid} = reaction, participants_map) do
    case Map.get(participants_map, pid) do
      %{name: name} when is_binary(name) and name != "" ->
        name

      _ ->
        case reaction.reactor_display_name do
          name when is_binary(name) and name != "" ->
            name

          _ ->
            Logger.warning(
              "reactor_name fallback: missing snapshot for participant_id=#{inspect(pid)} (backfill may be pending)"
            )

            "Someone"
        end
    end
  end

  # Prefer live presence (handles user→agent-account edge cases), then
  # fall back to the snapshot participant type (survives hard-delete).
  defp reactor_is_agent?(%{participant_id: pid} = reaction, agent_ids) do
    cond do
      MapSet.member?(agent_ids, pid) -> true
      reaction.reactor_participant_type == "agent" -> true
      true -> false
    end
  end

  defp build_attachments_map(messages) do
    messages
    |> Enum.map(& &1.id)
    |> Chat.list_attachments_for_messages()
  end

  defp put_attachment_map_entry(socket, message_id, attachments) do
    assign(
      socket,
      :attachments_map,
      Map.put(socket.assigns.attachments_map, message_id, attachments)
    )
  end

  defp delete_attachment_map_entry(socket, message_id) do
    assign(socket, :attachments_map, Map.delete(socket.assigns.attachments_map, message_id))
  end

  defp put_thread_attachment_map_entry(socket, message_id, attachments) do
    assign(
      socket,
      :thread_attachments_map,
      Map.put(socket.assigns.thread_attachments_map, message_id, attachments)
    )
  end

  defp delete_thread_attachment_map_entry(socket, message_id) do
    assign(
      socket,
      :thread_attachments_map,
      Map.delete(socket.assigns.thread_attachments_map, message_id)
    )
  end

  defp increment_unread(socket, space_id) do
    current = Map.get(socket.assigns.unread_counts, space_id, 0)
    update(socket, :unread_counts, &Map.put(&1, space_id, current + 1))
  end

  # ── Upload plumbing shared between send_message, send_thread_message, upload_send ──

  @doc """
  Post a message that may have pending uploads. The upload slot (:attachments
  or :thread_attachments) is configured via `allow_upload` on the parent
  LiveView. Returns `{:ok, socket, msg, attachments}` | `{:noop, socket}`
  | `{:error, socket, reason}`.
  """
  @spec post_message_with_upload(Phoenix.LiveView.Socket.t(), atom(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t(), map(), [map()]}
          | {:noop, Phoenix.LiveView.Socket.t()}
          | {:error, Phoenix.LiveView.Socket.t(), String.t()}
  def post_message_with_upload(socket, upload_name, attrs) do
    content = String.trim(Map.get(attrs, :content, "") || "")
    attrs = Map.put(attrs, :content, content)

    cond do
      upload_in_progress?(socket, upload_name) ->
        {:error, socket, "Please wait for uploads to finish."}

      content == "" and not has_completed_uploads?(socket, upload_name) ->
        {:noop, socket}

      true ->
        case persist_uploaded_attachments(socket, upload_name) do
          {:ok, pending_attachments} ->
            case Chat.post_message_with_attachments(attrs, pending_attachments, from_pid: self()) do
              {:ok, msg, saved_attachments} ->
                {:ok, socket, msg, saved_attachments}

              {:error, _reason} ->
                AttachmentStorage.delete_many(pending_attachments)
                {:error, socket, "Failed to send message."}
            end

          {:error, :storage_failed} ->
            {:error, socket, "Failed to store attachment."}
        end
    end
  end

  defp persist_uploaded_attachments(socket, upload_name) do
    results =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        result =
          case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
            {:ok, attrs} -> {:ok, attrs}
            {:error, _reason} -> {:error, :storage_failed}
          end

        {:ok, result}
      end)

    {ok_results, error_results} = Enum.split_with(results, &match?({:ok, _}, &1))
    attachments = Enum.map(ok_results, fn {:ok, attrs} -> attrs end)

    if error_results == [] do
      {:ok, attachments}
    else
      AttachmentStorage.delete_many(attachments)
      {:error, :storage_failed}
    end
  end

  defp has_completed_uploads?(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {[_ | _], _in_progress} -> true
      _ -> false
    end
  end

  defp upload_in_progress?(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {_completed, [_ | _]} -> true
      _ -> false
    end
  end
end
