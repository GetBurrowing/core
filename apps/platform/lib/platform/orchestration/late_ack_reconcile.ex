defmodule Platform.Orchestration.LateAckReconcile do
  @moduledoc """
  Clears a no-ack block when the timed-out dispatch's owner acks late
  (task 01a0e7ac stage 2).

  ## Why this lives at the event chokepoint, not in the router

  When `TaskRouter.fire_no_ack_alert/2` moves a task to `blocked`, the
  `TaskRouterWatcher` stops that task's router and `terminate/2` clears the
  ETS lease. A late `execution.acked` therefore has no router to consume it,
  and `task_ack` finds no lease, so it skips the ownership check and just
  persists the row. Both ack transports (the MCP `task_ack` tool and the
  RuntimeChannel socket) reach `RuntimeSupervision.record_event/1`, which
  calls `maybe_reconcile/3` after a NEW `execution.acked` row commits.

  ## What must hold before anything is cleared

  The decision is keyed on the block's CAUSE (`metadata["blocked_cause"]`,
  written by stage 1), never on the `blocked_reason` sentence or on `status`
  alone. Every one of these must hold:

    * the task is `blocked`;
    * the cause kind is `execution.no_ack_timeout`. A safety-net block, a
      block set by a person or agent through `task_update`, a dependency
      block, and any block with no cause are never cleared here;
    * the ack names the cause's stage, AND that stage is the running stage
      of the current plan. An ack for any other stage is still persisted by
      the caller, it just clears nothing: it says nothing about whether
      anyone took the dispatch that timed out;
    * the acking runtime is the cause's `runtime_id`, the lease owner when
      the alarm fired. This replaces the ETS ownership check the late path
      skips. A nil recorded owner never matches;
    * there is no open `needs_human` hold on the stage. An executor that
      acked and then filed `report_blocker(needs_human: true)` keeps the
      task blocked.

  The task then returns to the cause's `prior_status` (fallback
  `in_progress` when that is nil or not a valid edge out of `blocked`). The
  ticket said "back to in_progress", but deploy stages block from
  `deploying`, and forcing those to `in_progress` would mis-phase the
  deployer, so the recorded status is restored.

  The write is a compare-and-set on the `updated_at` just read: a person who
  moves or re-blocks the task in between wins, and the result is
  `{:skip, :stale_base}`.

  Resume uses the existing path. The reconcile broadcasts
  `{:task_updated, ...}` (the CAS transition alone broadcasts only when the
  phase pointer moves), the watcher starts a router, and that router's boot
  dispatch finds the durable owner-scoped ack and withholds the re-prompt.

  ## Two-sided ordering (stage 3)

  This is the ACK side of a two-sided ordering: the ack row is written, THEN
  this checks for the block. The alarm side (`TaskRouter.do_fire_no_ack/3`)
  writes the block, THEN re-checks for the owner's ack and calls
  `maybe_reconcile/3` itself. An ack that commits between the alarm's durable
  read and its stamp is therefore caught by the alarm side, and a stamp that
  commits before the ack row is caught here.
  """

  require Logger

  alias Platform.Orchestration.{ExecutionLease, ExecutionSpace, RuntimeSupervision}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Task, TransitionActor}

  @cause_kind "execution.no_ack_timeout"
  @via "late_ack_reconciled"
  @fallback_status "in_progress"

  @type skip_reason ::
          :not_found
          | :not_blocked
          | :no_cause
          | :other_cause
          | :stage_mismatch
          | :stage_not_running
          | :not_owner
          | :needs_human_hold
          | :stale_base
          | :transition_refused

  @doc """
  Re-read the task and clear its no-ack block if the ack from `runtime_id`
  for `stage_id` qualifies (see the moduledoc). Never raises for a bad id.
  """
  @spec maybe_reconcile(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:reconciled, Task.t()} | {:skip, skip_reason()}
  def maybe_reconcile(task_id, stage_id, runtime_id) when is_binary(task_id) do
    case Tasks.get_task_record(task_id) do
      %Task{} = task -> reconcile(task, stage_id, runtime_id)
      nil -> {:skip, :not_found}
    end
  end

  def maybe_reconcile(_task_id, _stage_id, _runtime_id), do: {:skip, :not_found}

  @doc """
  The checks and the compare-and-set write against a task the caller has
  ALREADY read. The write is guarded on `task.updated_at`, so a task that
  moved after `task` was read is left alone (`{:skip, :stale_base}`).
  `maybe_reconcile/3` is the entry point; this is public so the guard can be
  exercised with a stale read.
  """
  @spec reconcile(Task.t(), String.t() | nil, String.t() | nil) ::
          {:reconciled, Task.t()} | {:skip, skip_reason()}
  def reconcile(%Task{} = task, stage_id, runtime_id) do
    with :ok <- check_blocked(task),
         {:ok, cause} <- check_cause(task),
         :ok <- check_stage(task, cause, stage_id),
         :ok <- check_owner(cause, runtime_id),
         :ok <- check_no_hold(task, stage_id, runtime_id) do
      write(task, cause, stage_id, runtime_id)
    end
  end

  # ── checks ─────────────────────────────────────────────────────────────

  defp check_blocked(%Task{status: "blocked"}), do: :ok
  defp check_blocked(_task), do: {:skip, :not_blocked}

  defp check_cause(%Task{metadata: %{"blocked_cause" => %{"kind" => @cause_kind} = cause}}),
    do: {:ok, cause}

  defp check_cause(%Task{metadata: %{"blocked_cause" => %{}}}), do: {:skip, :other_cause}
  defp check_cause(_task), do: {:skip, :no_cause}

  defp check_stage(%Task{id: task_id}, %{"stage_id" => cause_stage}, stage_id)
       when is_binary(stage_id) and stage_id == cause_stage do
    case running_stage_id(task_id) do
      ^stage_id -> :ok
      _ -> {:skip, :stage_not_running}
    end
  end

  defp check_stage(_task, _cause, _stage_id), do: {:skip, :stage_mismatch}

  defp check_owner(%{"runtime_id" => owner}, runtime_id)
       when is_binary(owner) and owner == runtime_id,
       do: :ok

  defp check_owner(_cause, _runtime_id), do: {:skip, :not_owner}

  defp check_no_hold(%Task{id: task_id}, stage_id, runtime_id) do
    cond do
      RuntimeSupervision.needs_human_hold(task_id, stage_id, runtime_id) ->
        {:skip, :needs_human_hold}

      needs_human_lease?(RuntimeSupervision.current_lease_for_stage(task_id, stage_id)) ->
        {:skip, :needs_human_hold}

      true ->
        :ok
    end
  end

  defp needs_human_lease?(%ExecutionLease{} = lease),
    do: RuntimeSupervision.needs_human_hold?(lease)

  defp needs_human_lease?(_), do: false

  defp running_stage_id(task_id) do
    case Tasks.current_plan(task_id) do
      %{stages: stages} when is_list(stages) ->
        case Enum.find(stages, &(&1.status == "running")) do
          %{id: id} -> id
          nil -> nil
        end

      _ ->
        nil
    end
  end

  # ── write ──────────────────────────────────────────────────────────────

  defp write(%Task{} = task, cause, stage_id, runtime_id) do
    target = target_status(cause["prior_status"])

    TransitionActor.with_actor(:system, @via, fn ->
      Tasks.transition_task_status_if_unmodified(task, target, task.updated_at)
    end)
    |> case do
      {:ok, %Task{} = updated} ->
        # `transition_task_status_if_unmodified/3` broadcasts `{:task_updated,
        # _}` only when the phase pointer moves. The watcher restarts the
        # router off this broadcast, so it is sent unconditionally, with the
        # preloads `update_task/3` uses.
        Tasks.broadcast_board(
          {:task_updated, Repo.preload(updated, [:project, :epic, :sponsor, plans: :stages])}
        )

        seconds = seconds_since(cause["at"])
        announce(updated, stage_id, runtime_id, target, seconds)
        {:reconciled, updated}

      {:error, {:stale_base, _}} ->
        {:skip, :stale_base}

      {:error, reason} ->
        Logger.warning(
          "[LateAckReconcile] task #{task.id} stage #{stage_id} — blocked -> #{target} refused: #{inspect(reason)}"
        )

        {:skip, :transition_refused}
    end
  end

  defp target_status(prior) when is_binary(prior) do
    if prior in Map.get(Tasks.valid_task_transitions(), "blocked", []),
      do: prior,
      else: @fallback_status
  end

  defp target_status(_prior), do: @fallback_status

  defp seconds_since(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :second)
      _ -> nil
    end
  end

  defp seconds_since(_at), do: nil

  defp announce(%Task{id: task_id}, stage_id, runtime_id, target, seconds) do
    gap = if seconds, do: "#{seconds}s after the block", else: "after the block"

    content =
      "Late ack reconciled: runtime #{runtime_id} acked stage #{stage_id} #{gap}. " <>
        "The no-ack block is cleared and the task is back in #{target}."

    Logger.info("[LateAckReconcile] task #{task_id} — #{content}")

    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: space_id} ->
        ExecutionSpace.post_engagement(space_id, content,
          metadata: %{"reason" => @via, "stage_id" => stage_id}
        )

      _ ->
        :ok
    end
  end
end
