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
  | `:meeting_media_state` | `%{user_id, mic_enabled, camera_enabled}` — authoritative post-toggle media state; plus `native`, `mic_pending` when the iOS app's native call owns the media |

  ## Media state

  `:meeting_media_state` is broadcast as an event AND — as of task
  01a08d5a stage 3 — the committed `{mic_enabled, camera_enabled}` pair is
  cached onto the user's ETS row when one exists (i.e. while the user is
  in a meeting). Consumers (the persistent meeting mini-bar, in-chat
  meeting controls) reduce the events into their own assigns; a NEW
  LiveView process (a reconnect mount after a socket drop, or a
  `live_navigate` re-mount) seeds its assigns from the cached pair via
  `media_intent/1` so the `#meeting-client` dataset the JS hook reads
  carries the committed intent BEFORE the restore-on-reconnect join
  re-pushes `join-meeting`. We always carry the full pair so a single
  event keeps every surface in lockstep without consumers stitching
  partial updates. The pair lives and dies with the row: `broadcast_left/1`
  deletes it, so a user who left and joins again starts from the
  first-join defaults.

  Guests have no user_id and no row. Their committed pair is stored under
  `{:guest_media_intent, key}` where `key` is `guest_intent_key/1` of the
  invite token — the one thing that survives a guest's reconnect mount
  (the URL). See `put_guest_media_intent/2`.
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

    # Keep a committed media pair a previous row carried: the
    # restore-on-reconnect `do_join` re-runs this for a user who never
    # left, and dropping the pair here would re-open the exact window
    # (row rewritten, pair gone) this cache exists to close. The
    # broadcast payload is unchanged — the pair travels on the ETS row
    # and on `:meeting_media_state`, never on `:meeting_joined`.
    ets_insert(user_id, Map.merge(media_intent(user_id) || %{}, state))

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

  Producers (MeetingHooks, the shell mini-bar) call this immediately
  after flipping their own `:mic_enabled` / `:camera_enabled` assigns; the
  bar and in-chat controls consume off the existing `topic(user_id)`
  subscription.

  Also caches the pair onto the user's ETS row when one exists (the user
  is in a meeting), written BEFORE the broadcast so a handler that reads
  `media_intent/1` in response sees the new pair. No row → nothing is
  cached: a toggle outside a meeting has no intent to preserve, and
  minting a partial row here would make `get_for_user/1` report a
  meeting that does not exist.

  The optional `:native` (the native call's capabilities map) and
  `:mic_pending` keys (task 01a13c62 stage 3) ride along to the mini bar
  when the Burrow iOS app's native call owns the media. They are broadcast
  only, never cached, and absent on the browser path.
  """
  @spec broadcast_media_state(binary(), %{
          required(:mic_enabled) => boolean(),
          required(:camera_enabled) => boolean(),
          optional(:native) => map() | nil,
          optional(:mic_pending) => boolean()
        }) :: :ok
  def broadcast_media_state(user_id, %{mic_enabled: mic, camera_enabled: camera} = attrs)
      when is_binary(user_id) and is_boolean(mic) and is_boolean(camera) do
    case get_for_user(user_id) do
      %{} = row ->
        ets_insert(user_id, Map.merge(row, %{mic_enabled: mic, camera_enabled: camera}))

      nil ->
        :ok
    end

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:meeting_media_state,
       Map.merge(
         %{user_id: user_id, mic_enabled: mic, camera_enabled: camera},
         Map.take(attrs, [:native, :mic_pending])
       )}
    )
  end

  # ── Committed media intent (task 01a08d5a stage 3) ─────────────────────────

  @doc """
  The committed `%{mic_enabled, camera_enabled}` pair cached on `user_id`'s
  row, or `nil` when there is no row or the row predates any toggle (a
  user who joined and never touched a control has no cached pair — the
  seed then stays at the first-join defaults, which is the same value).
  """
  @spec media_intent(binary() | nil) :: %{mic_enabled: boolean(), camera_enabled: boolean()} | nil
  def media_intent(user_id) when is_binary(user_id) do
    case get_for_user(user_id) do
      %{mic_enabled: mic, camera_enabled: camera} when is_boolean(mic) and is_boolean(camera) ->
        %{mic_enabled: mic, camera_enabled: camera}

      _ ->
        nil
    end
  end

  def media_intent(_), do: nil

  @doc """
  Stable, non-reversible key for a guest's committed media intent. Derived
  from the invite token because that is what the guest's reconnect mount
  arrives with (same URL); the LiveKit identity is minted fresh per join
  (`guest:<random>`) and cannot be used. Hashed so the table never holds a
  bearer token.
  """
  @spec guest_intent_key(binary() | nil) :: binary() | nil
  def guest_intent_key(invite_token) when is_binary(invite_token) and invite_token != "" do
    Base.url_encode64(:crypto.hash(:sha256, invite_token), padding: false)
  end

  def guest_intent_key(_), do: nil

  @doc "Cache a guest's committed media pair under `guest_intent_key/1`. Not broadcast."
  @spec put_guest_media_intent(binary() | nil, %{
          required(:mic_enabled) => boolean(),
          required(:camera_enabled) => boolean()
        }) :: :ok
  def put_guest_media_intent(key, %{mic_enabled: mic, camera_enabled: camera})
      when is_binary(key) and is_boolean(mic) and is_boolean(camera) do
    ets_insert({:guest_media_intent, key}, %{mic_enabled: mic, camera_enabled: camera})
  end

  def put_guest_media_intent(_key, _pair), do: :ok

  @doc "The guest pair cached under `key`, or `nil`."
  @spec guest_media_intent(binary() | nil) ::
          %{mic_enabled: boolean(), camera_enabled: boolean()} | nil
  def guest_media_intent(key) when is_binary(key) do
    case ets_lookup({:guest_media_intent, key}) do
      [{_, %{mic_enabled: _, camera_enabled: _} = pair}] -> pair
      _ -> nil
    end
  end

  def guest_media_intent(_), do: nil

  @doc "Drop a guest's cached pair (explicit leave / room disconnect)."
  @spec clear_guest_media_intent(binary() | nil) :: :ok
  def clear_guest_media_intent(key) when is_binary(key),
    do: ets_delete({:guest_media_intent, key})

  def clear_guest_media_intent(_), do: :ok

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
