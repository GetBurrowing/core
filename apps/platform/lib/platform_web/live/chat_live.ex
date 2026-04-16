defmodule PlatformWeb.ChatLive do
  @moduledoc """
  LiveView for the Chat surface — with threads, reactions, pins, attachments,
  and collaborative live canvases.

  ## Layout

  Three-column layout when a thread is open:

      [Space sidebar | Message list | Thread panel]

  Thread panel collapses when closed. Pins panel slides in below the space
  header.

  ## Routes
    GET /chat             → :index — redirects to first space (or empty state)
    GET /chat/:space_slug → :show  — renders the selected space
  """

  use PlatformWeb, :live_view

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.PubSub, as: ChatPubSub

  alias PlatformWeb.ChatLive.ActiveAgentHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.NewChannelComponent
  alias PlatformWeb.ChatLive.NewConversationComponent
  alias PlatformWeb.ChatLive.PinHooks
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.SearchHooks
  alias PlatformWeb.ChatLive.SettingsComponent
  alias PlatformWeb.ChatLive.UploadHooks

  @message_limit 50
  @quick_emojis ["👍", "❤️", "😂", "🎉"]
  @max_upload_entries 5
  @max_upload_size 15_000_000
  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || Ecto.UUID.generate()
    channels = Chat.list_spaces(kind: "channel")
    conversations = if user_id, do: Chat.list_user_conversations(user_id), else: []
    dm_conversations = Enum.filter(conversations, fn s -> s.kind in ["dm", "group"] end)

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:user_id, user_id)
      |> assign(:spaces, channels ++ dm_conversations)
      |> assign(:channels, channels)
      |> assign(:dm_conversations, dm_conversations)
      |> assign(:active_space, nil)
      |> assign(:highlighted_thread_message_id, nil)
      |> assign(:current_participant, nil)
      |> assign(:reactions_map, %{})
      |> assign(:attachments_map, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_messages, [])
      |> assign(:thread_attachments_map, %{})
      |> assign(:thread_previews, %{})
      |> assign(:expanded_threads, MapSet.new())
      |> assign(:inline_thread_messages, %{})
      |> assign(:mobile_browser_open, false)
      |> assign(:show_new_channel_modal, false)
      |> assign(:show_new_conversation_modal, false)
      |> assign(:show_settings, false)
      |> assign(:quick_emojis, @quick_emojis)
      |> assign(:streaming_replies, %{})
      |> assign(:push_permission, "unknown")
      |> assign(:unread_counts, if(user_id, do: Chat.unread_counts_for_user(user_id), else: %{}))
      |> assign(:lightbox_url, nil)
      |> assign(:drafts, %{})
      |> assign_compose("")
      |> assign_thread_compose("")
      |> allow_upload(:attachments,
        accept: :any,
        auto_upload: true,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size,
        progress: &handle_upload_progress/3
      )
      |> allow_upload(:thread_attachments,
        accept: :any,
        auto_upload: true,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size,
        progress: &handle_upload_progress/3
      )
      |> stream(:messages, [])

    all_spaces = channels ++ dm_conversations

    # Subscribe to chat pubsub for unread counts in background conversations
    # (active space subscription happens in handle_params).
    if connected?(socket) do
      Enum.each(all_spaces, &ChatPubSub.subscribe(&1.id))
    end

    space_ids = Enum.map(all_spaces, & &1.id)

    socket =
      socket
      |> PresenceHooks.attach()
      |> PinHooks.attach()
      |> SearchHooks.attach()
      |> MentionsHooks.attach()
      |> UploadHooks.attach()
      |> CanvasHooks.attach()
      |> ActiveAgentHooks.attach()
      |> MeetingHooks.attach(space_ids)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"space_slug" => slug_or_id}, _url, socket) do
    # Save the outgoing channel's draft before switching
    socket =
      if prev = socket.assigns.active_space do
        ChatPubSub.unsubscribe(prev.id)
        Phoenix.PubSub.unsubscribe(Platform.PubSub, "active_agent:#{prev.id}")

        socket = PresenceHooks.leave_space(socket, prev.id)

        outgoing_draft = socket.assigns.compose_form[:text].value || ""
        update(socket, :drafts, &Map.put(&1, prev.id, outgoing_draft))
      else
        socket
      end

    # Try slug first, then ID fallback (for DM/group spaces without slugs)
    space =
      Chat.get_space_by_slug(slug_or_id) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id)) ||
        bootstrap_space(slug_or_id)

    if is_nil(space) do
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    else
      if connected?(socket) do
        ChatPubSub.subscribe(space.id)
        Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
      end

      participant = ensure_participant(space.id, socket.assigns.user_id)

      messages = load_channel_messages(space.id)
      latest_message = List.last(messages)

      if participant && latest_message do
        Chat.mark_space_read(participant.id, latest_message.id)
      end

      participants = Chat.list_participants(space.id)

      reactions_map = build_reactions_map(messages, participant)
      attachments_map = build_attachments_map(messages)
      thread_previews = Chat.thread_previews_for_messages(Enum.map(messages, & &1.id))

      page_title = space_page_title(space, participants, socket.assigns.user_id)

      # Refresh sidebar lists
      channels = Chat.list_spaces(kind: "channel")
      user_convos = Chat.list_user_conversations(socket.assigns.user_id)
      dm_convos = Enum.filter(user_convos, fn s -> s.kind in ["dm", "group"] end)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign(:active_space, space)
       |> PresenceHooks.enter_space(space, participant, participants)
       |> SearchHooks.reset_for_space()
       |> assign(:streaming_replies, %{})
       |> MentionsHooks.reset_for_space()
       |> assign(:current_participant, participant)
       |> assign(:reactions_map, reactions_map)
       |> assign(:attachments_map, attachments_map)
       |> assign(:active_thread, nil)
       |> assign(:thread_messages, [])
       |> assign(:thread_attachments_map, %{})
       |> assign(:thread_previews, thread_previews)
       |> assign(:expanded_threads, MapSet.new())
       |> assign(:inline_thread_messages, %{})
       |> PinHooks.load_for_space(space.id)
       |> CanvasHooks.load_for_space(space.id)
       |> ActiveAgentHooks.resolve_for_space(space.id, participants)
       |> assign(:mobile_browser_open, false)
       |> assign(:channels, channels)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> stream(:messages, messages, reset: true)
       |> clear_unread(space.id)
       |> restore_draft(space.id)}
    end
  end

  def handle_params(_params, _url, socket) do
    case socket.assigns.channels do
      [first | _] ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{first.slug}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_mobile_browser", _params, socket) do
    {:noreply, assign(socket, :mobile_browser_open, !socket.assigns.mobile_browser_open)}
  end

  def handle_event("close_mobile_browser", _params, socket) do
    {:noreply, assign(socket, :mobile_browser_open, false)}
  end

  # Cross-feature: Search event that also touches Threads + MessageList.
  # Stays here (coordinator) until Threads extracts; then becomes PubSub.
  def handle_event("search_open_result", %{"message-id" => message_id}, socket) do
    case Chat.get_message(message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Search result not found.")}

      %{thread_id: thread_id} = message when is_binary(thread_id) ->
        parent_msg_id =
          Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
            if tid == thread_id, do: pmid
          end)

        thread_msgs = load_thread_messages(message.space_id, thread_id)

        socket =
          if parent_msg_id do
            socket
            |> update(:expanded_threads, &MapSet.put(&1, parent_msg_id))
            |> update(:inline_thread_messages, &Map.put(&1, parent_msg_id, thread_msgs))
            |> SearchHooks.set_highlights(parent_msg_id, nil)
            |> reinsert_stream_message(parent_msg_id)
          else
            SearchHooks.set_highlights(socket, message.id, nil)
          end

        {:noreply, socket}

      message ->
        {:noreply,
         socket
         |> assign(:active_thread, nil)
         |> assign(:thread_messages, [])
         |> assign(:thread_attachments_map, %{})
         |> SearchHooks.set_highlights(message.id, nil)}
    end
  end

  def handle_event("push_subscribed", %{"endpoint" => endpoint, "keys" => keys}, socket) do
    if participant = socket.assigns[:current_participant] do
      Platform.Push.subscribe(participant.id, %{
        endpoint: endpoint,
        keys: %{p256dh: keys["p256dh"], auth: keys["auth"]}
      })
    end

    {:noreply, assign(socket, :push_permission, "granted")}
  end

  def handle_event("push_permission_state", %{"state" => state}, socket) do
    {:noreply, assign(socket, :push_permission, state)}
  end

  def handle_event("push_unsupported", _params, socket) do
    {:noreply, assign(socket, :push_permission, "unsupported")}
  end

  def handle_event("enable_notifications", _params, socket) do
    {:noreply, push_event(socket, "request_push_permission", %{})}
  end

  def handle_event("send_message", %{"compose" => %{"text" => content}}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_from_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> stream_insert(:messages, msg)
           |> put_attachment_map_entry(msg.id, attachments)
           |> assign_compose("")
           |> update(:drafts, &Map.delete(&1, space.id))}

        {:noop, socket} ->
          {:noreply, socket}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Upload staging dialog events ──────────────────────────────────────

  defp handle_upload_progress(_upload_name, _entry, socket) do
    {:noreply, socket}
  end

  def handle_event("open_lightbox", %{"url" => url}, socket) do
    {:noreply, assign(socket, :lightbox_url, url)}
  end

  def handle_event("close_lightbox", _params, socket) do
    {:noreply, assign(socket, :lightbox_url, nil)}
  end

  # Cross-feature: upload_send creates a message with attachments
  # (MessageList concern). Stays on parent until MessageList extracts.
  def handle_event("upload_send", _params, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      caption = String.trim(socket.assigns.upload_caption || "")
      tagged = socket.assigns.upload_tagged_agents

      # Append @mentions for tagged agents not already in caption
      mentions =
        tagged
        |> MapSet.to_list()
        |> Enum.reject(fn slug -> String.contains?(caption, "@#{String.capitalize(slug)}") end)
        |> Enum.map(fn slug -> "@#{String.capitalize(slug)}" end)

      content =
        case {caption, mentions} do
          {"", []} -> ""
          {"", _} -> Enum.join(mentions, " ")
          {c, []} -> c
          {c, _} -> c <> " " <> Enum.join(mentions, " ")
        end

      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      }

      case post_message_from_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> stream_insert(:messages, msg)
           |> put_attachment_map_entry(msg.id, attachments)
           |> UploadHooks.reset()}

        {:noop, _socket} ->
          {:noreply, put_flash(socket, :info, "No files selected")}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ── End upload staging dialog events ──────────────────────────────────

  def handle_event("compose_changed", %{"compose" => %{"text" => text}}, socket) do
    socket = assign_compose(socket, text)

    socket =
      case socket.assigns.active_space do
        %{id: space_id} ->
          update(socket, :drafts, &Map.put(&1, space_id, text))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("compose_changed", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_reaction_picker", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("react", %{"message_id" => msg_id, "emoji" => emoji}, socket) do
    react_to_message(socket, msg_id, emoji)
  end

  def handle_event("react", %{"message-id" => msg_id, "emoji" => emoji}, socket) do
    react_to_message(socket, msg_id, emoji)
  end

  # Redirect open_thread to inline expansion (side panel removed)
  def handle_event("open_thread", %{"message-id" => message_id}, socket) do
    handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)
  end

  def handle_event("open_thread", %{"message_id" => message_id}, socket) do
    handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:thread_attachments_map, %{})
     |> assign(:highlighted_thread_message_id, nil)}
  end

  defp react_to_message(socket, msg_id, emoji) do
    with participant when not is_nil(participant) <- socket.assigns.current_participant do
      groups = Map.get(socket.assigns.reactions_map, msg_id, [])
      already_reacted = Enum.any?(groups, &(&1.emoji == emoji && &1.reacted_by_me))

      if already_reacted do
        Chat.remove_reaction(msg_id, participant.id, emoji)
      else
        Chat.add_reaction(%{
          message_id: msg_id,
          participant_id: participant.id,
          emoji: emoji
        })
      end
    end

    {:noreply, socket}
  rescue
    e ->
      require Logger
      Logger.error("Reaction handler crashed: #{Exception.message(e)}")
      {:noreply, socket}
  end

  def handle_event("send_thread_message", %{"thread_compose" => %{"text" => content}}, socket) do
    with thread when not is_nil(thread) <- socket.assigns.active_thread,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: thread.space_id,
        thread_id: thread.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_from_upload(socket, :thread_attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> update(:thread_messages, &(&1 ++ [msg]))
           |> put_thread_attachment_map_entry(msg.id, attachments)
           |> assign_thread_compose("")}

        {:noop, socket} ->
          {:noreply, socket}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_inline_thread", %{"message_id" => msg_id}, socket) do
    handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket)
  end

  def handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket) do
    if MapSet.member?(socket.assigns.expanded_threads, msg_id) do
      # Collapse: remove from expanded set and re-insert message to force re-render
      socket =
        socket
        |> update(:expanded_threads, &MapSet.delete(&1, msg_id))
        |> update(:inline_thread_messages, &Map.delete(&1, msg_id))

      socket = reinsert_stream_message(socket, msg_id)
      {:noreply, socket}
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
          {:noreply, put_flash(socket, :error, "Could not open thread.")}

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

          socket = reinsert_stream_message(socket, msg_id)
          {:noreply, socket}
      end
    end
  end

  def handle_event(
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
          {:noreply,
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
          {:noreply, put_flash(socket, :error, "Failed to send reply.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_watch", _params, socket) do
    space = socket.assigns.active_space
    new_watch = !space.watch_enabled

    case Chat.update_space(space, %{watch_enabled: new_watch}) do
      {:ok, updated_space} ->
        socket = assign(socket, :active_space, updated_space)

        socket =
          if new_watch do
            # Watch turned ON — if no active agent and there's a primary agent, activate it
            if is_nil(ActiveAgentStore.get_active(space.id)) &&
                 is_binary(space.primary_agent_id) do
              primary_participant =
                space.id
                |> Chat.list_participants(participant_type: "agent")
                |> Enum.find(fn p -> p.participant_id == space.primary_agent_id end)

              if primary_participant do
                ActiveAgentStore.set_active(space.id, primary_participant.id)
              end

              socket
            else
              socket
            end
          else
            # Watch turned OFF — clear active agent immediately
            ActiveAgentStore.clear_active(space.id)
            socket
          end

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update watch setting.")}
    end
  end

  # Cross-feature: canvas_open writes Thread assigns (active_thread, …).
  # Stays on parent until Threads extracts.
  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    case CanvasHooks.find(socket, canvas_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Canvas not found.")}

      canvas ->
        {:noreply,
         socket
         |> CanvasHooks.set_active(canvas)
         |> assign(:active_thread, nil)
         |> assign(:thread_messages, [])
         |> assign(:thread_attachments_map, %{})}
    end
  end

  # Cross-feature: canvas_create creates a message + attachment entry
  # (MessageList concern). Stays on parent until MessageList extracts.
  def handle_event("canvas_create", %{"canvas" => canvas_params}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs =
        canvas_params
        |> Map.take(["title", "canvas_type"])
        |> Map.put("state", CanvasHooks.default_state(canvas_params["canvas_type"]))

      case Chat.create_canvas_with_message(space.id, participant.id, attrs) do
        {:ok, canvas, message} ->
          {:noreply,
           socket
           |> CanvasHooks.put(canvas)
           |> stream_insert(:messages, message)
           |> put_attachment_map_entry(message.id, [])
           |> CanvasHooks.set_active(canvas)
           |> assign(:active_thread, nil)
           |> assign(:thread_messages, [])
           |> assign(:thread_attachments_map, %{})
           |> CanvasHooks.show_panel()
           |> CanvasHooks.reset_new_form()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, CanvasHooks.changeset_error_summary(changeset))
           |> CanvasHooks.reset_new_form(canvas_params)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create canvas: #{inspect(reason)}")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Channel / Conversation creation events ─────────────────────────────────

  def handle_event("new_channel_open", _params, socket) do
    {:noreply, assign(socket, :show_new_channel_modal, true)}
  end

  def handle_event("new_conversation_open", _params, socket) do
    {:noreply, assign(socket, :show_new_conversation_modal, true)}
  end

  def handle_event("promote_to_channel", %{"name" => name}, socket) do
    space = socket.assigns.active_space

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.promote_to_channel(space, %{name: name, slug: slug}) do
      {:ok, updated} ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{updated.slug}")}

      {:error, :not_promotable} ->
        {:noreply,
         put_flash(socket, :error, "This conversation cannot be promoted to a channel.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not promote to channel.")}
    end
  end

  # ── Settings modal (see SettingsComponent) ────────────────────────────────

  def handle_event("settings_open", _params, socket) do
    {:noreply, assign(socket, :show_settings, true)}
  end

  @impl true
  def handle_info({:settings_closed}, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  def handle_info({:settings_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_settings, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:settings_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:new_channel_closed}, socket) do
    {:noreply, assign(socket, :show_new_channel_modal, false)}
  end

  def handle_info({:new_channel_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_new_channel_modal, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:new_channel_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:new_conversation_closed}, socket) do
    {:noreply, assign(socket, :show_new_conversation_modal, false)}
  end

  def handle_info({:new_conversation_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_new_conversation_modal, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:new_conversation_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:new_message, msg}, socket) do
    active_space = socket.assigns.active_space
    current_participant = socket.assigns.current_participant

    # If this message is from a background DM space (not the active one), count it as unread.
    # Don't count messages sent by the current user.
    is_background_dm =
      is_nil(active_space) or msg.space_id != active_space.id

    is_own_message =
      current_participant && msg.participant_id == current_participant.id

    socket =
      if is_background_dm and not is_own_message do
        increment_unread(socket, msg.space_id)
      else
        # Clear any streaming bubbles from this participant (final message replaces them)
        streaming =
          socket.assigns.streaming_replies
          |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
          |> Map.new()

        assign(socket, :streaming_replies, streaming)
      end

    if is_nil(active_space) or msg.space_id != active_space.id do
      {:noreply, socket}
    else
      # Clear streaming for this participant now
      streaming =
        socket.assigns.streaming_replies
        |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
        |> Map.new()

      socket = assign(socket, :streaming_replies, streaming)

      attachments = Chat.list_attachments(msg.id)

      # Mark as read for active space top-level messages
      if is_nil(msg.thread_id) && socket.assigns.current_participant do
        Chat.mark_space_read(socket.assigns.current_participant.id, msg.id)
      end

      if is_nil(msg.thread_id) do
        {:noreply,
         socket
         |> stream_insert(:messages, msg)
         |> put_attachment_map_entry(msg.id, attachments)
         |> SearchHooks.maybe_refresh()}
      else
        # Update side-panel thread if open
        socket =
          if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
            socket
            |> update(:thread_messages, &(&1 ++ [msg]))
            |> put_thread_attachment_map_entry(msg.id, attachments)
          else
            socket
          end

        # Update inline thread if expanded
        socket = maybe_update_inline_thread(socket, msg)

        {:noreply, SearchHooks.maybe_refresh(socket)}
      end
    end
  end

  def handle_info({:message_updated, msg}, socket) do
    attachments = Chat.list_attachments(msg.id)

    {:noreply,
     socket
     |> stream_insert(:messages, msg)
     |> put_attachment_map_entry(msg.id, attachments)
     |> SearchHooks.maybe_refresh()}
  end

  def handle_info({:message_deleted, msg}, socket) do
    {:noreply,
     socket
     |> stream_delete(:messages, msg)
     |> delete_attachment_map_entry(msg.id)
     |> delete_thread_attachment_map_entry(msg.id)
     |> SearchHooks.maybe_refresh()}
  end

  def handle_info({:reaction_added, reaction}, socket) do
    reactions_map =
      add_reaction_to_map(
        socket.assigns.reactions_map,
        reaction,
        socket.assigns.current_participant
      )

    {:noreply, assign(socket, :reactions_map, reactions_map)}
  rescue
    e ->
      require Logger
      Logger.error("Reaction broadcast (added) crashed: #{Exception.message(e)}")
      {:noreply, socket}
  end

  def handle_info({:reaction_removed, data}, socket) do
    reactions_map =
      remove_reaction_from_map(
        socket.assigns.reactions_map,
        data,
        socket.assigns.current_participant
      )

    {:noreply, assign(socket, :reactions_map, reactions_map)}
  rescue
    e ->
      require Logger
      Logger.error("Reaction broadcast (removed) crashed: #{Exception.message(e)}")
      {:noreply, socket}
  end

  def handle_info(
        {:agent_reply_chunk,
         %{chunk_id: chunk_id, text: text, done: done, participant_id: participant_id}},
        socket
      ) do
    if done do
      # Final chunk — clear the streaming entry; the real message arrives via :new_message
      {:noreply, update(socket, :streaming_replies, &Map.delete(&1, chunk_id))}
    else
      # Accumulate streaming text
      entry = %{text: text, participant_id: participant_id}
      {:noreply, update(socket, :streaming_replies, &Map.put(&1, chunk_id, entry))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="push-subscribe" phx-hook="PushSubscribe" class="hidden"></div>

    <div id="chat-state" phx-hook="ChatState" class="hidden"></div>

    <div id="meeting-client" phx-hook="MeetingClient" class="hidden"></div>
    <div id="meeting-room" phx-hook="MeetingRoom" class="hidden"></div>

    <%!-- Notification opt-in banner (shown when permission not yet granted) --%>
    <div
      :if={@push_permission == "prompt"}
      class="flex items-center justify-between gap-3 border-b border-info/20 bg-info/10 px-4 py-2"
    >
      <p class="text-sm text-info">
        <span class="hero-bell-alert mr-1 inline-block h-4 w-4 align-text-bottom" />
        Enable notifications to get alerts when agents respond or you're mentioned.
      </p>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-info btn-sm flex-shrink-0"
      >
        Enable
      </button>
    </div>

    <div class="flex h-full overflow-hidden">
      <%!-- Desktop sidebar --%>
      <aside
        id="chat-sidebar"
        phx-hook="ResizableSidebar"
        class="hidden lg:flex relative flex-shrink-0 flex-col border-r border-base-300 bg-base-200"
      >
        <%!-- Channels section --%>
        <div class="border-b border-base-300 px-4 py-3 flex items-center justify-between">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Channels
          </p>
          <button
            phx-click="new_channel_open"
            class="text-base-content/40 hover:text-primary"
            title="New channel"
          >
            <span class="hero-plus size-4"></span>
          </button>
        </div>

        <nav class="overflow-y-auto py-2">
          <.link
            :for={space <- @channels}
            navigate={~p"/chat/#{space.slug}"}
            class={[
              "flex items-center gap-2 px-3 py-1.5 text-sm transition-colors",
              "hover:bg-base-300 rounded mx-1",
              @active_space && @active_space.id == space.id &&
                "bg-primary/10 text-primary font-semibold border-l-2 border-primary"
            ]}
          >
            <span class="text-base-content/40">#</span>
            <span class="truncate flex-1">{space.name}</span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>

          <div :if={@channels == []} class="px-4 py-2 text-xs text-base-content/40">
            No channels yet
          </div>
        </nav>

        <%!-- Direct Messages section --%>
        <div class="border-t border-b border-base-300 px-4 py-3 flex items-center justify-between">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Direct Messages
          </p>
          <button
            phx-click="new_conversation_open"
            class="text-base-content/40 hover:text-primary"
            title="New conversation"
          >
            <span class="hero-plus size-4"></span>
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto py-2">
          <.link
            :for={space <- @dm_conversations}
            navigate={~p"/chat/#{space.slug || space.id}"}
            class={[
              "flex items-center gap-2 px-3 py-1.5 text-sm transition-colors",
              "hover:bg-base-300 rounded mx-1",
              @active_space && @active_space.id == space.id &&
                "bg-primary/10 text-primary font-semibold border-l-2 border-primary"
            ]}
          >
            <span class="truncate flex-1">{sidebar_display_name(space, @user_id)}</span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>

          <div :if={@dm_conversations == []} class="px-4 py-2 text-xs text-base-content/40">
            No conversations yet
          </div>
        </nav>

        <%!-- Drag handle for sidebar resize --%>
        <div
          class="absolute right-0 inset-y-0 w-1 cursor-col-resize hover:bg-primary/40 active:bg-primary/60 transition-colors z-10"
          aria-hidden="true"
        />
      </aside>

      <%!-- Mobile channel browser overlay --%>
      <%= if @mobile_browser_open do %>
        <div class="fixed inset-0 z-40 flex flex-col bg-base-100 lg:hidden">
          <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
            <p class="text-sm font-semibold">Conversations</p>
            <button
              phx-click="close_mobile_browser"
              class="flex items-center justify-center size-10 rounded-lg text-base-content/60 hover:bg-base-300 hover:text-base-content"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5"></span>
            </button>
          </header>

          <nav class="flex-1 overflow-y-auto py-2">
            <p class="px-4 py-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Channels
            </p>
            <.link
              :for={space <- @channels}
              navigate={~p"/chat/#{space.slug}"}
              phx-click="close_mobile_browser"
              class={[
                "flex items-center gap-3 px-4 py-3 text-sm transition-colors",
                "hover:bg-base-200",
                @active_space && @active_space.id == space.id &&
                  "bg-base-200 text-primary font-semibold"
              ]}
            >
              <span class="text-base-content/40 text-lg">#</span>
              <span class="truncate flex-1">{space.name}</span>
              <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                  {unread_label(Map.get(@unread_counts, space.id, 0))}
                </span>
              <% end %>
            </.link>

            <p class="px-4 py-1 mt-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Direct Messages
            </p>
            <.link
              :for={space <- @dm_conversations}
              navigate={~p"/chat/#{space.slug || space.id}"}
              phx-click="close_mobile_browser"
              class={[
                "flex items-center gap-3 px-4 py-3 text-sm transition-colors",
                "hover:bg-base-200",
                @active_space && @active_space.id == space.id &&
                  "bg-base-200 text-primary font-semibold"
              ]}
            >
              <span class="truncate flex-1">{sidebar_display_name(space, @user_id)}</span>
              <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                  {unread_label(Map.get(@unread_counts, space.id, 0))}
                </span>
              <% end %>
            </.link>

            <div
              :if={@channels == [] and @dm_conversations == []}
              class="px-4 py-6 text-sm text-base-content/40 text-center"
            >
              No conversations yet
            </div>
          </nav>
        </div>
      <% end %>

      <div class="flex flex-1 overflow-hidden min-w-0">
        <div
          id="chat-drop-zone"
          phx-hook="DragDropUpload"
          class="flex flex-1 flex-col overflow-hidden min-w-0"
        >
          <header
            :if={@active_space}
            class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-5"
          >
            <div class="flex items-center gap-2 overflow-hidden">
              <%!-- Mobile: tappable title to open browser --%>
              <button
                phx-click="toggle_mobile_browser"
                class="flex items-center gap-2 overflow-hidden lg:hidden"
                aria-label="Browse channels"
              >
                <span :if={@active_space.kind == "channel"} class="text-base-content/50">#</span>
                <span class="truncate font-semibold">
                  {space_header_name(@active_space, @space_participants, @user_id)}
                </span>
                <span class="hero-chevron-down size-4 text-base-content/40 flex-shrink-0"></span>
              </button>
              <%!-- Desktop: static title --%>
              <span class="hidden lg:flex items-center gap-2 overflow-hidden">
                <span
                  :if={@active_space.kind == "channel"}
                  class="text-base-content/50 text-lg font-bold"
                >
                  #
                </span>
                <span class="truncate font-bold text-base">
                  {space_header_name(@active_space, @space_participants, @user_id)}
                </span>
                <span
                  :if={@active_space.kind == "channel" && @active_space.topic}
                  class="truncate text-xs text-base-content/40"
                >
                  — {@active_space.topic}
                </span>
                <span
                  :if={@active_space.kind == "group"}
                  class="text-xs text-base-content/40"
                >
                  — {length(Enum.filter(@space_participants, &is_nil(&1.left_at)))} members
                </span>
              </span>

              <%!-- Promote to channel button for groups --%>
              <form
                :if={@active_space.kind == "group" && !@active_space.is_direct}
                phx-submit="promote_to_channel"
                class="hidden lg:flex items-center gap-1 ml-2"
              >
                <input
                  name="name"
                  type="text"
                  placeholder="Channel name…"
                  class="input input-bordered input-xs w-32"
                  required
                />
                <button type="submit" class="btn btn-xs btn-ghost">
                  Convert to Channel
                </button>
              </form>
            </div>

            <%!-- Join Meeting button --%>
            <button
              :if={@meetings_enabled && !@in_meeting}
              phx-click="meeting_join"
              class="flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-medium text-base-content/60 hover:text-primary hover:bg-primary/10 transition-colors"
              title="Start or join a meeting in this space"
            >
              <span class="hero-video-camera size-4"></span>
              <span class="hidden md:inline">Meet</span>
            </button>

            <div class="flex flex-shrink-0 items-center gap-3 text-xs text-base-content/50">
              <.form
                for={@search_form}
                id="chat-search-form"
                phx-change="search_submit"
                phx-submit="search_submit"
                class="hidden md:block"
              >
                <div class="flex items-center gap-2">
                  <.input
                    field={@search_form[:query]}
                    type="text"
                    placeholder="Search messages…"
                    autocomplete="off"
                    phx-debounce="250"
                    class="input input-bordered input-sm w-64 text-sm"
                  />

                  <button
                    :if={present?(@search_query)}
                    type="button"
                    phx-click="search_clear"
                    class="rounded px-2 py-1 text-xs hover:bg-base-300"
                  >
                    Clear
                  </button>
                </div>
              </.form>

              <button
                :if={@canvases != []}
                phx-click="canvas_panel_toggle"
                class={[
                  "flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300",
                  @show_canvases && "!bg-base-300 !text-primary"
                ]}
              >
                <span class="hero-puzzle-piece size-4"></span>
                <span class="hidden md:inline">{length(@canvases)}</span>
              </button>

              <button
                :if={@pins != []}
                phx-click="pin_panel_toggle"
                class={[
                  "flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300",
                  @show_pins && "!bg-base-300 !text-primary"
                ]}
              >
                <span class="hero-bookmark-solid size-4"></span>
                <span>{length(@pins)} pinned</span>
              </button>

              <%!-- Active agent indicator --%>
              <span
                :if={@active_agent_participant_id != nil}
                class="flex items-center gap-1 rounded px-2 py-0.5 text-xs text-success"
              >
                <span>🟢</span>
                <span class="hidden md:inline">Talking to {@active_agent_name || "Agent"}</span>
                <button
                  phx-click="active_agent_clear"
                  class="ml-1 text-base-content/40 hover:text-error transition-colors"
                  title="Clear active agent"
                >
                  <span class="hero-x-mark size-3"></span>
                </button>
              </span>
              <span
                :if={
                  @active_agent_participant_id == nil && @active_space.watch_enabled &&
                    (@agent_presence[:joined?] || @has_agent_participant)
                }
                class="flex items-center gap-1 rounded px-2 py-0.5 text-xs text-success/60"
              >
                <span>🟢</span>
                <span class="hidden md:inline">
                  {PresenceHooks.primary_agent_label(@active_space, @space_participants)} listening
                </span>
              </span>

              <%!-- Watch toggle (hidden for DM spaces — always ON) --%>
              <button
                :if={
                  (@agent_presence[:joined?] || @has_agent_participant) && @active_space.kind != "dm"
                }
                phx-click="toggle_watch"
                class={[
                  "flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300",
                  !@active_space.watch_enabled && "!bg-warning/20 !text-warning"
                ]}
                title={
                  if @active_space.watch_enabled,
                    do: "Disable watch — agent won't auto-respond",
                    else: "Enable watch — agent will auto-respond"
                }
              >
                <span class={[
                  "size-4",
                  if(@active_space.watch_enabled, do: "hero-eye", else: "hero-eye-slash")
                ]}>
                </span>
                <span class="hidden md:inline">
                  {if @active_space.watch_enabled, do: "watching", else: "paused"}
                </span>
              </button>

              <button
                phx-click="settings_open"
                class="flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300"
                title="Space settings"
              >
                <span class="hero-cog-6-tooth size-4"></span>
                <span class="hidden md:inline">settings</span>
              </button>
            </div>
          </header>

          <div
            :if={present?(@search_query)}
            class="border-b border-base-300 bg-base-200 px-5 py-3"
          >
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                  Search Results
                </p>
                <p class="text-sm text-base-content/70">
                  “{@search_query}” · {length(@search_results)} match{if length(@search_results) == 1,
                    do: "",
                    else: "es"}
                </p>
              </div>

              <button phx-click="search_clear" class="btn btn-ghost btn-xs">
                Clear
              </button>
            </div>

            <div class="mt-3 space-y-2">
              <button
                :for={result <- @search_results}
                type="button"
                phx-click="search_open_result"
                phx-value-message-id={result.id}
                class="block w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 text-left transition-colors hover:border-primary/40 hover:bg-base-100/80"
              >
                <div class="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-widest text-base-content/50">
                  <span>{PresenceHooks.sender_name(@participants_map, result.participant_id)}</span>
                  <.local_time
                    id={"search-time-#{result.id}"}
                    timestamp={result.inserted_at}
                  />
                  <span
                    :if={is_binary(result.thread_id)}
                    class="rounded-full bg-base-300 px-2 py-0.5 normal-case tracking-normal text-[10px]"
                  >
                    Thread
                  </span>
                  <span
                    :if={result.search_rank}
                    class="font-mono normal-case tracking-normal text-[10px] text-base-content/40"
                  >
                    rank {Float.round(result.search_rank, 3)}
                  </span>
                </div>

                <p class="mt-1 text-sm leading-6 text-base-content">
                  {search_headline(result)}
                </p>
              </button>

              <div
                :if={@search_results == []}
                class="rounded-xl border border-dashed border-base-300 bg-base-100 px-3 py-4 text-sm text-base-content/50"
              >
                No messages matched this search yet.
              </div>
            </div>
          </div>

          <div
            :if={@show_pins && @pins != []}
            class="border-b border-base-300 bg-base-200 px-5 py-2"
          >
            <p class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Pinned Messages
            </p>
            <div class="flex flex-col gap-1 max-h-40 overflow-y-auto">
              <div
                :for={pin <- @pins}
                class="flex items-center justify-between rounded bg-base-100 px-3 py-1.5 text-sm"
              >
                <span class="truncate text-base-content/70 text-xs">
                  <span class="hero-bookmark-solid size-3 inline-block align-text-bottom"></span>
                  pinned message
                  <span class="font-mono text-base-content/40 text-[10px]">
                    {String.slice(pin.message_id, 0, 8)}…
                  </span>
                </span>
                <button
                  phx-click="pin_toggle"
                  phx-value-message-id={pin.message_id}
                  phx-value-space-id={pin.space_id}
                  class="ml-2 text-xs text-base-content/40 hover:text-error"
                >
                  Unpin
                </button>
              </div>
            </div>
          </div>

          <div
            :if={@show_canvases}
            class="border-b border-base-300 bg-base-200 px-5 py-3"
          >
            <div class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_320px]">
              <div class="space-y-2">
                <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                  Live Canvases
                </p>

                <button
                  :for={canvas <- @canvases}
                  type="button"
                  phx-click="canvas_open"
                  phx-value-canvas-id={canvas.id}
                  class={[
                    "flex w-full items-center justify-between rounded-xl border px-3 py-2 text-left transition-colors",
                    "border-base-300 bg-base-100 hover:border-primary/40 hover:bg-base-100/80",
                    @active_canvas && @active_canvas.id == canvas.id && "border-primary bg-primary/5"
                  ]}
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-base-content">
                      {canvas.title || CanvasHooks.humanize_type(canvas.canvas_type)}
                    </p>
                    <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                      {CanvasHooks.humanize_type(canvas.canvas_type)}
                    </p>
                  </div>

                  <span class="ml-3 rounded-full bg-base-300 px-2 py-0.5 text-[11px] text-base-content/60">
                    Open
                  </span>
                </button>

                <div
                  :if={@canvases == []}
                  class="rounded-xl border border-dashed border-base-300 bg-base-100 px-3 py-4 text-sm text-base-content/50"
                >
                  No canvases yet. Create one to collaborate live in this channel.
                </div>
              </div>

              <.form
                for={@new_canvas_form}
                id="new-canvas-form"
                phx-submit="canvas_create"
                class="space-y-3 rounded-2xl border border-base-300 bg-base-100 p-4"
              >
                <div>
                  <p class="text-sm font-semibold text-base-content">New canvas</p>
                  <p class="text-xs text-base-content/50">
                    Creates a canvas and posts a linked canvas message.
                  </p>
                </div>

                <div class="space-y-1.5">
                  <label class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                    Title
                  </label>
                  <input
                    type="text"
                    name="canvas[title]"
                    value={@new_canvas_form[:title].value || ""}
                    placeholder="Sprint planning board"
                    class="input input-bordered w-full"
                  />
                </div>

                <div class="space-y-1.5">
                  <label class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                    Canvas type
                  </label>
                  <select name="canvas[canvas_type]" class="select select-bordered w-full">
                    <option
                      :for={type <- @canvas_types}
                      value={type}
                      selected={@new_canvas_form[:canvas_type].value == type}
                    >
                      {CanvasHooks.humanize_type(type)}
                    </option>
                  </select>
                </div>

                <button
                  type="submit"
                  class="btn btn-neutral w-full"
                  disabled={is_nil(@current_participant)}
                >
                  Create canvas
                </button>
              </.form>
            </div>
          </div>

          <div id="inline-focus-listener" phx-hook="InlineFocus" class="hidden"></div>
          <div
            id="message-list"
            class="flex-1 overflow-y-auto overflow-x-hidden bg-base-100 px-5 py-4 flex flex-col space-y-1"
            phx-update="stream"
            phx-hook="ScrollToBottom"
          >
            <div
              :for={{dom_id, msg} <- @streams.messages}
              :if={is_nil(msg.deleted_at)}
              id={dom_id}
              class={[
                "group relative flex gap-3 rounded-xl px-2 py-2 transition-colors",
                MapSet.member?(@agent_participant_ids, msg.participant_id) && "msg-agent",
                @highlighted_message_id == msg.id && "bg-primary/5 ring-1 ring-primary/20",
                @current_participant && msg.participant_id == @current_participant.id &&
                  !MapSet.member?(@agent_participant_ids, msg.participant_id) && "bg-base-200/60"
              ]}
              style={
                if MapSet.member?(@agent_participant_ids, msg.participant_id) do
                  accent =
                    Map.get(
                      @agent_colors_map,
                      msg.participant_id,
                      Platform.Agents.ColorPalette.default_accent()
                    )

                  "--agent-accent: #{accent};"
                end
              }
              data-participant-id={msg.participant_id}
              data-date={msg.inserted_at && DateTime.to_date(msg.inserted_at) |> Date.to_iso8601()}
            >
              <%!-- Avatar circle (hidden when grouped with previous message via JS) --%>
              <div class="flex-shrink-0 mt-0.5 message-avatar">
                <%= if MapSet.member?(@agent_participant_ids, msg.participant_id) do %>
                  <div class="w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold select-none bg-base-300 text-primary msg-agent-avatar">
                    {PresenceHooks.avatar_initial(@participants_map, msg.participant_id)}
                  </div>
                <% else %>
                  <.human_avatar
                    name={PresenceHooks.sender_name(@participants_map, msg.participant_id)}
                    avatar_url={
                      PresenceHooks.sender_avatar_url(@participants_map, msg.participant_id)
                    }
                    seed={PresenceHooks.sender_avatar_seed(@participants_map, msg.participant_id)}
                    size="md"
                  />
                <% end %>
              </div>

              <%!-- Message body --%>
              <div class="flex-1 min-w-0">
                <div class="flex items-baseline gap-2 message-header">
                  <span class={[
                    "text-sm font-bold",
                    if(MapSet.member?(@agent_participant_ids, msg.participant_id),
                      do: "msg-agent-name",
                      else: "text-base-content"
                    )
                  ]}>
                    {PresenceHooks.sender_name(@participants_map, msg.participant_id)}
                    <span
                      :if={MapSet.member?(@agent_participant_ids, msg.participant_id)}
                      class="msg-agent-badge"
                    >
                      AI
                    </span>
                  </span>
                  <.local_time
                    id={"message-time-#{msg.id}"}
                    timestamp={msg.inserted_at}
                    class="text-[10px] text-base-content/40"
                  />

                  <div class="ml-auto hidden group-hover:flex items-center gap-1">
                    <button
                      :for={emoji <- @quick_emojis}
                      phx-click="react"
                      phx-value-message_id={msg.id}
                      phx-value-emoji={emoji}
                      title={"React with #{emoji}"}
                      class="rounded px-1.5 py-0.5 text-sm hover:bg-base-300 transition-colors"
                    >
                      {emoji}
                    </button>

                    <button
                      :if={present?(msg.content)}
                      phx-hook="CopyToClipboard"
                      id={"copy-msg-#{msg.id}"}
                      data-clipboard-text={msg.content}
                      title="Copy message"
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors"
                    >
                      <span class="hero-clipboard-document-list size-4"></span>
                    </button>

                    <button
                      phx-click="toggle_inline_thread"
                      phx-value-message-id={msg.id}
                      title="Reply"
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors"
                    >
                      <span class="hero-chat-bubble-left-right size-4"></span>
                    </button>

                    <button
                      phx-click="toggle_inline_thread"
                      phx-value-message-id={msg.id}
                      title="Open thread"
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/40 hover:text-base-content/60 hover:bg-base-300 transition-colors"
                    >
                      <span class="hero-arrow-top-right-on-square size-4"></span>
                    </button>

                    <button
                      phx-click="pin_toggle"
                      phx-value-message-id={msg.id}
                      phx-value-space-id={msg.space_id}
                      title={if MapSet.member?(@pinned_message_ids, msg.id), do: "Unpin", else: "Pin"}
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors"
                    >
                      <span class={[
                        "size-4",
                        if(MapSet.member?(@pinned_message_ids, msg.id),
                          do: "hero-bookmark-solid",
                          else: "hero-bookmark"
                        )
                      ]}>
                      </span>
                    </button>
                  </div>
                </div>

                <div
                  :if={msg.content_type == "canvas"}
                  class="mt-1"
                >
                  <div :if={Map.get(@canvases_by_message_id, msg.id)} class="min-w-0 overflow-hidden">
                    <.canvas_document
                      canvas={Map.get(@canvases_by_message_id, msg.id)}
                      inline={true}
                      dom_id_base="chat-message-inline"
                    />
                  </div>

                  <div
                    :if={is_nil(Map.get(@canvases_by_message_id, msg.id))}
                    phx-click="canvas_open_mobile"
                    phx-value-message-id={msg.id}
                    class="rounded-lg bg-base-200 px-3 py-2 cursor-pointer hover:bg-base-300 transition-colors"
                  >
                    <p class="truncate text-sm font-semibold text-base-content">
                      {CanvasHooks.message_canvas_title(msg, @canvases_by_message_id)}
                    </p>
                    <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                      {CanvasHooks.message_canvas_type(msg, @canvases_by_message_id)} canvas
                    </p>
                  </div>
                </div>

                <div
                  :if={msg.content_type != "canvas" and present?(msg.content)}
                  class="prose prose-sm max-w-none text-sm text-base-content break-words chat-markdown"
                >
                  {Platform.Chat.ContentRenderer.render_message(msg.content)}
                </div>

                <%!-- Image gallery --%>
                <% images = Enum.filter(Map.get(@attachments_map, msg.id, []), &image_attachment?/1) %>
                <% non_images =
                  Enum.reject(Map.get(@attachments_map, msg.id, []), &image_attachment?/1) %>
                <div
                  :if={images != []}
                  class={"image-gallery count-#{min(length(images), 5)}"}
                >
                  <div
                    :for={{attachment, idx} <- Enum.with_index(images)}
                    phx-click="open_lightbox"
                    phx-value-url={attachment_url(attachment)}
                    class={"gallery-item cursor-pointer#{if length(images) == 3 and idx == 0, do: " span-2", else: ""}"}
                  >
                    <img
                      src={attachment_url(attachment)}
                      alt={attachment.filename}
                      loading="lazy"
                    />
                    <span class="gallery-filename">{attachment.filename}</span>
                    <div class="gallery-overlay">
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" /><line
                          x1="11"
                          y1="8"
                          x2="11"
                          y2="14"
                        /><line x1="8" y1="11" x2="14" y2="11" />
                      </svg>
                    </div>
                  </div>
                </div>
                <div :if={non_images != []} class="mt-1 flex flex-col gap-2">
                  <a
                    :for={attachment <- non_images}
                    href={attachment_url(attachment)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex w-fit items-center gap-2 rounded bg-base-200 px-2 py-1 text-sm text-primary hover:bg-base-300 hover:no-underline"
                  >
                    <span class="hero-paper-clip size-4"></span>
                    <span>{attachment.filename}</span>
                    <span class="text-xs text-base-content/40">
                      ({format_bytes(attachment.byte_size)})
                    </span>
                  </a>
                </div>

                <div
                  :if={Map.get(@reactions_map, msg.id, []) != []}
                  class="flex flex-wrap gap-1 mt-0.5"
                >
                  <button
                    :for={r <- Map.get(@reactions_map, msg.id, [])}
                    phx-click="react"
                    phx-value-message_id={msg.id}
                    phx-value-emoji={r.emoji}
                    class={[
                      "flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs transition-colors",
                      "hover:bg-base-300",
                      r.reacted_by_me && "border-primary bg-primary/10 text-primary",
                      !r.reacted_by_me && "border-base-300 text-base-content/60"
                    ]}
                  >
                    <span>{r.emoji}</span>
                    <span>{r.count}</span>
                  </button>

                  <button
                    class="flex items-center gap-1 rounded-full border border-dashed border-base-300 px-2 py-0.5 text-xs text-base-content/40 hover:bg-base-300 hover:text-base-content transition-colors opacity-0 group-hover:opacity-100"
                    phx-click="open_reaction_picker"
                    phx-value-message-id={msg.id}
                  >
                    <span class="hero-plus size-4"></span>
                  </button>
                </div>

                <%!-- Inline thread: indicator + expanded thread --%>
                <div :if={
                  Map.has_key?(@thread_previews, msg.id) or
                    MapSet.member?(@expanded_threads, msg.id)
                }>
                  <%!-- Thread indicator (collapsed state) --%>
                  <div
                    :if={not MapSet.member?(@expanded_threads, msg.id)}
                    phx-click="toggle_inline_thread"
                    phx-value-message-id={msg.id}
                    class="thread-indicator"
                  >
                    <div class="thread-avatars">
                      <div class="t-av ai">↩</div>
                    </div>
                    <span class="ti-count">
                      {Map.get(@thread_previews, msg.id, %{}) |> Map.get(:reply_count, 0)}
                      {if Map.get(@thread_previews, msg.id, %{}) |> Map.get(:reply_count, 0) == 1,
                        do: "reply",
                        else: "replies"}
                    </span>
                    <span
                      :if={Map.get(@thread_previews, msg.id, %{}) |> Map.get(:last_reply_at)}
                      class="ti-time"
                    >
                      · {relative_time(
                        Map.get(@thread_previews, msg.id, %{})
                        |> Map.get(:last_reply_at)
                      )}
                    </span>
                  </div>

                  <%!-- Expanded thread --%>
                  <div
                    :if={MapSet.member?(@expanded_threads, msg.id)}
                    class="thread-replies"
                    id={"inline-thread-#{msg.id}"}
                    phx-hook="InlineThread"
                  >
                    <div
                      :for={tmsg <- Map.get(@inline_thread_messages, msg.id, [])}
                      class={[
                        "thread-reply",
                        if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                          do: "agent-reply"
                        )
                      ]}
                    >
                      <div
                        class={[
                          "msg-avatar",
                          if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                            do: "ai",
                            else: "human"
                          )
                        ]}
                        style="width:28px;height:28px;font-size:10px"
                      >
                        {PresenceHooks.avatar_initial(@participants_map, tmsg.participant_id)}
                      </div>
                      <div class="msg-body">
                        <div class="msg-header">
                          <span class={[
                            "msg-username",
                            if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                              do: "ai-name"
                            )
                          ]}>
                            {PresenceHooks.sender_name(@participants_map, tmsg.participant_id)}
                          </span>
                          <span
                            :if={MapSet.member?(@agent_participant_ids, tmsg.participant_id)}
                            class="ai-badge"
                          >
                            AI
                          </span>
                          <.local_time
                            id={"inline-thread-ts-#{tmsg.id}"}
                            timestamp={tmsg.inserted_at}
                            class="msg-time"
                          />
                        </div>
                        <div class="msg-text">
                          {Platform.Chat.ContentRenderer.render_message(tmsg.content)}
                        </div>
                      </div>
                    </div>

                    <%!-- Thread composer --%>
                    <div class="thread-composer" style="flex-direction: column; align-items: stretch;">
                      <.form
                        for={%{}}
                        id={"inline-thread-compose-form-#{msg.id}"}
                        phx-submit="send_inline_thread_message"
                        class="thread-composer-form"
                        style="position: relative;"
                      >
                        <%!-- @mention autocomplete dropdown (inline thread) --%>
                        <div
                          :if={
                            @mention_suggestions != [] &&
                              @mention_source == "inline-thread-compose-form-#{msg.id}"
                          }
                          style="position: absolute; bottom: 100%; left: 0; z-index: 50; width: 16rem; margin-bottom: 4px;"
                        >
                          <div class="rounded-xl border border-base-300 bg-base-100 shadow-lg overflow-hidden">
                            <div class="py-1">
                              <button
                                :for={{suggestion, idx} <- Enum.with_index(@mention_suggestions)}
                                type="button"
                                data-mention-suggestion={if idx == 0, do: "first"}
                                phx-click={
                                  JS.dispatch("chat:insert-mention",
                                    to: "#inline-thread-compose-#{msg.id}",
                                    detail: %{name: suggestion.display_name || "User"}
                                  )
                                }
                                class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                              >
                                <div class="w-6 h-6 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-bold flex-shrink-0">
                                  {(suggestion.display_name || "U")
                                  |> String.trim()
                                  |> String.first()
                                  |> String.upcase()}
                                </div>
                                <span class="flex-1 truncate font-medium">
                                  {suggestion.display_name || "User"}
                                </span>
                                <span class={[
                                  "rounded-full px-1.5 py-0.5 text-[10px] uppercase tracking-wider",
                                  suggestion.participant_type == "agent" &&
                                    "bg-primary/10 text-primary",
                                  suggestion.participant_type != "agent" &&
                                    "bg-base-300 text-base-content/50"
                                ]}>
                                  {suggestion.participant_type}
                                </span>
                              </button>
                            </div>
                          </div>
                        </div>
                        <input
                          type="hidden"
                          name="inline_thread_compose[message_id]"
                          value={msg.id}
                        />
                        <input
                          type="text"
                          name="inline_thread_compose[text]"
                          id={"inline-thread-compose-#{msg.id}"}
                          placeholder="Reply in thread..."
                          autocomplete="off"
                          class="thread-input"
                          phx-hook="ComposeInput"
                        />
                        <button
                          type="submit"
                          class="thread-send"
                          disabled={is_nil(@current_participant)}
                          title="Reply"
                        >
                          <span class="hero-paper-airplane size-3.5 -rotate-45"></span>
                        </button>
                      </.form>
                    </div>

                    <%!-- Collapse thread --%>
                    <button
                      phx-click="toggle_inline_thread"
                      phx-value-message-id={msg.id}
                      class="thread-collapse"
                    >
                      ▲ Collapse thread
                    </button>
                  </div>
                </div>
              </div>
              <%!-- end message body --%>

              <%!-- Left-gutter reply button (desktop, hidden until hover via CSS) --%>
              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={msg.id}
                class="msg-reply-gutter"
                title="Reply"
              >
                ↩
              </button>
            </div>
          </div>

          <%!-- Streaming reply bubbles --%>
          <div
            :for={{chunk_id, entry} <- @streaming_replies}
            :if={entry.text != nil and entry.text != ""}
            id={"streaming-#{chunk_id}"}
            class="flex-shrink-0 px-5 pb-2 msg-agent"
            style={
              "--agent-accent: #{Map.get(@agent_colors_map, entry.participant_id, Platform.Agents.ColorPalette.default_accent())};"
            }
          >
            <div class="flex items-start gap-2">
              <div class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-xs font-medium msg-agent-avatar">
                {PresenceHooks.avatar_initial(@participants_map, entry.participant_id)}
              </div>
              <div class="min-w-0 flex-1">
                <div class="text-xs font-medium mb-0.5 msg-agent-name">
                  {PresenceHooks.sender_name(@participants_map, entry.participant_id)}
                </div>
                <div
                  class="prose prose-sm max-w-none text-sm text-base-content/80 border-l-2 pl-3"
                  style="border-color: color-mix(in oklch, var(--agent-accent, oklch(82% 0.12 207)) 30%, transparent);"
                >
                  {entry.text}<span
                    class="inline-block w-1.5 h-4 animate-pulse ml-0.5 align-middle rounded-sm"
                    style="background: color-mix(in oklch, var(--agent-accent, oklch(82% 0.12 207)) 50%, transparent);"
                  ></span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Typing indicator --%>
          <div
            :if={not MapSet.equal?(@agent_typing_pids, MapSet.new()) and @streaming_replies == %{}}
            class="flex-shrink-0 px-5 pb-1 flex items-center gap-2 text-xs text-base-content/50"
          >
            <span class="flex gap-0.5 items-center">
              <span
                class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
                style="animation-delay: 0ms"
              >
              </span>
              <span
                class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
                style="animation-delay: 150ms"
              >
              </span>
              <span
                class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
                style="animation-delay: 300ms"
              >
              </span>
            </span>
            <span>
              {PresenceHooks.thinking_label(@agent_typing_pids, @participants_map)} is thinking…
            </span>
          </div>

          <div class="flex-shrink-0 compose-input-area safe-area-bottom">
            <.form
              :if={@active_space}
              for={@compose_form}
              id="compose-form"
              phx-submit="send_message"
              phx-change="compose_changed"
              class="flex flex-col gap-2"
            >
              <%!-- @mention autocomplete dropdown --%>
              <div
                :if={@mention_suggestions != [] && @mention_source == "compose-form"}
                class="relative"
              >
                <div class="absolute bottom-0 left-0 z-50 w-64 rounded-xl border border-base-300 bg-base-100 shadow-lg overflow-hidden">
                  <div class="py-1">
                    <button
                      :for={{suggestion, idx} <- Enum.with_index(@mention_suggestions)}
                      type="button"
                      data-mention-suggestion={if idx == 0, do: "first"}
                      phx-click={
                        JS.dispatch("chat:insert-mention",
                          to: "##{@compose_form[:text].id}",
                          detail: %{name: suggestion.name}
                        )
                      }
                      class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                    >
                      <%= if suggestion.participant_type == "agent" do %>
                        <div class="w-6 h-6 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-bold flex-shrink-0">
                          {suggestion
                          |> Map.get(:name)
                          |> String.trim()
                          |> String.first()
                          |> String.upcase()}
                        </div>
                      <% else %>
                        <.human_avatar
                          name={suggestion.name}
                          avatar_url={suggestion.avatar_url}
                          seed={suggestion.avatar_seed}
                          size="sm"
                          class="flex-shrink-0"
                        />
                      <% end %>
                      <span class="flex-1 truncate font-medium">
                        {suggestion.name}
                      </span>
                      <span class={[
                        "rounded-full px-1.5 py-0.5 text-[10px] uppercase tracking-wider",
                        suggestion.participant_type == "agent" && "bg-primary/10 text-primary",
                        suggestion.participant_type != "agent" && "bg-base-300 text-base-content/50"
                      ]}>
                        {suggestion.participant_type}
                      </span>
                    </button>
                  </div>
                </div>
              </div>

              <%!-- Hidden file input — outside pill bar to avoid flex layout interference --%>
              <.live_file_input
                upload={@uploads.attachments}
                class="hidden"
                id="upload-file-trigger"
              />

              <%!-- Pill-shaped compose bar --%>
              <div class="compose-pill-bar">
                <button
                  type="button"
                  phx-click="upload_dialog_open"
                  class="compose-pill-attach cursor-pointer text-base-content/50 hover:bg-base-300/50 transition-colors"
                  title="Attach files"
                >
                  <span class="hero-plus size-5"></span>
                </button>

                <textarea
                  name="compose[text]"
                  id={@compose_form[:text].id}
                  data-draft-key={if @active_space, do: "chat-draft:" <> @active_space.id, else: nil}
                  placeholder={"Message ##{(@active_space && @active_space.name) || ""}"}
                  autocomplete="off"
                  rows="1"
                  class="min-w-0 flex-1 text-sm resize-none"
                  style="line-height:1.5;padding:4px 0;min-height:28px;max-height:200px;overflow-y:auto;field-sizing:content"
                  phx-hook="ComposeInput"
                >{Phoenix.HTML.Form.normalize_value("text", @compose_form[:text].value)}</textarea>

                <button
                  type="submit"
                  class="compose-pill-send"
                  disabled={is_nil(@current_participant)}
                  title="Send"
                >
                  <span class="hero-paper-airplane size-4 -rotate-45"></span>
                </button>
              </div>

              <p
                :for={error <- upload_errors(@uploads.attachments)}
                class="text-xs text-error"
              >
                {upload_error_to_string(error)}
              </p>

              <div :for={entry <- @uploads.attachments.entries}>
                <p
                  :for={error <- upload_errors(@uploads.attachments, entry)}
                  class="text-xs text-error"
                >
                  {entry.client_name}: {upload_error_to_string(error)}
                </p>
              </div>
            </.form>

            <p :if={is_nil(@current_participant) && @active_space} class="mt-1 text-xs text-error">
              Unable to join space — messages are read-only.
            </p>
          </div>

          <%!-- Upload staging dialog --%>
          <%= if @upload_dialog_open do %>
            <div class="upload-backdrop" phx-click="upload_dialog_close">
              <div class="upload-panel" phx-click="noop">
                <%!-- Header --%>
                <div class="upload-header">
                  <div class="upload-header-icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <rect x="3" y="3" width="18" height="18" rx="2" /><circle
                        cx="8.5"
                        cy="8.5"
                        r="1.5"
                      /><path d="M21 15l-5-5L5 21" />
                    </svg>
                  </div>
                  <div class="upload-header-text">
                    <div class="upload-title">Share Images</div>
                    <div class="upload-subtitle">
                      Upload images to
                      <strong>{"##{(@active_space && @active_space.name) || ""}"}</strong>
                    </div>
                  </div>
                  <button type="button" class="upload-close" phx-click="upload_dialog_close">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
                    </svg>
                  </button>
                </div>

                <%!-- Empty: Drop Zone --%>
                <div
                  :if={@uploads.attachments.entries == []}
                  class="upload-dropzone"
                  phx-click={JS.dispatch("click", to: "#upload-file-trigger")}
                >
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                    <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" /><polyline points="17 8 12 3 7 8" /><line
                      x1="12"
                      y1="3"
                      x2="12"
                      y2="15"
                    />
                  </svg>
                  <div class="upload-dropzone-title">Drag & drop images here</div>
                  <div class="upload-dropzone-or">or</div>
                  <button
                    type="button"
                    class="upload-browse-btn"
                    phx-click={JS.dispatch("click", to: "#upload-file-trigger")}
                  >
                    Browse files
                  </button>
                  <div class="upload-dropzone-sub">You can also paste images with ⌘V</div>
                  <div class="upload-dropzone-formats">
                    PNG · JPG · GIF · WebP · SVG — max 15 MB each
                  </div>
                </div>

                <%!-- Populated: Image Grid --%>
                <div :if={@uploads.attachments.entries != []} class="upload-grid-area">
                  <div class="upload-grid">
                    <div :for={entry <- @uploads.attachments.entries} class="upload-thumb">
                      <%= if String.starts_with?(entry.client_type, "image/") do %>
                        <.live_img_preview
                          entry={entry}
                          class="upload-thumb-inner"
                          style="width:100%;height:100%;object-fit:cover"
                        />
                      <% else %>
                        <div class="upload-thumb-inner">
                          <svg
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="1.5"
                          >
                            <rect x="3" y="3" width="18" height="18" rx="2" /><circle
                              cx="8.5"
                              cy="8.5"
                              r="1.5"
                            /><path d="M21 15l-5-5L5 21" />
                          </svg>
                        </div>
                      <% end %>
                      <span class="upload-thumb-name">{entry.client_name}</span>
                      <button
                        type="button"
                        class="upload-thumb-remove"
                        phx-click="upload_entry_cancel"
                        phx-value-ref={entry.ref}
                      >
                        ×
                      </button>
                      <%!-- Progress bar --%>
                      <div
                        :if={entry.progress > 0 and entry.progress < 100}
                        style="position:absolute;bottom:0;left:0;right:0;height:3px;background:rgba(0,0,0,0.3)"
                      >
                        <div style={"height:100%;background:var(--cyan);width:#{entry.progress}%;transition:width 300ms ease"}>
                        </div>
                      </div>
                    </div>
                    <%!-- Add more tile --%>
                    <button
                      type="button"
                      class="upload-add-tile"
                      phx-click={JS.dispatch("click", to: "#upload-file-trigger")}
                    >
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
                      </svg>
                      Add more
                    </button>
                  </div>
                </div>

                <%!-- Upload errors --%>
                <div :if={upload_errors(@uploads.attachments) != []} style="padding:0 20px">
                  <p
                    :for={error <- upload_errors(@uploads.attachments)}
                    class="text-xs"
                    style="color:var(--danger);margin-bottom:4px"
                  >
                    {upload_error_to_string(error)}
                  </p>
                </div>
                <div :for={entry <- @uploads.attachments.entries} style="padding:0 20px">
                  <p
                    :for={error <- upload_errors(@uploads.attachments, entry)}
                    class="text-xs"
                    style="color:var(--danger);margin-bottom:4px"
                  >
                    {entry.client_name}: {upload_error_to_string(error)}
                  </p>
                </div>

                <%!-- Agent Tag Section --%>
                <div :if={@uploads.attachments.entries != []} class="upload-agent-section">
                  <div class="upload-agent-label">Tag an agent</div>
                  <div class="upload-agent-chips">
                    <button
                      :for={
                        {slug, label} <- [
                          {"beacon", "Beacon"},
                          {"pixel", "Pixel"},
                          {"builder", "Builder"},
                          {"higgins", "Higgins"}
                        ]
                      }
                      type="button"
                      class={"agent-chip #{slug}#{if MapSet.member?(@upload_tagged_agents, slug), do: " selected", else: ""}"}
                      phx-click="upload_toggle_agent"
                      phx-value-agent={slug}
                    >
                      <span class="chip-dot"></span> {label}
                    </button>
                  </div>
                </div>

                <%!-- Comment --%>
                <div :if={@uploads.attachments.entries != []} class="upload-comment">
                  <form phx-change="upload_caption_change" phx-submit="upload_send">
                    <textarea
                      name="caption"
                      class="upload-comment-input"
                      placeholder="Add a comment about these images..."
                      phx-debounce="200"
                    >{@upload_caption}</textarea>
                  </form>
                </div>

                <%!-- Footer --%>
                <div :if={@uploads.attachments.entries != []} class="upload-footer">
                  <div class="upload-count">
                    <strong>{length(@uploads.attachments.entries)}</strong>
                    {if length(@uploads.attachments.entries) == 1, do: "image", else: "images"} selected
                  </div>
                  <div class="upload-footer-actions">
                    <button type="button" class="upload-btn-cancel" phx-click="upload_dialog_close">
                      Cancel
                    </button>
                    <button
                      type="button"
                      class="upload-btn-send"
                      phx-click="upload_send"
                      disabled={@uploads.attachments.entries == []}
                    >
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                        <line x1="22" y1="2" x2="11" y2="13" /><polygon points="22 2 15 22 11 13 2 9 22 2" />
                      </svg>
                      Send to {"##{(@active_space && @active_space.name) || ""}"}
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <%!-- Upload file input is in the compose area above (single instance to avoid duplicate IDs) --%>
          <% end %>
        </div>

        <%!-- Desktop: side panel --%>
        <div
          :if={@active_canvas}
          class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
        >
          <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
            <div class="min-w-0">
              <p class="text-sm font-semibold">Live Canvas</p>
              <p class="truncate text-xs text-base-content/50">
                {@active_canvas.title || CanvasHooks.humanize_type(@active_canvas.canvas_type)}
              </p>
            </div>

            <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <div class="flex-1 overflow-y-auto px-4 py-4">
            <.canvas_document canvas={@active_canvas} dom_id_base="chat-live-canvas-panel" />
          </div>
        </div>

        <%!-- Mobile: full-screen canvas overlay --%>
        <%= if @active_canvas do %>
          <div class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden">
            <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
              <div class="min-w-0">
                <p class="text-sm font-semibold">Live Canvas</p>
                <p class="truncate text-xs text-base-content/50">
                  {@active_canvas.title || CanvasHooks.humanize_type(@active_canvas.canvas_type)}
                </p>
              </div>

              <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
                <span class="hero-x-mark size-4"></span>
              </button>
            </header>

            <div class="flex-1 overflow-y-auto px-4 py-4">
              <.canvas_document canvas={@active_canvas} dom_id_base="chat-live-canvas-overlay" />
            </div>
          </div>
        <% end %>

        <%!-- Desktop: Meeting panel (side column) --%>
        <div
          :if={@in_meeting}
          id="meeting-panel"
          phx-hook="MeetingRoom"
          class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
        >
          <%!-- Panel header --%>
          <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
            <div class="flex items-center gap-2 min-w-0">
              <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
              <p class="text-sm font-semibold truncate">
                {(@active_space && @active_space.name) || "Meeting"}
              </p>
              <span id="meeting-duration" class="text-xs text-base-content/50 tabular-nums">
                0:00
              </span>
            </div>
            <button
              phx-click="meeting_leave"
              class="btn btn-ghost btn-xs text-error"
              title="Leave meeting"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Participant grid --%>
          <div class="flex-1 overflow-y-auto p-3">
            <div id="meeting-participants" class="meeting-participant-grid gap-2">
              <%!-- Participant tiles injected by meeting_panel.js --%>
            </div>

            <%!-- Meeting captions overlay --%>
            <div
              id="meeting-captions"
              phx-hook="MeetingCaptions"
              class="mt-2 rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 pointer-events-none transition-opacity duration-300"
            >
            </div>
          </div>

          <%!-- Controls bar --%>
          <div class="flex items-center justify-center gap-2 border-t border-base-300 px-4 py-3">
            <button
              phx-click="meeting_toggle_mic"
              class={[
                "meeting-control-btn rounded-full p-2.5 transition-colors",
                if(@mic_enabled,
                  do: "bg-base-200 hover:bg-base-300 text-base-content",
                  else: "bg-error/20 text-error hover:bg-error/30"
                )
              ]}
              title={if @mic_enabled, do: "Mute microphone", else: "Unmute microphone"}
            >
              <span class={[
                "size-5",
                if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
              ]}>
              </span>
            </button>

            <button
              phx-click="meeting_toggle_camera"
              class={[
                "meeting-control-btn rounded-full p-2.5 transition-colors",
                if(@camera_enabled,
                  do: "bg-base-200 hover:bg-base-300 text-base-content",
                  else: "bg-error/20 text-error hover:bg-error/30"
                )
              ]}
              title={if @camera_enabled, do: "Turn off camera", else: "Turn on camera"}
            >
              <span class={[
                "size-5",
                if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
              ]}>
              </span>
            </button>

            <button
              phx-click="meeting_toggle_screen_share"
              class={[
                "meeting-control-btn rounded-full p-2.5 transition-colors",
                if(@screen_share_enabled,
                  do: "bg-primary/20 text-primary hover:bg-primary/30",
                  else: "bg-base-200 hover:bg-base-300 text-base-content"
                )
              ]}
              title={if @screen_share_enabled, do: "Stop sharing screen", else: "Share screen"}
            >
              <span class="hero-computer-desktop size-5"></span>
            </button>

            <button
              phx-click="meeting_leave"
              class="meeting-control-btn rounded-full p-2.5 bg-error text-error-content hover:bg-error/80 transition-colors"
              title="Leave meeting"
            >
              <span class="hero-phone-x-mark size-5"></span>
            </button>
          </div>

          <%!-- Hidden media container for audio elements --%>
          <div id="meeting-media" class="hidden"></div>
        </div>

        <%!-- Mobile/Tablet: Meeting overlay --%>
        <%= if @in_meeting do %>
          <div class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden">
            <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
              <div class="flex items-center gap-2 min-w-0">
                <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
                <p class="text-sm font-semibold truncate">
                  {(@active_space && @active_space.name) || "Meeting"}
                </p>
                <span id="meeting-duration-mobile" class="text-xs text-base-content/50 tabular-nums">
                  0:00
                </span>
              </div>
              <button phx-click="meeting_leave" class="btn btn-ghost btn-xs" title="Back to chat">
                <span class="hero-arrow-left size-4"></span>
                <span class="text-xs">Chat</span>
              </button>
            </header>

            <div class="flex-1 overflow-y-auto p-4">
              <div class="meeting-participant-grid gap-2"></div>
            </div>

            <div class="flex items-center justify-center gap-3 border-t border-base-300 px-4 py-4 safe-area-bottom">
              <button
                phx-click="meeting_toggle_mic"
                class={[
                  "meeting-control-btn rounded-full p-3 transition-colors",
                  if(@mic_enabled,
                    do: "bg-base-200 text-base-content",
                    else: "bg-error/20 text-error"
                  )
                ]}
              >
                <span class={[
                  "size-6",
                  if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
                ]}>
                </span>
              </button>

              <button
                phx-click="meeting_toggle_camera"
                class={[
                  "meeting-control-btn rounded-full p-3 transition-colors",
                  if(@camera_enabled,
                    do: "bg-base-200 text-base-content",
                    else: "bg-error/20 text-error"
                  )
                ]}
              >
                <span class={[
                  "size-6",
                  if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
                ]}>
                </span>
              </button>

              <button
                phx-click="meeting_toggle_screen_share"
                class={[
                  "meeting-control-btn rounded-full p-3 transition-colors",
                  if(@screen_share_enabled,
                    do: "bg-primary/20 text-primary",
                    else: "bg-base-200 text-base-content"
                  )
                ]}
              >
                <span class="hero-computer-desktop size-6"></span>
              </button>

              <button
                phx-click="meeting_leave"
                class="meeting-control-btn rounded-full p-3 bg-error text-error-content hover:bg-error/80 transition-colors"
              >
                <span class="hero-phone-x-mark size-6"></span>
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Side thread panel removed — all thread interaction is inline --%>
      </div>
    </div>

    <.live_component
      module={SettingsComponent}
      id="chat-settings"
      open={@show_settings}
      space={@active_space}
    />

    <.live_component
      module={NewChannelComponent}
      id="chat-new-channel"
      open={@show_new_channel_modal}
    />

    <.live_component
      module={NewConversationComponent}
      id="chat-new-conversation"
      open={@show_new_conversation_modal}
      user_id={@user_id}
    />

    <%!-- Image lightbox modal --%>
    <div
      :if={@lightbox_url}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
      phx-click="close_lightbox"
    >
      <button
        class="absolute top-4 right-4 z-10 rounded-full bg-black/50 p-2 text-white hover:bg-black/70 transition-colors safe-area-top"
        phx-click="close_lightbox"
        aria-label="Close"
      >
        <span class="hero-x-mark size-6"></span>
      </button>
      <img
        src={@lightbox_url}
        class="max-h-[90vh] max-w-[95vw] rounded-lg object-contain shadow-2xl"
        phx-click="close_lightbox"
      />
    </div>
    """
  end

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
  end

  defp restore_draft(socket, space_id) do
    draft = Map.get(socket.assigns.drafts, space_id, "")
    assign_compose(socket, draft)
  end

  defp assign_thread_compose(socket, text) do
    assign(socket, :thread_compose_form, to_form(%{"text" => text}, as: :thread_compose))
  end

  defp build_reactions_map(messages, current_participant) do
    message_ids = Enum.map(messages, & &1.id)
    my_participant_id = current_participant && current_participant.id

    raw = Chat.list_reactions_for_messages(message_ids)

    Map.new(message_ids, fn msg_id ->
      reactions = Map.get(raw, msg_id, [])

      groups =
        reactions
        |> Enum.group_by(& &1.emoji)
        |> Enum.map(fn {emoji, rs} ->
          %{
            emoji: emoji,
            count: length(rs),
            reacted_by_me: Enum.any?(rs, &(&1.participant_id == my_participant_id))
          }
        end)
        |> Enum.sort_by(& &1.emoji)

      {msg_id, groups}
    end)
  end

  defp build_attachments_map(messages) do
    messages
    |> Enum.map(& &1.id)
    |> Chat.list_attachments_for_messages()
  end

  defp add_reaction_to_map(reactions_map, reaction, current_participant) do
    msg_id = reaction.message_id
    my_id = current_participant && current_participant.id
    groups = Map.get(reactions_map, msg_id, [])

    updated =
      case Enum.find_index(groups, &(&1.emoji == reaction.emoji)) do
        nil ->
          new_group = %{
            emoji: reaction.emoji,
            count: 1,
            reacted_by_me: reaction.participant_id == my_id
          }

          Enum.sort_by([new_group | groups], & &1.emoji)

        idx ->
          List.update_at(groups, idx, fn g ->
            %{
              g
              | count: g.count + 1,
                reacted_by_me: g.reacted_by_me || reaction.participant_id == my_id
            }
          end)
      end

    Map.put(reactions_map, msg_id, updated)
  end

  defp remove_reaction_from_map(reactions_map, %{message_id: msg_id} = data, current_participant) do
    emoji = data[:emoji]
    removed_pid = data[:participant_id]
    my_id = current_participant && current_participant.id
    groups = Map.get(reactions_map, msg_id, [])

    updated =
      groups
      |> Enum.map(fn g ->
        if g.emoji == emoji do
          new_count = max(0, g.count - 1)
          new_reacted = g.reacted_by_me && removed_pid != my_id
          %{g | count: new_count, reacted_by_me: new_reacted}
        else
          g
        end
      end)
      |> Enum.reject(&(&1.count == 0))

    Map.put(reactions_map, msg_id, updated)
  end

  defp load_channel_messages(space_id) do
    space_id
    |> Chat.list_messages(limit: @message_limit, top_level_only: true)
    |> Enum.reverse()
  end

  # Re-insert a message into the stream to force LiveView to re-render the
  # stream item after assign changes (e.g. expanded_threads, thread_previews).
  # Stream items only re-render on explicit stream_insert, not on assign changes.
  defp reinsert_stream_message(socket, msg_id) do
    case Chat.get_message(msg_id) do
      nil -> socket
      msg -> stream_insert(socket, :messages, msg)
    end
  end

  defp load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
  end

  # Updates the inline thread view and preview counts when a new thread reply arrives via PubSub.
  defp maybe_update_inline_thread(socket, %{thread_id: thread_id} = msg)
       when is_binary(thread_id) do
    # Find the parent message ID mapped to this thread
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

  attr(:id, :string, required: true)
  attr(:timestamp, :any, default: nil)
  attr(:class, :string, default: nil)

  defp local_time(assigns) do
    ~H"""
    <time
      :if={match?(%DateTime{}, @timestamp)}
      id={@id}
      datetime={DateTime.to_iso8601(@timestamp)}
      data-local-time={DateTime.to_iso8601(@timestamp)}
      phx-hook="LocalTime"
      class={@class}
    >
      {format_timestamp(@timestamp)}
    </time>
    """
  end

  defp post_message_from_upload(socket, upload_name, attrs) do
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

  # Valid slug pattern: lowercase alphanumerics separated by hyphens (1–64 chars).
  # This intentionally excludes anything with underscores, uppercase, special chars,
  # or tool-artifact strings like "__from_file__" that should never create real spaces.
  @slug_pattern ~r/^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$/

  defp bootstrap_space(slug) when is_binary(slug) do
    cond do
      # Never bootstrap for UUIDs — those are fetched directly
      valid_uuid?(slug) ->
        nil

      # Only bootstrap slugs that look like real channel slugs
      not String.match?(slug, @slug_pattern) ->
        nil

      true ->
        name =
          slug
          |> String.replace("-", " ")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join(" ")

        case Chat.create_space(%{name: name, slug: slug, kind: "channel"}) do
          {:ok, space} -> space
          {:error, _} -> Chat.get_space_by_slug(slug)
        end
    end
  end

  defp bootstrap_space(_), do: nil

  defp valid_uuid?(string) when is_binary(string) do
    case Ecto.UUID.cast(string) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp space_page_title(%{kind: "channel", name: name}, _participants, _user_id) do
    "# #{name}"
  end

  defp space_page_title(space, participants, user_id) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  defp space_header_name(%{kind: "channel", name: name}, _participants, _user_id), do: name

  defp space_header_name(space, participants, user_id) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  defp sidebar_display_name(space, current_user_id) do
    participants = Chat.list_participants(space.id)
    Chat.display_name_for_space(space, participants, current_user_id)
  end

  defp increment_unread(socket, space_id) do
    current = Map.get(socket.assigns.unread_counts, space_id, 0)
    update(socket, :unread_counts, &Map.put(&1, space_id, current + 1))
  end

  defp clear_unread(socket, space_id) do
    update(socket, :unread_counts, &Map.delete(&1, space_id))
  end

  defp unread_label(count) when count >= 9, do: "9+"
  defp unread_label(count) when count > 0, do: Integer.to_string(count)
  defp unread_label(_), do: nil

  # ADR 0027: default_attention_mode/1 and default_attention_label/1 removed
  # (agent_attention field no longer exists on Space)

  defp ensure_participant(space_id, user_id) do
    existing =
      space_id
      |> Chat.list_participants(include_left: true)
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      nil ->
        display_name = name_for_user(user_id)

        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, p} -> p
          {:error, _} -> nil
        end

      %{left_at: nil} = p ->
        p

      p ->
        case Chat.update_participant(p, %{left_at: nil, joined_at: DateTime.utc_now()}) do
          {:ok, rejoined} -> rejoined
          {:error, _} -> p
        end
    end
  end

  defp name_for_user(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  defp relative_time(nil), do: ""

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp image_attachment?(attachment) do
    String.starts_with?(attachment.content_type || "", "image/")
  end

  defp attachment_url(attachment), do: ~p"/chat/attachments/#{attachment.id}"

  defp search_headline(message) do
    headline =
      cond do
        present?(message.search_headline) -> message.search_headline
        present?(message.content) -> message.content
        true -> "No searchable text"
      end

    headline
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("&lt;mark&gt;", "<mark>")
    |> String.replace("&lt;/mark&gt;", "</mark>")
    |> Phoenix.HTML.raw()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp format_bytes(size) when is_integer(size) and size < 1_024, do: "#{size} B"

  defp format_bytes(size) when is_integer(size) and size < 1_048_576,
    do: "#{Float.round(size / 1_024, 1)} KB"

  defp format_bytes(size) when is_integer(size) and size < 1_073_741_824,
    do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_bytes(size) when is_integer(size), do: "#{Float.round(size / 1_073_741_824, 1)} GB"
  defp format_bytes(_size), do: "—"

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:too_many_files), do: "Too many files selected"
  defp upload_error_to_string(:not_accepted), do: "File type is not accepted"
  defp upload_error_to_string(error), do: inspect(error)

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%I:%M %p")
  end

  defp format_timestamp(_), do: ""

  defp format_message_date(nil), do: ""

  defp format_message_date(%DateTime{} = dt) do
    today = Date.utc_today()
    msg_date = DateTime.to_date(dt)

    cond do
      msg_date == today -> "Today"
      msg_date == Date.add(today, -1) -> "Yesterday"
      true -> Calendar.strftime(dt, "%a, %b %-d")
    end
  end

  defp format_message_date(_), do: ""

  @impl true
  def terminate(_reason, socket) do
    MeetingHooks.on_terminate(socket)
    :ok
  end
end
