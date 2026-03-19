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

  import PlatformWeb.Chat.CanvasComponents
  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]

  alias Platform.Accounts
  alias Platform.Agents.WorkspaceBootstrap
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Chat
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
    spaces = Chat.list_spaces()

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:user_id, user_id)
      |> assign(:spaces, spaces)
      |> assign(:active_space, nil)
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:highlighted_message_id, nil)
      |> assign(:highlighted_thread_message_id, nil)
      |> assign(:participants_map, %{})
      |> assign(:online_count, 0)
      |> assign(:agent_presence, default_agent_presence())
      |> assign(:current_participant, nil)
      |> assign(:reactions_map, %{})
      |> assign(:attachments_map, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_messages, [])
      |> assign(:thread_attachments_map, %{})
      |> assign(:pins, [])
      |> assign(:show_pins, false)
      |> assign(:pinned_message_ids, MapSet.new())
      |> assign(:canvases, [])
      |> assign(:canvases_by_message_id, %{})
      |> assign(:active_canvas, nil)
      |> assign(:show_canvases, false)
      |> assign(:mobile_browser_open, false)
      |> assign(:quick_emojis, @quick_emojis)
      |> assign(:canvas_types, @canvas_types)
      |> assign(:agent_typing, false)
      |> assign(:mention_suggestions, [])
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

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"space_slug" => slug}, _url, socket) do
    if prev = socket.assigns.active_space do
      ChatPubSub.unsubscribe(prev.id)

      if connected?(socket) do
        ChatPresence.untrack_in_space(self(), prev.id, socket.assigns.user_id)
      end
    end

    space = Chat.get_space_by_slug(slug) || bootstrap_space(slug)

    if is_nil(space) do
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    else
      if connected?(socket), do: ChatPubSub.subscribe(space.id)

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

      participants = Chat.list_participants(space.id)
      participants_map = Map.new(participants, fn p -> {p.id, p.display_name || "User"} end)

      online_count =
        if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

      reactions_map = build_reactions_map(messages, participant)
      attachments_map = build_attachments_map(messages)
      pins = Chat.list_pins(space.id)
      pinned_message_ids = MapSet.new(pins, & &1.message_id)
      canvases = Chat.list_canvases(space.id)
      canvases_by_message_id = build_canvas_map(canvases)

      {:noreply,
       socket
       |> assign(:page_title, "# #{space.name}")
       |> assign(:active_space, space)
       |> assign(:search_query, "")
       |> assign(:search_results, [])
       |> assign(:highlighted_message_id, nil)
       |> assign(:highlighted_thread_message_id, nil)
       |> assign_search_form("")
       |> assign(:participants_map, participants_map)
       |> assign(:online_count, online_count)
       |> assign(:agent_presence, agent_presence)
       |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
       |> assign(:agent_typing, false)
       |> assign(:mention_suggestions, [])
       |> assign(:current_participant, participant)
       |> assign(:reactions_map, reactions_map)
       |> assign(:attachments_map, attachments_map)
       |> assign(:active_thread, nil)
       |> assign(:thread_messages, [])
       |> assign(:thread_attachments_map, %{})
       |> assign(:pins, pins)
       |> assign(:show_pins, false)
       |> assign(:pinned_message_ids, pinned_message_ids)
       |> assign(:canvases, canvases)
       |> assign(:canvases_by_message_id, canvases_by_message_id)
       |> assign(:active_canvas, nil)
       |> assign(:show_canvases, false)
       |> assign(:mobile_browser_open, false)
       |> assign(:spaces, Chat.list_spaces())
       |> assign_new_canvas_form()
       |> stream(:messages, messages, reset: true)
       |> schedule_agent_presence_refresh()}
    end
  end

  def handle_params(_params, _url, socket) do
    case socket.assigns.spaces do
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

  def handle_event("open_search_result", %{"message_id" => message_id}, socket) do
    case Chat.get_message(message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Search result not found.")}

      %{thread_id: thread_id} = message when is_binary(thread_id) ->
        thread = Chat.get_thread(thread_id)
        thread_messages = load_thread_messages(message.space_id, thread_id)
        thread_attachments_map = build_attachments_map(thread_messages)

        {:noreply,
         socket
         |> assign(:active_thread, thread)
         |> assign(:active_canvas, nil)
         |> assign(:thread_messages, thread_messages)
         |> assign(:thread_attachments_map, thread_attachments_map)
         |> assign(:highlighted_message_id, nil)
         |> assign(:highlighted_thread_message_id, message.id)}

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

    {:noreply, socket}
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
           |> assign_compose("")}

        {:noop, socket} ->
          {:noreply, socket}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("compose_changed", %{"compose" => %{"text" => text}}, socket) do
    {:noreply, assign_compose(socket, text)}
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
          space.id
          |> Chat.list_participants()
          |> Enum.filter(fn p ->
            name = (p.display_name || "") |> String.downcase()
            String.starts_with?(name, String.downcase(query))
          end)
          |> Enum.take(8)
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
  end

  def handle_event("open_thread", %{"message_id" => message_id}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space do
      thread =
        Chat.get_thread_for_message(message_id) ||
          case Chat.create_thread(space.id, %{parent_message_id: message_id}) do
            {:ok, t} -> t
            {:error, _} -> nil
          end

      case thread do
        nil ->
          {:noreply, put_flash(socket, :error, "Could not open thread.")}

        thread ->
          thread_messages = load_thread_messages(space.id, thread.id)
          thread_attachments_map = build_attachments_map(thread_messages)

          {:noreply,
           socket
           |> assign(:active_thread, thread)
           |> assign(:active_canvas, nil)
           |> assign(:thread_messages, thread_messages)
           |> assign(:thread_attachments_map, thread_attachments_map)
           |> assign(:highlighted_message_id, nil)
           |> assign(:highlighted_thread_message_id, nil)
           |> assign_thread_compose("")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:thread_attachments_map, %{})
     |> assign(:highlighted_thread_message_id, nil)}
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

  def handle_event("toggle_pin", %{"message_id" => msg_id, "space_id" => space_id}, socket) do
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

  def handle_event("open_canvas", %{"canvas_id" => canvas_id}, socket) do
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

  def handle_event("close_canvas", _params, socket) do
    {:noreply, assign(socket, :active_canvas, nil)}
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

  @impl true
  def handle_info({:new_message, msg}, socket) do
    attachments = Chat.list_attachments(msg.id)

    if is_nil(msg.thread_id) do
      {:noreply,
       socket
       |> stream_insert(:messages, msg)
       |> put_attachment_map_entry(msg.id, attachments)
       |> maybe_refresh_search()}
    else
      if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
        {:noreply,
         socket
         |> update(:thread_messages, &(&1 ++ [msg]))
         |> put_thread_attachment_map_entry(msg.id, attachments)
         |> maybe_refresh_search()}
      else
        {:noreply, socket}
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
  end

  def handle_info({:reaction_removed, data}, socket) do
    reactions_map =
      remove_reaction_from_map(
        socket.assigns.reactions_map,
        data,
        socket.assigns.current_participant
      )

    {:noreply, assign(socket, :reactions_map, reactions_map)}
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

  def handle_info({:canvas_created, canvas}, socket) do
    {:noreply, put_canvas(socket, canvas)}
  end

  def handle_info({:canvas_updated, canvas}, socket) do
    {:noreply, put_canvas(socket, canvas)}
  end

  def handle_info({:participant_joined, participant}, socket) do
    {:noreply,
     update(socket, :participants_map, fn map ->
       Map.put(map, participant.id, participant.display_name || "User")
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

  def handle_info({:agent_typing, %{typing: typing}}, socket) do
    {:noreply,
     socket
     |> assign(:agent_typing, typing)
     |> assign(
       :agent_status,
       if(typing, do: :thinking, else: PlatformWeb.ShellLive.default_agent_status())
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="push-subscribe" phx-hook="PushSubscribe" class="hidden"></div>
    <div class="flex h-full overflow-hidden">
      <%!-- Desktop channel sidebar (hidden on mobile) --%>
      <aside class="hidden lg:flex w-52 flex-shrink-0 flex-col border-r border-base-300 bg-base-200">
        <div class="border-b border-base-300 px-4 py-3">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Channels
          </p>
        </div>

        <nav class="flex-1 overflow-y-auto py-2">
          <.link
            :for={space <- @spaces}
            navigate={~p"/chat/#{space.slug}"}
            class={[
              "flex items-center gap-2 px-3 py-1.5 text-sm transition-colors",
              "hover:bg-base-300 rounded mx-1",
              @active_space && @active_space.id == space.id &&
                "bg-primary/10 text-primary font-semibold border-l-2 border-primary"
            ]}
          >
            <span class="text-base-content/40">#</span>
            <span class="truncate">{space.name}</span>
          </.link>

          <div :if={@spaces == []} class="px-4 py-2 text-xs text-base-content/40">
            No channels yet
          </div>
        </nav>
      </aside>

      <%!-- Mobile channel browser overlay --%>
      <%= if @mobile_browser_open do %>
        <div class="fixed inset-0 z-40 flex flex-col bg-base-100 lg:hidden">
          <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
            <p class="text-sm font-semibold">Channels</p>
            <button
              phx-click="close_mobile_browser"
              class="rounded-lg p-1 text-base-content/60 hover:bg-base-300 hover:text-base-content"
              aria-label="Close channels"
            >
              <span class="hero-x-mark size-5"></span>
            </button>
          </header>

          <nav class="flex-1 overflow-y-auto py-2">
            <.link
              :for={space <- @spaces}
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
              <span class="truncate">{space.name}</span>
            </.link>

            <div :if={@spaces == []} class="px-4 py-6 text-sm text-base-content/40 text-center">
              No channels yet
            </div>
          </nav>
        </div>
      <% end %>

      <div class="flex flex-1 overflow-hidden min-w-0">
        <div class="flex flex-1 flex-col overflow-hidden min-w-0">
          <header
            :if={@active_space}
            class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-5"
          >
            <div class="flex items-center gap-2 overflow-hidden">
              <%!-- Mobile: tappable channel title to open browser --%>
              <button
                phx-click="toggle_mobile_browser"
                class="flex items-center gap-2 overflow-hidden lg:hidden"
                aria-label="Browse channels"
              >
                <span class="text-base-content/50">#</span>
                <span class="truncate font-semibold">{@active_space.name}</span>
                <span class="hero-chevron-down size-4 text-base-content/40 flex-shrink-0"></span>
              </button>
              <%!-- Desktop: static channel title --%>
              <span class="hidden lg:flex items-center gap-2 overflow-hidden">
                <span class="text-base-content/50 text-lg font-bold">#</span>
                <span class="truncate font-bold text-base">{@active_space.name}</span>
                <span
                  :if={@active_space.topic}
                  class="truncate text-xs text-base-content/40"
                >
                  — {@active_space.topic}
                </span>
              </span>
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
                    class="input input-bordered input-sm w-64"
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
                  "flex items-center gap-1 rounded px-2 py-0.5 text-xs transition-colors hover:bg-base-300",
                  @show_canvases && "bg-base-300 text-primary"
                ]}
              >
                <span>🧩</span>
                <span>{length(@canvases)} canvases</span>
              </button>

              <button
                :if={@pins != []}
                phx-click="toggle_pins_panel"
                class={[
                  "flex items-center gap-1 rounded px-2 py-0.5 text-xs transition-colors hover:bg-base-300",
                  @show_pins && "bg-base-300 text-primary"
                ]}
              >
                <span>📌</span>
                <span>{length(@pins)} pinned</span>
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
                  📌 pinned message
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

          <div
            id="message-list"
            class="flex-1 overflow-y-auto px-5 py-4 flex flex-col justify-end space-y-1"
            phx-update="stream"
            phx-hook="ScrollToBottom"
          >
            <div
              :for={{dom_id, msg} <- @streams.messages}
              :if={is_nil(msg.deleted_at)}
              id={dom_id}
              class={[
                "group relative flex gap-3 rounded-xl px-2 py-2 transition-colors",
                @highlighted_message_id == msg.id && "bg-primary/5 ring-1 ring-primary/20",
                @current_participant && msg.participant_id == @current_participant.id &&
                  "bg-base-200/60"
              ]}
              data-participant-id={msg.participant_id}
              data-date={msg.inserted_at && DateTime.to_date(msg.inserted_at) |> Date.to_iso8601()}
            >
              <%!-- Avatar circle (hidden when grouped with previous message via JS) --%>
              <div class="flex-shrink-0 mt-0.5 message-avatar">
                <div class="w-8 h-8 rounded-full bg-primary text-primary-content flex items-center justify-center text-sm font-bold select-none">
                  {avatar_initial(@participants_map, msg.participant_id)}
                </div>
              </div>

              <%!-- Message body --%>
              <div class="flex-1 min-w-0">
                <div class="flex items-baseline gap-2 message-header">
                  <span class="text-sm font-bold text-base-content">
                    {sender_name(@participants_map, msg.participant_id)}
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
                      phx-value-message-id={msg.id}
                      phx-value-emoji={emoji}
                      title={"React with #{emoji}"}
                      class="rounded px-1.5 py-0.5 text-sm hover:bg-base-300 transition-colors"
                    >
                      {emoji}
                    </button>

                    <button
                      phx-click="open_thread"
                      phx-value-message-id={msg.id}
                      title="Reply in thread"
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:bg-base-300 transition-colors"
                    >
                      💬
                    </button>

                    <button
                      phx-click="toggle_pin"
                      phx-value-message-id={msg.id}
                      phx-value-space-id={msg.space_id}
                      title={if MapSet.member?(@pinned_message_ids, msg.id), do: "Unpin", else: "Pin"}
                      class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:bg-base-300 transition-colors"
                    >
                      {if MapSet.member?(@pinned_message_ids, msg.id), do: "📌", else: "📍"}
                    </button>
                  </div>
                </div>

                <div
                  :if={msg.content_type == "canvas"}
                  class="mt-1 rounded-2xl border border-primary/20 bg-primary/5 p-3"
                >
                  <div class="min-w-0 mb-2">
                    <p class="truncate text-sm font-semibold text-base-content">
                      {message_canvas_title(msg, @canvases_by_message_id)}
                    </p>
                    <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                      {message_canvas_type(msg, @canvases_by_message_id)} live canvas
                    </p>
                  </div>

                  <div :if={Map.get(@canvases_by_message_id, msg.id)} class="min-w-0 overflow-hidden">
                    <.canvas_document canvas={Map.get(@canvases_by_message_id, msg.id)} />
                  </div>

                  <p :if={present?(msg.content)} class="mt-2 text-sm leading-6 text-base-content/70">
                    {msg.content}
                  </p>
                </div>

                <p
                  :if={msg.content_type != "canvas" and present?(msg.content)}
                  class="text-sm leading-6 text-base-content"
                >
                  {format_message_content(msg.content)}
                </p>

                <div
                  :if={Map.get(@attachments_map, msg.id, []) != []}
                  class="mt-1 flex flex-col gap-1"
                >
                  <a
                    :for={attachment <- Map.get(@attachments_map, msg.id, [])}
                    href={attachment_url(attachment)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex w-fit items-center gap-2 rounded bg-base-200 px-2 py-1 text-sm text-primary hover:bg-base-300 hover:no-underline"
                  >
                    <span>📎</span>
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
                    phx-value-message-id={msg.id}
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
                    <span>+</span>
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Typing indicator --%>
          <div
            :if={@agent_typing}
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
            <span>Zip is thinking…</span>
          </div>

          <div class="flex-shrink-0 border-t border-base-300 px-5 py-3">
            <.form
              :if={@active_space}
              for={@compose_form}
              id="compose-form"
              phx-submit="send_message"
              phx-change="compose_changed"
              class="flex flex-col gap-2"
            >
              <%!-- File chips above the input — only shown when files attached --%>
              <div
                :if={@uploads.attachments.entries != []}
                class="flex flex-wrap gap-1"
              >
                <span
                  :for={entry <- @uploads.attachments.entries}
                  class="inline-flex items-center gap-1 rounded-full bg-base-200 px-2 py-0.5 text-xs text-base-content/70"
                >
                  <span class="hero-paper-clip size-3"></span>
                  <span>{entry.client_name}</span>
                </span>
              </div>

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
                          detail: %{name: suggestion.display_name || "User"}
                        )
                      }
                      class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                    >
                      <div class="w-6 h-6 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-bold flex-shrink-0">
                        {suggestion.display_name |> String.trim() |> String.first() |> String.upcase()}
                      </div>
                      <span class="flex-1 truncate font-medium">
                        {suggestion.display_name || "User"}
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
                <label
                  class="flex-shrink-0 cursor-pointer rounded-full w-9 h-9 flex items-center justify-center text-base-content/50 hover:bg-base-300 transition-colors"
                  title="Attach files"
                >
                  <span class="hero-plus size-5"></span>
                  <.live_file_input upload={@uploads.attachments} class="hidden" />
                </label>

                <input
                  type="text"
                  name="compose[text]"
                  id={@compose_form[:text].id}
                  value={Phoenix.HTML.Form.normalize_value("text", @compose_form[:text].value)}
                  placeholder={"Message ##{(@active_space && @active_space.name) || ""}"}
                  autocomplete="off"
                  class="input input-bordered min-w-0 flex-1 rounded-xl text-sm"
                  phx-hook="ComposeInput"
                />

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
        </div>

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
              ✕
            </button>
          </div>

          <div class="flex-1 overflow-y-auto px-4 py-4">
            <.canvas canvas={@active_canvas} />
          </div>
        </div>

        <div
          :if={@active_thread}
          class="hidden lg:flex w-80 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
        >
          <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold">Thread</span>
              <span :if={@active_thread.title} class="text-xs text-base-content/50 truncate">
                {@active_thread.title}
              </span>
            </div>
            <button
              phx-click="close_thread"
              class="btn btn-ghost btn-xs"
              title="Close thread"
            >
              ✕
            </button>
          </div>

          <div
            id="thread-messages"
            class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
          >
            <div
              :for={msg <- @thread_messages}
              class={[
                "flex flex-col gap-0.5 rounded-xl px-2 py-1 transition-colors",
                @highlighted_thread_message_id == msg.id && "bg-primary/5 ring-1 ring-primary/20"
              ]}
            >
              <div class="flex items-baseline gap-2">
                <span class="text-xs font-semibold text-primary">
                  {sender_name(@participants_map, msg.participant_id)}
                </span>
                <.local_time
                  id={"thread-message-time-#{msg.id}"}
                  timestamp={msg.inserted_at}
                  class="text-[10px] text-base-content/40"
                />
              </div>

              <p :if={present?(msg.content)} class="text-sm leading-6 text-base-content">
                {msg.content}
              </p>

              <div
                :if={Map.get(@thread_attachments_map, msg.id, []) != []}
                class="mt-1 flex flex-col gap-1"
              >
                <a
                  :for={attachment <- Map.get(@thread_attachments_map, msg.id, [])}
                  href={attachment_url(attachment)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex w-fit items-center gap-2 rounded bg-base-200 px-2 py-1 text-sm text-primary hover:bg-base-300 hover:no-underline"
                >
                  <span>📎</span>
                  <span>{attachment.filename}</span>
                  <span class="text-xs text-base-content/40">
                    ({format_bytes(attachment.byte_size)})
                  </span>
                </a>
              </div>
            </div>

            <div :if={@thread_messages == []} class="text-xs text-base-content/40">
              No replies yet — be the first!
            </div>
          </div>

          <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
            <.form
              for={@thread_compose_form}
              id="thread-compose-form"
              phx-submit="send_thread_message"
              class="flex flex-col gap-2"
            >
              <div
                :if={@uploads.thread_attachments.entries != []}
                class="flex flex-wrap gap-1"
              >
                <span
                  :for={entry <- @uploads.thread_attachments.entries}
                  class="inline-flex items-center gap-1 rounded-full bg-base-200 px-2 py-0.5 text-xs text-base-content/70"
                >
                  <span>📎</span>
                  <span>{entry.client_name}</span>
                </span>
              </div>

              <div class="flex items-end gap-2">
                <label
                  class="flex-shrink-0 cursor-pointer rounded-full w-8 h-8 flex items-center justify-center text-base-content/50 hover:bg-base-300 transition-colors"
                  title="Attach files"
                >
                  <span class="text-base">📎</span>
                  <.live_file_input upload={@uploads.thread_attachments} class="hidden" />
                </label>

                <div class="flex-1 relative">
                  <textarea
                    name="thread_compose[text]"
                    id={@thread_compose_form[:text].id}
                    rows="2"
                    placeholder="Reply in thread…"
                    autocomplete="off"
                    class="textarea textarea-bordered w-full resize-none rounded-xl pr-10 text-sm leading-relaxed"
                  >{Phoenix.HTML.Form.normalize_value("textarea", @thread_compose_form[:text].value)}</textarea>
                  <button
                    type="submit"
                    class="absolute right-2 bottom-2 w-7 h-7 rounded-full btn btn-primary btn-xs flex items-center justify-center p-0"
                    disabled={is_nil(@current_participant)}
                    title="Reply"
                  >
                    ✈️
                  </button>
                </div>
              </div>

              <p
                :for={error <- upload_errors(@uploads.thread_attachments)}
                class="text-xs text-error"
              >
                {upload_error_to_string(error)}
              </p>

              <div :for={entry <- @uploads.thread_attachments.entries}>
                <p
                  :for={error <- upload_errors(@uploads.thread_attachments, entry)}
                  class="text-xs text-error"
                >
                  {entry.client_name}: {upload_error_to_string(error)}
                </p>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
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
    Enum.find(socket.assigns.canvases, &(&1.id == canvas_id))
  end

  defp default_canvas_state("table") do
    %{
      "columns" => ["Task", "Owner", "Status"],
      "rows" => [
        %{"Task" => "Plan", "Owner" => "Alice", "Status" => "Ready"},
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

  defp load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
  end

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

  defp bootstrap_space(slug) do
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

  defp sender_name(participants_map, participant_id) do
    Map.get(participants_map, participant_id, "User")
  end

  defp avatar_initial(participants_map, participant_id) do
    name = Map.get(participants_map, participant_id, "U")

    name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "U"
      ch -> String.upcase(ch)
    end
  end

  defp format_message_content(content) when is_binary(content) do
    import Phoenix.HTML, only: [raw: 1, html_escape: 1, safe_to_string: 1]

    content
    |> String.split(~r/(@\w+)/, include_captures: true)
    |> Enum.map(fn part ->
      if String.match?(part, ~r/^@\w+$/) do
        ~s(<span class="rounded bg-primary/20 text-primary px-1 font-medium">#{safe_to_string(html_escape(part))}</span>)
      else
        safe_to_string(html_escape(part))
      end
    end)
    |> Enum.join()
    |> raw()
  end

  defp format_message_content(_content), do: ""

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
end
