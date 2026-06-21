defmodule Platform.Meetings.State do
  @moduledoc """
  Per-user meeting state — ETS-backed cache + PubSub broadcaster.

  Tracks the user's currently-active meeting so that the shell layout can
  (a) hydrate the persistent meeting mini-bar synchronously on a fresh mount
  (a `live_navigate` re-mounts the shell and would otherwise miss the
  one-shot `:meeting_joined` PubSub event that fired on the original join)
  and (b) get live updates as the user joins/leaves meetings.

  Reads are direct ETS lookups (lock-free, concurrent) — every shell mount
  hits `get_for_user/1`, so a GenServer round-trip per mount would
  serialize unnecessarily. Writes go through this module's helper API so
  the ETS row and the PubSub broadcast are always issued together (row
  first, so any handler that calls `get_for_user/1` in response sees the
  new state).

  The GenServer exists only to own the named table's lifecycle; it does
  not serialize reads or writes.

  ## Topic

    * `"meeting:state:{user_id}"` — per-user meeting lifecycle events.

  ## Events

  | Event                  | Payload                                                                                              |
  |------------------------|------------------------------------------------------------------------------------------------------|
  | `:meeting_joined`      | `%{user_id, space_id, space_name, space_slug, meeting_slug, started_at}`                             |
  | `:meeting_left`        | `%{user_id}`                                                                                         |
  | `:meeting_media_state` | `%{user_id, mic_enabled, camera_enabled}` — authoritative post-toggle media state                    |

  ## Media state

  `:meeting_media_state` is a *transient* event — it is NOT cached in ETS.
  Consumers (the persistent meeting mini-bar, in-chat meeting controls)
  reduce these events into their own assigns. We always carry the full
  `{mic_enabled, camera_enabled}` pair so a single event keeps every
  surface in lockstep without consumers stitching partial updates.
  """

  use GenServer

  @pubsub Platform.PubSub
  @table :meeting_user_state

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start the state owner. Creates the named public ETS table on init so
  reads from any process are lock-free. Booted from
  `Platform.Application`'s child list.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # `:public` lets any process write (broadcast_joined / broadcast_left
    # run in the caller's process); `:named_table` lets readers reference
    # `@table` directly without locating the owning pid.
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # A previous incarnation (e.g. crash + supervisor restart) left the
        # table around — :public tables outlive their owner only when the
        # heir is set; in our case the table dies with the owner, so this
        # branch is defensive against tests that pre-create the table.
        :ok
    end

    {:ok, %{}}
  end

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

  # ── Read ───────────────────────────────────────────────────────────────────

  @doc """
  Look up the currently-active meeting for `user_id`. Returns the stored
  map (`%{space_id, space_name, space_slug, meeting_slug, started_at}`)
  or `nil` when the user is not in a meeting.

  Direct ETS lookup — no GenServer round-trip. Safe to call from any
  process, including from `mount/3` on every shell connection.
  """
  @spec get_for_user(binary() | nil) :: map() | nil
  def get_for_user(user_id) when is_binary(user_id) do
    case ets_lookup(user_id) do
      [{^user_id, state}] -> state
      _ -> nil
    end
  end

  def get_for_user(_), do: nil

  # ── Broadcast ──────────────────────────────────────────────────────────────

  @doc """
  Record that `user_id` has joined a meeting in `space_id` and broadcast
  the join. Writes the ETS row *first* so any handler that reads via
  `get_for_user/1` in response sees the new state.

  Subscribers receive:

      {:meeting_joined,
       %{
         user_id: user_id,
         space_id: space_id,
         space_name: space_name,
         space_slug: space_slug,
         meeting_slug: meeting_slug,
         started_at: %DateTime{}
       }}

  `started_at` is stamped here (not by callers) so reads via
  `get_for_user/1` and broadcast payloads agree on the same instant.
  """
  @spec broadcast_joined(binary(), binary(), binary(), binary() | nil, binary() | nil) :: :ok
  def broadcast_joined(user_id, space_id, space_name, space_slug, meeting_slug)
      when is_binary(user_id) and is_binary(space_id) do
    started_at = DateTime.utc_now()

    state = %{
      space_id: space_id,
      space_name: space_name,
      space_slug: space_slug,
      meeting_slug: meeting_slug,
      started_at: started_at
    }

    ets_insert(user_id, state)

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_joined, Map.put(state, :user_id, user_id)}
    )
  end

  @doc """
  Record that `user_id` has left their meeting and broadcast the leave.
  Deletes the ETS row *first* so any handler that reads via
  `get_for_user/1` in response sees `nil`.

  Subscribers receive:

      {:meeting_left, %{user_id: user_id}}
  """
  @spec broadcast_left(binary()) :: :ok
  def broadcast_left(user_id) when is_binary(user_id) do
    ets_delete(user_id)

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_left, %{user_id: user_id}}
    )
  end

  @doc """
  Broadcast `user_id`'s authoritative post-toggle media state.

  Subscribers receive:

      {:meeting_media_state,
       %{user_id: user_id, mic_enabled: boolean(), camera_enabled: boolean()}}

  The full pair is always carried (not separate mic/camera events) so a
  consumer that reduces these into assigns never has to stitch partial
  updates and can't end up with a stale-camera-on-fresh-mic state.

  Transient — not cached in ETS. Producers (MeetingHooks) call this
  immediately after flipping their own `:mic_enabled` / `:camera_enabled`
  assigns; the bar and in-chat controls consume off the existing
  `topic(user_id)` subscription.
  """
  @spec broadcast_media_state(binary(), %{
          required(:mic_enabled) => boolean(),
          required(:camera_enabled) => boolean()
        }) :: :ok
  def broadcast_media_state(user_id, %{mic_enabled: mic, camera_enabled: camera})
      when is_binary(user_id) and is_boolean(mic) and is_boolean(camera) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_media_state, %{user_id: user_id, mic_enabled: mic, camera_enabled: camera}}
    )
  end

  # ── Internal: ETS helpers ──────────────────────────────────────────────────
  #
  # Wrapped so calls during early boot (before `init/1` has installed the
  # table) or in test harnesses that haven't started the GenServer return
  # benign defaults instead of crashing the caller.

  defp ets_lookup(key) do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.lookup(@table, key)
    end
  end

  defp ets_insert(key, value) do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.insert(@table, {key, value})
    end

    :ok
  end

  defp ets_delete(key) do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, key)
    end

    :ok
  end
end
