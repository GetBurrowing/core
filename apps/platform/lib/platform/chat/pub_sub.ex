defmodule Platform.Chat.PubSub do
  @moduledoc """
  PubSub topic helpers for the Chat domain.

  ## Topics

    * `"chat:space:{space_id}"` — per-space event stream (messages, reactions,
      pins, participant changes).

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
end
