defmodule Platform.Orchestration.ExecutionStatus do
  @moduledoc "Server projection of measured execution, independent of workflow status."
  import Ecto.Query
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{Plan, Stage, Task}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent, RuntimeSupervision}

  @recent_seconds 120
  @terminal ~w(execution.finished execution.failed execution.abandoned execution.turn_ended)

  def load(tasks, now \\ DateTime.utc_now(), scope \\ nil) do
    tasks = Enum.filter(tasks, &(&1.status == "in_progress")) |> Enum.uniq_by(& &1.id)
    ids = Enum.map(tasks, & &1.id)
    if ids == [], do: %{}, else: load_batch(tasks, ids, now, scope)
  end

  defp load_batch(tasks, ids, now, scope) do
    plans =
      Repo.all(
        from(p in Plan,
          where: p.task_id in ^ids and p.status in ["approved", "completed"],
          distinct: p.task_id,
          order_by: [p.task_id, desc: p.version]
        )
      )

    plan_ids = Enum.map(plans, & &1.id)

    stages =
      Repo.all(from(s in Stage, where: s.plan_id in ^plan_ids and s.status == "running"))
      |> Map.new(&{&1.plan_id, &1})

    plans = Map.new(plans, &{&1.task_id, &1})

    leases =
      Repo.all(
        from(l in ExecutionLease,
          where: l.task_id in ^ids,
          order_by: [desc: l.updated_at, desc: l.id]
        )
      )
      |> Enum.group_by(& &1.task_id)

    events =
      Repo.all(
        from(e in RuntimeEvent,
          where:
            e.task_id in ^ids and
              e.event_type in ^(@terminal ++
                                  ~w(execution.started execution.progress execution.heartbeat execution.acked execution.blocked execution.unblocked)),
          where: fragment("COALESCE(?->>'worker_event_applied', 'true') <> 'false'", e.payload),
          distinct: [e.task_id, e.runtime_id, fragment("?->>'stage_id'", e.payload)],
          order_by: [
            e.task_id,
            e.runtime_id,
            fragment("?->>'stage_id'", e.payload),
            desc: e.occurred_at,
            desc: e.id
          ]
        )
      )
      |> Enum.group_by(& &1.task_id)

    agent_ids =
      tasks
      |> Enum.map(&Tasks.assignee_for_phase(&1, "execution"))
      |> Enum.flat_map(fn {id, type} ->
        if type == "agent" and Platform.UUID.valid?(id), do: [id], else: []
      end)

    owners =
      Repo.all(
        from(a in Agent,
          join: r in AgentRuntime,
          on: r.id == a.runtime_id,
          where: a.id in ^agent_ids,
          select: {a.id, r.runtime_id}
        )
      )
      |> Map.new()

    dep_ids =
      leases
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(fn l ->
        case ExecutionLease.dependency_wait(l) do
          nil -> []
          w -> Enum.map(w["dependencies"] || [], & &1["task_id"])
        end
      end)
      |> Enum.filter(&Platform.UUID.valid?/1)
      |> Enum.uniq()

    deps =
      Repo.all(
        from(t in Task,
          where: t.id in ^dep_ids and is_nil(t.deleted_at),
          select: {t.id, %{id: t.id, title: t.title, status: t.status, project_id: t.project_id}}
        )
        |> Tasks.maybe_scope_by(scope, :task)
      )
      |> Map.new()

    Map.new(tasks, fn task ->
      stage = with p when not is_nil(p) <- plans[task.id], do: stages[p.id]
      {owner_id, owner_type} = Tasks.assignee_for_phase(task, "execution")
      owner = owners[owner_id]

      current =
        Enum.find(leases[task.id] || [], fn l ->
          stage && l.stage_id == stage.id &&
            ((owner && l.runtime_id == owner) || (is_nil(owner_id) && owner_type != "user"))
        end)

      latest =
        Enum.find(events[task.id] || [], fn e ->
          current && e.runtime_id == current.runtime_id &&
            e.payload["stage_id"] == current.stage_id &&
            (is_nil(e.payload["runtime_worker_ref"]) ||
               e.payload["runtime_worker_ref"] == current.runtime_worker_ref)
        end)

      {task.id, project(task, stage, current, latest, deps, now)}
    end)
  end

  def attach(tasks, statuses),
    do: Enum.map(tasks, &Map.put(&1, :execution_activity, statuses[&1.id]))

  def for_task(task, scope \\ nil),
    do: load([task], DateTime.utc_now(), scope)[task.id] || unknown()

  def unknown,
    do: %{
      request_state: nil,
      state: :unknown,
      label: "No activity",
      reason: "Execution ownership or progress is unknown",
      activity_at: nil,
      blocked_at: nil,
      stage: nil,
      stage_id: nil,
      runtime_id: nil,
      lease_id: nil,
      hold_revision: nil,
      dependencies: [],
      can_recheck?: false,
      pulse?: false,
      elapsed: "unknown"
    }

  def project(_task, stage, lease, event, deps, now) do
    base =
      unknown()
      |> Map.merge(%{
        stage: stage && stage.name,
        stage_id: stage && stage.id,
        runtime_id: lease && lease.runtime_id,
        lease_id: lease && lease.id,
        activity_at: lease && lease.last_progress_at
      })

    cond do
      is_nil(stage) or is_nil(lease) ->
        base

      RuntimeSupervision.needs_human_hold?(lease) ->
        held(base, lease, deps, now)

      lease.status == "blocked" ->
        %{
          base
          | reason: lease.block_reason || "Waiting for execution evidence",
            elapsed: elapsed(lease.last_progress_at, now)
        }

      lease.status != "active" or (event && event.event_type in @terminal) ->
        %{
          base
          | reason: "Worker ended; awaiting current execution evidence",
            elapsed: elapsed(lease.last_progress_at, now)
        }

      is_binary(lease.runtime_worker_ref) and recent?(lease.last_progress_at, now) ->
        %{
          base
          | state: :running,
            label: "Running",
            reason: nil,
            pulse?: true,
            elapsed: elapsed(lease.last_progress_at, now)
        }

      true ->
        %{base | elapsed: elapsed(lease.last_progress_at, now)}
    end
  end

  defp held(base, lease, deps, now) do
    wait = ExecutionLease.dependency_wait(lease)
    refs = if wait, do: wait["dependencies"] || [], else: []

    dependencies =
      Enum.map(refs, fn r ->
        deps[r["task_id"]] || %{id: r["task_id"], title: "Unknown dependency", status: "unknown"}
      end)

    kind = if wait, do: :waiting, else: :human
    at = RuntimeSupervision.blocked_at(lease)
    reason = lease.block_reason || "Recorded human action required"
    wait_reason = if wait, do: wait["last_error"] || wait["reason"] || wait["state"], else: nil

    label =
      if wait,
        do: "Waiting on: " <> Enum.map_join(dependencies, ", ", & &1.title),
        else: "Needs you: " <> reason

    %{
      base
      | request_state: wait && wait["state"],
        state: kind,
        label: label,
        reason: wait_reason || reason,
        blocked_at: at,
        hold_revision: RuntimeSupervision.hold_revision(lease),
        dependencies: dependencies,
        can_recheck?:
          is_map(wait) and dependencies != [] and Enum.all?(dependencies, &(&1.status == "done")),
        elapsed: elapsed(at, now)
    }
  end

  def recent?(%DateTime{} = at, now), do: DateTime.diff(now, at, :second) in 0..@recent_seconds
  def recent?(_, _), do: false
  def elapsed(nil, _), do: "unknown"

  def elapsed(at, now) do
    s = max(DateTime.diff(now, at, :second), 0)

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m"
      true -> "#{div(s, 3600)}h"
    end
  end
end
