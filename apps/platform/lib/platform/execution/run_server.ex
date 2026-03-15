defmodule Platform.Execution.RunServer do
  @moduledoc """
  Supervised process managing a single execution run.

  `RunServer` is the primary OTP process that coordinates a run's full
  lifecycle:

    1. Ensures the context plane is open for the run's scope
    2. Transitions the run through its status machine
    3. Fans out context deltas and tracks runner acknowledgements
    4. Triggers stale/dead transitions when the runner misses its SLA
    5. Evicts the context session on terminal state

  ## State machine

      created → starting → running → {completed | failed | cancelled}
                                   ↓ (SLA timer)
                              context_stale (ack timeout)
                                   ↓ (dead timer)
                              context_dead  (runner presumed dead)

  ## Context SLA

  Two configurable timers drive stale detection:

    - `stale_timeout_ms` (default 30_000) — ms after a required version is
      issued before the run is marked `:stale`
    - `dead_timeout_ms`  (default 120_000) — ms after entering stale before
      the run is marked `:dead`

  ## PubSub

  RunServer subscribes to `"ctx:<scope_key>"` to receive `{:context_delta, _}`
  notifications.  On each delta it bumps `required_version` and resets the
  stale SLA timer.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Platform.Context
  alias Platform.Context.EvictionPolicy
  alias Platform.Execution.{ContextSession, Run}

  @default_stale_timeout_ms 30_000
  @default_dead_timeout_ms 120_000

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    @enforce_keys [:run]
    defstruct run: nil,
              stale_timer: nil,
              dead_timer: nil,
              stale_timeout_ms: 30_000,
              dead_timeout_ms: 120_000
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: via(run.id))
  end

  @doc "Returns a context snapshot for the run managed by this server."
  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def get_snapshot(run_id) do
    GenServer.call(via(run_id), :get_snapshot)
  end

  @doc "Pushes items into the run's context session."
  @spec push_context(String.t(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def push_context(run_id, items, opts \\ []) do
    GenServer.call(via(run_id), {:push_context, items, opts})
  end

  @doc "Records a runner acknowledgement of `version`."
  @spec ack_context(String.t(), non_neg_integer()) :: {:ok, Run.t()} | {:error, term()}
  def ack_context(run_id, version) do
    GenServer.call(via(run_id), {:ack_context, version})
  end

  @doc "Transitions the run status."
  @spec transition(String.t(), Run.status()) :: {:ok, Run.t()} | {:error, term()}
  def transition(run_id, new_status) do
    GenServer.call(via(run_id), {:transition, new_status})
  end

  @doc "Returns the current run struct."
  @spec get_run(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def get_run(run_id) do
    GenServer.call(via(run_id), :get_run)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)
    stale_ms = Keyword.get(opts, :stale_timeout_ms, @default_stale_timeout_ms)
    dead_ms = Keyword.get(opts, :dead_timeout_ms, @default_dead_timeout_ms)

    state = %State{
      run: run,
      stale_timeout_ms: stale_ms,
      dead_timeout_ms: dead_ms
    }

    # Open context sessions (idempotent)
    case ContextSession.open(run) do
      {:ok, %{scope_key: scope_key}} ->
        # Subscribe to context delta events for this scope
        Phoenix.PubSub.subscribe(Platform.PubSub, "ctx:#{scope_key}")
        Logger.debug("[RunServer] #{run.id} context session opened at scope #{scope_key}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("[RunServer] #{run.id} failed to open context session: #{inspect(reason)}")
        {:stop, {:context_session_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_snapshot, _from, %State{run: run} = state) do
    {:reply, ContextSession.snapshot(run), state}
  end

  def handle_call({:push_context, items, opts}, _from, %State{run: run} = state) do
    result = ContextSession.push(run, items, opts)
    {:reply, result, state}
  end

  def handle_call({:ack_context, version}, _from, %State{run: run} = state) do
    case ContextSession.ack(run, version) do
      {:ok, %Run{} = updated_run} ->
        new_state = cancel_stale_timer(%State{state | run: updated_run})
        {:reply, {:ok, updated_run}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:transition, new_status}, _from, %State{run: run} = state) do
    if valid_transition?(run.status, new_status) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      updated_run =
        case new_status do
          :running ->
            %Run{run | status: :running, started_at: run.started_at || now}

          terminal when terminal in [:completed, :failed, :cancelled] ->
            %Run{run | status: terminal, finished_at: now}

          other ->
            %Run{run | status: other}
        end

      new_state = %State{state | run: updated_run}
      new_state = handle_terminal(updated_run, new_state)

      {:reply, {:ok, updated_run}, new_state}
    else
      {:reply, {:error, {:invalid_transition, run.status, new_status}}, state}
    end
  end

  def handle_call(:get_run, _from, %State{run: run} = state) do
    {:reply, {:ok, run}, state}
  end

  @impl true
  def handle_info({:context_delta, _delta}, %State{run: run} = state) do
    # A new delta was published — bump required version and reset stale timer
    case ContextSession.require_current(run) do
      {:ok, required_version, %Run{} = updated_run} ->
        Logger.debug(
          "[RunServer] #{run.id} required_version bumped to #{required_version} via delta"
        )

        new_state =
          state
          |> cancel_stale_timer()
          |> Map.put(:run, updated_run)
          |> start_stale_timer()

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[RunServer] #{run.id} require_current failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(:stale_timeout, %State{run: %Run{} = run} = state) do
    Logger.warning("[RunServer] #{run.id} context stale — runner missed ack SLA")

    updated_run = %Run{run | ctx_status: :stale}
    new_state = %State{state | run: updated_run, stale_timer: nil}
    new_state = start_dead_timer(new_state)

    broadcast_ctx_status(updated_run)
    {:noreply, new_state}
  end

  def handle_info(:dead_timeout, %State{run: %Run{} = run} = state) do
    Logger.error("[RunServer] #{run.id} context dead — runner presumed dead")

    updated_run = %Run{run | ctx_status: :dead}
    new_state = %State{state | run: updated_run, dead_timer: nil}

    broadcast_ctx_status(updated_run)
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp via(run_id) do
    {:via, Registry, {Platform.Execution.Registry, {:run_server, run_id}}}
  end

  defp valid_transition?(from, to) do
    valid_transitions = %{
      created: [:starting, :cancelled],
      starting: [:running, :failed, :cancelled],
      running: [:completed, :failed, :cancelled]
    }

    to in Map.get(valid_transitions, from, [])
  end

  defp handle_terminal(%Run{status: status} = run, %State{} = state)
       when status in [:completed, :failed, :cancelled] do
    state = cancel_stale_timer(state)
    state = cancel_dead_timer(state)

    # Promote artifacts to task session, then evict run-scoped session
    EvictionPolicy.run_terminated(%{
      project_id: run.project_id,
      epic_id: run.epic_id,
      task_id: run.task_id,
      run_id: run.id
    })

    state
  end

  defp handle_terminal(_run, state), do: state

  defp start_stale_timer(%State{stale_timeout_ms: ms} = state) do
    timer = Process.send_after(self(), :stale_timeout, ms)
    %State{state | stale_timer: timer}
  end

  defp cancel_stale_timer(%State{stale_timer: nil} = state), do: state

  defp cancel_stale_timer(%State{stale_timer: timer} = state) do
    Process.cancel_timer(timer)
    %State{state | stale_timer: nil}
  end

  defp start_dead_timer(%State{dead_timeout_ms: ms} = state) do
    timer = Process.send_after(self(), :dead_timeout, ms)
    %State{state | dead_timer: timer}
  end

  defp cancel_dead_timer(%State{dead_timer: nil} = state), do: state

  defp cancel_dead_timer(%State{dead_timer: timer} = state) do
    Process.cancel_timer(timer)
    %State{state | dead_timer: nil}
  end

  defp broadcast_ctx_status(%Run{} = run) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      "execution:runs:#{run.task_id}",
      {:run_ctx_status_changed, run.id, run.ctx_status}
    )
  end
end
