defmodule Platform.Federation.DeadLetterBuffer do
  @moduledoc """
  In-process ring buffer (GenServer) storing the last 50 delivery failures.

  Dead letters are recorded when AgentResponder detects a runtime is offline
  at broadcast time. The buffer is queried by the admin federation UI.

  No database persistence — failures since last restart only.
  """
  use GenServer

  @max_entries 50

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Record a dead letter event.

  Expected keys: runtime_id, agent_id, agent_slug, space_id, reason, timestamp.
  """
  def record(entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:record, entry})
  end

  @doc "Return all stored dead letter entries, most recent first."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Clear all stored dead letters."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, []}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    updated = [entry | state] |> Enum.take(@max_entries)
    {:noreply, updated}
  end

  def handle_cast(:clear, _state) do
    {:noreply, []}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state, state}
  end
end
