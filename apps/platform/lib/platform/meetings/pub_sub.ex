defmodule Platform.Meetings.PubSub do
  @moduledoc """
  PubSub topic helpers for the Meetings domain.

  ## Topics

    * `"meetings:user:{user_id}"` — per-user meeting lifecycle events
      (join, leave, media state changes, participant count updates).
    * `"meetings:room:{room_id}"` — per-room event stream (participant join/leave,
      room status changes). Used by the full meeting panel in ChatLive.
    * `"meetings:presence:{space_id}"` — lightweight per-space presence topic.
      Carries only participant counts for sidebar indicators.
    * `"meetings:presence_summary"` — global summary topic for sidebar.
      Broadcasts when any space's meeting presence changes so the sidebar
      can refresh counts without subscribing to every space individually.

  ## Events

  | Topic                              | Event                                    | Payload                                |
  |------------------------------------|------------------------------------------|----------------------------------------|
  | `meetings:room:{room_id}`          | `{:participant_joined, p}`               | `%Meetings.Participant{}`              |
  | `meetings:room:{room_id}`          | `{:participant_left, p}`                 | `%Meetings.Participant{}`              |
  | `meetings:room:{room_id}`          | `{:room_activated, room}`                | `%Meetings.Room{}`                     |
  | `meetings:room:{room_id}`          | `{:room_finished, room}`                 | `%Meetings.Room{}`                     |
  | `meetings:presence:{space_id}`     | `{:meeting_presence_update, data}`       | `%{space_id, active, count}`           |
  | `meetings:presence_summary`        | `{:meeting_presence_summary, data}`      | `%{space_id: id}`                      |
  """

  @pubsub Platform.PubSub

  # ── Topics ──────────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a user's meeting events."
  @spec user_topic(binary()) :: String.t()
  def user_topic(user_id), do: "meetings:user:#{user_id}"

  @doc "Returns the PubSub topic for a specific meeting room."
  @spec room_topic(binary()) :: String.t()
  def room_topic(room_id), do: "meetings:room:#{room_id}"

  @doc "Returns the lightweight presence topic for a space."
  @spec presence_topic(binary()) :: String.t()
  def presence_topic(space_id), do: "meetings:presence:#{space_id}"

  @doc "Returns the global presence summary topic for sidebar updates."
  @spec presence_summary_topic() :: String.t()
  def presence_summary_topic, do: "meetings:presence_summary"

  # ── Subscribe ────────────────────────────────────────────────────────────────

  @doc "Subscribe the calling process to a user's meeting events."
  @spec subscribe_user(binary()) :: :ok | {:error, term()}
  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, user_topic(user_id))
  end

  @doc "Subscribe to all events for a specific meeting room."
  @spec subscribe_room(binary()) :: :ok | {:error, term()}
  def subscribe_room(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, room_topic(room_id))
  end

  @doc "Subscribe to lightweight meeting presence for a space."
  @spec subscribe_presence(binary()) :: :ok | {:error, term()}
  def subscribe_presence(space_id) do
    Phoenix.PubSub.subscribe(@pubsub, presence_topic(space_id))
  end

  @doc "Subscribe to the global presence summary topic (sidebar)."
  @spec subscribe_presence_summary() :: :ok | {:error, term()}
  def subscribe_presence_summary do
    Phoenix.PubSub.subscribe(@pubsub, presence_summary_topic())
  end

  @doc "Unsubscribe from a user's meeting events."
  @spec unsubscribe_user(binary()) :: :ok
  def unsubscribe_user(user_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, user_topic(user_id))
  end

  @doc "Unsubscribe from a meeting room topic."
  @spec unsubscribe_room(binary()) :: :ok
  def unsubscribe_room(room_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, room_topic(room_id))
  end

  @doc "Unsubscribe from a space's meeting presence topic."
  @spec unsubscribe_presence(binary()) :: :ok
  def unsubscribe_presence(space_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, presence_topic(space_id))
  end

  @doc "Unsubscribe from the global presence summary topic."
  @spec unsubscribe_presence_summary() :: :ok
  def unsubscribe_presence_summary do
    Phoenix.PubSub.unsubscribe(@pubsub, presence_summary_topic())
  end

  # ── Broadcast ────────────────────────────────────────────────────────────────

  @doc "Broadcast an event to all subscribers of a user's meeting topic."
  @spec broadcast_user(binary(), term()) :: :ok
  def broadcast_user(user_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), event)
  end

  @doc "Broadcast from a specific pid (sender won't receive the event)."
  @spec broadcast_user_from(binary(), pid(), term()) :: :ok
  def broadcast_user_from(user_id, from_pid, event) do
    Phoenix.PubSub.broadcast_from(@pubsub, from_pid, user_topic(user_id), event)
  end

  @doc "Broadcast an event to all subscribers of a meeting room."
  @spec broadcast_room(binary(), term()) :: :ok
  def broadcast_room(room_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, room_topic(room_id), event)
  end

  @doc "Broadcast a lightweight presence update for a space."
  @spec broadcast_presence(binary(), term()) :: :ok
  def broadcast_presence(space_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, presence_topic(space_id), event)
  end

  @doc "Broadcast a presence summary change (sidebar refresh)."
  @spec broadcast_presence_summary(binary()) :: :ok
  def broadcast_presence_summary(space_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      presence_summary_topic(),
      {:meeting_presence_summary, %{space_id: space_id}}
    )
  end
end
