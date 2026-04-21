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
  import PlatformWeb.ChatLive.Partials

  alias Phoenix.LiveView.JS
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.PubSub, as: ChatPubSub

  alias PlatformWeb.ChatLive.ActiveAgentHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.MessagesHooks
  alias PlatformWeb.ChatLive.NewChannelComponent
  alias PlatformWeb.ChatLive.NewConversationComponent
  alias PlatformWeb.ChatLive.PinHooks
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.SearchHooks
  alias PlatformWeb.ChatLive.SettingsComponent
  alias PlatformWeb.ChatLive.UploadHooks

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
      |> assign(:mobile_browser_open, false)
      |> assign(:show_new_channel_modal, false)
      |> assign(:show_new_conversation_modal, false)
      |> assign(:show_settings, false)
      |> assign(:quick_emojis, @quick_emojis)
      |> assign(:push_permission, "unknown")
      |> assign(:unread_counts, if(user_id, do: Chat.unread_counts_for_user(user_id), else: %{}))
      |> assign(:lightbox_url, nil)
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

    all_spaces = channels ++ dm_conversations

    # Subscribe to chat pubsub for unread counts in background conversations
    # (active space subscription happens in handle_params).
    # Also subscribe to the global space-lifecycle topic so newly created
    # channels appear in the sidebar without requiring a refresh.
    if connected?(socket) do
      Enum.each(all_spaces, &ChatPubSub.subscribe(&1.id))
      ChatPubSub.subscribe_spaces()
    end

    space_ids = Enum.map(all_spaces, & &1.id)

    socket =
      socket
      |> PresenceHooks.attach()
      |> MessagesHooks.attach()
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

        socket
        |> PresenceHooks.leave_space(prev.id)
        |> MessagesHooks.save_draft(prev.id)
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
        # Mount's subscribe loop (see `mount/3`) already subscribed this LV
        # to every space in the user's channel + DM list — which includes
        # whichever one is about to become active. Phoenix.PubSub does NOT
        # dedupe subscriptions per pid: a second subscribe adds a second
        # registry entry and a single broadcast fires handle_info twice.
        # Unsubscribe first to guarantee a single active subscription here.
        ChatPubSub.unsubscribe(space.id)
        ChatPubSub.subscribe(space.id)
        Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
      end

      participant = ensure_participant(space.id, socket.assigns.user_id)
      participants = Chat.list_participants(space.id)
      page_title = space_page_title(space, participants, socket.assigns.user_id)

      # Refresh sidebar lists
      channels = Chat.list_spaces(kind: "channel")
      user_convos = Chat.list_user_conversations(socket.assigns.user_id)
      dm_convos = Enum.filter(user_convos, fn s -> s.kind in ["dm", "group"] end)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign(:active_space, space)
       |> assign(:current_participant, participant)
       |> PresenceHooks.enter_space(space, participant, participants)
       |> MessagesHooks.enter_space(space, participant)
       |> SearchHooks.reset_for_space()
       |> MentionsHooks.reset_for_space()
       |> PinHooks.load_for_space(space.id)
       |> CanvasHooks.load_for_space(space.id)
       |> ActiveAgentHooks.resolve_for_space(space.id, participants)
       |> assign(:mobile_browser_open, false)
       |> assign(:channels, channels)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> clear_unread(space.id)}
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

  # Coordinator: Search event that also writes MessagesHooks state
  # (thread expansion, stream reinsert, highlight).
  def handle_event("search_open_result", %{"message-id" => message_id}, socket) do
    case Chat.get_message(message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Search result not found.")}

      %{thread_id: thread_id} = message when is_binary(thread_id) ->
        parent_msg_id =
          Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
            if tid == thread_id, do: pmid
          end)

        thread_msgs = MessagesHooks.load_thread_messages(message.space_id, thread_id)

        socket =
          if parent_msg_id do
            socket
            |> MessagesHooks.open_thread_context(parent_msg_id, thread_msgs)
            |> SearchHooks.set_highlights(parent_msg_id, nil)
          else
            SearchHooks.set_highlights(socket, message.id, nil)
          end

        {:noreply, socket}

      message ->
        {:noreply,
         socket
         |> MessagesHooks.reset_thread_panel()
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

  # ── Upload staging dialog events ──────────────────────────────────────

  defp handle_upload_progress(_upload_name, _entry, socket) do
    {:noreply, socket}
  end

  # Cross-feature: upload_send creates a message + attachments. Delegates
  # post+stream writes to MessagesHooks, resets UploadHooks on success.
  def handle_event("upload_send", _params, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      caption = String.trim(socket.assigns.upload_caption || "")
      tagged = socket.assigns.upload_tagged_agents

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

      case MessagesHooks.post_message_with_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> MessagesHooks.stream_insert_message(msg, attachments)
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

  # Coordinator: open a canvas and close the thread panel.
  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    case CanvasHooks.find(socket, canvas_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Canvas not found.")}

      canvas ->
        {:noreply,
         socket
         |> CanvasHooks.set_active(canvas)
         |> MessagesHooks.reset_thread_panel()}
    end
  end

  # Coordinator: create a canvas message, stream-insert it, open it.
  def handle_event("canvas_create", %{"canvas" => canvas_params}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = Map.take(canvas_params, ["title"])

      case Chat.create_canvas_with_message(space.id, participant.id, attrs) do
        {:ok, canvas, message} ->
          {:noreply,
           socket
           |> CanvasHooks.put(canvas)
           |> MessagesHooks.stream_insert_message(message)
           |> CanvasHooks.set_active(canvas)
           |> MessagesHooks.reset_thread_panel()
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

  def handle_info({:space_created, %{kind: "channel"} = space}, socket) do
    # Re-fetch sidebar lists so the new channel appears immediately for every
    # connected session, not just the creator. Subscribe to the new space's
    # topic for unread counts.
    ChatPubSub.subscribe(space.id)

    channels = Chat.list_spaces(kind: "channel")
    dm_conversations = socket.assigns.dm_conversations

    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:spaces, channels ++ dm_conversations)}
  end

  def handle_info({:space_created, _space}, socket), do: {:noreply, socket}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp clear_unread(socket, space_id) do
    update(socket, :unread_counts, &Map.delete(&1, space_id))
  end

  defp unread_label(count) when count >= 9, do: "9+"
  defp unread_label(count) when count > 0, do: Integer.to_string(count)
  defp unread_label(_), do: nil

  # ADR 0027: default_attention_mode/1 and default_attention_label/1 removed
  # (agent_attention field no longer exists on Space)

  # ADR 0038: participant rows represent current membership only — no
  # soft-delete to reconcile. If the user is in the space they get their
  # existing row; otherwise a fresh row is inserted.
  defp ensure_participant(space_id, user_id) do
    existing =
      space_id
      |> Chat.list_participants()
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      %Chat.Participant{} = p ->
        p

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
