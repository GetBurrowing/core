defmodule Platform.Execution.RunServer do
  @moduledoc """
  OTP control process for a single execution run.

  `RunServer` is the BEAM-owned source of truth for run liveness, progress,
  context acknowledgement, and stop/kill escalation semantics defined in
  ADR 0011.
  """

  use GenServer

  alias Platform.Execution.{ContextSession, Run}

  @type server :: GenServer.server()

  @default_kill_confirm_timeout_ms 1_000

  defstruct run: nil,
            runner: nil,
            liveness_timer: nil,
            force_stop_timer: nil,
            liveness_interval_ms: 1_000,
            kill_confirm_timeout_ms: @default_kill_confirm_timeout_ms,
            context_session: nil

  @type state :: %__MODULE__{
          run: Run.t(),
          runner: module(),
          liveness_timer: reference() | nil,
          force_stop_timer: reference() | nil,
          liveness_interval_ms: pos_integer(),
          kill_confirm_timeout_ms: pos_integer(),
          context_session: ContextSession.t() | nil
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run = Keyword.fetch!(opts, :run)
    run_id = run_id!(run)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    run_id = run_id!(run)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  @doc "Return the latest in-memory run snapshot."
  @spec status(server()) :: Run.t()
  def status(server), do: GenServer.call(server, :status)

  @doc "Record a runner heartbeat."
  @spec heartbeat(server(), non_neg_integer(), map()) :: {:ok, Run.t()}
  def heartbeat(server, seq, metadata \\ %{}) do
    GenServer.call(server, {:heartbeat, seq, metadata})
  end

  @doc "Record a deterministic run checkpoint."
  @spec checkpoint(server(), String.t() | atom(), map()) :: {:ok, Run.t()}
  def checkpoint(server, phase, metadata \\ %{}) do
    GenServer.call(server, {:checkpoint, phase, metadata})
  end

  @doc "Acknowledge the latest required context version."
  @spec ack_context_version(server(), non_neg_integer()) :: {:ok, Run.t()}
  def ack_context_version(server, version) do
    GenServer.call(server, {:ack_context_version, version})
  end

  @doc "Replace the active context session and push it to the runner provider."
  @spec push_context(server(), ContextSession.t() | map() | keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def push_context(server, context_session) do
    GenServer.call(server, {:push_context, context_session})
  end

  @doc "Request a fast graceful stop, with automatic escalation to force kill."
  @spec request_stop(server(), String.t() | atom(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def request_stop(server, reason \\ :cancelled, opts \\ []) do
    GenServer.call(server, {:request_stop, reason, opts})
  end

  @doc "Escalate immediately to force stop/kill semantics."
  @spec force_stop(server(), String.t() | atom(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def force_stop(server, reason \\ :killed, opts \\ []) do
    GenServer.call(server, {:force_stop, reason, opts})
  end

  @doc "Record runner exit."
  @spec runner_exited(server(), map() | keyword()) :: {:ok, Run.t()}
  def runner_exited(server, outcome \\ %{}) do
    GenServer.call(server, {:runner_exited, outcome})
  end

  @doc "Registry lookup helper for run-id addressing."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(Platform.Execution.Registry, run_id) do
      [{pid, _value}] -> pid
      _ -> nil
    end
  end

  @impl true
  def init(opts) do
    run =
      opts
      |> Keyword.fetch!(:run)
      |> normalize_run!()

    runner = Keyword.fetch!(opts, :runner)

    liveness_interval_ms =
      opts
      |> Keyword.get(:liveness_interval_ms, default_liveness_interval(run))
      |> normalize_pos_integer(default_liveness_interval(run))

    kill_confirm_timeout_ms =
      opts
      |> Keyword.get(:kill_confirm_timeout_ms, @default_kill_confirm_timeout_ms)
      |> normalize_pos_integer(@default_kill_confirm_timeout_ms)

    state = %__MODULE__{
      run: run,
      runner: runner,
      liveness_interval_ms: liveness_interval_ms,
      kill_confirm_timeout_ms: kill_confirm_timeout_ms,
      context_session: normalize_context_session(Keyword.get(opts, :context_session))
    }

    state = maybe_spawn_run(state, Keyword.get(opts, :spawn?, false), opts)
    {:ok, schedule_liveness_timer(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.run, state}

  def handle_call({:heartbeat, _seq, metadata}, _from, state) do
    now = DateTime.utc_now()

    run =
      state.run
      |> merge_metadata(metadata)
      |> Map.put(:last_heartbeat_at, now)
      |> mark_running()

    {:reply, {:ok, run}, %{state | run: run}}
  end

  def handle_call({:checkpoint, phase, metadata}, _from, state) do
    now = DateTime.utc_now()

    run =
      state.run
      |> Map.put(:phase, to_string(phase))
      |> Map.put(:last_progress_at, now)
      |> merge_metadata(metadata)
      |> mark_running()

    {:reply, {:ok, run}, %{state | run: run}}
  end

  def handle_call({:ack_context_version, version}, _from, state) do
    now = DateTime.utc_now()
    acknowledged_version = max(state.run.acknowledged_context_version, version)

    run =
      state.run
      |> Map.put(:acknowledged_context_version, acknowledged_version)
      |> Map.put(:last_context_ack_at, now)
      |> maybe_clear_context_request(acknowledged_version)
      |> mark_running()

    context_session =
      case state.context_session do
        %ContextSession{} = session -> ContextSession.acknowledge(session, version, now)
        nil -> nil
      end

    {:reply, {:ok, run}, %{state | run: run, context_session: context_session}}
  end

  def handle_call({:push_context, context_input}, _from, state) do
    with {:ok, context_session} <- normalize_context_session_result(context_input),
         :ok <- push_context_to_runner(state.runner, state.run, context_session) do
      run =
        state.run
        |> Map.put(
          :required_context_version,
          max(state.run.required_context_version, context_session.required_version)
        )
        |> Map.put(:context_requested_at, context_session.issued_at)
        |> Map.put(:phase, state.run.phase || "context_sync")

      {:reply, {:ok, run}, %{state | run: run, context_session: context_session}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_stop, reason, opts}, _from, state) do
    cond do
      Run.terminal?(state.run) or state.run.state in [:stopping, :kill_requested] ->
        {:reply, {:ok, state.run}, state}

      true ->
        requested_run =
          state.run
          |> Map.put(:state, :stopping)
          |> Map.put(:stop_reason, to_string(reason))
          |> Map.put(:stop_requested_at, DateTime.utc_now())

        run =
          requested_run
          |> maybe_merge_runner_result(
            invoke_runner(state.runner, :request_stop, [
              requested_run,
              Keyword.put(opts, :reason, reason)
            ])
          )

        state =
          state
          |> cancel_force_stop_timer()
          |> Map.put(:run, run)
          |> schedule_force_stop_timer()

        {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:force_stop, reason, opts}, _from, state) do
    if Run.terminal?(state.run) do
      {:reply, {:ok, state.run}, state}
    else
      state = force_stop_now(state, reason, opts)
      {:reply, {:ok, state.run}, state}
    end
  end

  def handle_call({:runner_exited, outcome}, _from, state) do
    run = finish_run(state.run, outcome)
    state = state |> cancel_force_stop_timer() |> Map.put(:run, run)
    {:reply, {:ok, run}, state}
  end

  @impl true
  def handle_info(:check_liveness, state) do
    state =
      state
      |> maybe_transition_liveness()
      |> schedule_liveness_timer()

    {:noreply, state}
  end

  def handle_info(:force_stop, state) do
    if state.run.state == :stopping do
      {:noreply, force_stop_now(state, state.run.stop_reason || :killed, [])}
    else
      {:noreply, %{state | force_stop_timer: nil}}
    end
  end

  defp maybe_spawn_run(state, false, _opts), do: state

  defp maybe_spawn_run(%__MODULE__{run: %Run{} = run} = state, true, opts) do
    case invoke_runner(state.runner, :spawn_run, [run, opts]) do
      {:ok, provider_ref} ->
        %{state | run: %Run{run | runner_ref: provider_ref, state: :starting}}

      _other ->
        state
    end
  end

  defp maybe_transition_liveness(%__MODULE__{run: %Run{} = run} = state) do
    now = DateTime.utc_now()
    classification = Run.classify(run, now)

    run =
      cond do
        Run.terminal?(run) ->
          run

        run.state == :kill_requested and
            kill_confirmation_expired?(run, state.kill_confirm_timeout_ms, now) ->
          %Run{run | state: :dead}

        run.state in [:stopping, :kill_requested] ->
          run

        classification == :dead ->
          %Run{run | state: :dead}

        classification == :stale ->
          %Run{run | state: :stale}

        run.state == :stale ->
          %Run{run | state: :running}

        true ->
          run
      end

    %{state | run: run}
  end

  defp mark_running(%Run{state: state} = run)
       when state in [:queued, :starting, :booting, :stale],
       do: %Run{run | state: :running}

  defp mark_running(run), do: run

  defp maybe_clear_context_request(%Run{} = run, acknowledged_version)
       when acknowledged_version >= run.required_context_version do
    %Run{run | context_requested_at: nil}
  end

  defp maybe_clear_context_request(run, _acknowledged_version), do: run

  defp finish_run(%Run{} = run, outcome) when is_list(outcome) do
    outcome
    |> Enum.into(%{})
    |> then(&finish_run(run, &1))
  end

  defp finish_run(%Run{} = run, %{} = outcome) do
    state =
      outcome
      |> Map.get(:state, Map.get(outcome, "state"))
      |> normalize_terminal_state(run)

    exit_code = Map.get(outcome, :exit_code, Map.get(outcome, "exit_code"))

    %Run{run | state: state, exit_code: normalize_optional_integer(exit_code)}
  end

  defp normalize_terminal_state(nil, %Run{state: :kill_requested}), do: :killed
  defp normalize_terminal_state(nil, %Run{state: :stopping}), do: :cancelled
  defp normalize_terminal_state(nil, _run), do: :completed

  defp normalize_terminal_state(state, _run)
       when state in [:completed, :failed, :cancelled, :killed, :dead], do: state

  defp normalize_terminal_state(state, _run) when is_binary(state) do
    case String.downcase(String.trim(state)) do
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      "killed" -> :killed
      "dead" -> :dead
      _ -> :completed
    end
  end

  defp normalize_terminal_state(_state, _run), do: :completed

  defp force_stop_now(%__MODULE__{} = state, reason, opts) do
    requested_run =
      state.run
      |> Map.put(:state, :kill_requested)
      |> Map.put(:stop_reason, state.run.stop_reason || to_string(reason))
      |> Map.put(:kill_requested_at, DateTime.utc_now())

    run =
      requested_run
      |> maybe_merge_runner_result(
        invoke_runner(state.runner, :force_stop, [
          requested_run,
          Keyword.put(opts, :reason, reason)
        ])
      )

    state
    |> cancel_force_stop_timer()
    |> Map.put(:run, run)
  end

  defp maybe_merge_runner_result(%Run{} = run, {:ok, metadata}) when is_map(metadata) do
    merge_metadata(run, metadata)
  end

  defp maybe_merge_runner_result(%Run{} = run, _result), do: run

  defp merge_metadata(%Run{} = run, metadata) when is_map(metadata) and map_size(metadata) > 0 do
    %Run{run | metadata: Map.merge(run.metadata, metadata)}
  end

  defp merge_metadata(run, _metadata), do: run

  defp schedule_liveness_timer(%__MODULE__{} = state) do
    state = cancel_liveness_timer(state)
    ref = Process.send_after(self(), :check_liveness, state.liveness_interval_ms)
    %{state | liveness_timer: ref}
  end

  defp schedule_force_stop_timer(%__MODULE__{} = state) do
    ref = Process.send_after(self(), :force_stop, state.run.kill_grace_ms)
    %{state | force_stop_timer: ref}
  end

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: nil} = state), do: state

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | liveness_timer: nil}
  end

  defp cancel_force_stop_timer(%__MODULE__{force_stop_timer: nil} = state), do: state

  defp cancel_force_stop_timer(%__MODULE__{force_stop_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | force_stop_timer: nil}
  end

  defp kill_confirmation_expired?(%Run{kill_requested_at: nil}, _timeout_ms, _now), do: false

  defp kill_confirmation_expired?(%Run{kill_requested_at: %DateTime{} = at}, timeout_ms, now) do
    DateTime.diff(now, at, :millisecond) > timeout_ms
  end

  defp push_context_to_runner(runner, run, %ContextSession{} = session) do
    case invoke_runner(runner, :push_context, [run, session, []]) do
      :ok -> :ok
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_runner(runner, function_name, args) when is_atom(runner) do
    apply(runner, function_name, args)
  rescue
    error -> {:error, error}
  end

  defp default_liveness_interval(%Run{} = run) do
    run.heartbeat_timeout_ms
    |> min(run.progress_timeout_ms)
    |> min(run.context_ack_timeout_ms)
    |> div(4)
    |> max(250)
  end

  defp normalize_run!(%Run{} = run), do: run

  defp normalize_run!(attrs) do
    case Run.new(attrs) do
      {:ok, run} -> run
      {:error, reason} -> raise ArgumentError, "invalid run: #{inspect(reason)}"
    end
  end

  defp normalize_context_session(nil), do: nil

  defp normalize_context_session(%ContextSession{} = session), do: session

  defp normalize_context_session(input) do
    case ContextSession.new(input) do
      {:ok, session} -> session
      {:error, _reason} -> nil
    end
  end

  defp normalize_context_session_result(%ContextSession{} = session), do: {:ok, session}
  defp normalize_context_session_result(input), do: ContextSession.new(input)

  defp normalize_pos_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_pos_integer(_value, default), do: default

  defp normalize_optional_integer(nil), do: nil
  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_value), do: nil

  defp run_id!(%Run{id: id}) when is_binary(id), do: id

  defp run_id!(attrs) when is_map(attrs) do
    Map.get(attrs, :id) || Map.get(attrs, "id") || raise(ArgumentError, "run id required")
  end

  defp via_tuple(run_id) do
    {:via, Registry, {Platform.Execution.Registry, run_id}}
  end
end
