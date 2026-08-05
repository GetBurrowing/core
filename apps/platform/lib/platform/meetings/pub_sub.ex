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
    * `"meeting:intent_enqueued"` — the dispatcher's drain wake-up.
      Fires when a meeting has work to send: a new row was inserted,
      or the serial cursor was released (task 019f70b8 stage 3).
      Dedupe hits don't re-notify — that would spam the dispatcher for
      no-op writes.
    * `"meeting:{meeting_id}:intents"` — per-meeting intent-queue event
      stream (task 019f70b8 stage 2). Every state transition on a
      `Platform.Meetings.IntentQueue.Server` row publishes here so the
      live-tuning UI can render the queue without polling. Eight event
      kinds cover the nine row statuses (`:cancelled` and
      `:cancelled_late` share `:intent_cancelled` — the payload's
      `:status` field disambiguates).
    * `"meeting:{meeting_id}"` — the per-meeting SHELL topic (task
      019fbaac stage 1). Distinct from `"meeting:{meeting_id}:intents"`
      above, which carries queue-row transitions: this one carries
      state changes to the meeting itself. `PlatformWeb.MeetingLive`
      has subscribed to this exact string since the intents panel
      landed; before task 019fbaac nothing published on it. The mute
      event below is its first publisher, which is why muting reaches
      every connected client with no new subscription and no rejoin.

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
  | `meeting:intent_enqueued`                 | `{:intent_enqueued, payload}`            | `%{meeting_id: id, room_id: id \\| nil}`                                    |
  | `meeting:{meeting_id}:intents`            | `{:intent_classified, row}`              | intent-queue row map (see `IntentQueue.Server`)                             |
  | `meeting:{meeting_id}:intents`            | `{:intent_dispatched, row}`              | intent-queue row map                                                        |
  | `meeting:{meeting_id}:intents`            | `{:intent_acked, row}`                   | intent-queue row map                                                        |
  | `meeting:{meeting_id}:intents`            | `{:intent_completed, row}`               | intent-queue row map                                                        |
  | `meeting:{meeting_id}:intents`            | `{:intent_cancelled, row}`               | intent-queue row map (`:cancelled` OR `:cancelled_late`)                    |
  | `meeting:{meeting_id}:intents`            | `{:intent_timed_out, row}`               | intent-queue row map                                                        |
  | `meeting:{meeting_id}:intents`            | `{:intent_dispatch_failed, row}`         | intent-queue row map                                                        |
  | `meeting:{meeting_id}:intents`            | `{:intent_no_ack_spawn_failed, row}`     | intent-queue row map                                                        |
  | `meeting:{meeting_id}`                    | `{:intent_mute_changed, payload}`        | `%{meeting_id: id, muted_at: DateTime.t() \\| nil}`                         |
  """

  alias Platform.Meetings.IntentRouting

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

  @doc """
  Returns the canonical "some meeting has work to send" topic.
  Subscribed to by the Meeting Producer's IntentDispatcher so a single
  subscription catches every drain wake-up across every active
  meeting. Phoenix.PubSub has no wildcard match, so we publish once on
  this global topic — there is deliberately NO per-meeting mirror
  because the dispatcher is a global singleton with no per-meeting
  subscribers.
  """
  @spec intent_enqueued_topic() :: String.t()
  def intent_enqueued_topic, do: "meeting:intent_enqueued"

  @doc """
  Returns the per-meeting intent-queue event topic (task 019f70b8
  stage 2).

  Deliberately per-MEETING, not per-room: the queue owner
  (`Platform.Meetings.IntentQueue.Server`) is Registry-keyed by
  meeting_id, and the live-tuning UI is mounted inside a meeting. A
  room can outlive / precede the `Meeting` row, so keying the topic on
  room_id would leave the UI subscribed to a topic the queue never
  publishes on.
  """
  @spec intents_topic(binary()) :: String.t()
  def intents_topic(meeting_id) when is_binary(meeting_id),
    do: "meeting:#{meeting_id}:intents"

  @doc """
  Returns the canonical "a classified utterance is about action items"
  topic (task 019fb90f-36e3 stage 1).

  GLOBAL, deliberately — and this is the whole reason it exists rather
  than reusing `intents_topic/1`. The consumer is
  `Platform.Responsibilities.Router`, which calls
  `subscribe_event_topics/1` ONCE at boot from the topic strings its
  enabled rows declare. It cannot subscribe to a topic whose name
  embeds a runtime meeting id, so a per-meeting mirror would be a
  topic the router is structurally unable to hear. Same shape, and for
  the same reason, as `intent_enqueued_topic/0`.
  """
  @spec action_item_intent_topic() :: String.t()
  def action_item_intent_topic, do: IntentRouting.topic("action_items")

  @doc """
  Returns the global topic a classified intent is broadcast on, or `nil`
  when the intent has no routing row (it takes the runtime-attention
  path instead).

  The generalisation of `action_item_intent_topic/0`. Global for the
  reason described there: the Router subscribes once at boot and cannot
  hear a topic whose name embeds a runtime meeting id.
  """
  @spec intent_topic(String.t()) :: String.t() | nil
  def intent_topic(intent) when is_binary(intent), do: IntentRouting.topic(intent)

  @doc """
  Returns the per-meeting SHELL topic (task 019fbaac stage 1) — state
  changes to the meeting itself, as opposed to `intents_topic/1`'s
  queue-row transitions.

  The string is `"meeting:{meeting_id}"` and that is not a free choice:
  `PlatformWeb.MeetingLive` already subscribes to exactly this string
  (via a local `meeting_topic/1` helper) for every connected
  authenticated viewer. Until this task nothing broadcast on it — it
  was a live subscription with no publisher. Defining the canonical
  helper here means new publishers land next to the topic table every
  other meeting consumer reads, instead of re-deriving the string.
  """
  @spec meeting_topic(binary()) :: String.t()
  def meeting_topic(meeting_id) when is_binary(meeting_id),
    do: "meeting:#{meeting_id}"

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

  @doc """
  Subscribe to the canonical `meeting:intent_enqueued` topic. The
  Meeting Producer's IntentDispatcher uses this to drain a meeting's
  queue the moment it has something to send, without polling.
  """
  @spec subscribe_intent_enqueued() :: :ok | {:error, term()}
  def subscribe_intent_enqueued do
    Phoenix.PubSub.subscribe(@pubsub, intent_enqueued_topic())
  end

  @doc """
  Subscribe to a single meeting's intent-queue event stream. Used by
  the MeetingLive intents panel (stage 7) and by tests that need a
  transition collector.
  """
  @spec subscribe_intents(binary()) :: :ok | {:error, term()}
  def subscribe_intents(meeting_id) when is_binary(meeting_id) do
    Phoenix.PubSub.subscribe(@pubsub, intents_topic(meeting_id))
  end

  @doc "Unsubscribe from a meeting's intent-queue event stream."
  @spec unsubscribe_intents(binary()) :: :ok
  def unsubscribe_intents(meeting_id) when is_binary(meeting_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, intents_topic(meeting_id))
  end

  @doc """
  Subscribe to a single meeting's shell topic (task 019fbaac stage 1).

  The authenticated `MeetingLive` already subscribes to this topic on
  its own; the guest surface does not, and calls this helper.
  """
  @spec subscribe_meeting(binary()) :: :ok | {:error, term()}
  def subscribe_meeting(meeting_id) when is_binary(meeting_id) do
    Phoenix.PubSub.subscribe(@pubsub, meeting_topic(meeting_id))
  end

  @doc "Unsubscribe from a meeting's shell topic."
  @spec unsubscribe_meeting(binary()) :: :ok
  def unsubscribe_meeting(meeting_id) when is_binary(meeting_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, meeting_topic(meeting_id))
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

  @doc "Unsubscribe from the canonical `meeting:intent_enqueued` topic."
  @spec unsubscribe_intent_enqueued() :: :ok
  def unsubscribe_intent_enqueued do
    Phoenix.PubSub.unsubscribe(@pubsub, intent_enqueued_topic())
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

  @doc """
  Broadcast an `:intent_enqueued` event on the canonical
  `meeting:intent_enqueued` topic. This is the dispatcher's **drain
  wake-up**, not a queue-content event — the per-meeting
  `meeting:<id>:intents` topic is where row transitions live.

  `payload` carries `:meeting_id` (required — it is the key the
  dispatcher drains by) and `:room_id` when known.

  Fired by `Platform.Meetings.IntentQueue.Server` on two occasions:

    * a new row was inserted (dedupe hits do NOT re-broadcast —
      re-notifying for a no-op write would spam the dispatcher), and
    * the serial cursor was released, meaning the meeting may now send
      its next intent.

  Before task 019f70b8 this carried `%{room_id, dedupe_key}` so the
  dispatcher could claim one row out of a global table. The table is
  gone; the meeting is the unit.
  """
  @spec broadcast_intent_enqueued(map()) :: :ok
  def broadcast_intent_enqueued(payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(@pubsub, intent_enqueued_topic(), {:intent_enqueued, payload})
  end

  @doc """
  Broadcast one action-item-classified utterance to the Responsibilities
  Router (task 019fb90f-36e3 stage 1).

  Fired by `Platform.Meetings.IntentDispatcher` — NOT by the classifier
  — from the narrow fork in `dispatch_row/3`, after the row has been
  moved to `:dispatched`. Broadcasting at classify time instead would
  double-produce (the row would also go out as runtime attention to
  `meeting_scribe`) and would drop the meeting's serial cursor, which
  is the only thing stopping two concurrent utterances from racing on
  one action-items canvas.

  `payload` carries `meeting_id`, `room_id`, `intent_id`, `space_id`,
  `transcript_id`, `chunk_excerpt`, `classified_intent`, `confidence`
  and `speaker`. Only `meeting_id`, `intent_id` and `chunk_excerpt` are
  reliably non-nil; the rest degrade to nil when the room has no
  transcript row yet, and the handler's context gatherer is written to
  treat each of them as independently missing.

  The event atom at the head — `:action_item_intent` — is the router's
  `event_match` for `meetings.action_items`. Renaming it silently
  unfires the responsibility, which is what
  `test/platform/responsibilities/event_topic_delivery_test.exs` binds
  end-to-end.
  """
  @spec broadcast_action_item_intent(map()) :: :ok
  def broadcast_action_item_intent(payload) when is_map(payload) do
    broadcast_intent("action_items", payload)
  end

  @doc """
  Broadcast one classified utterance to the Responsibilities Router on
  the topic its intent routes to.

  The generalisation of `broadcast_action_item_intent/1` — same
  contract, same caller (`IntentDispatcher`'s responsibility fork,
  after the row is `:dispatched`), with the topic and the event atom
  read from `Platform.Meetings.IntentRouting` instead of hardcoded.
  That table is also what the handlers' `register/0` reads its
  `trigger_config` from, so the broadcast and the subscription cannot
  name different topics.

  Returns `{:error, :unroutable_intent}` for an intent with no routing
  row rather than broadcasting into a topic nobody declared. That is a
  caller bug — `IntentDispatcher` only reaches this function after
  `IntentRouting.responsibility_key/1` returned non-nil — and a silent
  `:ok` would hold the meeting's serial cursor until the 90s ack window
  expired, which is exactly the invisibility the queue exists to
  remove.
  """
  @spec broadcast_intent(String.t(), map()) :: :ok | {:error, :unroutable_intent}
  def broadcast_intent(intent, payload) when is_binary(intent) and is_map(payload) do
    case IntentRouting.entry(intent) do
      %{topic: topic, event: event} ->
        Phoenix.PubSub.broadcast(@pubsub, topic, {event, payload})

      nil ->
        {:error, :unroutable_intent}
    end
  end

  @doc """
  Broadcast an `:intent_mute_changed` event on a meeting's shell topic
  (task 019fbaac stage 1).

  `muted_at` is a `DateTime` when the meeting is muted and `nil` when
  it is not — subscribers derive the boolean with `not is_nil/1` rather
  than being handed one, so the "when was this placed" answer travels
  with the event and a late-joining client that missed the toggle still
  gets the full state on the next broadcast.

  Fired by `Platform.Meetings.set_intent_muted/2` on EVERY call,
  including a no-op re-mute: a second client that missed the first
  event still needs it, and suppressing the duplicate would trade a
  cheap message for a permanently wrong badge.
  """
  @spec broadcast_intent_mute_changed(binary(), DateTime.t() | nil) :: :ok
  def broadcast_intent_mute_changed(meeting_id, muted_at)
      when is_binary(meeting_id) and (is_nil(muted_at) or is_struct(muted_at, DateTime)) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      meeting_topic(meeting_id),
      {:intent_mute_changed, %{meeting_id: meeting_id, muted_at: muted_at}}
    )
  end

  # ── Per-meeting intent-queue transitions (task 019f70b8 stage 2) ─────────────
  #
  # Eight helpers for nine statuses. `:cancelled` and `:cancelled_late`
  # deliberately share `broadcast_intent_cancelled/2` — both mean "the
  # producer pulled this row"; the payload's `:status` distinguishes
  # "we stopped it in time" from "it had already completed". Every
  # other status gets its own event because the UI renders them
  # differently: notably `:timed_out` (amber — "we waited and got
  # nothing") must stay visually distinct from `:dispatch_failed` /
  # `:no_ack_spawn_failed` (red — "something is broken"), which is why
  # they are three separate events rather than one `:intent_failed`.
  #
  # Payload is always the FULL intent row map, so a subscriber can
  # render without a follow-up read into the queue server.

  @doc "Broadcast a newly-classified (`:queued`) intent row."
  @spec broadcast_intent_classified(binary(), map()) :: :ok
  def broadcast_intent_classified(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_classified, intent)

  @doc "Broadcast an intent row that just moved to `:dispatched`."
  @spec broadcast_intent_dispatched(binary(), map()) :: :ok
  def broadcast_intent_dispatched(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_dispatched, intent)

  @doc "Broadcast an intent row that just moved to `:acked`."
  @spec broadcast_intent_acked(binary(), map()) :: :ok
  def broadcast_intent_acked(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_acked, intent)

  @doc "Broadcast an intent row that just moved to `:completed`."
  @spec broadcast_intent_completed(binary(), map()) :: :ok
  def broadcast_intent_completed(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_completed, intent)

  @doc """
  Broadcast an intent row that just moved to `:cancelled` OR
  `:cancelled_late`. Read `intent.status` to tell them apart.
  """
  @spec broadcast_intent_cancelled(binary(), map()) :: :ok
  def broadcast_intent_cancelled(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_cancelled, intent)

  @doc "Broadcast an intent row that just moved to `:timed_out`."
  @spec broadcast_intent_timed_out(binary(), map()) :: :ok
  def broadcast_intent_timed_out(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_timed_out, intent)

  @doc "Broadcast an intent row that just moved to `:dispatch_failed`."
  @spec broadcast_intent_dispatch_failed(binary(), map()) :: :ok
  def broadcast_intent_dispatch_failed(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_dispatch_failed, intent)

  @doc "Broadcast an intent row that just moved to `:no_ack_spawn_failed`."
  @spec broadcast_intent_no_ack_spawn_failed(binary(), map()) :: :ok
  def broadcast_intent_no_ack_spawn_failed(meeting_id, intent),
    do: broadcast_intent_event(meeting_id, :intent_no_ack_spawn_failed, intent)

  defp broadcast_intent_event(meeting_id, event, intent)
       when is_binary(meeting_id) and is_atom(event) and is_map(intent) do
    Phoenix.PubSub.broadcast(@pubsub, intents_topic(meeting_id), {event, intent})
  end
end
