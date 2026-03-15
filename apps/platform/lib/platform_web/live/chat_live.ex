defmodule PlatformWeb.ChatLive do
  @moduledoc """
  LiveView for the Chat surface — with threads, reactions, pins, and attachments.

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

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub

  @message_limit 50
  @quick_emojis ["👍", "❤️", "😂", "🎉"]
  @max_upload_entries 5
  @max_upload_size 15_000_000

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
      |> assign(:participants_map, %{})
      |> assign(:online_count, 0)
      |> assign(:current_participant, nil)
      |> assign(:reactions_map, %{})
      |> assign(:attachments_map, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_messages, [])
      |> assign(:thread_attachments_map, %{})
      |> assign(:pins, [])
      |> assign(:show_pins, false)
      |> assign(:pinned_message_ids, MapSet.new())
      |> assign(:quick_emojis, @quick_emojis)
      |> assign_compose("")
      |> assign_thread_compose("")
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

      if connected?(socket) && participant do
        display_name = resolve_display_name(socket.assigns.user_id, participant)

        ChatPresence.track_in_space(self(), space.id, socket.assigns.user_id, %{
          display_name: display_name,
          participant_type: "user"
        })
      end

      messages =
        space.id
        |> Chat.list_messages(limit: @message_limit)
        |> Enum.reverse()

      participants = Chat.list_participants(space.id)
      participants_map = Map.new(participants, fn p -> {p.id, p.display_name || "User"} end)

      online_count =
        if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

      reactions_map = build_reactions_map(messages, participant)
      attachments_map = build_attachments_map(messages)
      pins = Chat.list_pins(space.id)
      pinned_message_ids = MapSet.new(pins, & &1.message_id)

      {:noreply,
       socket
       |> assign(:page_title, "# #{space.name}")
       |> assign(:active_space, space)
       |> assign(:participants_map, participants_map)
       |> assign(:online_count, online_count)
       |> assign(:current_participant, participant)
       |> assign(:reactions_map, reactions_map)
       |> assign(:attachments_map, attachments_map)
       |> assign(:active_thread, nil)
       |> assign(:thread_messages, [])
       |> assign(:thread_attachments_map, %{})
       |> assign(:pins, pins)
       |> assign(:show_pins, false)
       |> assign(:pinned_message_ids, pinned_message_ids)
       |> assign(:spaces, Chat.list_spaces())
       |> stream(:messages, messages, reset: true)}
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
           |> assign(:thread_messages, thread_messages)
           |> assign(:thread_attachments_map, thread_attachments_map)
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
     |> assign(:thread_attachments_map, %{})}
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

  @impl true
  def handle_info({:new_message, msg}, socket) do
    attachments = Chat.list_attachments(msg.id)

    if is_nil(msg.thread_id) do
      {:noreply,
       socket
       |> stream_insert(:messages, msg)
       |> put_attachment_map_entry(msg.id, attachments)}
    else
      if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
        {:noreply,
         socket
         |> update(:thread_messages, &(&1 ++ [msg]))
         |> put_thread_attachment_map_entry(msg.id, attachments)}
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
     |> put_attachment_map_entry(msg.id, attachments)}
  end

  def handle_info({:message_deleted, msg}, socket) do
    {:noreply,
     socket
     |> stream_delete(:messages, msg)
     |> delete_attachment_map_entry(msg.id)
     |> delete_thread_attachment_map_entry(msg.id)}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full overflow-hidden">
      <aside class="flex w-52 flex-shrink-0 flex-col border-r border-base-300 bg-base-200">
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
                "bg-base-300 text-primary font-semibold"
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

      <div class="flex flex-1 overflow-hidden min-w-0">
        <div class="flex flex-1 flex-col overflow-hidden min-w-0">
          <header
            :if={@active_space}
            class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-5"
          >
            <div class="flex items-center gap-2 overflow-hidden">
              <span class="text-base-content/50">#</span>
              <span class="truncate font-semibold">{@active_space.name}</span>
              <span
                :if={@active_space.topic}
                class="hidden truncate text-xs text-base-content/40 sm:block"
              >
                — {@active_space.topic}
              </span>
            </div>

            <div class="flex flex-shrink-0 items-center gap-3 text-xs text-base-content/50">
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

              <div class="flex items-center gap-1.5">
                <span class="inline-block size-2 rounded-full bg-success"></span>
                <span>{@online_count} online</span>
              </div>
            </div>
          </header>

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
            id="message-list"
            class="flex-1 overflow-y-auto px-5 py-4 space-y-3"
            phx-update="stream"
          >
            <div
              :for={{dom_id, msg} <- @streams.messages}
              :if={is_nil(msg.deleted_at)}
              id={dom_id}
              class="group relative flex flex-col gap-0.5"
            >
              <div class="flex items-baseline gap-2">
                <span class="text-xs font-semibold text-primary">
                  {sender_name(@participants_map, msg.participant_id)}
                </span>
                <span class="text-[10px] text-base-content/40">
                  {format_timestamp(msg.inserted_at)}
                </span>

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

              <p :if={present?(msg.content)} class="text-sm leading-6 text-base-content">
                {msg.content}
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
              </div>
            </div>
          </div>

          <div class="flex-shrink-0 border-t border-base-300 px-5 py-3">
            <.form
              :if={@active_space}
              for={@compose_form}
              id="compose-form"
              phx-submit="send_message"
              class="flex flex-col gap-2"
            >
              <div class="flex gap-2">
                <.input
                  field={@compose_form[:text]}
                  type="text"
                  placeholder={"Message ##{(@active_space && @active_space.name) || ""}"}
                  autocomplete="off"
                  class="flex-1"
                />
                <button
                  type="submit"
                  class="btn btn-neutral"
                  disabled={is_nil(@current_participant)}
                >
                  Send
                </button>
              </div>

              <div class="flex flex-wrap items-center gap-3 text-xs text-base-content/50">
                <label class="inline-flex cursor-pointer items-center gap-2 rounded px-2 py-1 hover:bg-base-200">
                  <span>📎</span>
                  <span>Add files</span>
                  <.live_file_input upload={@uploads.attachments} class="hidden" />
                </label>

                <span
                  :for={entry <- @uploads.attachments.entries}
                  class="rounded bg-base-200 px-2 py-1 text-base-content/70"
                >
                  {entry.client_name}
                </span>
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
          :if={@active_thread}
          class="flex w-80 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
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
              class="flex flex-col gap-0.5"
            >
              <div class="flex items-baseline gap-2">
                <span class="text-xs font-semibold text-primary">
                  {sender_name(@participants_map, msg.participant_id)}
                </span>
                <span class="text-[10px] text-base-content/40">
                  {format_timestamp(msg.inserted_at)}
                </span>
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
              <div class="flex gap-2">
                <.input
                  field={@thread_compose_form[:text]}
                  type="text"
                  placeholder="Reply in thread…"
                  autocomplete="off"
                  class="flex-1 text-sm"
                />
                <button
                  type="submit"
                  class="btn btn-neutral btn-sm"
                  disabled={is_nil(@current_participant)}
                >
                  Reply
                </button>
              </div>

              <div class="flex flex-wrap items-center gap-3 text-xs text-base-content/50">
                <label class="inline-flex cursor-pointer items-center gap-2 rounded px-2 py-1 hover:bg-base-200">
                  <span>📎</span>
                  <span>Add files</span>
                  <.live_file_input upload={@uploads.thread_attachments} class="hidden" />
                </label>

                <span
                  :for={entry <- @uploads.thread_attachments.entries}
                  class="rounded bg-base-200 px-2 py-1 text-base-content/70"
                >
                  {entry.client_name}
                </span>
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

  defp load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
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
            case Chat.post_message_with_attachments(attrs, pending_attachments) do
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

  defp sender_name(participants_map, participant_id) do
    Map.get(participants_map, participant_id, "User")
  end

  defp attachment_url(attachment), do: ~p"/chat/attachments/#{attachment.id}"

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
end
