defmodule PlatformWeb.MeetingPresenceEvents do
  @moduledoc """
  Server half of the in-call toasts and the full-load guard (task 01a1e82a
  stage 2). Kept next to `PlatformWeb.MeetingBarPresence`, out of
  `PlatformWeb.ShellLive`, so that file does not grow again.

    * `push_joined/2`, `push_left/2`, `push_ended/3` send the
      `meeting_presence:toast` push_event that `assets/js/meeting_presence.js`
      renders ("You joined <name>", "You left <name>" with who is still in
      the room, "<host> ended <name>").
    * `track/1` resolves the live `%Meeting{}` behind the shell's active
      meeting space: its id keys the client's once-per-meeting "still in"
      toast, its project is where `Meetings.end_meeting/1` broadcasts
      `{:meeting_ended, meeting}`, and its host decides whether the phone
      Leave sheet offers "End for everyone".
    * `subscribe/1` / `release/1` / `owns_update?/1` take that project
      topic with the same deferred, checked subscription as the bar's
      presence topic (see `PlatformWeb.MeetingBarPresence`): CalendarLive
      and MeetingLive subscribe to the same topic themselves, and a second
      subscription would hand them every lifecycle event twice.
    * `auth_route_patterns_json/0` is the `live_session :authenticated` route
      list, read from the router once at compile time. The client guard
      treats a `data-phx-link="redirect"` outside it as a full page load.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias PlatformWeb.MeetingBarPresence

  @pubsub Platform.PubSub
  @event "meeting_presence:toast"

  @auth_routes for %{
                     path: path,
                     metadata: %{phoenix_live_view: {_, _, _, %{name: :authenticated}}}
                   } <-
                     PlatformWeb.Router.__routes__(),
                   uniq: true,
                   do: path
  @auth_routes_json Jason.encode!(@auth_routes)

  @doc "The `live_session :authenticated` route paths, e.g. `/chat/:space_slug`."
  @spec auth_route_patterns() :: [String.t()]
  def auth_route_patterns, do: @auth_routes

  @doc "`auth_route_patterns/0` as the JSON `#meeting-presence` carries."
  @spec auth_route_patterns_json() :: String.t()
  def auth_route_patterns_json, do: @auth_routes_json

  @doc "Default assigns for a shell with no tracked meeting."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    socket
    |> assign(:meeting_id, nil)
    |> assign(:meeting_project_id, nil)
    |> assign(:meeting_can_end, false)
  end

  @doc """
  Resolve the live meeting behind `:meeting_space_id` and assign its id,
  project and whether the current user hosts it. No live meeting (an ad-hoc
  room, a malformed id) leaves all three empty.
  """
  @spec track(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def track(socket) do
    space_id = socket.assigns[:meeting_space_id]

    case Platform.UUID.valid?(space_id) && Meetings.get_live_meeting_for_space(space_id) do
      %Meeting{} = meeting ->
        socket
        |> assign(:meeting_id, meeting.id)
        |> assign(:meeting_project_id, meeting.project_id)
        |> assign(:meeting_can_end, host?(meeting, socket.assigns[:current_user_id]))
        |> assign_meeting_started_at(meeting)

      _ ->
        reset(socket)
    end
  end

  # The bar's clock, the lock-screen card and the tab title count the
  # MEETING's elapsed time (task 01a1e82a remediation, finding 3), not this
  # viewer's join: `Platform.Meetings.State` stamps `started_at` on every
  # join broadcast, including the restore when the viewer walks out of the
  # call room, so the join time restarted the clock at 0:00. An ad-hoc room
  # with no started meeting keeps the join time.
  defp assign_meeting_started_at(socket, %Meeting{started_at: %DateTime{} = started_at}),
    do: assign(socket, :meeting_started_at, started_at)

  defp assign_meeting_started_at(socket, _meeting), do: socket

  @doc "Subscribe to the tracked meeting's project topic unless the process already is."
  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    socket = release(socket)

    case socket.assigns[:meeting_project_id] do
      project_id when is_binary(project_id) ->
        topic = Meetings.project_meetings_topic(project_id)
        owned? = topic not in Registry.keys(@pubsub, self())
        if owned?, do: Meetings.subscribe_to_project_meetings(project_id)
        assign(socket, :meeting_project_sub, {project_id, owned?})

      _ ->
        socket
    end
  end

  @doc "Drop the shell's own project subscription, if it holds one."
  @spec release(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def release(socket) do
    case socket.assigns[:meeting_project_sub] do
      {project_id, true} ->
        Phoenix.PubSub.unsubscribe(@pubsub, Meetings.project_meetings_topic(project_id))

      _ ->
        :ok
    end

    assign(socket, :meeting_project_sub, nil)
  end

  @doc "True when the shell itself took the project topic (so the host LV expects nothing)."
  @spec owns_update?(Phoenix.LiveView.Socket.t()) :: boolean()
  def owns_update?(socket), do: match?({_, true}, socket.assigns[:meeting_project_sub])

  @doc "True when `meeting` is the one this shell is in."
  @spec current_meeting?(Phoenix.LiveView.Socket.t(), Meeting.t()) :: boolean()
  def current_meeting?(socket, %Meeting{id: id}),
    do:
      socket.assigns[:meeting_active] == true and is_binary(id) and
        id == socket.assigns[:meeting_id]

  @doc "\"You joined <name>\", with the mic / camera state the call starts with."
  @spec push_joined(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push_joined(socket, media) do
    push_event(socket, @event, %{
      kind: "joined",
      meeting_id: socket.assigns[:meeting_id] || socket.assigns[:meeting_space_id],
      name: name(socket),
      mic: Map.get(media, :mic, true),
      camera: Map.get(media, :camera, false)
    })
  end

  @doc """
  The "You left <name>" payload: who is still in the room, read AFTER the
  leave was stamped so the leaver is not counted, and where Rejoin goes.
  Must run before the shell resets its meeting assigns.
  """
  @spec left_payload(Phoenix.LiveView.Socket.t()) :: map()
  def left_payload(socket) do
    uid = socket.assigns[:current_user_id]
    space_id = socket.assigns[:meeting_space_id]

    names =
      if Platform.UUID.valid?(space_id) do
        space_id
        |> Meetings.active_participants_for_space()
        |> Enum.reject(&(is_binary(uid) and &1.user_id == uid))
        |> Enum.map(&MeetingBarPresence.display_name/1)
      else
        []
      end

    %{
      kind: "left",
      meeting_id: socket.assigns[:meeting_id] || space_id,
      name: name(socket),
      names: names,
      count: length(names),
      return_path:
        PlatformWeb.MeetingBarLive.return_to_call_path(
          socket.assigns[:meeting_slug],
          socket.assigns[:meeting_space_slug],
          space_id
        )
    }
  end

  @doc "Push a `left_payload/1` toast."
  @spec push_left(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push_left(socket, payload), do: push_event(socket, @event, payload)

  @doc "\"<host> ended <name>\"."
  @spec push_ended(Phoenix.LiveView.Socket.t(), Meeting.t()) :: Phoenix.LiveView.Socket.t()
  def push_ended(socket, %Meeting{} = meeting) do
    push_event(socket, @event, %{
      kind: "ended",
      meeting_id: meeting.id,
      name: name(socket),
      host: host_name(meeting)
    })
  end

  @doc """
  "End for everyone" from the phone Leave sheet. `:meeting_can_end` only
  decides whether the sheet offers it; it was computed when the shell last
  tracked the meeting and can be stale, so the host check runs again on the
  meeting fetched here before anything ends.
  """
  @spec end_for_everyone(Phoenix.LiveView.Socket.t()) :: {:ok, %Meeting{}} | :refused
  def end_for_everyone(socket) do
    uid = socket.assigns[:current_user_id]
    space_id = socket.assigns[:meeting_space_id]

    with true <- socket.assigns[:meeting_can_end] == true,
         true <- Platform.UUID.valid?(space_id),
         %Meeting{} = meeting <- Meetings.get_live_meeting_for_space(space_id),
         true <- host?(meeting, uid),
         {:ok, ended} <- Meetings.end_meeting(meeting) do
      {:ok, ended}
    else
      _ -> :refused
    end
  end

  defp name(socket), do: socket.assigns[:meeting_space_name] || "Meeting"

  # The host is a `chat_participants` row; for a user participant its
  # `participant_id` is the user id.
  defp host?(%Meeting{host_participant_id: host_id}, uid)
       when is_binary(host_id) and is_binary(uid) do
    case host_participant(host_id) do
      %{participant_type: "user", participant_id: ^uid} -> true
      _ -> false
    end
  end

  defp host?(_meeting, _uid), do: false

  defp host_name(%Meeting{host_participant_id: host_id}) when is_binary(host_id) do
    case host_participant(host_id) do
      %{display_name: name} when is_binary(name) and name != "" ->
        name

      %{participant_type: "user", participant_id: user_id} ->
        case Accounts.get_user(user_id) do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> "The host"
        end

      _ ->
        "The host"
    end
  end

  defp host_name(_meeting), do: "The host"

  defp host_participant(host_id) do
    if Platform.UUID.valid?(host_id), do: Chat.get_participant(host_id)
  end
end
