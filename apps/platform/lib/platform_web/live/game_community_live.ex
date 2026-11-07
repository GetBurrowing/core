defmodule PlatformWeb.GameCommunityLive do
  @moduledoc "Game text chat using Burrow messages and PubSub with public labels only."
  use PlatformWeb, :live_view
  alias Platform.{Accounts, Chat, Games}

  @impl true
  def mount(_params, session, socket) do
    case authorized(session["game_slug"], session["current_user_id"]) do
      {:ok, game, user, space, participant} ->
        if connected?(socket), do: Chat.PubSub.subscribe(space.id)

        socket =
          socket
          |> assign(:game_access_denied, false)
          |> assign(:game_slug, game["slug"])
          |> assign(:player_id, user.id)
          |> assign(:space_id, space.id)
          |> assign(:participant_id, participant.id)
          |> assign(:form, to_form(%{"text" => ""}, as: :compose))
          |> assign(:send_error, nil)
          |> stream(:messages, public_messages(space.id))

        {:ok, socket}

      _ ->
        {:ok, assign(socket, :game_access_denied, true)}
    end
  end

  @impl true
  def render(%{game_access_denied: true} = assigns) do
    ~H"""
    <p id="game-chat-access-denied" role="status">
      Sign in and join this game’s community to see its messages.
    </p>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="gp-player-chat">
      <div
        id="game-messages"
        phx-update="stream"
        class="gp-player-messages"
        role="log"
        aria-label="Player conversation"
      >
        <article :for={{id, message} <- @streams.messages} id={id} class="gp-player-message">
          <div>
            <strong>{message.label}</strong><span :if={message.ai?} class="gp-badge">AI</span><time datetime={
              DateTime.to_iso8601(message.at)
            }>{Calendar.strftime(message.at, "%H:%M")} UTC</time>
          </div>
          <p>{message.text}</p>
        </article>
      </div>
      <p :if={@send_error} role="alert" class="gp-request-error">{@send_error}</p>
      <.form for={@form} id="compose-form" phx-submit="send_message" class="gp-player-composer">
        <.input
          field={@form[:text]}
          id="game-message-text"
          type="text"
          label="Message the pilots"
          maxlength="2000"
          autocomplete="off"
        />
        <button type="submit" aria-label="Send message" class="gp-player-send">Send</button>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{game_access_denied: true}} = socket),
    do: {:noreply, socket}

  def handle_event("send_message", %{"compose" => %{"text" => text}}, socket) do
    with {:ok, _game, user, _space, participant} <-
           authorized(socket.assigns.game_slug, socket.assigns.player_id),
         :ok <-
           Platform.Access.check(
             Platform.Access.Scope.for_user(user),
             "chat.write",
             {:space, socket.assigns.space_id}
           ),
         text when is_binary(text) <- text,
         text <- String.trim(text),
         true <- text != "" and String.length(text) <= 2000,
         {:ok, message} <-
           Chat.post_message(%{
             space_id: socket.assigns.space_id,
             participant_id: participant.id,
             content_type: "text",
             content: text,
             author_display_name: Games.player_display_name(user),
             author_avatar_url: nil
           }) do
      {:noreply,
       socket
       |> stream_insert(:messages, public_message(message))
       |> assign(:form, to_form(%{"text" => ""}, as: :compose))
       |> assign(:send_error, nil)}
    else
      {:error, :forbidden} ->
        {:noreply, assign(socket, :game_access_denied, true)}

      _ ->
        {:noreply,
         assign(socket, :send_error, "Message not sent. Check your connection and try again.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, %{assigns: %{game_access_denied: true}} = socket),
    do: {:noreply, socket}

  def handle_info({event, message}, socket) when event in [:new_message, :message_updated] do
    case authorized(socket.assigns.game_slug, socket.assigns.player_id) do
      {:ok, _, _, _, _} ->
        if message.space_id == socket.assigns.space_id and message.content_type == "text" and
             is_nil(message.thread_id) do
          {:noreply, stream_insert(socket, :messages, public_message(message))}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, assign(socket, :game_access_denied, true)}
    end
  end

  def handle_info({:message_deleted, message}, socket),
    do: {:noreply, stream_delete_by_dom_id(socket, :messages, "messages-" <> message.id)}

  def handle_info({event, _participant}, socket)
      when event in [:participant_left, :participant_joined] do
    case authorized(socket.assigns.game_slug, socket.assigns.player_id) do
      {:ok, _, _, _, _} ->
        {:noreply,
         stream(socket, :messages, public_messages(socket.assigns.space_id), reset: true)}

      _ ->
        {:noreply, assign(socket, :game_access_denied, true)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp authorized(slug, user_id) do
    with %{} = game <- Games.get(slug),
         %{} = user <- Games.user(user_id),
         %{joined?: true, space: space} <- Games.community(game, user),
         {:ok, participant} <- Chat.SpaceAccess.authorize_writer(space.id, user) do
      {:ok, game, user, space, participant}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp public_messages(space_id) do
    labels = labels_for_space(space_id)

    Chat.list_messages(space_id, order: :asc, limit: 50)
    |> Enum.filter(&(&1.content_type == "text" and is_nil(&1.thread_id)))
    |> Enum.map(&public_message(&1, labels))
  end

  defp public_message(message), do: public_message(message, labels_for_space(message.space_id))

  defp public_message(message, labels) do
    identity =
      Map.get(labels, message.participant_id) ||
        %{
          label:
            Games.generated_handle(message.author_user_id || message.participant_id || message.id),
          ai?: false
        }

    Map.merge(identity, %{id: message.id, text: message.content, at: message.inserted_at})
  end

  defp labels_for_space(space_id) do
    participants = Chat.list_participants(space_id)

    users =
      participants
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Accounts.get_users_map(include_archived: true)

    Map.new(participants, fn participant ->
      identity =
        if participant.participant_type == "agent" do
          %{label: participant.display_name || "AI pilot", ai?: true}
        else
          user = Map.get(users, participant.participant_id) || %{id: participant.participant_id}
          %{label: Games.player_display_name(user), ai?: false}
        end

      {participant.id, identity}
    end)
  end
end
