defmodule Platform.Chat.ActiveAgentStore do
  @moduledoc """
  ETS-backed GenServer that tracks the currently active agent per space.

  Only one agent may be "active" (holding the mutex) in a given space at a time.
  After a configurable inactivity timeout (default 15 minutes) the mutex is
  automatically released and a PubSub broadcast notifies subscribers.

  ## Read path

  `get_active/1` and `get_last_agent/1` read directly from ETS for speed — no
  GenServer round-trip. Under the web role with a cluster peer (task 01a155a6
  stage 4) they read the PEER's row through `Platform.Role.Peer.read/5`
  (`:erpc`, 2s timeout), because that is where `server/0` sends every write;
  an unreachable peer reads as `nil`.

  ## Write path

  `set_active/2`, `clear_active/1`, and `clear_if_match/2` are GenServer calls
  that serialise mutations and manage per-space timers.

  ## Row shape

  Rows are 4-tuples:

      {space_id, active_agent_participant_id | nil, last_agent_participant_id | nil, timer_ref | nil}

  Releasing the mutex (explicit clear, match-guarded clear, or inactivity
  timeout) *retains* the row with a `nil` active field rather than deleting it,
  so `last_agent_participant_id` survives as a memory of who was most recently
  armed. Callers that only care about the mutex should keep using
  `get_active/1`, which still returns `nil` once the mutex is released.

  ## PubSub

  Every mutation broadcasts `{:active_agent_changed, space_id, agent_participant_id | nil}`
  on topic `"active_agent:\#{space_id}"`.
  """

  use GenServer

  require Logger

  alias Platform.Role.Peer

  @table :active_agent_store
  @pubsub Platform.PubSub

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Start the store as a named GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set `agent_participant_id` as the active agent for `space_id`.

  Cancels any existing inactivity timer for the space, starts a fresh one,
  and broadcasts the change via PubSub.
  """
  @spec set_active(binary(), binary()) :: :ok
  def set_active(space_id, agent_participant_id) do
    write({:set_active, space_id, agent_participant_id})
  end

  @doc """
  Return the currently active `agent_participant_id` for `space_id`, or `nil`.

  Reads directly from ETS (no GenServer call) for minimal latency.
  """
  @spec get_active(binary()) :: binary() | nil
  def get_active(space_id) do
    if Peer.remote?(),
      do: Peer.read(__MODULE__, :local_get_active, [space_id], nil),
      else: local_get_active(space_id)
  end

  @doc false
  # This node's row. Public so a web node can read it from its peer.
  @spec local_get_active(binary()) :: binary() | nil
  def local_get_active(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, agent_participant_id, _last, _timer_ref}] -> agent_participant_id
      [] -> nil
    end
  end

  @doc """
  Return the most recently active `agent_participant_id` for `space_id`, or `nil`.

  Unlike `get_active/1` this survives the mutex being released — the row is
  retained (with a `nil` active field) on clear and on inactivity timeout, so
  the last agent to hold the mutex is still known.

  Reads directly from ETS (no GenServer call) for minimal latency.
  """
  @spec get_last_agent(binary()) :: binary() | nil
  def get_last_agent(space_id) do
    if Peer.remote?(),
      do: Peer.read(__MODULE__, :local_get_last_agent, [space_id], nil),
      else: local_get_last_agent(space_id)
  end

  @doc false
  # This node's row. Public so a web node can read it from its peer.
  @spec local_get_last_agent(binary()) :: binary() | nil
  def local_get_last_agent(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, _active, last_agent_participant_id, _timer_ref}] -> last_agent_participant_id
      [] -> nil
    end
  end

  @doc """
  Clear the active agent for `space_id` unconditionally.

  Cancels the inactivity timer and broadcasts the change.
  """
  @spec clear_active(binary()) :: :ok
  def clear_active(space_id) do
    write({:clear_active, space_id})
  end

  @doc """
  Clear the active agent for `space_id` only if it currently matches
  `agent_participant_id`. Returns `:ok` regardless (idempotent).

  This prevents a stale timeout from clearing a different agent that took
  over the mutex after the timer was started.
  """
  @spec clear_if_match(binary(), binary()) :: :ok
  def clear_if_match(space_id, agent_participant_id) do
    write({:clear_if_match, space_id, agent_participant_id})
  end

  @doc """
  The store every write goes to: this node's, or under the web role with a
  cluster peer (task 01a155a6 stage 3), the peer's.

  A web node runs no `AttentionRouter`, so the mutex that decides routing is
  the full peer's. If a web node kept its own, an eye click there would arm a
  store nothing routes from, and its 15-minute release timer would broadcast
  `{:active_agent_changed, space_id, nil}` on `"active_agent:<space_id>"`,
  which clustered PubSub delivers to the full node's chat LiveViews, telling
  them the mutex was released while the real one is still held.
  """
  @spec server() :: GenServer.server()
  def server, do: Peer.server(__MODULE__)

  # A remote write that cannot reach the peer (nodedown, not yet connected)
  # is logged and dropped: the callers are request-path UI events and the
  # mutex they would have set lives on a node that is not there.
  defp write(request) do
    case server() do
      {__MODULE__, peer} = remote ->
        try do
          GenServer.call(remote, request)
        catch
          :exit, reason ->
            Logger.warning(
              "[ActiveAgentStore] #{elem(request, 0)} not applied: peer #{peer} " <>
                "unreachable (#{inspect(reason)})"
            )

            :ok
        end

      local ->
        GenServer.call(local, request)
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set_active, space_id, agent_participant_id}, _from, state) do
    cancel_existing_timer(space_id)

    timer_ref =
      Process.send_after(self(), {:timeout, space_id, agent_participant_id}, timeout_ms())

    # The newly-armed agent is also the new "last" agent for the space.
    :ets.insert(@table, {space_id, agent_participant_id, agent_participant_id, timer_ref})
    broadcast_change(space_id, agent_participant_id)

    {:reply, :ok, state}
  end

  def handle_call({:clear_active, space_id}, _from, state) do
    cancel_existing_timer(space_id)
    release(space_id)
    broadcast_change(space_id, nil)

    {:reply, :ok, state}
  end

  def handle_call({:clear_if_match, space_id, agent_participant_id}, _from, state) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, ^agent_participant_id, _last, timer_ref}] ->
        cancel_timer(timer_ref)
        release(space_id)
        broadcast_change(space_id, nil)

      _other ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:timeout, space_id, agent_participant_id}, state) do
    # Use the match-guarded clear so a newer agent isn't accidentally evicted.
    case :ets.lookup(@table, space_id) do
      [{^space_id, ^agent_participant_id, _last, _timer_ref}] ->
        release(space_id)
        broadcast_change(space_id, nil)

      _other ->
        :ok
    end

    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Release the mutex while retaining the row so `get_last_agent/1` keeps
  # working. The agent that was active becomes the new "last"; if the space was
  # already released we keep whatever "last" it already carried. A space with no
  # row at all stays absent — there is nothing to remember.
  defp release(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, active, last, _timer_ref}] ->
        :ets.insert(@table, {space_id, nil, active || last, nil})

      [] ->
        :ok
    end
  end

  defp cancel_existing_timer(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, _active, _last, timer_ref}] -> cancel_timer(timer_ref)
      [] -> :ok
    end
  end

  # Rows that were cleared but retained carry a `nil` timer_ref.
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref) when is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

  defp timeout_ms do
    Application.get_env(:platform, :active_agent_timeout_ms, 900_000)
  end

  defp broadcast_change(space_id, agent_participant_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "active_agent:#{space_id}",
      {:active_agent_changed, space_id, agent_participant_id}
    )
  end
end
