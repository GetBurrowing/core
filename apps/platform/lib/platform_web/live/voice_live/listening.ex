defmodule PlatformWeb.VoiceLive.Listening do
  @moduledoc """
  The Voice page's "listening" presence entry (task 01a21e8d stage 2).

  While the on-device Voice page holds a partner's DM and is visible, the
  LiveView process is tracked in `Platform.Chat.Presence` for that DM under
  the user's id with the meta

      %{participant_type: "user", surface: "voice"}

  `Platform.Chat.Presence.voice_listener_ids/1` reads that meta and
  `Platform.Chat.AttentionRouter` then sends no push for an agent's reply in
  that DM: the person is hearing it spoken.

  This module is the single writer of that entry:

    * `listen/2` tracks the DM (untracking any other DM first);
    * `unlisten/1` untracks it and forgets the target;
    * `set_visible/2` untracks when the page is hidden and re-tracks the
      remembered target when it is visible again.

  The entry is per-pid, so a ChatLive tab of the same user in the same DM
  keeps its own entry. It clears on its own when the LiveView process exits
  (Phoenix.Presence drops a dead pid's entries), which covers a dropped
  socket. A failed track fails OPEN: nothing is tracked and pushes go out.
  Logs carry an error tag only, never ids, names or message text.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  require Logger

  alias Platform.Chat.Presence

  @doc "The presence meta the Voice page tracks (`Presence.voice_listener_meta/0`)."
  @spec meta() :: map()
  def meta, do: Presence.voice_listener_meta()

  @doc """
  Listen on `space_id`: remember it as the target and track it when the
  socket is connected, the page is visible and a user is signed in.
  """
  @spec listen(Phoenix.LiveView.Socket.t(), binary() | nil) :: Phoenix.LiveView.Socket.t()
  def listen(socket, space_id) when is_binary(space_id) do
    socket =
      case socket.assigns[:voice_listening_space_id] do
        nil -> socket
        ^space_id -> socket
        _other -> untrack(socket)
      end

    socket
    |> assign(:voice_listen_target, space_id)
    |> track(space_id)
  end

  def listen(socket, _space_id), do: socket

  @doc "Stop listening: untrack the entry and forget the target."
  @spec unlisten(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def unlisten(socket) do
    socket
    |> untrack()
    |> assign(:voice_listen_target, nil)
  end

  @doc """
  The page became hidden (`false`) or visible (`true`). Hidden untracks but
  keeps the target, so visible tracks the same DM again.
  """
  @spec set_visible(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def set_visible(socket, visible) when is_boolean(visible) do
    socket = assign(socket, :voice_visible?, visible)

    case {visible, socket.assigns[:voice_listen_target]} do
      {false, _target} -> untrack(socket)
      {true, nil} -> socket
      {true, target} -> track(socket, target)
    end
  end

  defp track(socket, space_id) do
    user_id = user_id(socket)

    cond do
      socket.assigns[:voice_listening_space_id] == space_id ->
        socket

      connected?(socket) and socket.assigns[:voice_visible?] != false and is_binary(user_id) ->
        case Presence.safe_track_in_space(
               self(),
               space_id,
               user_id,
               Presence.voice_listener_meta()
             ) do
          {:ok, _ref} ->
            assign(socket, :voice_listening_space_id, space_id)

          {:error, {:already_tracked, _pid, _topic, _key}} ->
            assign(socket, :voice_listening_space_id, space_id)

          {:error, reason} ->
            Logger.warning("[VoiceLive.Listening] track failed: #{error_tag(reason)}")
            socket
        end

      true ->
        socket
    end
  end

  defp untrack(socket) do
    case socket.assigns[:voice_listening_space_id] do
      nil ->
        socket

      space_id ->
        case Presence.safe_untrack_in_space(self(), space_id, user_id(socket)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[VoiceLive.Listening] untrack failed: #{error_tag(reason)}")
        end

        assign(socket, :voice_listening_space_id, nil)
    end
  end

  defp user_id(socket) do
    case socket.assigns[:current_user_record] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp error_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_tag({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_tag(%{__struct__: module}), do: inspect(module)
  defp error_tag(_reason), do: "error"
end
