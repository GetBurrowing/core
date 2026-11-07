defmodule PlatformWeb.GameCommunityLive do
  @moduledoc "A game-scoped, authenticated entry to the canonical embedded chat."
  use PlatformWeb, :live_view

  @impl true
  def mount(params, session, socket) do
    with %{} = game <- Platform.Games.get(session["game_slug"]),
         %{} = user <- Platform.Games.user(session["current_user_id"]),
         %{joined?: true, space: space} <- Platform.Games.community(game, user) do
      socket = assign(socket, :current_user_record, user)
      {:cont, socket} = PlatformWeb.LiveAuth.on_mount(:default, params, session, socket)

      PlatformWeb.ChatLive.embedded_mount(params,
        %{"current_user_id" => user.id, "chat_space_slug" => space.id},
        assign(socket, :game_access_denied, false))
    else
      _ -> {:ok, assign(socket, :game_access_denied, true)}
    end
  end

  @impl true
  def render(%{game_access_denied: true} = assigns) do
    ~H"""
    <p id="game-chat-access-denied" role="status">Sign in and join this game’s community to see its messages.</p>
    """
  end

  def render(assigns), do: PlatformWeb.ChatLive.render(assigns)

  @impl true
  def handle_event(_event, _params, %{assigns: %{game_access_denied: true}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, socket), do: PlatformWeb.ChatLive.handle_event(event, params, socket)

  @impl true
  def handle_info(_message, %{assigns: %{game_access_denied: true}} = socket), do: {:noreply, socket}
  def handle_info(message, socket), do: PlatformWeb.ChatLive.handle_info(message, socket)

  @impl true
  def terminate(_reason, %{assigns: %{game_access_denied: true}}), do: :ok
  def terminate(reason, socket), do: PlatformWeb.ChatLive.terminate(reason, socket)
end
