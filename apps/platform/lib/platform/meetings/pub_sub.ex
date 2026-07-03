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
    * `"meeting:finished"` — canonical broadcast surface for transcript-
      finalisation, consumed by the M6 `Platform.Responsibilities.Router`
      to fire the `meetings.summarize` responsibility. Phoenix.PubSub
      doesn't support wildcards, so we publish on BOTH the canonical
      topic AND `"meeting:finished:{room_id}"` (for per-room LiveView
      subscribers). The Router subscribes to the canonical topic only.
    * `"meeting:transcript_chunk"` — canonical broadcast surface for
      individual transcript segment appends, consumed by the Meeting
      Producer's classifier (task 019f2452). Same dual-topic pattern
      as `meeting:finished`: publish on BOTH the canonical topic AND
      `"meeting:transcript_chunk:{room_id}"` so the classifier can
      subscribe once while per-room consumers stay narrow.

  ## Events

  | Topic                                     | Event                                    | Payload                                                                     |
  |-------------------------------------------|------------------------------------------|-----------------------------------------------------------------------------|
  | `meetings:room:{room_id}`                 | `{:participant_joined, p}`               | `%Meetings.Participant{}`                                                   |
  | `meetings:room:{room_id}`                 | `{:participant_left, p}`                 | `%Meetings.Participant{}`                                                   |
  | `meetings:room:{room_id}`                 | `{:room_activated, room}`                | `%Meetings.Room{}`                                                          |
  | `meetings:room:{room_id}`                 | `{:room_finished, room}`                 | `%Meetings.Room{}`                                                          |
  | `meetings:presence:{space_id}`            | `{:meeting_presence_update, data}`       | `%{space_id, active, count}`                                                |
  | `meetings:presence_summary`               | `{:meeting_presence_summary, data}`      | `%{space_id: id}`                                                           |
  | `meeting:finished`                        | `{:meeting_finished, payload}`           | `%{transcript_id: id, room_id: id, space_id: id}`                           |
  | `meeting:finished:{room_id}`              | `{:meeting_finished, payload}`           | `%{transcript_id: id, room_id: id, space_id: id}`                           |
  | `meeting:transcript_chunk`                | `{:transcript_chunk, payload}`           | `%{room_id: id, transcript_id: id, segment: map(), meeting_id: id \\| nil}` |
  | `meeting:transcript_chunk:{room_id}`      | `{:transcript_chunk, payload}`           | `%{room_id: id, transcript_id: id, segment: map(), meeting_id: id \\| nil}` |
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

  @doc """
  Returns the canonical "any meeting finished" topic. Subscribed to by
  the M6 `Platform.Responsibilities.Router` because Phoenix.PubSub has
  no wildcard match — broadcasts to `meeting_finished_topic/1` are
  mirrored to this topic so a single subscription suffices.
  """
  @spec meeting_finished_topic() :: String.t()
  def meeting_finished_topic, do: "meeting:finished"

  @doc """
  Returns the per-room "meeting finished" topic. Used by LiveView
  surfaces that already know the room they care about (so they
  don't have to filter every cross-org broadcast).
  """
  @spec meeting_finished_topic(binary()) :: String.t()
  def meeting_finished_topic(room_id) when is_binary(room_id),
    do: "meeting:finished:#{room_id}"

  @doc """
  Returns the canonical "any transcript chunk" topic. Subscribed to by
  the Meeting Producer's classifier so a single subscription catches
  every appended segment across every active room (Phoenix.PubSub has
  no wildcard match). Broadcasts to `transcript_chunk_topic/1` are
  mirrored to this topic.
  """
  @spec transcript_chunk_topic() :: String.t()
  def transcript_chunk_topic, do: "meeting:transcript_chunk"

  @doc """
  Returns the per-room transcript-chunk topic. Used by consumers that
  already know the room they care about and don't want to filter every
  cross-org broadcast.
  """
  @spec transcript_chunk_topic(binary()) :: String.t()
  def transcript_chunk_topic(room_id) when is_binary(room_id),
    do: "meeting:transcript_chunk:#{room_id}"

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

  @doc """
  Subscribe to the canonical `meeting:finished` topic. The M6
  responsibility router uses this to fire `meetings.summarize`
  without needing one subscription per room.
  """
  @spec subscribe_meeting_finished() :: :ok | {:error, term()}
  def subscribe_meeting_finished do
    Phoenix.PubSub.subscribe(@pubsub, meeting_finished_topic())
  end

  @doc "Subscribe to a specific room's `meeting:finished` topic."
  @spec subscribe_meeting_finished(binary()) :: :ok | {:error, term()}
  def subscribe_meeting_finished(room_id) when is_binary(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, meeting_finished_topic(room_id))
  end

  @doc """
  Subscribe to the canonical `meeting:transcript_chunk` topic. The
  Meeting Producer's classifier uses this to react to every appended
  transcript segment without needing one subscription per room.
  """
  @spec subscribe_transcript_chunk() :: :ok | {:error, term()}
  def subscribe_transcript_chunk do
    Phoenix.PubSub.subscribe(@pubsub, transcript_chunk_topic())
  end

  @doc "Subscribe to a specific room's `meeting:transcript_chunk` topic."
  @spec subscribe_transcript_chunk(binary()) :: :ok | {:error, term()}
  def subscribe_transcript_chunk(room_id) when is_binary(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, transcript_chunk_topic(room_id))
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

  @doc "Unsubscribe from the canonical `meeting:finished` topic."
  @spec unsubscribe_meeting_finished() :: :ok
  def unsubscribe_meeting_finished do
    Phoenix.PubSub.unsubscribe(@pubsub, meeting_finished_topic())
  end

  @doc "Unsubscribe from a specific room's `meeting:finished` topic."
  @spec unsubscribe_meeting_finished(binary()) :: :ok
  def unsubscribe_meeting_finished(room_id) when is_binary(room_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, meeting_finished_topic(room_id))
  end

  @doc "Unsubscribe from the canonical `meeting:transcript_chunk` topic."
  @spec unsubscribe_transcript_chunk() :: :ok
  def unsubscribe_transcript_chunk do
    Phoenix.PubSub.unsubscribe(@pubsub, transcript_chunk_topic())
  end

  @doc "Unsubscribe from a specific room's `meeting:transcript_chunk` topic."
  @spec unsubscribe_transcript_chunk(binary()) :: :ok
  def unsubscribe_transcript_chunk(room_id) when is_binary(room_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, transcript_chunk_topic(room_id))
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

  @doc """
  Broadcast a `:meeting_finished` event on BOTH the canonical
  `meeting:finished` topic AND the per-room
  `meeting:finished:{room_id}` topic.

  Publishing on the canonical topic lets the M6 responsibility router
  fire `meetings.summarize` with a single Phoenix.PubSub subscription
  (PubSub has no wildcard match); publishing on the per-room topic
  keeps room-scoped LiveView subscribers in sync.

  `payload` should carry at least `:transcript_id`, `:room_id`, and
  `:space_id` (matches the
  `Platform.Responsibilities.ContextProviders` contract for the
  `:meeting_transcript` slot).
  """
  @spec broadcast_meeting_finished(binary(), map()) :: :ok
  def broadcast_meeting_finished(room_id, payload)
      when is_binary(room_id) and is_map(payload) do
    event = {:meeting_finished, payload}
    Phoenix.PubSub.broadcast(@pubsub, meeting_finished_topic(), event)
    Phoenix.PubSub.broadcast(@pubsub, meeting_finished_topic(room_id), event)
    :ok
  end

  @doc """
  Broadcast a `:transcript_chunk` event on BOTH the canonical
  `meeting:transcript_chunk` topic AND the per-room
  `meeting:transcript_chunk:{room_id}` topic.

  Publishing on the canonical topic lets the Meeting Producer's
  classifier react to every appended segment with a single
  Phoenix.PubSub subscription (PubSub has no wildcard match);
  publishing on the per-room topic keeps room-scoped consumers
  from having to filter cross-org traffic.

  `payload` should carry at least `:room_id`, `:transcript_id`,
  `:segment` (the segment map that was appended), and `:meeting_id`
  (which may be `nil` — the room can produce chunks before a
  `Meeting` row is linked, and the classifier is responsible for
  enrichment).
  """
  @spec broadcast_transcript_chunk(binary(), map()) :: :ok
  def broadcast_transcript_chunk(room_id, payload)
      when is_binary(room_id) and is_map(payload) do
    event = {:transcript_chunk, payload}
    Phoenix.PubSub.broadcast(@pubsub, transcript_chunk_topic(), event)
    Phoenix.PubSub.broadcast(@pubsub, transcript_chunk_topic(room_id), event)
    :ok
  end
end
