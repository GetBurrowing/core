defmodule PlatformWeb.ChatLive do
  @moduledoc """
  LiveView for the Chat surface.

  Renders a sidebar of spaces on the left and a message thread on the right.
  Subscribes to `Platform.Chat.PubSub` for real-time updates and tracks the
  current user via `Platform.Chat.Presence`.

  Routes:
    GET /chat          → :index — redirects to the first space (or creates "general")
    GET /chat/:space_slug → :show  — renders the selected space
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub

  @message_limit 50

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
      |> assign_compose("")
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

    # Guard: if bootstrap failed for some reason, bail out
    if is_nil(space) do
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    else
      # Subscribe to real-time events
      if connected?(socket), do: ChatPubSub.subscribe(space.id)

      # Ensure this user has a participant record in the space
      participant = ensure_participant(space.id, socket.assigns.user_id)

      # Track presence
      if connected?(socket) && participant do
        display_name = resolve_display_name(socket.assigns.user_id, participant)

        ChatPresence.track_in_space(self(), space.id, socket.assigns.user_id, %{
          display_name: display_name,
          participant_type: "user"
        })
      end

      # Load messages (list_messages returns newest-first → reverse for chronological order)
      messages =
        space.id
        |> Chat.list_messages(limit: @message_limit)
        |> Enum.reverse()

      # Build id→display_name lookup (keyed by participant PK, not participant_id)
      participants = Chat.list_participants(space.id)
      participants_map = Map.new(participants, fn p -> {p.id, p.display_name || "User"} end)

      online_count =
        if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

      {:noreply,
       socket
       |> assign(:page_title, "# #{space.name}")
       |> assign(:active_space, space)
       |> assign(:participants_map, participants_map)
       |> assign(:online_count, online_count)
       |> assign(:current_participant, participant)
       |> assign(:spaces, Chat.list_spaces())
       |> stream(:messages, messages, reset: true)}
    end
  end

  def handle_params(_params, _url, socket) do
    # :index action — redirect to first known space, or show empty state if none exist
    case socket.assigns.spaces do
      [first | _] ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{first.slug}")}

      [] ->
        # No spaces yet — stay at /chat and render the empty/no-spaces state
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
      # Broadcast from self so our own socket receives the new message
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

  # ── PubSub callbacks ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_message, msg}, socket) do
    {:noreply, stream_insert(socket, :messages, msg)}
  end

  def handle_info({:message_updated, msg}, socket) do
    {:noreply, stream_insert(socket, :messages, msg)}
  end

  def handle_info({:message_deleted, msg}, socket) do
    {:noreply, stream_delete(socket, :messages, msg)}
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

  def handle_info({:reaction_added, _reaction}, socket), do: {:noreply, socket}
  def handle_info({:reaction_removed, _data}, socket), do: {:noreply, socket}
  def handle_info({:pin_added, _pin}, socket), do: {:noreply, socket}
  def handle_info({:pin_removed, _data}, socket), do: {:noreply, socket}

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

      <%!-- ── Chat area ────────────────────────────────────────────── --%>
      <div class="flex flex-1 flex-col overflow-hidden">
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

          <div class="flex flex-shrink-0 items-center gap-1.5 text-xs text-base-content/50">
            <span class="inline-block size-2 rounded-full bg-success"></span>
            <span>{@online_count} online</span>
          </div>
        </header>

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
    </div>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
  end

  # Find the space by slug; create it if this is the first visit
  defp bootstrap_space(slug) do
    name =
      slug
      |> String.replace("-", " ")
      |> String.split()
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    case Chat.create_space(%{name: name, slug: slug, kind: "channel"}) do
      {:ok, space} -> space
      # Race condition or validation error; re-fetch
      {:error, _} -> Chat.get_space_by_slug(slug)
    end
  end

  # Ensure the user has an active participant record in this space
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
