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
  alias Platform.Agents.WorkspaceBootstrap
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  @message_limit 50
  @quick_emojis ["👍", "❤️", "😂", "🎉"]
  @max_upload_entries 5
  @max_upload_size 15_000_000
  @canvas_types ~w(table form code diagram dashboard custom)
  @agent_presence_refresh_ms 30_000

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
      |> assign(:space_participants, [])
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:highlighted_message_id, nil)
      |> assign(:highlighted_thread_message_id, nil)
      |> assign(:participants_map, %{})
      |> assign(:agent_participant_ids, MapSet.new())
      |> assign(:agent_colors_map, %{})
      |> assign(:online_count, 0)
      |> assign(:agent_presence, default_agent_presence())
      |> assign(:has_agent_participant, false)
      |> assign(:current_participant, nil)
      |> assign(:reactions_map, %{})
      |> assign(:attachments_map, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_messages, [])
      |> assign(:thread_attachments_map, %{})
      |> assign(:thread_previews, %{})
      |> assign(:expanded_threads, MapSet.new())
      |> assign(:inline_thread_messages, %{})
      |> assign(:pins, [])
      |> assign(:show_pins, false)
      |> assign(:pinned_message_ids, MapSet.new())
      |> assign(:canvases, [])
      |> assign(:canvases_by_message_id, %{})
      |> assign(:active_canvas, nil)
      |> assign(:show_canvases, false)
      |> assign(:active_agent_participant_id, nil)
      |> assign(:active_agent_name, nil)
      |> assign(:mobile_browser_open, false)
      |> assign(:show_new_channel_modal, false)
      |> assign(:show_new_conversation_modal, false)
      |> assign(:show_settings, false)
      |> assign(:settings_form, to_form(%{}))
      |> assign(:picker_users, [])
      |> assign(:picker_agents, [])
      |> assign(:picker_query, "")
      |> assign(:picker_selected, [])
      |> assign(:new_channel_form, to_form(%{"name" => "", "description" => ""}))
      |> assign(:quick_emojis, @quick_emojis)
      |> assign(:canvas_types, @canvas_types)
      |> assign(:agent_typing_pids, MapSet.new())
      |> assign(:streaming_replies, %{})
      |> assign(:mention_suggestions, [])
      |> assign(:push_permission, "unknown")
      |> assign(:unread_counts, if(user_id, do: Chat.unread_counts_for_user(user_id), else: %{}))
      |> assign(:upload_dialog_open, false)
      |> assign(:upload_caption, "")
      |> assign(:drafts, %{})
      |> assign_compose("")
      |> assign_thread_compose("")
      |> assign_search_form("")
      |> assign_new_canvas_form()
      |> allow_upload(:attachments,
        accept: :any,
        auto_upload: true,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size
      )
      |> allow_upload(:thread_attachments,
        accept: :any,
        auto_upload: true,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size
      )
      |> stream(:messages, [])

    # Subscribe to all spaces (channels + DMs) so we can count unread messages
    # in background conversations (active space subscription happens in handle_params)
    if connected?(socket) do
      Enum.each(channels ++ dm_conversations, fn space ->
        ChatPubSub.subscribe(space.id)
      end)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"space_slug" => slug_or_id}, _url, socket) do
    # Save the outgoing channel's draft before switching
    socket =
      if prev = socket.assigns.active_space do
        ChatPubSub.unsubscribe(prev.id)
        Phoenix.PubSub.unsubscribe(Platform.PubSub, "active_agent:#{prev.id}")

        if connected?(socket) do
          ChatPresence.untrack_in_space(self(), prev.id, socket.assigns.user_id)
        end

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
      agent_presence = ensure_native_agent_presence(space.id)

      if connected?(socket) && participant do
        display_name = resolve_display_name(socket.assigns.user_id, participant)

        ChatPresence.track_in_space(self(), space.id, socket.assigns.user_id, %{
          display_name: display_name,
          participant_type: "user"
        })
      end

      messages = load_channel_messages(space.id)
      latest_message = List.last(messages)

      if participant && latest_message do
        Chat.mark_space_read(participant.id, latest_message.id)
      end

      participants = Chat.list_participants(space.id)

      users_by_id =
        participants
        |> Enum.filter(&(&1.participant_type == "user"))
        |> Enum.map(& &1.participant_id)
        |> Accounts.get_users_map()

      participants_map = build_participant_identity_map(participants, users_by_id)

      agent_participant_ids =
        participants |> Enum.filter(&(&1.participant_type == "agent")) |> MapSet.new(& &1.id)

      agent_colors_map = Chat.agent_color_map_for_participants(participants)

      has_agent_participant = Enum.any?(participants, &(&1.participant_type == "agent"))

      online_count =
        if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

      reactions_map = build_reactions_map(messages, participant)
      attachments_map = build_attachments_map(messages)
      thread_previews = Chat.thread_previews_for_messages(Enum.map(messages, & &1.id))
      pins = Chat.list_pins(space.id)
      pinned_message_ids = MapSet.new(pins, & &1.message_id)
      canvases = Chat.list_canvases(space.id)
      canvases_by_message_id = build_canvas_map(canvases)

      page_title = space_page_title(space, participants, socket.assigns.user_id)

      # Resolve active agent indicator
      {active_agent_participant_id, active_agent_name} =
        resolve_active_agent(space.id, participants)

      # Refresh sidebar lists
      channels = Chat.list_spaces(kind: "channel")
      user_convos = Chat.list_user_conversations(socket.assigns.user_id)
      dm_convos = Enum.filter(user_convos, fn s -> s.kind in ["dm", "group"] end)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign(:active_space, space)
       |> assign(:space_participants, participants)
       |> assign(:search_query, "")
       |> assign(:search_results, [])
       |> assign(:highlighted_message_id, nil)
       |> assign(:highlighted_thread_message_id, nil)
       |> assign_search_form("")
       |> assign(:participants_map, participants_map)
       |> assign(:agent_participant_ids, agent_participant_ids)
       |> assign(:agent_colors_map, agent_colors_map)
       |> assign(:online_count, online_count)
       |> assign(:agent_presence, agent_presence)
       |> assign(:has_agent_participant, has_agent_participant)
       |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
       |> assign(:agent_typing_pids, MapSet.new())
       |> assign(:streaming_replies, %{})
       |> assign(:mention_suggestions, [])
       |> assign(:current_participant, participant)
       |> assign(:reactions_map, reactions_map)
       |> assign(:attachments_map, attachments_map)
       |> assign(:active_thread, nil)
       |> assign(:thread_messages, [])
       |> assign(:thread_attachments_map, %{})
       |> assign(:thread_previews, thread_previews)
       |> assign(:expanded_threads, MapSet.new())
       |> assign(:inline_thread_messages, %{})
       |> assign(:pins, pins)
       |> assign(:show_pins, false)
       |> assign(:pinned_message_ids, pinned_message_ids)
       |> assign(:canvases, canvases)
       |> assign(:canvases_by_message_id, canvases_by_message_id)
       |> assign(:active_canvas, nil)
       |> assign(:show_canvases, false)
       |> assign(:active_agent_participant_id, active_agent_participant_id)
       |> assign(:active_agent_name, active_agent_name)
       |> assign(:mobile_browser_open, false)
       |> assign(:channels, channels)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> assign_new_canvas_form()
       |> stream(:messages, messages, reset: true)
       |> schedule_agent_presence_refresh()
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

  def handle_event("search_messages", %{"search" => %{"query" => query}}, socket) do
    {:noreply, apply_search(socket, query)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, clear_search(socket)}
  end

  def handle_event("open_search_result", %{"message-id" => message_id}, socket) do
    case Chat.get_message(message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Search result not found.")}

      %{thread_id: thread_id} = message when is_binary(thread_id) ->
        # Find the parent message for this thread and expand inline
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
            |> assign(:highlighted_message_id, parent_msg_id)
            |> reinsert_stream_message(parent_msg_id)
          else
            socket
            |> assign(:highlighted_message_id, message.id)
          end

        {:noreply, socket}

      message ->
        {:noreply,
         socket
         |> assign(:active_thread, nil)
         |> assign(:thread_messages, [])
         |> assign(:thread_attachments_map, %{})
         |> assign(:highlighted_message_id, message.id)
         |> assign(:highlighted_thread_message_id, nil)}
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

  def handle_event("show_upload_dialog", _params, socket) do
    {:noreply, assign(socket, :upload_dialog_open, true)}
  end

  def handle_event("hide_upload_dialog", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.attachments.entries, socket, fn entry, acc ->
        cancel_upload(acc, :attachments, entry.ref)
      end)

    {:noreply,
     socket
     |> assign(:upload_dialog_open, false)
     |> assign(:upload_caption, "")}
  end

  def handle_event("upload_caption_changed", %{"caption" => text}, socket) do
    {:noreply, assign(socket, :upload_caption, text)}
  end

  def handle_event("send_upload", _params, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(socket.assigns.upload_caption || "")
      }

      case post_message_from_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> stream_insert(:messages, msg)
           |> put_attachment_map_entry(msg.id, attachments)
           |> assign(:upload_dialog_open, false)
           |> assign(:upload_caption, "")}

        {:noop, _socket} ->
          {:noreply, put_flash(socket, :info, "No files selected")}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

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

  def handle_event("mention_query", %{"query" => query}, socket) do
    suggestions =
      case socket.assigns.active_space do
        nil ->
          []

        space ->
          participants = Chat.list_participants(space.id)

          users_by_id =
            participants
            |> Enum.filter(&(&1.participant_type == "user"))
            |> Enum.map(& &1.participant_id)
            |> Accounts.get_users_map()

          participants
          |> Enum.filter(fn p ->
            name = (p.display_name || "") |> String.downcase()
            String.starts_with?(name, String.downcase(query))
          end)
          |> Enum.take(8)
          |> Enum.map(&participant_identity(&1, Map.get(users_by_id, &1.participant_id)))
      end

    {:noreply, assign(socket, :mention_suggestions, suggestions)}
  end

  def handle_event("mention_query", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
  end

  def handle_event("clear_mention_suggestions", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
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

  def handle_event("toggle_pin", %{"message_id" => msg_id, "space_id" => space_id}, socket) do
    handle_event("toggle_pin", %{"message-id" => msg_id, "space-id" => space_id}, socket)
  end

  def handle_event("toggle_pin", %{"message-id" => msg_id, "space-id" => space_id}, socket) do
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

    {:noreply, socket}
  end

  def handle_event("toggle_pins_panel", _params, socket) do
    {:noreply, assign(socket, :show_pins, !socket.assigns.show_pins)}
  end

  def handle_event("toggle_canvases_panel", _params, socket) do
    {:noreply, assign(socket, :show_canvases, !socket.assigns.show_canvases)}
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

  def handle_event("clear_active_agent", _params, socket) do
    space = socket.assigns.active_space
    ActiveAgentStore.clear_active(space.id)
    {:noreply, socket}
  end

  def handle_event("open_canvas", %{"canvas-id" => canvas_id}, socket) do
    case find_canvas(socket, canvas_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Canvas not found.")}

      canvas ->
        {:noreply,
         socket
         |> assign(:active_canvas, canvas)
         |> assign(:active_thread, nil)
         |> assign(:thread_messages, [])
         |> assign(:thread_attachments_map, %{})}
    end
  end

  def handle_event("canvas_action", %{"value" => value, "canvas-id" => canvas_id}, socket) do
    require Logger

    case find_canvas(socket, canvas_id) do
      nil ->
        Logger.warning("canvas_action: canvas not found (canvas_id=#{inspect(canvas_id)})")
        {:noreply, socket}

      canvas ->
        Logger.info(
          "canvas_action: canvas=#{canvas.id} value=#{inspect(value)} space=#{canvas.space_id}"
        )

        ChatPubSub.broadcast(canvas.space_id, {:canvas_action, canvas, value})
        dispatch_canvas_action_to_agent(canvas, value)
        {:noreply, socket}
    end
  end

  def handle_event("close_canvas", _params, socket) do
    {:noreply, assign(socket, :active_canvas, nil)}
  end

  def handle_event("open_canvas_mobile", %{"message-id" => message_id}, socket) do
    case Map.get(socket.assigns.canvases_by_message_id, message_id) do
      nil ->
        {:noreply, socket}

      canvas ->
        {:noreply, assign(socket, :active_canvas, find_canvas(socket, canvas.id) || canvas)}
    end
  end

  def handle_event("create_canvas", %{"canvas" => canvas_params}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs =
        canvas_params
        |> Map.take(["title", "canvas_type"])
        |> Map.put("state", default_canvas_state(canvas_params["canvas_type"]))

      case Chat.create_canvas_with_message(space.id, participant.id, attrs) do
        {:ok, canvas, message} ->
          {:noreply,
           socket
           |> put_canvas(canvas)
           |> stream_insert(:messages, message)
           |> put_attachment_map_entry(message.id, [])
           |> assign(:active_canvas, canvas)
           |> assign(:active_thread, nil)
           |> assign(:thread_messages, [])
           |> assign(:thread_attachments_map, %{})
           |> assign(:show_canvases, true)
           |> assign_new_canvas_form()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, changeset_error_summary(changeset))
           |> assign_new_canvas_form(canvas_params)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create canvas: #{inspect(reason)}")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("canvas_sort", %{"id" => canvas_id, "column" => column}, socket) do
    with %{} = canvas <- find_canvas(socket, canvas_id) do
      sort_by = Map.get(canvas.state || %{}, "sort_by")
      sort_dir = Map.get(canvas.state || %{}, "sort_dir", "asc")
      next_dir = if sort_by == column and sort_dir == "asc", do: "desc", else: "asc"

      Chat.update_canvas_state(canvas, %{"sort_by" => column, "sort_dir" => next_dir})
    end

    {:noreply, socket}
  end

  def handle_event("save_canvas_form", %{"canvas_id" => canvas_id, "values" => values}, socket) do
    with %{} = canvas <- find_canvas(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "values" => values,
        "submitted_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:noreply, socket}
  end

  def handle_event(
        "save_canvas_code",
        %{"canvas_id" => canvas_id, "code_canvas" => params},
        socket
      ) do
    with %{} = canvas <- find_canvas(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "language" => params["language"],
        "content" => params["content"],
        "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:noreply, socket}
  end

  def handle_event(
        "save_canvas_diagram",
        %{"canvas_id" => canvas_id, "diagram_canvas" => params},
        socket
      ) do
    with %{} = canvas <- find_canvas(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "diagram_title" => params["diagram_title"],
        "source" => params["source"],
        "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:noreply, socket}
  end

  def handle_event("refresh_canvas_dashboard", %{"id" => canvas_id}, socket) do
    with %{} = canvas <- find_canvas(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "metrics" => refresh_dashboard_metrics(canvas.state || %{}),
        "refreshed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:noreply, socket}
  end

  # ── Channel / Conversation creation events ─────────────────────────────────

  def handle_event("open_new_channel_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_channel_modal, true)
     |> assign(:new_channel_form, to_form(%{"name" => "", "description" => ""}))}
  end

  def handle_event("close_new_channel_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_channel_modal, false)}
  end

  def handle_event("create_channel", %{"name" => name, "description" => desc}, socket) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.create_channel(%{name: name, slug: slug, description: desc}) do
      {:ok, space} ->
        {:noreply,
         socket
         |> assign(:show_new_channel_modal, false)
         |> push_navigate(to: ~p"/chat/#{space.slug}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create channel. Name may be taken.")}
    end
  end

  def handle_event("open_new_conversation_modal", _params, socket) do
    users = Platform.Accounts.list_users()
    agents = Chat.list_agents_for_picker()

    {:noreply,
     socket
     |> assign(:show_new_conversation_modal, true)
     |> assign(:picker_users, users)
     |> assign(:picker_agents, agents)
     |> assign(:picker_query, "")
     |> assign(:picker_selected, [])}
  end

  def handle_event("close_new_conversation_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_conversation_modal, false)}
  end

  def handle_event("picker_search", %{"value" => query}, socket) do
    users = Platform.Accounts.list_users(query: query)
    agents = Chat.list_agents_for_picker()

    filtered_agents =
      if query == "" do
        agents
      else
        pattern = String.downcase(query)
        Enum.filter(agents, fn a -> String.contains?(String.downcase(a.name || ""), pattern) end)
      end

    {:noreply,
     socket
     |> assign(:picker_query, query)
     |> assign(:picker_users, users)
     |> assign(:picker_agents, filtered_agents)}
  end

  def handle_event("picker_toggle", %{"type" => type, "id" => id}, socket) do
    selected = socket.assigns.picker_selected
    entry = %{type: type, id: id}

    updated =
      if Enum.any?(selected, fn s -> s.type == type and s.id == id end) do
        Enum.reject(selected, fn s -> s.type == type and s.id == id end)
      else
        selected ++ [entry]
      end

    {:noreply, assign(socket, :picker_selected, updated)}
  end

  def handle_event("create_conversation", _params, socket) do
    selected = socket.assigns.picker_selected
    user_id = socket.assigns.user_id

    if selected == [] do
      {:noreply, put_flash(socket, :error, "Select at least one person or agent.")}
    else
      specs = Enum.map(selected, fn s -> %{type: s.type, id: s.id} end)

      result =
        if length(specs) == 1 do
          [spec] = specs
          Chat.find_or_create_dm(user_id, spec.type, spec.id)
        else
          Chat.create_group_conversation(user_id, specs)
        end

      case result do
        {:ok, space} ->
          nav_target = space.slug || space.id

          {:noreply,
           socket
           |> assign(:show_new_conversation_modal, false)
           |> push_navigate(to: ~p"/chat/#{nav_target}")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not create conversation.")}
      end
    end
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

  # ── Settings modal events ──────────────────────────────────────────────────

  def handle_event("show_settings", _params, socket) do
    space = socket.assigns.active_space

    form =
      to_form(%{
        "name" => space.name || "",
        "description" => space.description || "",
        "topic" => space.topic || "",
        "promote_name" => ""
      })

    {:noreply,
     socket
     |> assign(:show_settings, true)
     |> assign(:settings_form, form)}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  def handle_event("save_settings", params, socket) do
    space = socket.assigns.active_space

    attrs =
      case space.kind do
        "channel" ->
          slug =
            (params["name"] || space.name)
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9\s-]/, "")
            |> String.replace(~r/\s+/, "-")
            |> String.trim("-")

          %{
            name: params["name"],
            slug: slug,
            description: params["description"],
            topic: params["topic"]
          }

        "group" ->
          %{name: params["name"]}

        "dm" ->
          %{}
      end

    case Chat.update_space(space, attrs) do
      {:ok, updated} ->
        nav_target = updated.slug || updated.id

        {:noreply,
         socket
         |> assign(:show_settings, false)
         |> push_navigate(to: ~p"/chat/#{nav_target}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
    end
  end

  def handle_event("archive_space", _params, socket) do
    space = socket.assigns.active_space

    case Chat.archive_space(space) do
      {:ok, _} ->
        {:noreply, push_navigate(socket, to: ~p"/chat")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not archive space.")}
    end
  end

  def handle_event("settings_promote_to_channel", %{"promote_name" => name}, socket) do
    space = socket.assigns.active_space

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.promote_to_channel(space, %{name: name, slug: slug}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:show_settings, false)
         |> push_navigate(to: ~p"/chat/#{updated.slug}")}

      {:error, :not_promotable} ->
        {:noreply, put_flash(socket, :error, "This conversation cannot be promoted.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not promote to channel.")}
    end
  end

  @impl true
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
         |> maybe_refresh_search()}
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

        {:noreply, maybe_refresh_search(socket)}
      end
    end
  end

  def handle_info({:message_updated, msg}, socket) do
    attachments = Chat.list_attachments(msg.id)

    {:noreply,
     socket
     |> stream_insert(:messages, msg)
     |> put_attachment_map_entry(msg.id, attachments)
     |> maybe_refresh_search()}
  end

  def handle_info({:message_deleted, msg}, socket) do
    {:noreply,
     socket
     |> stream_delete(:messages, msg)
     |> delete_attachment_map_entry(msg.id)
     |> delete_thread_attachment_map_entry(msg.id)
     |> maybe_refresh_search()}
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

  def handle_info({:pin_added, pin}, socket) do
    pins = socket.assigns.pins ++ [pin]
    pinned_message_ids = MapSet.put(socket.assigns.pinned_message_ids, pin.message_id)

    {:noreply,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)}
  end

  def handle_info({:pin_removed, %{message_id: msg_id}}, socket) do
    pins = Enum.reject(socket.assigns.pins, &(&1.message_id == msg_id))
    pinned_message_ids = MapSet.delete(socket.assigns.pinned_message_ids, msg_id)

    {:noreply,
     socket
     |> assign(:pins, pins)
     |> assign(:pinned_message_ids, pinned_message_ids)}
  end

  def handle_info({:canvas_action, _canvas, _value}, socket) do
    # Canvas action events are handled at the source (handle_event);
    # other LiveView clients just ignore the PubSub broadcast.
    {:noreply, socket}
  end

  def handle_info({:canvas_created, canvas}, socket) do
    {:noreply, put_canvas(socket, canvas)}
  end

  def handle_info({:canvas_updated, canvas}, socket) do
    {:noreply, put_canvas(socket, canvas)}
  end

  def handle_info({:participant_joined, participant}, socket) do
    user =
      if participant.participant_type == "user" do
        Accounts.get_user(participant.participant_id)
      else
        nil
      end

    {:noreply,
     update(socket, :participants_map, fn map ->
       Map.put(map, participant.id, participant_identity(participant, user))
     end)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    online_count =
      if space = socket.assigns.active_space do
        ChatPresence.online_count(space.id)
      else
        0
      end

    {:noreply, assign(socket, :online_count, online_count)}
  end

  def handle_info(:refresh_agent_presence, socket) do
    socket =
      case socket.assigns.active_space do
        nil ->
          socket

        space ->
          agent_presence = ChatPresence.native_agent_presence(space.id)

          socket
          |> assign(:agent_presence, agent_presence)
          |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
          |> schedule_agent_presence_refresh()
      end

    {:noreply, socket}
  end

  def handle_info({:agent_typing, %{typing: typing, participant_id: participant_id}}, socket) do
    socket =
      socket
      |> update(:agent_typing_pids, fn pids ->
        if typing, do: MapSet.put(pids, participant_id), else: MapSet.delete(pids, participant_id)
      end)
      |> assign(
        :agent_status,
        if(typing, do: :thinking, else: PlatformWeb.ShellLive.default_agent_status())
      )

    # Update composite status for the roster indicator (busy when any agent is typing)
    any_typing = not MapSet.equal?(socket.assigns.agent_typing_pids, MapSet.new())

    socket =
      if socket.assigns[:principal_name] do
        if any_typing do
          assign(socket, :composite_status, :busy)
        else
          # Recalculate from roster when typing stops
          case socket.assigns[:active_space] do
            %{id: space_id} ->
              composite = Platform.Chat.SpaceAgentPresence.composite_status_for_space(space_id)
              assign(socket, :composite_status, composite)

            _ ->
              socket
          end
        end
      else
        socket
      end

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

  def handle_info({:active_agent_changed, _space_id, agent_participant_id}, socket) do
    participants = socket.assigns.space_participants
    name = resolve_agent_name(agent_participant_id, participants)

    {:noreply,
     socket
     |> assign(:active_agent_participant_id, agent_participant_id)
     |> assign(:active_agent_name, name)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="push-subscribe" phx-hook="PushSubscribe" class="hidden"></div>

    <div id="chat-state" phx-hook="ChatState" class="hidden"></div>

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
            phx-click="open_new_channel_modal"
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
            phx-click="open_new_conversation_modal"
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

            <div class="flex flex-shrink-0 items-center gap-3 text-xs text-base-content/50">
              <.form
                for={@search_form}
                id="chat-search-form"
                phx-change="search_messages"
                phx-submit="search_messages"
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
                    phx-click="clear_search"
                    class="rounded px-2 py-1 text-xs hover:bg-base-300"
                  >
                    Clear
                  </button>
                </div>
              </.form>

              <button
                :if={@canvases != []}
                phx-click="toggle_canvases_panel"
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
                phx-click="toggle_pins_panel"
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
                  phx-click="clear_active_agent"
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
                  {primary_agent_label(@active_space, @space_participants)} listening
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
                phx-click="show_settings"
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

              <button phx-click="clear_search" class="btn btn-ghost btn-xs">
                Clear
              </button>
            </div>

            <div class="mt-3 space-y-2">
              <button
                :for={result <- @search_results}
                type="button"
                phx-click="open_search_result"
                phx-value-message-id={result.id}
                class="block w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 text-left transition-colors hover:border-primary/40 hover:bg-base-100/80"
              >
                <div class="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-widest text-base-content/50">
                  <span>{sender_name(@participants_map, result.participant_id)}</span>
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
                  phx-click="toggle_pin"
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
                  phx-click="open_canvas"
                  phx-value-canvas-id={canvas.id}
                  class={[
                    "flex w-full items-center justify-between rounded-xl border px-3 py-2 text-left transition-colors",
                    "border-base-300 bg-base-100 hover:border-primary/40 hover:bg-base-100/80",
                    @active_canvas && @active_canvas.id == canvas.id && "border-primary bg-primary/5"
                  ]}
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-base-content">
                      {canvas.title || humanize_canvas_type(canvas.canvas_type)}
                    </p>
                    <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                      {humanize_canvas_type(canvas.canvas_type)}
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
                phx-submit="create_canvas"
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
                      {humanize_canvas_type(type)}
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
                    {avatar_initial(@participants_map, msg.participant_id)}
                  </div>
                <% else %>
                  <.human_avatar
                    name={sender_name(@participants_map, msg.participant_id)}
                    avatar_url={sender_avatar_url(@participants_map, msg.participant_id)}
                    seed={sender_avatar_seed(@participants_map, msg.participant_id)}
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
                    {sender_name(@participants_map, msg.participant_id)}
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
                      phx-click="toggle_pin"
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
                    phx-click="open_canvas_mobile"
                    phx-value-message-id={msg.id}
                    class="rounded-lg bg-base-200 px-3 py-2 cursor-pointer hover:bg-base-300 transition-colors"
                  >
                    <p class="truncate text-sm font-semibold text-base-content">
                      {message_canvas_title(msg, @canvases_by_message_id)}
                    </p>
                    <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                      {message_canvas_type(msg, @canvases_by_message_id)} canvas
                    </p>
                  </div>
                </div>

                <div
                  :if={msg.content_type != "canvas" and present?(msg.content)}
                  class="prose prose-sm max-w-none text-sm text-base-content break-words chat-markdown"
                >
                  {Platform.Chat.ContentRenderer.render_message(msg.content)}
                </div>

                <div
                  :if={Map.get(@attachments_map, msg.id, []) != []}
                  class="mt-1 flex flex-col gap-2"
                >
                  <a
                    :for={
                      attachment <-
                        Enum.filter(Map.get(@attachments_map, msg.id, []), &image_attachment?/1)
                    }
                    href={attachment_url(attachment)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="block max-w-sm"
                  >
                    <img
                      src={attachment_url(attachment)}
                      alt={attachment.filename}
                      loading="lazy"
                      class="rounded-lg max-h-64 object-contain bg-base-200"
                    />
                  </a>
                  <a
                    :for={
                      attachment <-
                        Enum.reject(Map.get(@attachments_map, msg.id, []), &image_attachment?/1)
                    }
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
              </div>

              <%!-- Floating reply button (appears on hover) --%>
              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={msg.id}
                class="absolute -bottom-2 right-3 z-10 flex items-center gap-1 rounded-full bg-base-200 border border-base-300 shadow-sm px-2 py-0.5 text-xs text-base-content/60 hover:text-primary hover:border-primary/40 opacity-0 group-hover:opacity-100 transition-all"
              >
                <span class="hero-chat-bubble-left size-3"></span>
                <span>Reply</span>
              </button>

              <%!-- Inline thread: preview bar + expanded thread --%>
              <div
                :if={
                  Map.has_key?(@thread_previews, msg.id) or MapSet.member?(@expanded_threads, msg.id)
                }
                class="ml-9 mt-1"
              >
                <%!-- Thread preview / collapse bar --%>
                <button
                  phx-click="toggle_inline_thread"
                  phx-value-message-id={msg.id}
                  class="flex items-center gap-1.5 text-xs text-primary hover:text-primary/70 transition-colors"
                >
                  <span class="hero-chat-bubble-left size-3.5"></span>
                  <span>
                    {Map.get(@thread_previews, msg.id, %{}) |> Map.get(:reply_count, 0)}
                    {if Map.get(@thread_previews, msg.id, %{}) |> Map.get(:reply_count, 0) == 1,
                      do: "reply",
                      else: "replies"}
                  </span>
                  <span
                    class="hero-chevron-down size-3 transition-transform"
                    style={
                      if MapSet.member?(@expanded_threads, msg.id), do: "transform: rotate(180deg)"
                    }
                  >
                  </span>
                </button>

                <%!-- Expanded inline thread messages --%>
                <div
                  :if={MapSet.member?(@expanded_threads, msg.id)}
                  class="mt-2 space-y-2 border-l-2 border-base-300 pl-3"
                  id={"inline-thread-#{msg.id}"}
                  phx-hook="InlineThread"
                >
                  <div
                    :for={tmsg <- Map.get(@inline_thread_messages, msg.id, [])}
                    class="flex items-start gap-2"
                  >
                    <div class={[
                      "flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-medium",
                      if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                        do: "bg-primary/10 text-primary",
                        else: "bg-base-200 text-base-content/60"
                      )
                    ]}>
                      {avatar_initial(@participants_map, tmsg.participant_id)}
                    </div>
                    <div class="min-w-0 flex-1">
                      <div class="flex items-baseline gap-2">
                        <span class="text-xs font-medium text-base-content/70">
                          {sender_name(@participants_map, tmsg.participant_id)}
                        </span>
                        <.local_time
                          id={"inline-thread-ts-#{tmsg.id}"}
                          timestamp={tmsg.inserted_at}
                          class="text-[10px] text-base-content/40"
                        />
                      </div>
                      <div class="prose prose-sm max-w-none text-sm text-base-content break-words">
                        {Platform.Chat.ContentRenderer.render_message(tmsg.content)}
                      </div>
                    </div>
                  </div>

                  <%!-- Inline thread composer --%>
                  <.form
                    for={%{}}
                    id={"inline-thread-compose-form-#{msg.id}"}
                    phx-submit="send_inline_thread_message"
                    class="flex items-end gap-2 pt-1"
                  >
                    <input type="hidden" name="inline_thread_compose[message_id]" value={msg.id} />
                    <div class="flex-1 relative">
                      <textarea
                        name="inline_thread_compose[text]"
                        id={"inline-thread-compose-#{msg.id}"}
                        rows="1"
                        placeholder="Reply…"
                        autocomplete="off"
                        class="textarea textarea-bordered w-full resize-none rounded-xl pr-10 text-sm leading-relaxed"
                        phx-hook="ComposeInput"
                      ></textarea>
                      <button
                        type="submit"
                        class="absolute right-2 bottom-2 w-7 h-7 rounded-full btn btn-primary btn-xs flex items-center justify-center p-0"
                        disabled={is_nil(@current_participant)}
                        title="Reply"
                      >
                        <span class="hero-paper-airplane size-4 -rotate-45"></span>
                      </button>
                    </div>
                  </.form>
                </div>
              </div>
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
                {avatar_initial(@participants_map, entry.participant_id)}
              </div>
              <div class="min-w-0 flex-1">
                <div class="text-xs font-medium mb-0.5 msg-agent-name">
                  {sender_name(@participants_map, entry.participant_id)}
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
            <span>{thinking_label(@agent_typing_pids, @participants_map)} is thinking…</span>
          </div>

          <div class="flex-shrink-0 border-t border-base-300 px-5 py-3 safe-area-bottom">
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
                :if={@mention_suggestions != []}
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
                          detail: %{name: participant_name(suggestion)}
                        )
                      }
                      class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                    >
                      <%= if suggestion.participant_type == "agent" do %>
                        <div class="w-6 h-6 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-bold flex-shrink-0">
                          {suggestion
                          |> participant_name()
                          |> String.trim()
                          |> String.first()
                          |> String.upcase()}
                        </div>
                      <% else %>
                        <.human_avatar
                          name={participant_name(suggestion)}
                          avatar_url={participant_avatar_url(suggestion)}
                          seed={participant_avatar_seed(suggestion)}
                          size="sm"
                          class="flex-shrink-0"
                        />
                      <% end %>
                      <span class="flex-1 truncate font-medium">
                        {participant_name(suggestion)}
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

              <%!-- Compose row: [+] [input stretches] [send] --%>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="show_upload_dialog"
                  class="flex-shrink-0 cursor-pointer rounded-full w-9 h-9 flex items-center justify-center text-base-content/50 hover:bg-base-300 transition-colors"
                  title="Attach files"
                >
                  <span class="hero-plus size-5"></span>
                </button>
                <%!-- Hidden file input keeps LiveView upload channel active for drag-drop --%>
                <.live_file_input upload={@uploads.attachments} class="hidden" />

                <textarea
                  name="compose[text]"
                  id={@compose_form[:text].id}
                  data-draft-key={if @active_space, do: "chat-draft:" <> @active_space.id, else: nil}
                  placeholder={"Message ##{(@active_space && @active_space.name) || ""}"}
                  autocomplete="off"
                  rows="1"
                  class="min-w-0 flex-1 rounded-xl text-sm resize-none bg-base-100 border border-base-300 focus:border-primary focus:outline-none transition-colors"
                  style="line-height:1.5;padding:6px 12px;min-height:33px;max-height:200px;overflow-y:auto;field-sizing:content"
                  phx-hook="ComposeInput"
                >{Phoenix.HTML.Form.normalize_value("text", @compose_form[:text].value)}</textarea>

                <button
                  type="submit"
                  class="flex-shrink-0 w-9 h-9 rounded-full btn btn-primary btn-sm flex items-center justify-center p-0"
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
            <div
              class="absolute inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
              phx-click="hide_upload_dialog"
            >
              <div
                class="mx-4 w-full max-w-lg rounded-2xl bg-base-100 shadow-2xl border border-base-300"
                phx-click-away="hide_upload_dialog"
                onclick="event.stopPropagation()"
              >
                <%!-- Header --%>
                <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
                  <h3 class="text-base font-semibold">Upload files</h3>
                  <button
                    type="button"
                    phx-click="hide_upload_dialog"
                    class="btn btn-ghost btn-xs btn-circle"
                    title="Close"
                  >
                    <span class="hero-x-mark size-4"></span>
                  </button>
                </div>

                <%!-- File previews --%>
                <div class="px-5 py-4">
                  <div
                    :if={@uploads.attachments.entries != []}
                    class="grid grid-cols-3 gap-3 mb-4"
                  >
                    <div
                      :for={entry <- @uploads.attachments.entries}
                      class="relative group"
                    >
                      <%= if String.starts_with?(entry.client_type, "image/") do %>
                        <.live_img_preview
                          entry={entry}
                          class="w-full h-24 object-cover rounded-lg border border-base-300"
                        />
                      <% else %>
                        <div class="w-full h-24 rounded-lg border border-base-300 bg-base-200 flex flex-col items-center justify-center gap-1 px-2">
                          <span class="hero-document size-8 text-base-content/40"></span>
                          <span class="text-[10px] text-base-content/60 truncate w-full text-center">
                            {entry.client_name}
                          </span>
                        </div>
                      <% end %>

                      <%!-- Remove button --%>
                      <button
                        type="button"
                        phx-click="cancel_upload"
                        phx-value-ref={entry.ref}
                        class="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-error text-error-content flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity shadow-sm"
                        title="Remove"
                      >
                        <span class="hero-x-mark size-3"></span>
                      </button>

                      <%!-- Progress bar --%>
                      <div
                        :if={entry.progress > 0 and entry.progress < 100}
                        class="absolute bottom-1 left-1 right-1"
                      >
                        <div class="h-1 rounded-full bg-base-300 overflow-hidden">
                          <div
                            class="h-full bg-primary transition-all duration-300"
                            style={"width: #{entry.progress}%"}
                          >
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div
                    :if={@uploads.attachments.entries == []}
                    class="text-center py-8 text-base-content/40"
                  >
                    <span class="hero-cloud-arrow-up size-12 mx-auto mb-2"></span>
                    <p class="text-sm">No files selected yet</p>
                  </div>

                  <%!-- Upload errors --%>
                  <p
                    :for={error <- upload_errors(@uploads.attachments)}
                    class="text-xs text-error mb-2"
                  >
                    {upload_error_to_string(error)}
                  </p>

                  <div :for={entry <- @uploads.attachments.entries}>
                    <p
                      :for={error <- upload_errors(@uploads.attachments, entry)}
                      class="text-xs text-error mb-1"
                    >
                      {entry.client_name}: {upload_error_to_string(error)}
                    </p>
                  </div>

                  <%!-- Add more files — triggers the hidden live_file_input in compose area --%>
                  <button
                    type="button"
                    onclick="document.getElementById('chat-drop-zone').querySelector('input[type=file]').click()"
                    class="flex items-center gap-2 text-sm text-primary cursor-pointer hover:underline mt-2"
                  >
                    <span class="hero-plus size-4"></span>
                    <span>Add more files</span>
                  </button>
                </div>

                <%!-- Caption --%>
                <div class="px-5 pb-4">
                  <form phx-change="upload_caption_changed" phx-submit="send_upload">
                    <textarea
                      name="caption"
                      placeholder="Add a caption (optional)..."
                      rows="2"
                      phx-debounce="200"
                      class="w-full rounded-xl text-sm resize-none bg-base-100 border border-base-300 focus:border-primary focus:outline-none transition-colors px-3 py-2"
                    >{@upload_caption}</textarea>
                  </form>
                </div>

                <%!-- Footer --%>
                <div class="flex items-center justify-end gap-2 border-t border-base-300 px-5 py-3">
                  <button
                    type="button"
                    phx-click="hide_upload_dialog"
                    class="btn btn-ghost btn-sm"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="send_upload"
                    class="btn btn-primary btn-sm"
                    disabled={@uploads.attachments.entries == []}
                  >
                    Send
                  </button>
                </div>
              </div>
            </div>
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
                {@active_canvas.title || humanize_canvas_type(@active_canvas.canvas_type)}
              </p>
            </div>

            <button phx-click="close_canvas" class="btn btn-ghost btn-xs" title="Close canvas">
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
                  {@active_canvas.title || humanize_canvas_type(@active_canvas.canvas_type)}
                </p>
              </div>

              <button phx-click="close_canvas" class="btn btn-ghost btn-xs" title="Close canvas">
                <span class="hero-x-mark size-4"></span>
              </button>
            </header>

            <div class="flex-1 overflow-y-auto px-4 py-4">
              <.canvas_document canvas={@active_canvas} dom_id_base="chat-live-canvas-overlay" />
            </div>
          </div>
        <% end %>

        <%!-- Side thread panel removed — all thread interaction is inline --%>
      </div>
    </div>

    <%!-- Space Settings Modal --%>
    <%= if @show_settings && @active_space do %>
      <div
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        phx-click="close_settings"
      >
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6 max-h-[80vh] overflow-y-auto"
          onclick="event.stopPropagation()"
        >
          <h3 class="text-lg font-bold mb-4">
            <%= case @active_space.kind do %>
              <% "channel" -> %>
                Channel Settings
              <% "dm" -> %>
                Conversation Settings
              <% "group" -> %>
                Group Settings
              <% _ -> %>
                Settings
            <% end %>
          </h3>

          <form phx-submit="save_settings">
            <%!-- Channel-specific fields --%>
            <%= if @active_space.kind == "channel" do %>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  name="name"
                  type="text"
                  class="input input-bordered w-full"
                  value={@active_space.name}
                  required
                />
              </div>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="description"
                  class="textarea textarea-bordered w-full"
                  placeholder="What's this channel about?"
                >{@active_space.description}</textarea>
              </div>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Topic</span></label>
                <input
                  name="topic"
                  type="text"
                  class="input input-bordered w-full"
                  value={@active_space.topic}
                  placeholder="Current topic of discussion"
                />
              </div>
            <% end %>

            <%!-- Group-specific fields --%>
            <%= if @active_space.kind == "group" do %>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Custom Name (optional)</span></label>
                <input
                  name="name"
                  type="text"
                  class="input input-bordered w-full"
                  value={@active_space.name}
                  placeholder="Override auto-generated name"
                />
              </div>
            <% end %>

            <%!-- ADR 0027: Agent attention mode removed; replaced by active agent mutex (Stage 3) --%>

            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_settings" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </form>

          <%!-- Danger Zone --%>
          <div class="divider text-xs text-base-content/40 mt-6">Danger Zone</div>

          <%= if @active_space.kind == "channel" do %>
            <button
              phx-click="archive_space"
              class="btn btn-error btn-outline btn-sm w-full"
              data-confirm="Are you sure you want to archive this channel? This cannot be undone."
            >
              Archive Channel
            </button>
          <% end %>

          <%= if @active_space.kind == "group" && !@active_space.is_direct do %>
            <form phx-submit="settings_promote_to_channel" class="mb-2">
              <label class="label"><span class="label-text text-sm">Promote to Channel</span></label>
              <div class="flex gap-2">
                <input
                  name="promote_name"
                  type="text"
                  class="input input-bordered input-sm flex-1"
                  placeholder="Channel name"
                  required
                />
                <button type="submit" class="btn btn-sm btn-outline">Promote</button>
              </div>
            </form>
          <% end %>
        </div>
      </div>
    <% end %>

    <%!-- New Channel Modal --%>
    <%= if @show_new_channel_modal do %>
      <div
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        phx-click="close_new_channel_modal"
      >
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6"
          phx-click-away="close_new_channel_modal"
        >
          <h3 class="text-lg font-bold mb-4">Create Channel</h3>
          <form phx-submit="create_channel">
            <div class="form-control mb-3">
              <label class="label"><span class="label-text">Name</span></label>
              <input
                name="name"
                type="text"
                class="input input-bordered w-full"
                placeholder="e.g. engineering"
                required
              />
            </div>
            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Description (optional)</span></label>
              <input
                name="description"
                type="text"
                class="input input-bordered w-full"
                placeholder="What's this channel about?"
              />
            </div>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_new_channel_modal" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Create</button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <%!-- New Conversation Modal --%>
    <%= if @show_new_conversation_modal do %>
      <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6"
          phx-click-away="close_new_conversation_modal"
        >
          <h3 class="text-lg font-bold mb-4">New Conversation</h3>

          <div class="form-control mb-3">
            <input
              type="text"
              class="input input-bordered w-full input-sm"
              placeholder="Search users or agents…"
              phx-keyup="picker_search"
              phx-key=""
              value={@picker_query}
            />
          </div>

          <%!-- Selected --%>
          <div :if={@picker_selected != []} class="flex flex-wrap gap-1 mb-3">
            <span
              :for={sel <- @picker_selected}
              class="badge badge-primary badge-sm gap-1 cursor-pointer"
              phx-click="picker_toggle"
              phx-value-type={sel.type}
              phx-value-id={sel.id}
            >
              {picker_selected_name(sel, @picker_users, @picker_agents)}
              <span class="text-xs">x</span>
            </span>
          </div>

          <%!-- Users --%>
          <div class="max-h-48 overflow-y-auto space-y-1 mb-3">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50 px-1">
              Users
            </p>
            <%= for user <- @picker_users do %>
              <% is_self = user.id == @user_id %>
              <% is_selected =
                Enum.any?(@picker_selected, fn s -> s.type == "user" and s.id == user.id end) %>
              <button
                :if={!is_self}
                type="button"
                phx-click="picker_toggle"
                phx-value-type="user"
                phx-value-id={user.id}
                class={[
                  "flex items-center gap-2 w-full px-2 py-1.5 rounded text-sm text-left transition-colors",
                  if(is_selected, do: "bg-primary/10 text-primary", else: "hover:bg-base-200")
                ]}
              >
                <.human_avatar
                  name={user.name || user.email || "User"}
                  avatar_url={user.avatar_url}
                  seed={user.oidc_sub || user.email || user.id}
                  size="sm"
                  class="flex-shrink-0"
                />
                <span class="truncate">{user.name || user.email}</span>
                <span :if={is_selected} class="ml-auto text-xs">selected</span>
              </button>
            <% end %>
          </div>

          <%!-- Agents --%>
          <div :if={@picker_agents != []} class="max-h-32 overflow-y-auto space-y-1 mb-4">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50 px-1">
              Agents
            </p>
            <%= for agent <- @picker_agents do %>
              <% is_selected =
                Enum.any?(@picker_selected, fn s -> s.type == "agent" and s.id == agent.id end) %>
              <button
                type="button"
                phx-click="picker_toggle"
                phx-value-type="agent"
                phx-value-id={agent.id}
                class={[
                  "flex items-center gap-2 w-full px-2 py-1.5 rounded text-sm text-left transition-colors",
                  if(is_selected, do: "bg-primary/10 text-primary", else: "hover:bg-base-200")
                ]}
              >
                <span class="w-6 h-6 rounded-full bg-accent/20 flex items-center justify-center text-xs font-bold text-accent">
                  {String.first(agent.name || "A") |> String.upcase()}
                </span>
                <span class="truncate">{agent.name}</span>
                <span class="badge badge-xs badge-accent ml-1">bot</span>
                <span :if={is_selected} class="ml-auto text-xs">selected</span>
              </button>
            <% end %>
          </div>

          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="close_new_conversation_modal"
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="create_conversation"
              class="btn btn-primary btn-sm"
              disabled={@picker_selected == []}
            >
              {if length(@picker_selected) <= 1, do: "Start DM", else: "Create Group"}
            </button>
          </div>
        </div>
      </div>
    <% end %>
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

  defp assign_search_form(socket, query) do
    assign(socket, :search_form, to_form(%{"query" => query}, as: :search))
  end

  defp apply_search(socket, query) do
    trimmed_query = String.trim(query || "")

    results =
      case socket.assigns.active_space do
        %{id: space_id} when trimmed_query != "" ->
          Chat.search_messages(space_id, trimmed_query, limit: 12)

        _ ->
          []
      end

    socket
    |> assign(:search_query, trimmed_query)
    |> assign(:search_results, results)
    |> assign(:highlighted_message_id, nil)
    |> assign(:highlighted_thread_message_id, nil)
    |> assign_search_form(trimmed_query)
  end

  defp clear_search(socket) do
    socket
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:highlighted_message_id, nil)
    |> assign(:highlighted_thread_message_id, nil)
    |> assign_search_form("")
  end

  defp maybe_refresh_search(socket) do
    if present?(socket.assigns.search_query) do
      apply_search(socket, socket.assigns.search_query)
    else
      socket
    end
  end

  defp assign_new_canvas_form(socket, attrs \\ %{}) do
    params = %{
      "title" => Map.get(attrs, "title", ""),
      "canvas_type" => Map.get(attrs, "canvas_type", "table")
    }

    assign(socket, :new_canvas_form, to_form(params, as: :canvas))
  end

  defp build_canvas_map(canvases) do
    Map.new(canvases, fn canvas -> {canvas.message_id, canvas} end)
    |> Map.delete(nil)
  end

  defp put_canvas(socket, canvas) do
    canvases =
      socket.assigns.canvases
      |> Enum.reject(&(&1.id == canvas.id))
      |> Kernel.++([canvas])
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_message_id, build_canvas_map(canvases))
    |> maybe_assign_active_canvas(canvas)
  end

  defp maybe_assign_active_canvas(socket, canvas) do
    case socket.assigns.active_canvas do
      %{id: id} when id == canvas.id -> assign(socket, :active_canvas, canvas)
      _ -> socket
    end
  end

  defp find_canvas(socket, canvas_id) do
    Chat.get_canvas(canvas_id) || Enum.find(socket.assigns.canvases, &(&1.id == canvas_id))
  end

  defp dispatch_canvas_action_to_agent(canvas, value) do
    require Logger

    with %{participant_type: "agent", participant_id: agent_id} <-
           Chat.get_participant(canvas.created_by),
         %Platform.Agents.Agent{} = agent <- Platform.Agents.get_agent(agent_id),
         runtime_id when is_binary(runtime_id) <- agent.runtime_id,
         topic = "runtime:#{runtime_id}",
         bundle = Platform.Chat.ContextPlane.build_context_bundle(canvas.space_id),
         tools = PlatformWeb.Channels.ToolSurface.tool_definitions() do
      payload = %{
        signal: %{
          reason: :canvas_action,
          space_id: canvas.space_id,
          canvas_id: canvas.id,
          canvas_title: canvas.title,
          action_value: value
        },
        message: %{
          content: "Action button pressed on canvas \"#{canvas.title || canvas.id}\": #{value}",
          author: "system"
        },
        history: [],
        context: bundle,
        tools: tools
      }

      case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
        :ok ->
          Logger.info(
            "canvas_action dispatched to agent #{agent_id} (runtime: #{runtime_id}) value=#{value}"
          )

        {:error, reason} ->
          Logger.warning("canvas_action dispatch failed: #{inspect(reason)}")
      end
    else
      _ ->
        Logger.debug(
          "canvas_action: creator is not an agent or runtime not found, skipping dispatch"
        )
    end
  end

  defp default_canvas_state("table") do
    %{
      "columns" => ["Task", "Owner", "Status"],
      "rows" => [
        %{"Task" => "Plan", "Owner" => "Rowan", "Status" => "Ready"},
        %{"Task" => "Build", "Owner" => "Zip", "Status" => "In Progress"},
        %{"Task" => "Ship", "Owner" => "Team", "Status" => "Queued"}
      ],
      "sort_dir" => "asc"
    }
  end

  defp default_canvas_state("form") do
    %{
      "fields" => [
        %{
          "name" => "goal",
          "label" => "Goal",
          "type" => "text",
          "placeholder" => "What are we aligning on?"
        },
        %{
          "name" => "owner",
          "label" => "Owner",
          "type" => "text",
          "placeholder" => "Who is driving it?"
        },
        %{
          "name" => "notes",
          "label" => "Notes",
          "type" => "textarea",
          "placeholder" => "Shared notes"
        }
      ],
      "values" => %{},
      "submit_label" => "Save"
    }
  end

  defp default_canvas_state("code") do
    %{
      "language" => "elixir",
      "content" => "# Shared canvas\n# Add notes or code here\n"
    }
  end

  defp default_canvas_state("diagram") do
    %{
      "diagram_title" => "Workflow",
      "source" => "graph TD\n  Idea --> Build\n  Build --> Review\n  Review --> Ship"
    }
  end

  defp default_canvas_state("dashboard") do
    %{"metrics" => refresh_dashboard_metrics(%{})}
  end

  defp default_canvas_state(_type) do
    %{"notes" => "Custom canvas ready for shared state."}
  end

  defp refresh_dashboard_metrics(state) do
    now = DateTime.utc_now()
    tick = System.system_time(:second)
    existing = Map.get(state, "metrics", [])

    labels =
      existing
      |> Enum.map(&Map.get(&1, "label"))
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ["Open items", "People here", "Fresh edits"]
        labels -> labels
      end

    [
      %{
        "label" => Enum.at(labels, 0, "Open items"),
        "value" => Integer.to_string(rem(tick, 9) + 3),
        "trend" => "Updated #{format_timestamp(now)}"
      },
      %{
        "label" => Enum.at(labels, 1, "People here"),
        "value" => Integer.to_string(rem(tick, 4) + 1),
        "trend" => "Live presence"
      },
      %{
        "label" => Enum.at(labels, 2, "Fresh edits"),
        "value" => Integer.to_string(rem(tick, 7) + 1),
        "trend" => "Rolling 15 min"
      }
    ]
  end

  defp message_canvas_id(message, canvases_by_message_id) do
    with %{} = structured <- message.structured_content,
         canvas_id when is_binary(canvas_id) <- Map.get(structured, "canvas_id") do
      canvas_id
    else
      _ ->
        case Map.get(canvases_by_message_id, message.id) do
          %{id: id} -> id
          _ -> nil
        end
    end
  end

  defp message_canvas_title(message, canvases_by_message_id) do
    case Map.get(canvases_by_message_id, message.id) do
      %{title: title} when is_binary(title) and title != "" ->
        title

      _ ->
        get_in(message.structured_content || %{}, ["title"]) ||
          "Untitled Canvas"
    end
  end

  defp message_canvas_type(message, canvases_by_message_id) do
    type =
      case Map.get(canvases_by_message_id, message.id) do
        %{canvas_type: type} when is_binary(type) -> type
        _ -> get_in(message.structured_content || %{}, ["canvas_type"]) || "custom"
      end

    humanize_canvas_type(type)
  end

  defp humanize_canvas_type(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_canvas_type(_type), do: "Canvas"

  defp changeset_error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      replacements = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        replacements |> Map.get(key, key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  rescue
    _ -> "Please check the canvas fields and try again."
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

  defp thinking_label(pids, participants_map) do
    pids
    |> MapSet.to_list()
    |> Enum.map(&sender_name(participants_map, &1))
    |> Enum.join(" & ")
  end

  defp unread_label(count) when count >= 9, do: "9+"
  defp unread_label(count) when count > 0, do: Integer.to_string(count)
  defp unread_label(_), do: nil

  defp picker_selected_name(%{type: "user", id: id}, users, _agents) do
    case Enum.find(users, fn u -> u.id == id end) do
      %{name: name} when is_binary(name) -> name
      %{email: email} -> email
      _ -> "User"
    end
  end

  defp picker_selected_name(%{type: "agent", id: id}, _users, agents) do
    case Enum.find(agents, fn a -> a.id == id end) do
      %{name: name} -> name
      _ -> "Agent"
    end
  end

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

  defp resolve_display_name(user_id, participant) do
    participant.display_name || name_for_user(user_id)
  end

  defp ensure_native_agent_presence(space_id) do
    # Use non-blocking status() for initial render, then boot async
    status = WorkspaceBootstrap.status()

    case status do
      %{configured?: true, agent: %{} = agent} ->
        _ = Chat.ensure_agent_participant(space_id, agent, display_name: agent.name)

        if status.pid, do: allow_runtime_sandbox(status.pid)

        # Boot the runtime asynchronously if not already running
        unless status.reachable? do
          Task.start(fn -> WorkspaceBootstrap.boot() end)
        end

      _ ->
        # Attempt async boot in background
        Task.start(fn -> WorkspaceBootstrap.boot() end)
    end

    ChatPresence.native_agent_presence(space_id)
  end

  defp schedule_agent_presence_refresh(socket) do
    if connected?(socket) && socket.assigns.active_space do
      Process.send_after(self(), :refresh_agent_presence, @agent_presence_refresh_ms)
    end

    socket
  end

  defp default_agent_presence do
    %{
      configured?: false,
      bootable?: false,
      reachable?: false,
      running?: false,
      workspace_path: nil,
      agent_slug: nil,
      agent_name: nil,
      agent: nil,
      pid: nil,
      error: nil,
      joined?: false,
      participant: nil,
      indicator: :missing
    }
  end

  defp allow_runtime_sandbox(pid) when is_pid(pid) do
    if sandbox_pool?() do
      case Sandbox.allow(Repo, self(), pid) do
        :ok -> :ok
        {:already, :owner} -> :ok
        {:already, :allowed} -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp allow_runtime_sandbox(_pid), do: :ok

  defp sandbox_pool? do
    case Repo.config()[:pool] do
      Sandbox -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp build_participant_identity_map(participants, users_by_id) do
    Map.new(participants, fn participant ->
      {participant.id,
       participant_identity(participant, Map.get(users_by_id, participant.participant_id))}
    end)
  end

  defp participant_identity(participant, user \\ nil)

  defp participant_identity(%{participant_type: "agent"} = participant, _user) do
    name = participant.display_name || "Agent"

    %{
      participant_type: "agent",
      name: name,
      display_name: name,
      avatar_url: participant.avatar_url,
      avatar_seed: participant.participant_id || participant.id
    }
  end

  defp participant_identity(participant, user) do
    name = participant_name(participant, user)

    %{
      participant_type: "user",
      name: name,
      display_name: name,
      avatar_url: participant.avatar_url || (user && user.avatar_url),
      avatar_seed: participant_avatar_seed(participant, user)
    }
  end

  defp participant_name(participant), do: participant_name(participant, nil)

  defp participant_name(%{name: name}, _user) when is_binary(name) and name != "", do: name

  defp participant_name(%{resolved_name: name}, _user) when is_binary(name) and name != "",
    do: name

  defp participant_name(%{display_name: name}, _user) when is_binary(name) and name != "",
    do: name

  defp participant_name(_participant, %{name: name}) when is_binary(name) and name != "", do: name

  defp participant_name(_participant, %{email: email}) when is_binary(email) and email != "",
    do: email

  defp participant_name(_participant, _user), do: "User"

  defp participant_avatar_url(%{avatar_url: avatar_url}) when is_binary(avatar_url),
    do: avatar_url

  defp participant_avatar_url(_participant), do: nil

  defp participant_avatar_seed(%{avatar_seed: seed}) when not is_nil(seed), do: seed

  defp participant_avatar_seed(participant, user \\ nil) do
    cond do
      user && is_binary(user.oidc_sub) && user.oidc_sub != "" ->
        user.oidc_sub

      user && is_binary(user.email) && user.email != "" ->
        user.email

      is_binary(participant.participant_id) && participant.participant_id != "" ->
        participant.participant_id

      is_binary(participant.id) && participant.id != "" ->
        participant.id

      true ->
        "user"
    end
  end

  defp sender_name(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> "User"
    end
  end

  defp sender_avatar_url(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{avatar_url: avatar_url} when is_binary(avatar_url) -> avatar_url
      _ -> nil
    end
  end

  defp sender_avatar_seed(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{avatar_seed: avatar_seed} when not is_nil(avatar_seed) -> avatar_seed
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> participant_id || "user"
    end
  end

  defp avatar_initial(participants_map, participant_id) do
    sender_name(participants_map, participant_id)
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "U"
      ch -> String.upcase(ch)
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

  # Resolve the currently active agent's participant ID and display name
  defp resolve_active_agent(space_id, participants) do
    case ActiveAgentStore.get_active(space_id) do
      nil ->
        {nil, nil}

      participant_id ->
        name = resolve_agent_name(participant_id, participants)
        {participant_id, name}
    end
  end

  # Resolve an agent's display name from their participant ID
  defp resolve_agent_name(nil, _participants), do: nil

  defp resolve_agent_name(participant_id, participants) do
    case Enum.find(participants, &(&1.id == participant_id)) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_agent_name_by_id(agent_id)
      nil -> resolve_agent_name_by_lookup(participant_id)
    end
  end

  defp resolve_agent_name_by_id(agent_id) do
    case Repo.get(Platform.Agents.Agent, agent_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Agent"
    end
  end

  defp resolve_agent_name_by_lookup(participant_id) do
    case Chat.get_participant(participant_id) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_agent_name_by_id(agent_id)
      _ -> "Agent"
    end
  end

  # Build label for the primary agent when in listening mode
  defp primary_agent_label(%{primary_agent_id: nil}, _participants), do: "Agent"

  defp primary_agent_label(%{primary_agent_id: primary_agent_id}, participants) do
    case Enum.find(participants, fn p ->
           p.participant_type == "agent" && p.participant_id == primary_agent_id
         end) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> resolve_agent_name_by_id(primary_agent_id)
    end
  end
end
