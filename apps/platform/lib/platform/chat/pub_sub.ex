defmodule Platform.Chat.PubSub do
  @moduledoc """
  PubSub topic helpers for the Chat domain.

  ## Topics

    * `"chat:space:{space_id}"` — per-space event stream (messages, reactions,
      pins, participant changes, canvas lifecycle events).
    * `"chat:canvas:{canvas_id}:{location_epoch}"` — per-canvas event stream (state updates,
      focused canvas subscribers).
    * `"chat:canvas_room:{canvas_id}:{node_id}:{location_epoch}"` — one canvas room's
      shared-state diffs, presence and ephemeral broadcasts
      (`Platform.Chat.CanvasRoom`).

  ## Usage in LiveView

      # subscribe on mount
      Platform.Chat.PubSub.subscribe(space.id)

      # handle broadcasts
      def handle_info({:new_message, msg}, socket), do: ...
      def handle_info({:message_updated, msg}, socket), do: ...
      def handle_info({:message_deleted, msg}, socket), do: ...
      def handle_info({:reaction_added, reaction}, socket), do: ...
      def handle_info({:reaction_removed, data}, socket), do: ...
      def handle_info({:pin_added, pin}, socket), do: ...
      def handle_info({:pin_removed, data}, socket), do: ...
      def handle_info({:participant_joined, participant}, socket), do: ...
      def handle_info({:participant_left, participant}, socket), do: ...

  ## Event shapes

  | Event                          | Payload                                        |
  |--------------------------------|------------------------------------------------|
  | `{:new_message, msg}`          | `%Platform.Chat.Message{}`                     |
  | `{:message_updated, msg}`      | `%Platform.Chat.Message{}`                     |
  | `{:message_deleted, msg}`      | `%Platform.Chat.Message{}`                     |
  | `{:reaction_added, reaction}`  | `%Platform.Chat.Reaction{}`                    |
  | `{:reaction_removed, data}`    | `%{message_id: id, participant_id: id, emoji: s}` |
  | `{:pin_added, pin}`            | `%Platform.Chat.Pin{}`                         |
  | `{:pin_removed, data}`         | `%{space_id: id, message_id: id}`              |
  | `{:participant_joined, p}`     | `%Platform.Chat.Participant{}`                  |
  | `{:participant_left, p}`       | `%Platform.Chat.Participant{}`                  |
  | `{:participant_role_changed, p}` | `%Platform.Chat.Participant{}` (after commit, `Chat.set_member_role/4`) |
  """

  @pubsub Platform.PubSub

  # ── Topics ──────────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a given space."
  @spec space_topic(binary()) :: String.t()
  def space_topic(space_id), do: "chat:space:#{space_id}"

  @doc "Returns the PubSub topic for a specific canvas."
  @spec canvas_topic(binary()) :: String.t()
  def canvas_topic(canvas_id), do: canvas_topic(canvas_id, location_epoch(canvas_id))

  @doc false
  def canvas_topic(canvas_id, epoch), do: "chat:canvas:#{canvas_id}:#{epoch}"

  defp location_epoch(canvas_id) do
    case Platform.Chat.get_canvas_with_deleted(canvas_id) do
      %{location_epoch: epoch} -> epoch
      _ -> 0
    end
  end

  @doc """
  Returns the PubSub topic for one canvas room (`Platform.Chat.CanvasRoom`,
  keyed by canvas id AND node id). Deliberately NOT `canvas_topic/1`: every
  LiveView with the canvas's space open subscribes that one, so room traffic
  (cursors included) on it would reach every viewer of the space.
  """
  @spec canvas_room_topic(binary(), binary()) :: String.t()
  def canvas_room_topic(canvas_id, node_id),
    do: "chat:canvas_room:#{canvas_id}:#{node_id}:#{location_epoch(canvas_id)}"

  @doc """
  Returns the global topic for space-lifecycle events (creation, archival).

  Subscribers receive `{:space_created, space}` and `{:space_archived, space}`.
  """
  @spec spaces_topic() :: String.t()
  def spaces_topic, do: "chat:spaces"

  @doc """
  Returns the per-user topic for sidebar-shape invalidation events.

  Subscribers receive `:sidebar_changed` and recompute their resolved
  sidebar sections. Used so an admin curation write (Stage 6) or a personal
  arrangement change (Stage 5) can invalidate a connected session's cached
  sidebar without a full refresh.
  """
  @spec sidebar_topic(binary()) :: String.t()
  def sidebar_topic(user_id), do: "chat:sidebar:#{user_id}"

  @doc """
  Returns the shared topic for org-DEFAULT sidebar changes (Stage 6).

  Subscribers receive `:sidebar_defaults_changed` and recompute their
  resolved sidebar sections. Used so a root-admin curation write (rename /
  recolor / reorder / reassign of the org-default layer) propagates to ALL
  connected sessions, not just the acting admin's tab. Distinct from the
  per-user `sidebar_topic/1` (personal arrangement changes) because an admin
  default change affects everyone, whereas a personal change affects only
  the one user's other tabs.
  """
  @spec sidebar_defaults_topic() :: String.t()
  def sidebar_defaults_topic, do: "chat:sidebar:defaults"

  @doc """
  Returns the per-participant topic for thread read-cursor changes (task
  01a174f5 stage 1).

  Subscribers receive `{:thread_read, %{participant_id, thread_id,
  last_read_message_id}}` after `Platform.Chat.mark_thread_read/3` advances
  that participant's cursor. Keyed by the chat participant id (one per
  space), and deliberately NOT on `space_topic/1`: every viewer of a space
  subscribes that, and none of them needs another member's read state.
  """
  @spec thread_reads_topic(binary()) :: String.t()
  def thread_reads_topic(participant_id), do: "chat:thread_reads:#{participant_id}"

  # Retain exact subscribed epochs, so a move away and back never revives an
  # old reader, and unsubscribe still clears all pre-move registrations.
  defp subscribe_location(key, topic) do
    topics = Process.get({__MODULE__, key}, MapSet.new())
    Process.put({__MODULE__, key}, MapSet.put(topics, topic))
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  defp unsubscribe_location(key, fallback) do
    case Process.delete({__MODULE__, key}) do
      nil -> Phoenix.PubSub.unsubscribe(@pubsub, fallback)
      topics -> Enum.each(topics, &Phoenix.PubSub.unsubscribe(@pubsub, &1))
    end

    :ok
  end

  # ── Subscribe ────────────────────────────────────────────────────────────────

  @doc """
  Subscribe the calling process to all events for `space_id`.

  Typically called in a LiveView `mount/3`.
  """
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(space_id) do
    Phoenix.PubSub.subscribe(@pubsub, space_topic(space_id))
  end

  @doc "Unsubscribe the calling process from a space's event stream."
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(space_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, space_topic(space_id))
  end

  @doc "Subscribe the calling process to a specific canvas topic."
  @spec subscribe_canvas(binary()) :: :ok | {:error, term()}
  def subscribe_canvas(canvas_id) do
    subscribe_location({:canvas, canvas_id}, canvas_topic(canvas_id))
  end

  @doc "Unsubscribe the calling process from a canvas topic."
  @spec unsubscribe_canvas(binary()) :: :ok
  def unsubscribe_canvas(canvas_id) do
    unsubscribe_location({:canvas, canvas_id}, canvas_topic(canvas_id))
  end

  @doc "Subscribe the calling process to one canvas room's topic."
  @spec subscribe_canvas_room(binary(), binary()) :: :ok | {:error, term()}
  def subscribe_canvas_room(canvas_id, node_id) do
    subscribe_location({:canvas_room, canvas_id, node_id}, canvas_room_topic(canvas_id, node_id))
  end

  @doc "Unsubscribe the calling process from one canvas room's topic."
  @spec unsubscribe_canvas_room(binary(), binary()) :: :ok
  def unsubscribe_canvas_room(canvas_id, node_id) do
    unsubscribe_location(
      {:canvas_room, canvas_id, node_id},
      canvas_room_topic(canvas_id, node_id)
    )
  end

  @doc """
  Subscribe the calling process to the global space-lifecycle topic.

  Used by ChatLive to receive `{:space_created, space}` events so newly
  created channels appear live in every connected user's sidebar without
  a refresh.
  """
  @spec subscribe_spaces() :: :ok | {:error, term()}
  def subscribe_spaces do
    Phoenix.PubSub.subscribe(@pubsub, spaces_topic())
  end

  @doc "Unsubscribe the calling process from the global space-lifecycle topic."
  @spec unsubscribe_spaces() :: :ok
  def unsubscribe_spaces do
    Phoenix.PubSub.unsubscribe(@pubsub, spaces_topic())
  end

  @doc """
  Subscribe the calling process to a user's sidebar-invalidation topic.

  Used by ChatLive in `mount/3` so a `:sidebar_changed` broadcast (fired by
  Stage 5/6 arrangement/curation writes) prompts a resolver recompute.
  """
  @spec subscribe_sidebar(binary()) :: :ok | {:error, term()}
  def subscribe_sidebar(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, sidebar_topic(user_id))
  end

  @doc "Unsubscribe the calling process from a user's sidebar-invalidation topic."
  @spec unsubscribe_sidebar(binary()) :: :ok
  def unsubscribe_sidebar(user_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, sidebar_topic(user_id))
  end

  @doc """
  Subscribe the calling process to the shared org-default sidebar topic.

  Used by ChatLive in `mount/3` so a `:sidebar_defaults_changed` broadcast
  (fired by Stage 6 root-admin curation writes) prompts a resolver recompute
  in every connected session — an admin default change is visible to all
  users, not just the acting admin.
  """
  @spec subscribe_sidebar_defaults() :: :ok | {:error, term()}
  def subscribe_sidebar_defaults do
    Phoenix.PubSub.subscribe(@pubsub, sidebar_defaults_topic())
  end

  @doc "Unsubscribe the calling process from the shared org-default sidebar topic."
  @spec unsubscribe_sidebar_defaults() :: :ok
  def unsubscribe_sidebar_defaults do
    Phoenix.PubSub.unsubscribe(@pubsub, sidebar_defaults_topic())
  end

  @doc "Subscribe the calling process to a participant's thread read-cursor topic."
  @spec subscribe_thread_reads(binary()) :: :ok | {:error, term()}
  def subscribe_thread_reads(participant_id) do
    Phoenix.PubSub.subscribe(@pubsub, thread_reads_topic(participant_id))
  end

  @doc "Unsubscribe the calling process from a participant's thread read-cursor topic."
  @spec unsubscribe_thread_reads(binary()) :: :ok
  def unsubscribe_thread_reads(participant_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, thread_reads_topic(participant_id))
  end

  # ── Broadcast ────────────────────────────────────────────────────────────────

  @doc """
  Broadcast `event` to all subscribers of `space_id`.

  Returns `:ok`; errors are logged but not raised.
  """
  @spec broadcast(binary(), term()) :: :ok
  def broadcast(space_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, space_topic(space_id), event)
  end

  @doc """
  Broadcast the agent typing toggle for chat participant `participant_id`
  on `space_id`'s topic.

  THE producer of `{:agent_typing, %{space_id, participant_id, typing}}`.
  `Platform.Chat.AgentResponder` and `PlatformWeb.RuntimeChannel` used to
  build the tuple inline at six sites; the consumers are
  `PlatformWeb.ChatLive.PresenceHooks` (the composer's "X is thinking…"),
  `PlatformWeb.MeetingLive` (the `/meetings` rail) and
  `PlatformWeb.ChatLive.MeetingHooks` (the quickmeet rail). Tests that
  exercise a consumer broadcast through this function so the payload they
  assert on cannot drift from the one production sends.
  """
  @spec broadcast_agent_typing(binary(), binary(), boolean()) :: :ok | {:error, term()}
  def broadcast_agent_typing(space_id, participant_id, typing) when is_boolean(typing) do
    broadcast(
      space_id,
      {:agent_typing, %{space_id: space_id, participant_id: participant_id, typing: typing}}
    )
  end

  @doc """
  Broadcast `event` from `from_pid` — the sender will *not* receive it.

  Useful in LiveViews that want to optimistically update their own state
  without receiving the echo.
  """
  @spec broadcast_from(binary(), pid(), term()) :: :ok
  def broadcast_from(space_id, from_pid, event) do
    Phoenix.PubSub.broadcast_from(@pubsub, from_pid, space_topic(space_id), event)
  end

  @doc "Broadcast a canvas-specific event to all subscribers of `canvas_id`."
  @spec broadcast_canvas(binary(), term()) :: :ok
  def broadcast_canvas(canvas_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, canvas_topic(canvas_id), event)
  end

  @doc false
  # A room pins its location topic at startup. Cursor and presence traffic
  # stays query-free, and a retired room can never broadcast into a new epoch.
  def broadcast_canvas_room_topic(topic, event) when is_binary(topic),
    do: Phoenix.PubSub.broadcast(@pubsub, topic, event)

  @doc "Broadcast an event to every subscriber of one canvas room."
  @spec broadcast_canvas_room(binary(), binary(), term()) :: :ok
  def broadcast_canvas_room(canvas_id, node_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, canvas_room_topic(canvas_id, node_id), event)
  end

  @doc """
  Broadcast `{:thread_read, payload}` on `participant_id`'s thread-reads topic.
  THE producer; called only by `Platform.Chat.mark_thread_read/3`.
  """
  @spec broadcast_thread_read(binary(), map()) :: :ok | {:error, term()}
  def broadcast_thread_read(participant_id, payload) do
    Phoenix.PubSub.broadcast(@pubsub, thread_reads_topic(participant_id), {:thread_read, payload})
  end

  @doc "Broadcast a space-lifecycle event to every connected chat session."
  @spec broadcast_space_event(term()) :: :ok
  def broadcast_space_event(event) do
    Phoenix.PubSub.broadcast(@pubsub, spaces_topic(), event)
  end

  @doc """
  Broadcast a `:sidebar_changed` invalidation to a user's connected sessions.

  A no-op when nobody is subscribed (fire-and-forget); safe to call before
  the Stage 4 subscriber wiring lands in any given environment.
  """
  @spec broadcast_sidebar_changed(binary()) :: :ok
  def broadcast_sidebar_changed(user_id) do
    Phoenix.PubSub.broadcast(@pubsub, sidebar_topic(user_id), :sidebar_changed)
  end

  @doc """
  Broadcast a `:sidebar_changed` invalidation to a user's OTHER connected
  sessions — `from_pid` will not receive its own echo.

  Stage 5 arrangement writes (edit-layout mode) update the originating
  LiveView's `@sidebar_sections` optimistically in the same handler, so the
  acting tab must NOT also receive `:sidebar_changed`: that handler reloads
  the saved order from the DB, which would clobber the just-applied
  in-memory state for an anonymous / fail-soft user whose write didn't
  persist. Other tabs of the same user still converge.
  """
  @spec broadcast_sidebar_changed_from(binary(), pid()) :: :ok
  def broadcast_sidebar_changed_from(user_id, from_pid) do
    Phoenix.PubSub.broadcast_from(@pubsub, from_pid, sidebar_topic(user_id), :sidebar_changed)
  end

  @doc """
  Broadcast a `:sidebar_defaults_changed` invalidation to every connected
  session (Stage 6 root-admin curation write).

  Fired by `broadcast_from/3` from the acting admin's pid: the admin handler
  recomputes its own `@sidebar_sections` synchronously, so it must not also
  receive the echo (which would trigger a redundant second recompute). Every
  OTHER connected session — including other tabs of the same admin and every
  non-admin user — receives it and recomputes, so an org-default change
  propagates live. A no-op when nobody is subscribed (fire-and-forget).
  """
  @spec broadcast_sidebar_defaults_changed_from(pid()) :: :ok
  def broadcast_sidebar_defaults_changed_from(from_pid) do
    Phoenix.PubSub.broadcast_from(
      @pubsub,
      from_pid,
      sidebar_defaults_topic(),
      :sidebar_defaults_changed
    )
  end
end
