defmodule Platform.Meetings.IntentQueue.Supervisor do
  @moduledoc """
  `DynamicSupervisor` for per-meeting intent-queue owners (task
  019f70b8 stage 2).

  Children are started **on demand** — the first `enqueue/2` for a
  meeting creates its queue — and run `restart: :temporary`. Temporary
  is the honest strategy for this subsystem: the queue's whole state
  lives in an ETS table owned by the child, so restarting a crashed
  child would hand callers an empty queue that merely looks healthy.
  Letting it stay down means the next `ensure_started/2` builds a fresh
  one, which is the same outcome without the lie.
  """

  use DynamicSupervisor

  alias Platform.Meetings.IntentQueue.Server

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Return the queue owner for `meeting_id`, starting it if needed.

  Idempotent and race-safe: two concurrent callers can both reach
  `start_child/2`, and the loser gets `{:error, {:already_started, pid}}`
  back from the Registry's unique-key guarantee, which we normalise to
  `{:ok, pid}`.
  """
  @spec ensure_started(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(meeting_id, opts \\ []) when is_binary(meeting_id) do
    case Server.whereis(meeting_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        spec = %{
          id: {Server, meeting_id},
          start: {Server, :start_link, [Keyword.put(opts, :meeting_id, meeting_id)]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc """
  Stop the queue owner for `meeting_id` if one is running. The ETS
  table goes with it. `:ok` either way.
  """
  @spec stop(binary()) :: :ok
  def stop(meeting_id) when is_binary(meeting_id) do
    case Server.whereis(meeting_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end

  @doc "Count of live per-meeting queue owners. Operational/test reflection."
  @spec count_queues() :: non_neg_integer()
  def count_queues do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end

  @doc """
  Meeting ids with a live queue owner.

  Read off the Registry rather than `which_children/1` so no
  `GenServer.call` is needed — the dispatcher's belt-and-braces tick
  walks this list every 30 seconds and must not be able to block on a
  busy queue.

  The `is_binary` guard matters: the same Registry also holds the
  `{:intent, id}` reverse index each server registers for its rows, and
  those keys are tuples.
  """
  @spec live_meeting_ids() :: [binary()]
  def live_meeting_ids do
    Registry.select(Platform.Meetings.Registry, [
      {{:"$1", :"$2", :"$3"}, [{:is_binary, :"$1"}], [:"$1"]}
    ])
  end
end
