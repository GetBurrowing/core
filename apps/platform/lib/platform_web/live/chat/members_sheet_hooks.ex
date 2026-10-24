defmodule PlatformWeb.ChatLive.MembersSheetHooks do
  @moduledoc """
  Lifecycle hook module for the Members sheet in `PlatformWeb.ChatLive`
  (task 01a1557a-8f80 stage 3). `PlatformWeb.ChatLive.MembersComponent`
  renders it; this module owns whether it is open.

  Owns:

    * Assign: `:show_members`
    * Event:  `"members_open"` — from the header `members-open` button, the
      space sheet's Members row and the refused-summon notice's "View
      members". Opens for every space but a DM. Opening is harmless for
      anyone: the sheet's controls are affordance only and the Chat context
      re-authorizes every write.
    * Info:   `{:members_closed}` and `{:members_flash, kind, msg}`, sent by
      the component.

  The refresh on joins, leaves and presence diffs lives in
  `PlatformWeb.ChatLive.PresenceHooks`, which already receives them.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.MembersSheetHooks.attach(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  @doc "Attach the Members sheet handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:show_members, false)
    |> attach_hook(:members_sheet_events, :handle_event, &handle_event/3)
    |> attach_hook(:members_sheet_info, :handle_info, &handle_info/2)
  end

  defp handle_event("members_open", _params, socket) do
    case socket.assigns[:active_space] do
      %{kind: kind} when kind != "dm" -> {:halt, assign(socket, :show_members, true)}
      _other -> {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:members_closed}, socket),
    do: {:halt, assign(socket, :show_members, false)}

  defp handle_info({:members_flash, kind, msg}, socket),
    do: {:halt, put_flash(socket, kind, msg)}

  defp handle_info(_msg, socket), do: {:cont, socket}
end
