defmodule PlatformWeb.MeetingBarPresence do
  @moduledoc """
  Shell-side state for the in-call top bar (`PlatformWeb.MeetingBarLive`).

  Task 01a1e82a stage 1. Two jobs, kept out of `PlatformWeb.ShellLive` so
  that file does not grow again:

    * `in_call_room?/2` is the ONE definition of "this page is the call
      room". The bar hides only there (`/meetings/<meeting_slug>`); every
      other authenticated page shows it, the meeting's own chat included.
    * The roster behind the bar's avatars and "<N> here": read from the
      meeting participant rows (`Meetings.active_participants_for_space/1`)
      and refreshed on the existing per-space presence topic
      (`MeetingsPubSub.presence_topic/1`). No new transport.

  ## Why the subscription is deferred and checked

  ChatLive's `MeetingHooks.attach/2` and MeetingLive already subscribe this
  same process to presence topics. Phoenix.PubSub delivers once per
  subscription, so subscribing again would hand those hosts every update
  twice. The shell's `on_mount` runs before the host's `mount/3`, so it
  cannot know yet. `schedule_subscribe/1` therefore sends itself a message
  that runs after mount; `subscribe/1` then subscribes only when the process
  is not already registered on the topic, and records whether it owns the
  subscription. `owns_update?/2` tells the shell whether to halt an update
  (shell-owned: no host handler expects it) or let it continue to the host.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @max_faces 4
  @pubsub Platform.PubSub

  @doc "True only on the call room, `/meetings/<meeting_slug>`."
  @spec in_call_room?(String.t() | nil, String.t() | nil) :: boolean()
  def in_call_room?(path, meeting_slug) when is_binary(path) and is_binary(meeting_slug),
    do: path == "/meetings/#{meeting_slug}"

  def in_call_room?(_path, _meeting_slug), do: false

  @doc "Default assigns for a shell with no active meeting."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    socket
    |> assign(:meeting_roster, [])
    |> assign(:meeting_here_count, 0)
  end

  @doc """
  Reload the roster for the shell's active meeting space. A space id that is
  not a UUID (or no space) yields an empty roster rather than a cast error.
  """
  @spec assign_roster(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_roster(socket) do
    space_id = socket.assigns[:meeting_space_id]

    participants =
      if Platform.UUID.valid?(space_id),
        do: Meetings.active_participants_for_space(space_id),
        else: []

    socket
    |> assign(:meeting_roster, participants |> Enum.take(@max_faces) |> Enum.map(&face/1))
    |> assign(:meeting_here_count, length(participants))
  end

  @doc """
  Queue `subscribe/1` to run after the host LiveView has mounted. Skipped in
  MeetingLive: that is the call room, where the bar never shows, and
  MeetingLive takes the presence topic itself at mount and later
  (`enter_guest_topics/2`), on the assumption that it is the topic's only
  subscriber in its process.
  """
  @spec schedule_subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def schedule_subscribe(socket) do
    if Phoenix.LiveView.connected?(socket) and socket.view != PlatformWeb.MeetingLive and
         is_binary(socket.assigns[:meeting_space_id]) do
      send(self(), :meeting_bar_presence_subscribe)
    end

    socket
  end

  @doc """
  Subscribe to the active meeting space's presence topic unless the process
  already is, and record `{space_id, owned?}` in `:meeting_presence_sub`.
  """
  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    socket = release(socket)

    case socket.assigns[:meeting_space_id] do
      space_id when is_binary(space_id) ->
        topic = MeetingsPubSub.presence_topic(space_id)
        owned? = topic not in Registry.keys(@pubsub, self())
        if owned?, do: MeetingsPubSub.subscribe_presence(space_id)
        assign(socket, :meeting_presence_sub, {space_id, owned?})

      _ ->
        socket
    end
  end

  @doc "Drop the shell's own presence subscription, if it holds one."
  @spec release(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def release(socket) do
    case socket.assigns[:meeting_presence_sub] do
      {space_id, true} -> MeetingsPubSub.unsubscribe_presence(space_id)
      _ -> :ok
    end

    assign(socket, :meeting_presence_sub, nil)
  end

  @doc "True when the shell itself subscribed to `space_id`'s presence topic."
  @spec owns_update?(Phoenix.LiveView.Socket.t(), String.t()) :: boolean()
  def owns_update?(socket, space_id),
    do: socket.assigns[:meeting_presence_sub] == {space_id, true}

  defp face(participant) do
    name = display_name(participant)
    %{id: participant.id, name: name, initials: initials(name)}
  end

  defp display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp display_name(%{agent: %{name: name}}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
