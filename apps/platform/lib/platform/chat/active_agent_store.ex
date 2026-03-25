defmodule Platform.Chat.ActiveAgentStore do
  @moduledoc """
  ETS-backed GenServer that tracks the currently active agent per space.

  Only one agent may be "active" (holding the mutex) in a given space at a time.
  After a configurable inactivity timeout (default 15 minutes) the mutex is
  automatically released and a PubSub broadcast notifies subscribers.

  ## Read path

  `get_active/1` reads directly from ETS for speed — no GenServer round-trip.

  ## Write path

  `set_active/2`, `clear_active/1`, and `clear_if_match/2` are GenServer calls
  that serialise mutations and manage per-space timers.

  ## PubSub

  Every mutation broadcasts `{:active_agent_changed, space_id, agent_participant_id | nil}`
  on topic `"active_agent:\#{space_id}"`.
  """

  use GenServer

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
    GenServer.call(__MODULE__, {:set_active, space_id, agent_participant_id})
  end

  @doc """
  Return the currently active `agent_participant_id` for `space_id`, or `nil`.

  Reads directly from ETS (no GenServer call) for minimal latency.
  """
  @spec get_active(binary()) :: binary() | nil
  def get_active(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, agent_participant_id, _timer_ref}] -> agent_participant_id
      [] -> nil
    end
  end

  @doc """
  Clear the active agent for `space_id` unconditionally.

  Cancels the inactivity timer and broadcasts the change.
  """
  @spec clear_active(binary()) :: :ok
  def clear_active(space_id) do
    GenServer.call(__MODULE__, {:clear_active, space_id})
  end

  @doc """
  Clear the active agent for `space_id` only if it currently matches
  `agent_participant_id`. Returns `:ok` regardless (idempotent).

  This prevents a stale timeout from clearing a different agent that took
  over the mutex after the timer was started.
  """
  @spec clear_if_match(binary(), binary()) :: :ok
  def clear_if_match(space_id, agent_participant_id) do
    GenServer.call(__MODULE__, {:clear_if_match, space_id, agent_participant_id})
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

    :ets.insert(@table, {space_id, agent_participant_id, timer_ref})
    broadcast_change(space_id, agent_participant_id)

    {:reply, :ok, state}
  end

  def handle_call({:clear_active, space_id}, _from, state) do
    cancel_existing_timer(space_id)
    :ets.delete(@table, space_id)
    broadcast_change(space_id, nil)

    {:reply, :ok, state}
  end

  def handle_call({:clear_if_match, space_id, agent_participant_id}, _from, state) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, ^agent_participant_id, timer_ref}] ->
        Process.cancel_timer(timer_ref)
        :ets.delete(@table, space_id)
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
      [{^space_id, ^agent_participant_id, _timer_ref}] ->
        :ets.delete(@table, space_id)
        broadcast_change(space_id, nil)

      _other ->
        :ok
    end

    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp cancel_existing_timer(space_id) do
    case :ets.lookup(@table, space_id) do
      [{^space_id, _agent, timer_ref}] -> Process.cancel_timer(timer_ref)
      [] -> :ok
    end
  end

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
