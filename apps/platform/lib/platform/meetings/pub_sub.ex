defmodule Platform.Meetings.PubSub do
  @moduledoc """
  PubSub topic helpers for the Meetings domain.

  ## Topics

    * `"meetings:user:{user_id}"` — per-user meeting lifecycle events
      (join, leave, media state changes, participant count updates).
    * `"meetings:room:{room_id}"` — per-room events (participant join/leave,
      room started/finished).

  ## Events

  | Event                                  | Payload                                          |
  |----------------------------------------|--------------------------------------------------|
  | `{:meeting_joined, meeting_info}`      | `%{space_id, space_slug, space_name, room_id, …}`|
  | `{:meeting_left, info}`                | `%{room_id, user_id}`                            |
  | `{:meeting_participant_update, info}`   | `%{room_id, participant_count}`                  |
  | `{:meeting_media_state, info}`          | `%{mic_enabled, camera_enabled}`                 |

  ## Usage

      # Subscribe to a user's meeting events (in ShellLive mount)
      Platform.Meetings.PubSub.subscribe_user(user_id)

      # Broadcast that a user joined a meeting
      Platform.Meetings.PubSub.broadcast_user(user_id, {:meeting_joined, info})
  """

  @pubsub Platform.PubSub

  # ── Topics ──────────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a user's meeting events."
  @spec user_topic(binary()) :: String.t()
  def user_topic(user_id), do: "meetings:user:#{user_id}"

  @doc "Returns the PubSub topic for a specific meeting room."
  @spec room_topic(binary()) :: String.t()
  def room_topic(room_id), do: "meetings:room:#{room_id}"

  # ── Subscribe ────────────────────────────────────────────────────────────────

  @doc "Subscribe the calling process to a user's meeting events."
  @spec subscribe_user(binary()) :: :ok | {:error, term()}
  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, user_topic(user_id))
  end

  @doc "Subscribe the calling process to a room's meeting events."
  @spec subscribe_room(binary()) :: :ok | {:error, term()}
  def subscribe_room(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, room_topic(room_id))
  end

  @doc "Unsubscribe from a user's meeting events."
  @spec unsubscribe_user(binary()) :: :ok
  def unsubscribe_user(user_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, user_topic(user_id))
  end

  @doc "Unsubscribe from a room's meeting events."
  @spec unsubscribe_room(binary()) :: :ok
  def unsubscribe_room(room_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, room_topic(room_id))
  end

  # ── Broadcast ────────────────────────────────────────────────────────────────

  @doc "Broadcast an event to all subscribers of a user's meeting topic."
  @spec broadcast_user(binary(), term()) :: :ok
  def broadcast_user(user_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), event)
  end

  @doc "Broadcast an event to all subscribers of a room's meeting topic."
  @spec broadcast_room(binary(), term()) :: :ok
  def broadcast_room(room_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, room_topic(room_id), event)
  end

  @doc "Broadcast from a specific pid (sender won't receive the event)."
  @spec broadcast_user_from(binary(), pid(), term()) :: :ok
  def broadcast_user_from(user_id, from_pid, event) do
    Phoenix.PubSub.broadcast_from(@pubsub, from_pid, user_topic(user_id), event)
  end
end
