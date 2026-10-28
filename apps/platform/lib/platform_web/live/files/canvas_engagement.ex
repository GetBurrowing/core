defmodule PlatformWeb.Files.CanvasEngagement do
  @moduledoc "Connected standalone viewing uses the existing space Presence lifecycle."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  alias Platform.Chat
  alias Platform.Chat.{CanvasAccess, Presence}

  def attach(socket) do
    socket
    |> assign(:fullscreen_presence, nil)
    |> track()
    |> attach_hook(:fullscreen_canvas_lifecycle, :handle_info, &info/2)
  end

  def refresh(socket) do
    canvas = socket.assigns[:canvas]
    actor = %{id: socket.assigns[:current_user_id]}

    case canvas &&
           CanvasAccess.fetch_for_viewer(canvas.id, actor,
             audit: false,
             access_scope: socket.assigns[:access_scope]
           ) do
      {:ok, fresh, _} -> socket |> assign(:canvas, fresh) |> clear() |> track()
      _ -> socket |> clear() |> assign(:canvas, nil) |> assign(:load_error, :not_found)
    end
  end

  def clear(socket) do
    case socket.assigns[:fullscreen_presence] do
      {space_id, key} ->
        Presence.safe_untrack_in_space(self(), space_id, key)
        Phoenix.PubSub.unsubscribe(Platform.PubSub, Chat.PubSub.space_topic(space_id))

      _ ->
        :ok
    end

    assign(socket, :fullscreen_presence, nil)
  end

  defp track(socket) do
    canvas = socket.assigns[:canvas]
    user_id = socket.assigns[:current_user_id]

    if connected?(socket) && canvas && is_binary(user_id) &&
         Chat.participant?(canvas.space_id, user_id) do
      case Presence.safe_track_in_space(self(), canvas.space_id, user_id, %{
             participant_type: "user",
             canvas: %{canvas_id: canvas.id, engagement: :viewing}
           }) do
        {:ok, _} ->
          Chat.PubSub.subscribe(canvas.space_id)
          assign(socket, :fullscreen_presence, {canvas.space_id, user_id})

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp info({:canvas_deleted, %{id: id}}, socket) do
    if socket.assigns[:canvas] && socket.assigns.canvas.id == id,
      do: {:cont, clear(socket)},
      else: {:cont, socket}
  end

  defp info({:canvas_updated, %{id: id}}, socket) do
    if socket.assigns[:canvas] && socket.assigns.canvas.id == id,
      do: {:halt, refresh(socket)},
      else: {:cont, socket}
  end

  defp info({event, _}, socket) when event in [:participant_left, :participant_joined] do
    {:halt, refresh(socket)}
  end

  defp info(_, socket), do: {:cont, socket}
end
