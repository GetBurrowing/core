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

  alias Platform.Execution.CredentialLease

  alias Platform.Orchestration.{
    ContextAssembler,
    ExecutionSpace,
    HeartbeatScheduler,
    RuntimeSupervision
  }

  alias Platform.Tasks
  alias Platform.Tasks.{DeployResolver, ReviewRequests}

  # Cooldown window for runtime activity: if the runtime sent a progress/heartbeat
  # event within this window, suppress the next heartbeat to avoid interrupting
  # an actively-streaming agent. Half the shortest non-planning interval (coding: 10 min).
  @runtime_activity_cooldown_ms 2 * 60_000

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
            last_runtime_event_at: DateTime.t() | nil,
            last_dispatch_at: DateTime.t() | nil,
            task_status: String.t() | nil,
            lease_status: String.t() | nil,
            heartbeat_ref: reference() | nil,
            deploy_lease: CredentialLease.t() | nil,
            escalation_count: non_neg_integer(),
            status: :dispatching | :running | :stalled | :complete | :escalated | :waiting_human
          }

    defstruct [
      :task_id,
      :assignee,
      :execution_space_id,
      :current_stage_id,
      :stage_started_at,
      :last_evidence_at,
      :last_runtime_event_at,
      :last_dispatch_at,
      :task_status,
      :lease_status,
      :heartbeat_ref,
      :deploy_lease,
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

    # Hydrate task_status from DB so heartbeat guards can check the phase
    # without a DB query on every heartbeat tick.
    initial_task_status =
      case Tasks.get_task_detail(task_id) do
        %{status: s} -> s
        _ -> nil
      end

    state =
      %State{
        task_id: task_id,
        assignee: assignee,
        execution_space_id: execution_space_id,
        task_status: initial_task_status
      }
      |> maybe_hydrate_from_lease()
      |> maybe_hydrate_current_stage()

    case state.lease_status do
      "active" ->
        state = maybe_mark_review_task_in_review(state)

        if waiting_for_human_review?(state) do
          send(self(), :dispatch)
          {:ok, %{state | status: :waiting_human}}
        else
          {:ok, schedule_heartbeat(%{state | status: :running})}
        end

      "blocked" ->
        {:ok, %{state | status: :waiting_human}}

      _ ->
        # Schedule initial dispatch on next tick
        send(self(), :dispatch)
        {:ok, state}
    end
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
      last_evidence_at: state.last_evidence_at,
      last_runtime_event_at: state.last_runtime_event_at,
      last_dispatch_at: state.last_dispatch_at,
      task_status: state.task_status,
      lease_status: state.lease_status
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    task = Tasks.get_task_detail(state.task_id)

    if task do
      plan = Tasks.current_plan(state.task_id)
      stage = current_running_stage(plan)

      # Lease deploy credentials if this is a deploy stage
      state = maybe_lease_deploy_credentials(state, task, stage)

      context = ContextAssembler.build(state.task_id, state.deploy_lease)
      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      case dispatch_attention(state.assignee, state.task_id, "task_assigned", context, prompt) do
        :ok ->
          # Post log message to execution space after successful runtime dispatch so
          # boot retries do not duplicate task-assigned chatter.
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

          state =
            state
            |> Map.put(:status, :running)
            |> Map.put(:last_dispatch_at, DateTime.utc_now())
            |> Map.put(:task_status, task.status)
            |> maybe_set_stage(stage)
            |> maybe_mark_review_task_in_review()

          state =
            if waiting_for_human_review?(state) do
              state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)
            else
              schedule_heartbeat(state)
            end

          {:noreply, state}

        {:error, :endpoint_not_ready} ->
          Logger.warning(
            "[TaskRouter] endpoint not ready for task #{state.task_id}; retrying dispatch"
          )

          Process.send_after(self(), :dispatch, 1_000)
          {:noreply, state}

        {:error, _reason} ->
          state =
            state
            |> Map.put(:status, :running)
            |> Map.put(:last_dispatch_at, DateTime.utc_now())
            |> Map.put(:task_status, task.status)
            |> maybe_set_stage(stage)
            |> maybe_mark_review_task_in_review()

          state =
            if waiting_for_human_review?(state) do
              state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)
            else
              schedule_heartbeat(state)
            end

          {:noreply, state}
      end
    else
      Logger.warning("[TaskRouter] task #{state.task_id} not found, stopping")
      {:stop, :normal, state}
    end
  end

  def handle_info(:heartbeat, %State{status: :waiting_human} = state) do
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    state = %{state | heartbeat_ref: nil}

    stage_type = heartbeat_stage_type(state)

    if HeartbeatScheduler.manual_approval?(stage_type) do
      {:noreply, schedule_heartbeat(state)}
    else
      interval_ms = HeartbeatScheduler.interval_ms(stage_type) || 0

      cond do
        # Guard 1: Suppress heartbeat if we dispatched within the current heartbeat interval.
        # The agent hasn't had a full interval to respond yet — don't interrupt.
        dispatch_within_interval?(state, interval_ms) ->
          Logger.debug(
            "[TaskRouter] heartbeat suppressed for task #{state.task_id}: dispatch too recent"
          )

          {:noreply, schedule_heartbeat(state)}

        # Guard 2: Suppress heartbeat if the runtime sent a progress/heartbeat event recently.
        # The agent is actively streaming — don't interrupt with a nudge.
        runtime_activity_within_cooldown?(state) ->
          Logger.debug(
            "[TaskRouter] heartbeat suppressed for task #{state.task_id}: runtime activity within cooldown"
          )

          {:noreply, schedule_heartbeat(state)}

        # Guard 3: Plan-aware gating for the planning phase.
        # Defensive catch for missed PubSub events — check plan status directly.
        state.task_status == "planning" ->
          {:noreply, handle_planning_heartbeat(state)}

        true ->
          task = Tasks.get_task_detail(state.task_id)

          if task do
            idle_ms = latest_activity_age_ms(state)
            stall_threshold = HeartbeatScheduler.stall_threshold_ms(stage_type)

            if stall_threshold && idle_ms >= stall_threshold do
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
  end

  # Board PubSub: task updated for our task
  def handle_info({:task_updated, %{id: task_id} = task}, %State{task_id: task_id} = state) do
    task_status = Map.get(task, :status) || Map.get(task, "status")

    state =
      state
      |> Map.put(:last_evidence_at, DateTime.utc_now())
      |> then(fn s -> if task_status, do: Map.put(s, :task_status, task_status), else: s end)
      |> reset_escalation()

    state =
      if waiting_for_human_review?(state) do
        state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)
      else
        schedule_heartbeat(state)
      end

    {:noreply, state}
  end

  def handle_info({:runtime_event, event}, %State{task_id: task_id} = state)
      when event.task_id == task_id do
    {:noreply, apply_runtime_event(state, event)}
  end

  # Board PubSub: stage transitioned
  def handle_info({:stage_transitioned, stage}, %State{} = state) do
    # Only react if this stage belongs to our task's current plan
    plan = Tasks.current_plan(state.task_id)

    if plan && stage.plan_id == plan.id do
      # Revoke deploy lease when a deploy stage completes (passed or failed)
      state =
        if stage.status in ["passed", "failed"] do
          revoke_deploy_lease(state)
        else
          state
        end

      state =
        state
        |> Map.put(:current_stage_id, stage.id)
        |> Map.put(:stage_started_at, DateTime.utc_now())
        |> Map.put(:last_evidence_at, DateTime.utc_now())
        |> reset_escalation()

      # If a review or deploy stage fails, bounce the task back to in_progress
      state =
        if stage.status == "failed" do
          task = Tasks.get_task_detail(state.task_id)

          cond do
            # Deploy stage failed — bounce deploying → in_progress
            task && task.status == "deploying" ->
              handle_deploy_stage_failure(state, task, stage)

            # Review stage failed — bounce in_review → in_progress
            task && task.status == "in_review" ->
              case Tasks.transition_task(task, "in_progress") do
                {:ok, _updated} ->
                  Logger.info(
                    "[TaskRouter] review stage failed — bounced task #{state.task_id} back to in_progress"
                  )

                {:error, reason} ->
                  Logger.warning(
                    "[TaskRouter] failed to bounce task #{state.task_id} to in_progress: #{inspect(reason)}"
                  )
              end

            true ->
              :ok
          end

          # Re-dispatch so the agent picks up the in_progress prompt
          send(self(), :dispatch)
          state |> Map.put(:status, :running) |> schedule_heartbeat()
        else
          state = maybe_mark_review_task_in_review(state)

          if waiting_for_human_review?(state) do
            if stage.status == "running" do
              send(self(), :dispatch)
            end

            state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)
          else
            # When a new stage becomes running, re-dispatch so the agent gets
            # an updated prompt that describes the current stage
            if stage.status == "running" do
              send(self(), :dispatch)
            end

            schedule_heartbeat(state)
          end
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Board PubSub: plan completed for our task
  # in_progress → in_review (execution plan done, hand off to review)
  # in_review   → deploying (review plan done, deploy stage injected by PlanEngine)
  # deploying   → done      (deploy stage passed)
  def handle_info(
        {:plan_updated, %{task_id: task_id, status: "completed"} = _plan},
        %State{task_id: task_id} = state
      ) do
    task = Tasks.get_task_detail(task_id)

    if task do
      {target_status, log_label} =
        case task.status do
          "in_progress" -> {"in_review", "execution plan completed"}
          "in_review" -> {"deploying", "review plan completed"}
          "deploying" -> {"done", "deploy completed"}
          other -> {nil, other}
        end

      if target_status do
        case Tasks.transition_task(task, target_status) do
          {:ok, _updated} ->
            Logger.info(
              "[TaskRouter] #{log_label} — transitioned task #{task_id} to #{target_status}"
            )

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to transition task #{task_id} to #{target_status}: #{inspect(reason)}"
            )
        end
      end
    end

    # Re-dispatch so the agent picks up the updated status prompt
    send(self(), :dispatch)
    {:noreply, state}
  end

  # Board PubSub: plan updated for our task
  def handle_info({:plan_updated, %{task_id: task_id} = plan}, %State{task_id: task_id} = state) do
    state =
      case plan.status do
        "pending_review" ->
          state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)

        "approved" ->
          state
          |> Map.put(:status, :running)
          |> ensure_execution_stage_started(task_id)
          |> schedule_heartbeat()

        "rejected" ->
          state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)

        _other ->
          state
      end

    {:noreply, state}
  end

  # Ignore unrelated board events
  def handle_info({:plan_updated, _plan}, state), do: {:noreply, state}
  def handle_info({:task_updated, _task}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_heartbeat(state)
    revoke_deploy_lease(state)

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
    task_status = context[:task][:status] || context[:task]["status"]
    space_id = context[:execution_space_id]

    payload = %{
      signal: %{reason: reason, task_id: task_id, task_status: task_status, space_id: space_id},
      context: context,
      message: %{content: prompt, author: "TaskRouter"}
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
  rescue
    error in ArgumentError ->
      Logger.warning(
        "[TaskRouter] endpoint not ready while dispatching #{reason} for task #{task_id}: #{Exception.message(error)}"
      )

      {:error, :endpoint_not_ready}
  end

  # Defensive plan-aware heartbeat gating for the planning phase.
  # Uses latest_plan (any status) instead of current_plan (approved/completed only)
  # because during planning the plan may be in draft or pending_review.
  defp handle_planning_heartbeat(state) do
    plan = Tasks.latest_plan(state.task_id)

    cond do
      # Plan submitted and awaiting human review — suppress heartbeat entirely
      # and move to waiting_human state (defensive catch for missed PubSub).
      plan && plan.status == "pending_review" ->
        Logger.info(
          "[TaskRouter] heartbeat suppressed for task #{state.task_id}: plan is pending_review (defensive catch)"
        )

        state |> cancel_heartbeat() |> Map.put(:status, :waiting_human)

      # Plan is still being drafted — agent is actively working on it.
      # Skip this heartbeat but reschedule (don't interrupt the drafting process).
      plan && plan.status == "draft" ->
        Logger.debug(
          "[TaskRouter] heartbeat suppressed for task #{state.task_id}: plan is in draft"
        )

        schedule_heartbeat(state)

      # Plan was rejected — agent needs a nudge to revise.
      # Fall through to normal heartbeat behavior.
      plan && plan.status == "rejected" ->
        task = Tasks.get_task_detail(state.task_id)

        if task do
          send_heartbeat(state, task)
          schedule_heartbeat(state)
        else
          schedule_heartbeat(state)
        end

      # No plan exists yet — send heartbeat normally so agent creates one,
      # but only if the dispatch cooldown has passed (handled by guard 1 above).
      true ->
        task = Tasks.get_task_detail(state.task_id)

        if task do
          send_heartbeat(state, task)
          schedule_heartbeat(state)
        else
          schedule_heartbeat(state)
        end
    end
  end

  defp send_heartbeat(state, task) do
    # During planning, use latest_plan to include draft/pending_review plans
    # that current_plan (approved/completed only) would miss.
    plan =
      if state.task_status == "planning" do
        Tasks.latest_plan(state.task_id)
      else
        Tasks.current_plan(state.task_id)
      end

    stage = find_stage(plan, state.current_stage_id)
    elapsed = elapsed_seconds(state.stage_started_at)

    pending_validations =
      if stage do
        (stage.validations || [])
        |> Enum.filter(&(&1.status in ["pending", "running"]))
      else
        []
      end

    context = ContextAssembler.build(state.task_id, state.deploy_lease)
    prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, elapsed, pending_validations, plan)

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
    stage_type = heartbeat_stage_type(state)

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

  defp handle_possible_stall(%State{status: :waiting_human} = state, _task), do: state

  defp handle_possible_stall(state, task) do
    stage_type = heartbeat_stage_type(state)
    max_esc = HeartbeatScheduler.max_escalations(stage_type) || 2
    new_count = state.escalation_count + 1

    idle_seconds = div(latest_activity_age_ms(state), 1_000)

    # Post stall detection log
    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Stall detected: no runtime activity for #{idle_seconds}s on stage #{state.current_stage_id || "unknown"} | Escalation #{new_count}/#{max_esc}"
      )
    end

    if new_count >= max_esc do
      recover_or_escalate(state, task, idle_seconds)
    else
      # Send heartbeat and bump escalation count
      send_heartbeat(state, task)
      state = %{state | escalation_count: new_count}
      schedule_heartbeat(state)
    end
  end

  defp recover_or_escalate(%State{} = state, task, idle_seconds) do
    if silent_active_runtime?(state) do
      recover_silent_runtime(state, task, idle_seconds)
    else
      escalate(state, task)
    end
  end

  defp recover_silent_runtime(%State{} = state, task, idle_seconds) do
    phase = runtime_phase_for_task(task)
    abandoned = RuntimeSupervision.abandon_current_lease_for_task(state.task_id, phase)

    Logger.warning(
      "[TaskRouter] task #{state.task_id} detected silent #{phase} runtime after #{idle_seconds}s; abandoned #{abandoned} lease(s) and re-dispatching"
    )

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Watchdog: runtime went silent for #{idle_seconds}s during #{phase}; abandoning the current attempt and launching a fresh retry"
      )
    end

    send(self(), :dispatch)

    state
    |> cancel_heartbeat()
    |> Map.put(:status, :dispatching)
    |> Map.put(:lease_status, "abandoned")
    |> Map.put(:escalation_count, 0)
  end

  defp silent_active_runtime?(%State{lease_status: "active", last_runtime_event_at: %DateTime{}}),
    do: true

  defp silent_active_runtime?(_state), do: false

  defp runtime_phase_for_task(%{status: "planning"}), do: "planning"
  defp runtime_phase_for_task(%{status: "in_review"}), do: "review"
  defp runtime_phase_for_task(%{status: "deploying"}), do: "deploying"
  defp runtime_phase_for_task(_task), do: "execution"

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

  defp maybe_hydrate_from_lease(%State{} = state) do
    case RuntimeSupervision.current_lease_for_task(state.task_id) do
      %{runtime_id: runtime_id} = lease when runtime_id == state.assignee.id ->
        last_runtime_event_at =
          lease.last_progress_at || lease.last_heartbeat_at || lease.started_at

        %{
          state
          | last_runtime_event_at: last_runtime_event_at,
            lease_status: lease.status
        }

      _ ->
        state
    end
  end

  defp maybe_hydrate_current_stage(%State{} = state) do
    plan = Tasks.current_plan(state.task_id)
    running_stage = current_running_stage(plan)

    maybe_set_stage(state, running_stage)
  end

  defp apply_runtime_event(state, event) do
    event_time = event.occurred_at || DateTime.utc_now()
    lease_status = event.lease && event.lease.status

    base_state =
      state
      |> Map.put(:last_runtime_event_at, event_time)
      |> Map.put(:lease_status, lease_status || state.lease_status)
      |> reset_escalation()

    case event.event_type do
      type
      when type in [
             "assignment.accepted",
             "execution.started",
             "execution.heartbeat",
             "execution.progress",
             "execution.unblocked"
           ] ->
        base_state
        |> Map.put(:status, :running)
        |> schedule_heartbeat()

      "execution.blocked" ->
        base_state
        |> cancel_heartbeat()
        |> Map.put(:status, :waiting_human)

      "execution.finished" ->
        base_state
        |> cancel_heartbeat()
        |> Map.put(:status, :running)

      type when type in ["execution.failed", "execution.abandoned", "assignment.rejected"] ->
        base_state
        |> cancel_heartbeat()
        |> Map.put(:status, :stalled)

      _ ->
        base_state
    end
  end

  # Returns true if `last_dispatch_at` is within the given interval, meaning the
  # agent hasn't had a full heartbeat cycle to respond to the dispatch yet.
  defp dispatch_within_interval?(%State{last_dispatch_at: nil}, _interval_ms), do: false

  defp dispatch_within_interval?(%State{last_dispatch_at: dispatch_at}, interval_ms) do
    DateTime.diff(DateTime.utc_now(), dispatch_at, :millisecond) < interval_ms
  end

  # Returns true if the runtime sent a progress/heartbeat event within the
  # cooldown window, indicating the agent is actively streaming.
  defp runtime_activity_within_cooldown?(%State{last_runtime_event_at: nil}), do: false

  defp runtime_activity_within_cooldown?(%State{last_runtime_event_at: event_at}) do
    DateTime.diff(DateTime.utc_now(), event_at, :millisecond) < @runtime_activity_cooldown_ms
  end

  defp latest_activity_at(state) do
    [state.last_runtime_event_at, state.last_evidence_at, state.stage_started_at]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> DateTime.utc_now()
      values -> Enum.max_by(values, &DateTime.to_unix(&1, :microsecond))
    end
  end

  defp latest_activity_age_ms(state) do
    DateTime.diff(DateTime.utc_now(), latest_activity_at(state), :millisecond)
    |> max(0)
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

  defp maybe_transition_task_to_in_review(task_id) do
    case Tasks.get_task_detail(task_id) do
      %{status: "in_progress"} = task ->
        case Tasks.transition_task(task, "in_review") do
          {:ok, _updated} ->
            Logger.info(
              "[TaskRouter] review gate started — transitioned task #{task_id} to in_review"
            )

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to transition task #{task_id} to in_review on review gate: #{inspect(reason)}"
            )
        end

      _other ->
        :ok
    end
  end

  defp ensure_execution_stage_started(state, task_id) do
    task = Tasks.get_task_detail(task_id)
    plan = Tasks.current_plan(task_id)

    cond do
      task == nil or task.status != "in_progress" or is_nil(plan) ->
        state

      running_stage = current_running_stage(plan) ->
        send(self(), :dispatch)
        maybe_set_stage(state, running_stage)

      pending_stage = first_pending_stage(plan) ->
        case Platform.Tasks.PlanEngine.start_stage(pending_stage.id) do
          {:ok, started_stage} ->
            maybe_set_stage(state, started_stage)

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to start first execution stage for task #{task_id}: #{inspect(reason)}"
            )

            state
        end

      true ->
        send(self(), :dispatch)
        state
    end
  end

  defp current_running_stage(nil), do: nil

  defp current_running_stage(plan) do
    (plan.stages || [])
    |> Enum.find(&(&1.status == "running"))
  end

  defp first_pending_stage(nil), do: nil

  defp first_pending_stage(plan) do
    (plan.stages || [])
    |> Enum.find(&(&1.status == "pending"))
  end

  defp waiting_for_human_review?(%State{task_id: task_id} = state) do
    current_stage_type(state) == "manual_approval" and pending_review_request?(task_id)
  end

  defp heartbeat_stage_type(%State{} = state) do
    case current_stage_type(state) do
      "manual_approval" ->
        if pending_review_request?(state.task_id), do: "manual_approval", else: "review"

      other ->
        other
    end
  end

  defp pending_review_request?(task_id) do
    ReviewRequests.list_pending_for_task(task_id) != []
  end

  defp maybe_mark_review_task_in_review(%State{} = state) do
    if current_stage_type(state) == "manual_approval" do
      maybe_transition_task_to_in_review(state.task_id)
    end

    state
  end

  defp current_stage_type(%State{current_stage_id: nil}), do: "coding"

  defp current_stage_type(%State{task_id: task_id, current_stage_id: stage_id}) do
    plan = Tasks.current_plan(task_id)
    stage = find_stage(plan, stage_id)

    if stage do
      # Check if all remaining (pending) validations on this stage are manual_approval.
      # If so, treat the stage as a human gate — no heartbeat should fire.
      pending_validations =
        (stage.validations || [])
        |> Enum.filter(&(&1.status == "pending"))

      if pending_validations != [] &&
           Enum.all?(pending_validations, &(&1.kind == "manual_approval")) do
        "manual_approval"
      else
        infer_stage_type(stage.name)
      end
    else
      "coding"
    end
  end

  # Map human-readable stage names to cadence keys.
  # Falls back to "coding" for unrecognized names.
  defp infer_stage_type(name) do
    name_lower = String.downcase(name || "")

    cond do
      String.contains?(name_lower, "planning") -> "planning"
      String.contains?(name_lower, "review") -> "review"
      String.contains?(name_lower, "deploy") -> "deploying"
      String.contains?(name_lower, "ci") -> "ci_check"
      String.contains?(name_lower, "manual_approval") -> "manual_approval"
      true -> "coding"
    end
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

  # ── Deploy credential leasing ──────────────────────────────────────────

  # Deploy stall threshold — 15 minutes TTL for deploy leases
  @deploy_lease_ttl_seconds 900

  defp maybe_lease_deploy_credentials(%State{deploy_lease: existing} = state, _task, _stage)
       when not is_nil(existing) do
    # Already have an active lease — check validity
    if CredentialLease.valid?(existing) do
      state
    else
      # Lease expired — try to re-lease
      %{state | deploy_lease: nil}
      |> maybe_lease_deploy_credentials(Tasks.get_task_detail(state.task_id), nil)
    end
  end

  defp maybe_lease_deploy_credentials(%State{} = state, task, stage) do
    if deploy_stage?(stage) do
      lease_deploy_credentials(state, task, stage)
    else
      state
    end
  end

  defp lease_deploy_credentials(%State{} = state, task, stage) do
    task = Tasks.ensure_project_loaded(task)
    project = task.project

    if project do
      strategy = Tasks.resolve_deploy_strategy(task)
      target_name = get_in(strategy, ["config", "target"])

      if target_name do
        run_id = "#{state.task_id}:#{stage && stage.id}"

        case DeployResolver.resolve(project, target_name) do
          {:ok, target} ->
            case DeployResolver.lease_for_target(target, run_id, ttl: @deploy_lease_ttl_seconds) do
              {:ok, lease} ->
                Logger.info(
                  "[TaskRouter] leased deploy credentials for task #{state.task_id}, " <>
                    "target: #{target_name}, TTL: #{@deploy_lease_ttl_seconds}s"
                )

                if state.execution_space_id do
                  ExecutionSpace.post_log(
                    state.execution_space_id,
                    "Deploy credentials leased for target '#{target_name}' (TTL: #{div(@deploy_lease_ttl_seconds, 60)}min)"
                  )
                end

                %{state | deploy_lease: lease}

              {:error, reason} ->
                Logger.warning(
                  "[TaskRouter] failed to lease deploy credentials for task #{state.task_id}: #{inspect(reason)}"
                )

                state
            end

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to resolve deploy target '#{target_name}' for task #{state.task_id}: #{inspect(reason)}"
            )

            state
        end
      else
        # No target configured — deploy without credentials (agent uses its own)
        state
      end
    else
      state
    end
  end

  defp revoke_deploy_lease(%State{deploy_lease: nil} = state), do: state

  defp revoke_deploy_lease(%State{deploy_lease: lease} = state) do
    case CredentialLease.revoke(lease) do
      {:ok, _revoked} ->
        Logger.info("[TaskRouter] revoked deploy lease #{lease.id} for task #{state.task_id}")

        if state.execution_space_id do
          ExecutionSpace.post_log(
            state.execution_space_id,
            "Deploy credentials revoked (lease #{lease.id})"
          )
        end

      _ ->
        :ok
    end

    %{state | deploy_lease: nil}
  end

  defp deploy_stage?(nil), do: false

  defp deploy_stage?(stage) do
    name = String.downcase(stage.name || "")
    String.starts_with?(name, "deploy:")
  end

  # ── Deploy failure handling ────────────────────────────────────────────

  defp handle_deploy_stage_failure(%State{} = state, task, stage) do
    # Extract failure evidence from the stage's failed validations
    failed_validations = extract_failed_validations(stage)

    evidence_summary =
      failed_validations
      |> Enum.map(fn {kind, evidence} -> "#{kind}: #{summarize_evidence(evidence)}" end)
      |> Enum.join("; ")

    # Extract merge SHA for potential revert tracking
    merge_sha =
      failed_validations
      |> Enum.find_value(fn {_kind, evidence} ->
        Map.get(evidence, "sha") || Map.get(evidence, "merge_sha")
      end)

    # Transition task back to in_progress
    case Tasks.transition_task(task, "in_progress") do
      {:ok, _updated} ->
        Logger.info(
          "[TaskRouter] deploy stage failed — bounced task #{state.task_id} back to in_progress" <>
            if(merge_sha, do: " (merge SHA: #{merge_sha})", else: "")
        )

      {:error, reason} ->
        Logger.warning(
          "[TaskRouter] failed to bounce task #{state.task_id} to in_progress after deploy failure: #{inspect(reason)}"
        )
    end

    # Log to execution space with failure details
    if state.execution_space_id do
      log_parts = [
        "Deploy stage failed: #{evidence_summary}.",
        "Task returned to in_progress for retry.",
        if(merge_sha, do: "Merge SHA for potential revert: #{merge_sha}", else: nil)
      ]

      log_content = log_parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      ExecutionSpace.post_log(state.execution_space_id, log_content)
    end

    state
  end

  defp extract_failed_validations(stage) do
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    validations
    |> Enum.filter(fn v ->
      status = Map.get(v, :status) || Map.get(v, "status")
      status == "failed"
    end)
    |> Enum.map(fn v ->
      kind = Map.get(v, :kind) || Map.get(v, "kind") || "unknown"
      evidence = Map.get(v, :evidence) || Map.get(v, "evidence") || %{}
      {kind, evidence}
    end)
  end

  defp summarize_evidence(evidence) when is_map(evidence) do
    case Map.get(evidence, "conclusion") || Map.get(evidence, "reason") do
      nil ->
        case map_size(evidence) do
          0 -> "no details"
          _ -> inspect(evidence) |> String.slice(0, 200)
        end

      summary ->
        to_string(summary)
    end
  end

  defp summarize_evidence(_), do: "no details"
end
