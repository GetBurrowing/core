defmodule PlatformWeb.ChatLive.MeetingHooks do
  @moduledoc """
  Lifecycle hook for the Meeting feature in `PlatformWeb.ChatLive`.

  See ADR 0035. This module owns the LIVE meeting path that uses
  `MeetingClient` (client-side LiveKit) + `MeetingState` broadcasts.

  ## Historical context

  ChatLive briefly hosted two parallel meeting UIs — `@in_meeting` (this
  one, the live path) and `@meeting_active` (an earlier DB-participant
  model that was never fully wired up and whose broadcast path had no
  real-world trigger). The dead path is gone — this module is the
  single source of truth.

  ## Assigns owned

    * `:in_meeting` — user is actively in the LiveKit room
    * `:meetings_enabled` — feature flag from `Platform.Meetings.enabled?/0`
    * `:mic_enabled`, `:camera_enabled`, `:screen_share_enabled` — local
      media state mirrored from the MeetingClient JS hook
    * `:meeting_counts` — sidebar badges (space_id → participant count)

  ## Events

    * `"meeting_join"` — ensure DB room, generate token, push_event to
      `MeetingClient` JS hook, broadcast via `MeetingState`
    * `"meeting_leave"` — broadcast via `MeetingState`, reset media
      state, push_event `"leave-meeting"` to the JS hook
    * `"meeting_left"` — from `meeting_client.js` on
      `RoomEvent.Disconnected` (same effect as `meeting_leave` but
      without the push_event)
    * `"meeting_toggle_mic"` / `"meeting_toggle_camera"` /
      `"meeting_toggle_screen_share"` — flip local state and push to JS

  ## Info handled

    * `{:meeting_presence_update, %{space_id, active, count}}` — update
      sidebar count map
    * `{:meeting_presence_summary, %{space_id}}` — refresh full
      `meeting_counts` from DB

  ## Usage

      # In ChatLive.mount/3, when connected?(socket):
      socket = PlatformWeb.ChatLive.MeetingHooks.attach(socket, all_space_ids)

      # In ChatLive.terminate/2:
      PlatformWeb.ChatLive.MeetingHooks.on_terminate(socket)
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, connected?: 1]

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.State, as: MeetingState

  @doc """
  Attach Meeting handlers. Call from `ChatLive.mount/3`.

  If `space_ids` is non-empty, subscribes to per-space presence topics
  for the sidebar badges and eagerly loads the current counts.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), [binary()]) :: Phoenix.LiveView.Socket.t()
  def attach(socket, space_ids \\ []) do
    socket =
      socket
      |> assign(:in_meeting, false)
      |> assign(:meetings_enabled, Meetings.enabled?())
      |> assign(:mic_enabled, true)
      |> assign(:camera_enabled, false)
      |> assign(:screen_share_enabled, false)
      |> assign(:meeting_counts, %{})
      |> attach_hook(:meeting_events, :handle_event, &handle_event/3)
      |> attach_hook(:meeting_info, :handle_info, &handle_info/2)

    if connected?(socket) and space_ids != [] do
      Enum.each(space_ids, &MeetingsPubSub.subscribe_presence/1)
      MeetingsPubSub.subscribe_presence_summary()

      assign(socket, :meeting_counts, Meetings.active_meeting_counts(space_ids))
    else
      socket
    end
  end

  @doc """
  Clean up on LV termination — broadcast "left" so the mini-bar
  doesn't ghost after a tab close while in a meeting.
  """
  @spec on_terminate(Phoenix.LiveView.Socket.t()) :: :ok
  def on_terminate(socket) do
    if socket.assigns[:in_meeting] and socket.assigns[:user_id] do
      MeetingState.broadcast_left(socket.assigns.user_id)
    end

    :ok
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("meeting_join", _params, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant,
         {:ok, room} <- Meetings.ensure_room(space.id),
         identity = "user:#{socket.assigns.user_id}",
         name = participant.display_name || "User",
         {:ok, token} <- Meetings.generate_token(room, %{identity: identity, name: name}) do
      socket =
        socket
        |> assign(:in_meeting, true)
        |> push_event("join-meeting", %{
          token: token,
          url: Meetings.livekit_url(),
          room_name: room.livekit_room_name,
          space_slug: space.slug
        })

      MeetingState.broadcast_joined(socket.assigns.user_id, space.id, space.name)

      {:halt, socket}
    else
      {:error, reason} ->
        Logger.warning("[ChatLive] meeting_join failed: #{inspect(reason)}")
        {:halt, socket}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_event("meeting_leave", _params, socket) do
    MeetingState.broadcast_left(socket.assigns.user_id)

    {:halt,
     socket
     |> reset_meeting_state()
     |> push_event("leave-meeting", %{})}
  end

  # Fired from meeting_client.js on RoomEvent.Disconnected (including
  # client-initiated leaves that already happened).
  defp handle_event("meeting_left", _params, socket) do
    MeetingState.broadcast_left(socket.assigns.user_id)
    {:halt, reset_meeting_state(socket)}
  end

  defp handle_event("meeting_toggle_mic", _params, socket) do
    {:halt,
     socket
     |> assign(:mic_enabled, !socket.assigns.mic_enabled)
     |> push_event("toggle-mic", %{})}
  end

  defp handle_event("meeting_toggle_camera", _params, socket) do
    {:halt,
     socket
     |> assign(:camera_enabled, !socket.assigns.camera_enabled)
     |> push_event("toggle-camera", %{})}
  end

  defp handle_event("meeting_toggle_screen_share", _params, socket) do
    {:halt,
     socket
     |> assign(:screen_share_enabled, !socket.assigns.screen_share_enabled)
     |> push_event("toggle-screen-share", %{})}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info(
         {:meeting_presence_update, %{space_id: space_id, active: active, count: count}},
         socket
       ) do
    counts =
      if active do
        Map.put(socket.assigns.meeting_counts, space_id, count)
      else
        Map.delete(socket.assigns.meeting_counts, space_id)
      end

    {:halt, assign(socket, :meeting_counts, counts)}
  end

  defp handle_info({:meeting_presence_summary, %{space_id: _space_id}}, socket) do
    space_ids = socket.assigns[:spaces] |> List.wrap() |> Enum.map(& &1.id)
    counts = Meetings.active_meeting_counts(space_ids)
    {:halt, assign(socket, :meeting_counts, counts)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Internals ────────────────────────────────────────────────────────

  defp reset_meeting_state(socket) do
    socket
    |> assign(:in_meeting, false)
    |> assign(:mic_enabled, true)
    |> assign(:camera_enabled, false)
    |> assign(:screen_share_enabled, false)
  end
end
