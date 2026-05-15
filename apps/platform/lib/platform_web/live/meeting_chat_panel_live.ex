defmodule PlatformWeb.MeetingChatPanelLive do
  @moduledoc """
  Embedded chat panel for the Meetings module — placeholder for the
  intent panel (ADR 0042).

  This is the *render path* this stack member ships (task 019e2475-87a8
  stage 1). It is nested inside `PlatformWeb.MeetingLive` via:

      <%= live_render(@socket, PlatformWeb.MeetingChatPanelLive,
            id: "meeting-chat-panel-\#{@meeting.id}",
            session: %{"chat_space_slug" => @meeting.chat_space.slug}) %>

  ## Why a meeting-owned LV (and not nested ChatLive)?

  Stage 1's contract enumerates two embedding options:

    (a) reuse a `<.chat_panel space_id={...} />` style component —
        no such component exists; ChatLive's 1243-line heex is not
        carved out, and `chat_live.ex` is a 874-line LV with its own
        sidebar, mode switching, modal management, mobile drawer and
        push_navigate-on-empty-slug behavior.
    (b) nest `PlatformWeb.ChatLive` directly via `live_render` with the
        meeting's chat space slug.

  We took the spirit of (b) — a nested LiveView — but ship a
  *meeting-owned* chat panel LV instead of nesting the full ChatLive.
  Reasons this is the right balance for the placeholder:

    * ChatLive reads `space_slug` from URL params (`handle_params/3`),
      not session — nesting it would require teaching it to bootstrap
      from session and short-circuit its own redirect-to-first-channel
      catch-all. That's invasive on a high-traffic 874-line LV.
    * The intent panel (the eventual replacement for this surface, per
      ADR 0042) is a fundamentally different UI from the chat surface;
      keeping the embedded panel module-local now means the migration
      will not have to extract this pane back out of ChatLive later.
    * The placeholder needs a small subset of chat: messages list +
      composer + live PubSub. That fits cleanly in a ~150-line LV.

  ## Future migration

  When the real intent panel ships, this module is replaced wholesale.
  The `data-intent-panel-host="true"` attribute on the panel root in
  `meeting_live.html.heex` is the greppable hook future-Rowan will use
  to find this surface for swap-out.

  ## Mount + assigns

    * `:chat_space` — the bound `%Platform.Chat.Space{}` (looked up by
      slug from the session).
    * `:messages` — newest-first list from `Chat.list_messages/2`,
      capped at 50. Ordered chronologically (ascending) for display.
    * `:participant` — the per-user `%Platform.Chat.Participant{}` row
      for posting; created on demand.
    * `:user_id` — current user UUID from session (or a synthetic
      ephemeral UUID when no session, to keep the LV functional in the
      placeholder phase).
    * `:composer_text` — buffered composer body.
    * `:loaded` — boolean, true once messages are loaded (false when
      the session lookup found no chat_space — defensive empty render).
  """
  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub

  @message_limit 50

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || Ecto.UUID.generate()
    chat_space_slug = session["chat_space_slug"]

    socket =
      socket
      |> assign(:user_id, user_id)
      |> assign(:composer_text, "")
      |> assign(:loaded, false)
      |> assign(:chat_space, nil)
      |> assign(:participant, nil)
      |> assign(:messages, [])

    socket =
      case chat_space_slug && Chat.get_space_by_slug(chat_space_slug) do
        %Platform.Chat.Space{} = space ->
          if connected?(socket), do: ChatPubSub.subscribe(space.id)

          participant = ensure_participant(space.id, user_id)
          messages = load_messages(space.id)

          socket
          |> assign(:chat_space, space)
          |> assign(:participant, participant)
          |> assign(:messages, messages)
          |> assign(:loaded, true)

        _ ->
          # Defensive: if the embedded panel was mounted without a valid
          # slug (e.g. meeting record had a missing chat_space), render
          # an empty placeholder rather than crashing the parent LV.
          socket
      end

    {:ok, socket, layout: false}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("composer_change", %{"composer" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :composer_text, text)}
  end

  def handle_event("send_message", %{"composer" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.chat_space) ->
        {:noreply, socket}

      true ->
        attrs = %{
          space_id: socket.assigns.chat_space.id,
          participant_id: socket.assigns.participant.id,
          content_type: "text",
          content: text
        }

        case Chat.post_message(attrs, from_pid: self()) do
          {:ok, message} ->
            # broadcast_from skipped *this* pid; append locally so the
            # composer-owner sees their own message immediately.
            {:noreply,
             socket
             |> assign(:composer_text, "")
             |> update(:messages, fn msgs -> append_message(msgs, message) end)}

          {:error, _changeset} ->
            {:noreply, socket}
        end
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_message, %{space_id: space_id} = msg}, socket) do
    if socket.assigns.chat_space && socket.assigns.chat_space.id == space_id do
      {:noreply, update(socket, :messages, fn msgs -> append_message(msgs, msg) end)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all: the chat-space topic carries many event shapes (reactions,
  # pins, edits, etc.). The placeholder panel only renders raw messages;
  # ignore the rest so a sibling broadcast can't crash the embed.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp load_messages(space_id) do
    space_id
    |> Chat.list_messages(limit: @message_limit, top_level_only: true)
    |> Enum.reverse()
  end

  defp append_message(messages, msg) do
    if Enum.any?(messages, &(&1.id == msg.id)) do
      messages
    else
      messages ++ [msg]
    end
  end

  # Mirrors `PlatformWeb.ChatLive.ensure_participant/2` (chat_live.ex:779)
  # — ADR 0038: participant rows represent current membership only;
  # find-or-insert is the right shape.
  defp ensure_participant(space_id, user_id) do
    existing =
      space_id
      |> Chat.list_participants()
      |> Enum.find(fn p -> p.participant_type == "user" and p.participant_id == user_id end)

    case existing do
      %Platform.Chat.Participant{} = p ->
        p

      nil ->
        display_name = name_for_user(user_id)

        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, p} ->
            p

          {:error, _} ->
            # Race-loser fallback: re-read the (now-existing) row.
            space_id
            |> Chat.list_participants()
            |> Enum.find(fn p -> p.participant_type == "user" and p.participant_id == user_id end)
        end
    end
  end

  defp name_for_user(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-intent-panel-host="true"
      data-pane="meeting-chat-panel"
      class="flex h-full min-h-0 flex-col bg-base-100 text-base-content"
      id={"meeting-chat-panel-root-#{@chat_space && @chat_space.id || "empty"}"}
    >
      <%= if @loaded do %>
        <div
          class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-2"
          data-pane-section="messages"
          id="meeting-chat-panel-messages"
        >
          <%= if @messages == [] do %>
            <p class="m-auto text-xs text-base-content/40">
              No messages yet. Start the conversation.
            </p>
          <% else %>
            <article
              :for={msg <- @messages}
              class="flex flex-col gap-0.5 rounded-lg bg-base-200/40 px-3 py-2"
              data-message-id={msg.id}
            >
              <header class="flex items-baseline gap-2">
                <span class="text-xs font-semibold text-base-content/80">
                  {msg.author_display_name || "Unknown"}
                </span>
                <span class="text-[10px] text-base-content/40">
                  {Calendar.strftime(msg.inserted_at, "%H:%M")}
                </span>
              </header>
              <p class="whitespace-pre-wrap break-words text-sm text-base-content">
                {msg.content}
              </p>
            </article>
          <% end %>
        </div>

        <form
          phx-submit="send_message"
          phx-change="composer_change"
          class="flex flex-shrink-0 items-end gap-2 border-t border-base-300 bg-base-200/40 px-3 py-2 pb-[max(0.5rem,env(safe-area-inset-bottom))]"
          data-pane-section="composer"
        >
          <textarea
            name="composer[text]"
            rows="1"
            placeholder="Message"
            class="textarea textarea-bordered textarea-sm min-h-9 flex-1 resize-none bg-base-100"
            aria-label="Message"
          ><%= @composer_text %></textarea>
          <button
            type="submit"
            class="btn btn-primary btn-sm gap-1"
            disabled={String.trim(@composer_text) == ""}
            aria-label="Send message"
          >
            <span class="hero-paper-airplane size-4"></span>
            <span class="hidden sm:inline">Send</span>
          </button>
        </form>
      <% else %>
        <div
          class="flex h-full items-center justify-center text-xs text-base-content/40"
          data-pane-section="empty"
        >
          <span class="hero-chat-bubble-left-right size-5"></span>
          <span class="ml-2">No discussion bound to this meeting.</span>
        </div>
      <% end %>
    </div>
    """
  end
end
