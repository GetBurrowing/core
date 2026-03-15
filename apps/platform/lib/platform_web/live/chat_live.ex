defmodule PlatformWeb.ChatLive do
  @moduledoc """
  LiveView for the Chat surface — with threads, reactions, and pins.

  ## Layout

  Three-column layout when a thread is open:

      [Space sidebar | Message list | Thread panel]

  Thread panel collapses when closed.  Pins panel slides in below the space
  header.

  ## Assigns

    * `:active_space`        — current `%Space{}` or `nil`
    * `:spaces`              — sidebar list
    * `:participants_map`    — `%{participant_id => display_name}`
    * `:online_count`        — integer
    * `:current_participant` — `%Participant{}` for the session user in this space
    * `:reactions_map`       — `%{message_id => [%{emoji, count, reacted_by_me}]}`
    * `:active_thread`       — `%Thread{}` or `nil`
    * `:thread_messages`     — `[%Message{}]` for the active thread
    * `:pins`                — `[%Pin{}]` for the active space
    * `:pinned_message_ids`  — `MapSet.t(binary())` for O(1) lookup in template

  ## Routes
    GET /chat             → :index — redirects to first space (or empty state)
    GET /chat/:space_slug → :show  — renders the selected space
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub

  @message_limit 50
  @quick_emojis ["👍", "❤️", "😂", "🎉"]

  # ── Mount ──────────────────────────────────────────────────────────────────

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
      |> assign(:active_thread, nil)
      |> assign(:thread_messages, [])
      |> assign(:pins, [])
      |> assign(:show_pins, false)
      |> assign(:pinned_message_ids, MapSet.new())
      |> assign(:quick_emojis, @quick_emojis)
      |> assign_compose("")
      |> assign_thread_compose("")
      |> stream(:messages, [])

    {:ok, socket}
  end

  # ── handle_params ──────────────────────────────────────────────────────────

  @impl true
  def handle_params(%{"space_slug" => slug}, _url, socket) do
    # Unsubscribe from the previous space if navigating
    if prev = socket.assigns.active_space do
      ChatPubSub.unsubscribe(prev.id)

      if connected?(socket) do
        ChatPresence.untrack_in_space(self(), prev.id, socket.assigns.user_id)
      end
    end

    # Find or bootstrap the space
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

      # Load messages (newest-first → reverse for chronological display)
      messages =
        space.id
        |> Chat.list_messages(limit: @message_limit)
        |> Enum.reverse()

      participants = Chat.list_participants(space.id)
      participants_map = Map.new(participants, fn p -> {p.id, p.display_name || "User"} end)

      online_count =
        if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

      # Load reactions for all visible messages in one query
      reactions_map = build_reactions_map(messages, participant)

      # Load pins for this space
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
       |> assign(:active_thread, nil)
       |> assign(:thread_messages, [])
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

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("send_message", %{"compose" => %{"text" => content}}, socket) do
    content = String.trim(content)

    with false <- content == "",
         space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      case Chat.post_message(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: content
           }) do
        {:ok, msg} ->
          {:noreply, socket |> stream_insert(:messages, msg) |> assign_compose("")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send message.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Reactions ──────────────────────────────────────────────────────────────

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

    # State updates come via PubSub
    {:noreply, socket}
  end

  # ── Threads ────────────────────────────────────────────────────────────────

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

          {:noreply,
           socket
           |> assign(:active_thread, thread)
           |> assign(:thread_messages, thread_messages)
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
     |> assign(:thread_messages, [])}
  end

  def handle_event("send_thread_message", %{"thread_compose" => %{"text" => content}}, socket) do
    content = String.trim(content)

    with false <- content == "",
         thread when not is_nil(thread) <- socket.assigns.active_thread,
         space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      case Chat.post_message(%{
             space_id: space.id,
             thread_id: thread.id,
             participant_id: participant.id,
             content_type: "text",
             content: content
           }) do
        {:ok, msg} ->
          thread_messages = socket.assigns.thread_messages ++ [msg]

          {:noreply,
           socket
           |> assign(:thread_messages, thread_messages)
           |> assign_thread_compose("")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send reply.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Pins ───────────────────────────────────────────────────────────────────

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

    # State updates come via PubSub
    {:noreply, socket}
  end

  def handle_event("toggle_pins_panel", _params, socket) do
    {:noreply, assign(socket, :show_pins, !socket.assigns.show_pins)}
  end

  # ── PubSub callbacks ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_message, msg}, socket) do
    # Only stream top-level (non-thread) messages into the main list.
    # Thread messages are loaded separately.
    if is_nil(msg.thread_id) do
      {:noreply, stream_insert(socket, :messages, msg)}
    else
      # Append to thread panel if the active thread matches
      if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
        {:noreply, update(socket, :thread_messages, &(&1 ++ [msg]))}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info({:message_updated, msg}, socket) do
    {:noreply, stream_insert(socket, :messages, msg)}
  end

  def handle_info({:message_deleted, msg}, socket) do
    {:noreply, stream_delete(socket, :messages, msg)}
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

  # Catch-all to avoid crashing on unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full overflow-hidden">
      <%!-- ── Space sidebar ─────────────────────────────────────────── --%>
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

      <%!-- ── Main content (messages + thread panel) ─────────────────── --%>
      <div class="flex flex-1 overflow-hidden min-w-0">
        <%!-- ── Messages column ───────────────────────────────────────── --%>
        <div class="flex flex-1 flex-col overflow-hidden min-w-0">
          <%!-- Space header --%>
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
              <%!-- Pins toggle button --%>
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

              <%!-- Online count --%>
              <div class="flex items-center gap-1.5">
                <span class="inline-block size-2 rounded-full bg-success"></span>
                <span>{@online_count} online</span>
              </div>
            </div>
          </header>

          <%!-- Pins panel (below header, above messages) --%>
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

          <%!-- Message list --%>
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
              <%!-- Row: sender + timestamp + action buttons --%>
              <div class="flex items-baseline gap-2">
                <span class="text-xs font-semibold text-primary">
                  {sender_name(@participants_map, msg.participant_id)}
                </span>
                <span class="text-[10px] text-base-content/40">
                  {format_timestamp(msg.inserted_at)}
                </span>

                <%!-- Action bar (visible on hover) --%>
                <div class="ml-auto hidden group-hover:flex items-center gap-1">
                  <%!-- Quick emoji reactions --%>
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

                  <%!-- Reply in thread --%>
                  <button
                    phx-click="open_thread"
                    phx-value-message-id={msg.id}
                    title="Reply in thread"
                    class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:bg-base-300 transition-colors"
                  >
                    💬
                  </button>

                  <%!-- Pin / Unpin --%>
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

              <%!-- Message content --%>
              <p class="text-sm leading-6 text-base-content">{msg.content}</p>

              <%!-- Reactions row --%>
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

          <%!-- Compose bar --%>
          <div class="flex-shrink-0 border-t border-base-300 px-5 py-3">
            <.form
              :if={@active_space}
              for={@compose_form}
              id="compose-form"
              phx-submit="send_message"
              class="flex gap-2"
            >
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
            </.form>

            <p :if={is_nil(@current_participant) && @active_space} class="mt-1 text-xs text-error">
              Unable to join space — messages are read-only.
            </p>
          </div>
        </div>

        <%!-- ── Thread panel ──────────────────────────────────────────── --%>
        <div
          :if={@active_thread}
          class="flex w-80 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
        >
          <%!-- Thread header --%>
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

          <%!-- Thread messages --%>
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
              <p class="text-sm leading-6 text-base-content">{msg.content}</p>
            </div>

            <div :if={@thread_messages == []} class="text-xs text-base-content/40">
              No replies yet — be the first!
            </div>
          </div>

          <%!-- Thread compose --%>
          <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
            <.form
              for={@thread_compose_form}
              id="thread-compose-form"
              phx-submit="send_thread_message"
              class="flex gap-2"
            >
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
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
  end

  defp assign_thread_compose(socket, text) do
    assign(socket, :thread_compose_form, to_form(%{"text" => text}, as: :thread_compose))
  end

  # Build the reactions_map from a list of messages + current participant.
  # Groups reactions by emoji with count + reacted_by_me flag.
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

  # Incrementally update reactions_map when a reaction is added via PubSub.
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

  # Incrementally update reactions_map when a reaction is removed via PubSub.
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
          # If the removed reaction was mine, clear reacted_by_me
          new_reacted = g.reacted_by_me && removed_pid != my_id
          %{g | count: new_count, reacted_by_me: new_reacted}
        else
          g
        end
      end)
      |> Enum.reject(&(&1.count == 0))

    Map.put(reactions_map, msg_id, updated)
  end

  # Load messages for an open thread (oldest-first for threaded display).
  defp load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
  end

  # Find the space by slug; create it if this is the first visit.
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

  # Ensure the user has an active participant record in this space.
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
        # Participant left previously — rejoin
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

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%I:%M %p")
  end

  defp format_timestamp(_), do: ""
end
