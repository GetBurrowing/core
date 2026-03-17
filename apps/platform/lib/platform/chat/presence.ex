defmodule Platform.Chat.Presence do
  @moduledoc """
  Phoenix.Presence for tracking online participants in chat spaces.

  Started automatically by `Platform.Application` after PubSub.

  ## Tracking a participant

  Call from a connected LiveView (or any long-lived process) using the
  topic returned by `Platform.Chat.PubSub.space_topic/1`:

      topic = Platform.Chat.PubSub.space_topic(space_id)
      Platform.Chat.Presence.track(self(), topic, participant_id, %{
        participant_type: "user",
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

  Or use the convenience helpers that accept a `space_id` directly:

      Platform.Chat.Presence.track_in_space(self(), space_id, participant_id, %{
        participant_type: "user",
        display_name: "Alice"
      })

  ## Listing presences

      presences = Platform.Chat.Presence.list_space(space_id)
      # => %{"participant-uuid" => %{metas: [%{display_name: "Alice", phx_ref: "…"}]}}

  ## Online count

      Platform.Chat.Presence.online_count(space_id)
      # => 3

  ## Presence diffs in LiveView

  Presence diffs are broadcast on the space topic, so a single
  `Platform.Chat.PubSub.subscribe/1` call receives both chat events and
  presence diffs:

      # in mount/3
      Platform.Chat.PubSub.subscribe(space.id)

      # handle_info callback
      def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
        # diff = %{joins: %{}, leaves: %{}}
        {:noreply, update_presences(socket, diff)}
      end
  """

  use Phoenix.Presence,
    otp_app: :platform,
    pubsub_server: Platform.PubSub

  alias Platform.Agents.WorkspaceBootstrap
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub

  # ── Convenience helpers (space_id ─► topic) ──────────────────────────────────

  @doc """
  Track `pid` as an online participant in `space_id`.

  `key` is the participant's UUID string. `meta` is any serialisable map.
  """
  @spec track_in_space(pid(), binary(), binary(), map()) ::
          {:ok, binary()} | {:error, term()}
  def track_in_space(pid, space_id, key, meta \\ %{}) do
    track(pid, ChatPubSub.space_topic(space_id), key, meta)
  end

  @doc "Update the presence metadata for `key` in `space_id`."
  @spec update_in_space(pid(), binary(), binary(), map() | (map() -> map())) ::
          {:ok, binary()} | {:error, term()}
  def update_in_space(pid, space_id, key, meta) do
    update(pid, ChatPubSub.space_topic(space_id), key, meta)
  end

  @doc """
  Explicitly untrack `key` from `space_id`.

  Presence is cleaned up automatically when the process exits; only call
  this to remove presence early (e.g. user navigates away from a space tab).
  """
  @spec untrack_in_space(pid(), binary(), binary()) :: :ok
  def untrack_in_space(pid, space_id, key) do
    untrack(pid, ChatPubSub.space_topic(space_id), key)
  end

  @doc """
  Return the current presence map for a space.

  Shape: `%{key => %{metas: [meta_map, …]}}` where `key` is the
  participant UUID string.
  """
  @spec list_space(binary()) :: map()
  def list_space(space_id) do
    list(ChatPubSub.space_topic(space_id))
  end

  @doc "Return the number of unique participants currently online in a space."
  @spec online_count(binary()) :: non_neg_integer()
  def online_count(space_id) do
    space_id |> list_space() |> map_size()
  end

  @doc """
  Return runtime-backed presence for the configured native agent in a space.
  """
  @spec native_agent_presence(binary(), keyword()) :: map()
  def native_agent_presence(space_id, opts \\ []) do
    status = WorkspaceBootstrap.status(opts)

    participant =
      case status.agent do
        nil ->
          nil

        agent ->
          Chat.list_participants(space_id, participant_type: "agent")
          |> Enum.find(&(&1.participant_id == agent.id))
      end

    Map.merge(status, %{
      joined?: not is_nil(participant),
      participant: participant,
      indicator: native_agent_indicator(status)
    })
  end

  defp native_agent_indicator(%{reachable?: true}), do: :online
  defp native_agent_indicator(%{configured?: true}), do: :offline
  defp native_agent_indicator(_status), do: :missing
end
