defmodule PlatformWeb.Files.CanvasStarHooks do
  @moduledoc "The fullscreen header uses the browser's explicit persisted star API."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  alias Platform.Files.Stars

  def attach(socket) do
    if connected?(socket), do: Stars.subscribe(actor(socket))

    socket
    |> assign(:canvas_star_version, 0)
    |> attach_hook(:canvas_personal_star, :handle_event, &event/3)
    |> attach_hook(:canvas_personal_star_sync, :handle_info, &info/2)
  end

  defp actor(socket), do: %{id: socket.assigns[:current_user_id]}

  defp event("canvas_personal_star", %{"starred" => starred}, socket)
       when starred in ["true", "false"] do
    case socket.assigns[:canvas] do
      %{id: id} ->
        socket =
          case Stars.set(actor(socket), {:canvas, id}, starred == "true") do
            :ok -> assign(socket, :canvas_star_version, socket.assigns.canvas_star_version + 1)
            _ -> put_flash(socket, :error, "This canvas is no longer available to star.")
          end

        {:halt, socket}

      _ ->
        {:halt, socket}
    end
  end

  defp event("canvas_personal_star", _params, socket), do: {:halt, socket}
  defp event(_, _, socket), do: {:cont, socket}

  defp info({:stars_changed, _target}, socket),
    do: {:halt, assign(socket, :canvas_star_version, socket.assigns.canvas_star_version + 1)}

  defp info(_, socket), do: {:cont, socket}
end
