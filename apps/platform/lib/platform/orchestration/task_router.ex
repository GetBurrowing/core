defmodule Platform.Orchestration.TaskRouter do
  @moduledoc """
  Per-task orchestration process: dispatch, heartbeat, escalation.

  One `TaskRouter` process runs per active task assignment. It subscribes to
  `tasks:board` PubSub events to track stage transitions and resets its
  heartbeat timer whenever progress is observed.

  All decisions are deterministic — no LLM in the router.
  """

  use GenServer

  require Logger

  alias Platform.Orchestration.{ContextAssembler, ExecutionSpace, HeartbeatScheduler}
  alias Platform.Tasks

  # ── State ──────────────────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            task_id: String.t(),
            assignee: %{type: :federated, id: String.t()},
            execution_space_id: String.t() | nil,
            current_stage_id: String.t() | nil,
            stage_started_at: DateTime.t() | nil,
            last_evidence_at: DateTime.t() | nil,
            heartbeat_ref: reference() | nil,
            escalation_count: non_neg_integer(),
            status: :dispatching | :running | :stalled | :complete | :escalated
          }

    defstruct [
      :task_id,
      :assignee,
      :execution_space_id,
      :current_stage_id,
      :stage_started_at,
      :last_evidence_at,
      :heartbeat_ref,
      escalation_count: 0,
      status: :dispatching
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────

  @doc "Start a TaskRouter for the given task assignment."
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    assignee = Keyword.fetch!(opts, :assignee)
    name = via(task_id)
    GenServer.start_link(__MODULE__, %{task_id: task_id, assignee: assignee}, name: name)
  end

  @doc "Stop the router for the given task."
  def stop(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :not_found}
    end
  end

  @doc "Return the current status of the router for the given task."
  def current_status(task_id) do
    GenServer.call(via(task_id), :current_status)
  end

  defp via(task_id) do
    {:via, Registry, {Platform.Orchestration.Registry, task_id}}
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(%{task_id: task_id, assignee: assignee}) do
    Tasks.subscribe_board()

    execution_space_id =
      case ExecutionSpace.find_or_create(task_id) do
        {:ok, space} ->
          space.id

        {:error, reason} ->
          Logger.warning(
            "[TaskRouter] failed to create execution space for #{task_id}: #{inspect(reason)}"
          )

          nil
      end

    state = %State{
      task_id: task_id,
      assignee: assignee,
      execution_space_id: execution_space_id
    }

    # Schedule initial dispatch on next tick
    send(self(), :dispatch)

    {:ok, state}
  end

  @impl true
  def handle_call(:current_status, _from, state) do
    reply = %{
      task_id: state.task_id,
      assignee: state.assignee,
      execution_space_id: state.execution_space_id,
      status: state.status,
      current_stage_id: state.current_stage_id,
      escalation_count: state.escalation_count,
      stage_started_at: state.stage_started_at,
      last_evidence_at: state.last_evidence_at
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    task = Tasks.get_task_detail(state.task_id)

    if task do
      plan = Tasks.current_plan(state.task_id)
      stage = current_running_stage(plan)
      context = ContextAssembler.build(state.task_id)
      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # Post log message to execution space
      if state.execution_space_id do
        stage_count = if plan, do: length(plan.stages || []), else: 0
        stage_pos = if stage, do: stage.position, else: 1

        log_content =
          "Task assigned: #{task.title} | Stage: #{stage_pos}/#{stage_count} | Assignee: #{state.assignee.id} | Heartbeat: #{heartbeat_interval_min(stage)}min"

        ExecutionSpace.post_log(state.execution_space_id, log_content)

        ExecutionSpace.post_engagement(state.execution_space_id, prompt,
          metadata: %{"reason" => "task_assigned"}
        )
      end

      dispatch_attention(state.assignee, state.task_id, "task_assigned", context, prompt)

      state =
        state
        |> Map.put(:status, :running)
        |> maybe_set_stage(stage)
        |> schedule_heartbeat()

      {:noreply, state}
    else
      Logger.warning("[TaskRouter] task #{state.task_id} not found, stopping")
      {:stop, :normal, state}
    end
  end

  def handle_info(:heartbeat, state) do
    state = %{state | heartbeat_ref: nil}

    stage_type = current_stage_type(state)

    if HeartbeatScheduler.manual_approval?(stage_type) do
      {:noreply, schedule_heartbeat(state)}
    else
      task = Tasks.get_task_detail(state.task_id)

      if task do
        elapsed = elapsed_seconds(state.stage_started_at)
        stall_threshold = HeartbeatScheduler.stall_threshold_ms(stage_type)

        if stall_threshold && elapsed * 1_000 >= stall_threshold do
          {:noreply, handle_possible_stall(state, task)}
        else
          send_heartbeat(state, task)
          {:noreply, schedule_heartbeat(state)}
        end
      else
        {:noreply, schedule_heartbeat(state)}
      end
    end
  end

  # Board PubSub: task updated for our task
  def handle_info({:task_updated, %{id: task_id} = _task}, %State{task_id: task_id} = state) do
    state =
      state
      |> Map.put(:last_evidence_at, DateTime.utc_now())
      |> reset_escalation()
      |> schedule_heartbeat()

    {:noreply, state}
  end

  # Board PubSub: stage transitioned
  def handle_info({:stage_transitioned, stage}, %State{} = state) do
    # Only react if this stage belongs to our task's current plan
    plan = Tasks.current_plan(state.task_id)

    if plan && stage.plan_id == plan.id do
      state =
        state
        |> Map.put(:current_stage_id, stage.id)
        |> Map.put(:stage_started_at, DateTime.utc_now())
        |> Map.put(:last_evidence_at, DateTime.utc_now())
        |> reset_escalation()
        |> schedule_heartbeat()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Ignore unrelated board events
  def handle_info({:task_updated, _task}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_heartbeat(state)

    # Archive execution space on shutdown (best-effort — DB may be unavailable)
    if state.execution_space_id do
      try do
        ExecutionSpace.post_log(
          state.execution_space_id,
          "Task router stopped for task #{state.task_id}"
        )

        ExecutionSpace.archive(state.task_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Dispatch helpers ───────────────────────────────────────────────────

  defp dispatch_attention(%{type: :federated, id: runtime_id}, task_id, reason, context, prompt) do
    payload = %{
      signal: %{reason: reason, task_id: task_id},
      context: context,
      message: %{content: prompt}
    }

    topic = "runtime:#{runtime_id}"

    case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
      :ok ->
        Logger.info("[TaskRouter] dispatched #{reason} to #{topic} for task #{task_id}")
        :ok

      {:error, err} ->
        Logger.error("[TaskRouter] broadcast failed to #{topic}: #{inspect(err)}")
        {:error, :broadcast_failed}
    end
  end

  defp send_heartbeat(state, task) do
    plan = Tasks.current_plan(state.task_id)
    stage = find_stage(plan, state.current_stage_id)
    elapsed = elapsed_seconds(state.stage_started_at)

    pending_validations =
      if stage do
        (stage.validations || [])
        |> Enum.filter(&(&1.status in ["pending", "running"]))
      else
        []
      end

    context = ContextAssembler.build(state.task_id)
    prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, elapsed, pending_validations)

    # Post heartbeat as engagement message (triggers attention routing)
    if state.execution_space_id do
      ExecutionSpace.post_engagement(state.execution_space_id, prompt,
        metadata: %{"reason" => "task_heartbeat"}
      )
    end

    dispatch_attention(state.assignee, state.task_id, "task_heartbeat", context, prompt)
  end

  # ── Heartbeat scheduling ───────────────────────────────────────────────

  defp schedule_heartbeat(state) do
    state = cancel_heartbeat(state)
    stage_type = current_stage_type(state)

    case HeartbeatScheduler.interval_ms(stage_type) do
      nil ->
        # manual_approval — no heartbeat
        state

      interval_ms ->
        ref = Process.send_after(self(), :heartbeat, interval_ms)
        %{state | heartbeat_ref: ref}
    end
  end

  defp cancel_heartbeat(%{heartbeat_ref: nil} = state), do: state

  defp cancel_heartbeat(%{heartbeat_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | heartbeat_ref: nil}
  end

  # ── Stall / escalation ────────────────────────────────────────────────

  defp handle_possible_stall(state, task) do
    stage_type = current_stage_type(state)
    max_esc = HeartbeatScheduler.max_escalations(stage_type) || 2
    new_count = state.escalation_count + 1

    # Post stall detection log
    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Stall detected: no evidence for stage #{state.current_stage_id || "unknown"} | Escalation #{new_count}/#{max_esc}"
      )
    end

    if new_count >= max_esc do
      escalate(state, task)
    else
      # Send heartbeat and bump escalation count
      send_heartbeat(state, task)
      state = %{state | escalation_count: new_count}
      schedule_heartbeat(state)
    end
  end

  defp escalate(state, _task) do
    Logger.warning(
      "[TaskRouter] task #{state.task_id} stalled after #{state.escalation_count + 1} escalations"
    )

    state = %{state | status: :stalled, escalation_count: state.escalation_count + 1}

    # Post stall/escalation log to execution space
    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Escalation: task stalled after #{state.escalation_count} missed heartbeats | Assignee: #{state.assignee.id}"
      )
    end

    # Broadcast stall event to PubSub
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      "tasks:board",
      {:task_stalled, state.task_id, state.assignee, :heartbeat_timeout}
    )

    # Enter slower polling mode (30 min) after escalation
    state = cancel_heartbeat(state)
    ref = Process.send_after(self(), :heartbeat, 30 * 60_000)
    %{state | heartbeat_ref: ref}
  end

  defp reset_escalation(state) do
    if state.status == :stalled do
      %{state | status: :running, escalation_count: 0}
    else
      %{state | escalation_count: 0}
    end
  end

  # ── Stage helpers ──────────────────────────────────────────────────────

  defp maybe_set_stage(state, nil), do: state

  defp maybe_set_stage(state, stage) do
    %{
      state
      | current_stage_id: stage.id,
        stage_started_at: stage.started_at || DateTime.utc_now()
    }
  end

  defp current_running_stage(nil), do: nil

  defp current_running_stage(plan) do
    (plan.stages || [])
    |> Enum.find(&(&1.status == "running"))
  end

  defp current_stage_type(%State{current_stage_id: nil}), do: "coding"

  defp current_stage_type(%State{task_id: task_id, current_stage_id: stage_id}) do
    plan = Tasks.current_plan(task_id)
    stage = find_stage(plan, stage_id)
    if stage, do: stage.name, else: "coding"
  end

  defp find_stage(nil, _stage_id), do: nil

  defp find_stage(plan, stage_id) do
    Enum.find(plan.stages || [], &(&1.id == stage_id))
  end

  defp elapsed_seconds(nil), do: 0

  defp elapsed_seconds(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) |> max(0)
  end

  defp heartbeat_interval_min(nil), do: 10

  defp heartbeat_interval_min(stage) do
    case HeartbeatScheduler.interval_ms(stage.name) do
      nil -> 0
      ms -> div(ms, 60_000)
    end
  end
end
