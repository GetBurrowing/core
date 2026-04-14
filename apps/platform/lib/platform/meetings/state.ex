defmodule Platform.Meetings.State do
  @moduledoc """
  Thin PubSub broadcast helper for user-level meeting state.

  Publishes `:meeting_joined` and `:meeting_left` events to a per-user topic
  so that the shell layout can show/hide the persistent meeting mini-bar
  regardless of which page the user is viewing.

  ## Topic

    * `"meeting:state:{user_id}"` — per-user meeting lifecycle events.

  ## Events

  | Event                | Payload                                                        |
  |----------------------|----------------------------------------------------------------|
  | `:meeting_joined`    | `%{user_id: id, space_id: id, space_name: name}`              |
  | `:meeting_left`      | `%{user_id: id}`                                              |
  """

  @pubsub Platform.PubSub

  # ── Topic ──────────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a user's meeting state."
  @spec topic(binary()) :: String.t()
  def topic(user_id), do: "meeting:state:#{user_id}"

  # ── Subscribe ──────────────────────────────────────────────────────────────

  @doc "Subscribe the calling process to meeting state changes for `user_id`."
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  end

  # ── Broadcast ──────────────────────────────────────────────────────────────

  @doc """
  Broadcast that `user_id` has joined a meeting in `space_id`.

  All subscribers to the user's meeting state topic will receive:

      {:meeting_joined, %{user_id: user_id, space_id: space_id, space_name: space_name}}
  """
  @spec broadcast_joined(binary(), binary(), binary()) :: :ok
  def broadcast_joined(user_id, space_id, space_name) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_joined, %{user_id: user_id, space_id: space_id, space_name: space_name}}
    )
  end

  @doc """
  Broadcast that `user_id` has left their meeting.

  All subscribers to the user's meeting state topic will receive:

      {:meeting_left, %{user_id: user_id}}
  """
  @spec broadcast_left(binary()) :: :ok
  def broadcast_left(user_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_left, %{user_id: user_id}}
    )
  end
end
