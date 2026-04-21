defmodule Platform.Chat.PubSub do
  @moduledoc """
  PubSub topic helpers for the Chat domain.

  ## Topics

    * `"chat:space:{space_id}"` — per-space event stream (messages, reactions,
      pins, participant changes, canvas lifecycle events).
    * `"chat:canvas:{canvas_id}"` — per-canvas event stream (state updates,
      focused canvas subscribers).

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
  """

  @pubsub Platform.PubSub

  # ── Topics ──────────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a given space."
  @spec space_topic(binary()) :: String.t()
  def space_topic(space_id), do: "chat:space:#{space_id}"

  @doc "Returns the PubSub topic for a specific canvas."
  @spec canvas_topic(binary()) :: String.t()
  def canvas_topic(canvas_id), do: "chat:canvas:#{canvas_id}"

  @doc """
  Returns the global topic for space-lifecycle events (creation, archival).

  Subscribers receive `{:space_created, space}` and `{:space_archived, space}`.
  """
  @spec spaces_topic() :: String.t()
  def spaces_topic, do: "chat:spaces"

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
    Phoenix.PubSub.subscribe(@pubsub, canvas_topic(canvas_id))
  end

  @doc "Unsubscribe the calling process from a canvas topic."
  @spec unsubscribe_canvas(binary()) :: :ok
  def unsubscribe_canvas(canvas_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, canvas_topic(canvas_id))
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

  @doc "Broadcast a space-lifecycle event to every connected chat session."
  @spec broadcast_space_event(term()) :: :ok
  def broadcast_space_event(event) do
    Phoenix.PubSub.broadcast(@pubsub, spaces_topic(), event)
  end
end
