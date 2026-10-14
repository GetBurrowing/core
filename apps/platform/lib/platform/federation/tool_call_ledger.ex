defmodule Platform.Federation.ToolCallLedger do
  @moduledoc """
  Writes `dispatch_tool_calls` rows for `Platform.Federation.ToolCall`
  (task 01a114a8 stage 1).

  ## Never raises, never changes the call

  `record/1` returns `:ok` whatever happens. Attribution and the insert run
  in a `Platform.TaskSupervisor` child, so neither adds latency to the tool
  call. A failed insert is logged with the tool name, runtime id and the
  exception's module, and is then dropped (the ADR-0048 posture, as in
  `HeartbeatScheduler.append_experiment_directive/4`). In test env
  `:tool_call_ledger_sync` is `true`, so the same body runs inline under the
  test's sandbox owner; the body still rescues everything.

  ## Never persists arguments or results

  The only things that reach this module from a call's args are
  `attribution_hints/1`: the string values of `task_id`, `stage_id`,
  `plan_id` and `space_id`. Those are ids, not content. They are used to
  derive the row's attribution and are not stored themselves (only the
  derived `task_id` / `stage_id` / `lease_id` are). Nothing here logs a
  value from args or results.

  ## The attribution ladder (`attribute/3`), cheapest first

    1. `explicit_arg`: `task_id`, `stage_id` or `plan_id` in args. A
       `stage_id` or `plan_id` alone is resolved to its task.
    2. `execution_space`: `space_id` is a task's execution space.
    3. `sole_acked_stage`: the runtime has exactly one acked stage (an
       `execution.acked` runtime_event in the last
       `:tool_call_ledger_ack_window_days`, default 7) whose stage row is
       still `running`. This is the rung Claude Code runtimes can satisfy;
       they never write execution_lease rows (`execution.acked` maps to
       `nil` in `RuntimeSupervision`'s `@event_statuses`).
    4. `sole_lease`: the runtime holds exactly one live `active` or
       `blocked` execution_lease (OpenClaw runtimes).
    5. `unattributed`.

  A runtime working several tasks at once (Dalton routinely does) fails
  rungs 3 and 4 by design: a guess would be worse than a reported
  `unattributed`. The coverage figure is reported by
  `Platform.Orchestration.DispatchMetrics`, never hidden.

  Rungs 1 to 3 fill `lease_id` when the runtime holds exactly one live
  lease on the attributed task (and stage, when known).
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat.Space
  alias Platform.Federation.ToolCallRecord
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  @hint_keys ~w(task_id stage_id plan_id space_id)
  @live_lease_statuses ~w(active blocked)

  @doc """
  The attribution-relevant ids from a call's args: string values of
  #{Enum.map_join(@hint_keys, ", ", &"`#{&1}`")} that are canonical UUIDs.
  Every other key, and every non-UUID value, is dropped here.
  """
  @spec attribution_hints(map()) :: map()
  def attribution_hints(args) when is_map(args) do
    Enum.reduce(@hint_keys, %{}, fn key, acc ->
      case Map.get(args, key) do
        value when is_binary(value) ->
          if Platform.UUID.valid?(value), do: Map.put(acc, key, value), else: acc

        _ ->
          acc
      end
    end)
  end

  def attribution_hints(_args), do: %{}

  @doc """
  Record one call. `entry` carries `:id`, `:tool`, `:status`,
  `:duration_ms`, `:result_bytes`, `:runtime_id`, `:agent_id`,
  `:parent_run_id`, `:hints` (from `attribution_hints/1`) and, for
  `suite_run` only, `:script_sha256` / `:script_bytes` and `:error_kind`
  (an enumerated kind, never a message). Always returns `:ok`.
  """
  @spec record(map()) :: :ok
  def record(entry) when is_map(entry) do
    if Application.get_env(:platform, :tool_call_ledger_sync, false) do
      write(entry)
    else
      start_async(entry)
    end

    :ok
  rescue
    error ->
      log_failure(entry, error)
      :ok
  end

  defp start_async(entry) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> write(entry) end)
  end

  @doc false
  # Public for the test seam only (`:tool_call_ledger_writer`).
  @spec write(map()) :: :ok
  def write(entry) do
    writer = Application.get_env(:platform, :tool_call_ledger_writer, __MODULE__)
    writer.insert(entry)
    :ok
  rescue
    _error in DBConnection.OwnershipError ->
      # A child that outlived its test's sandbox owner. Nothing to record.
      :ok

    error ->
      log_failure(entry, error)
      :ok
  catch
    kind, _reason ->
      log_failure(entry, kind)
      :ok
  end

  @doc false
  # The default writer: attribute, then insert.
  def insert(entry) do
    runtime_id = Map.get(entry, :runtime_id)
    attribution = attribute(Map.get(entry, :hints, %{}), runtime_id, DateTime.utc_now())

    attrs =
      entry
      |> Map.take([
        :tool,
        :status,
        :duration_ms,
        :result_bytes,
        :runtime_id,
        :agent_id,
        :script_sha256,
        :script_bytes,
        :error_kind
      ])
      |> Map.put(:parent_run_id, valid_uuid_or_nil(Map.get(entry, :parent_run_id)))
      |> put_id(valid_uuid_or_nil(Map.get(entry, :id)))
      |> Map.merge(attribution)

    attrs
    |> ToolCallRecord.changeset()
    |> Repo.insert!()
  end

  @doc """
  Run the attribution ladder. Returns
  `%{attribution, task_id, stage_id, lease_id}`.
  """
  @spec attribute(map(), String.t() | nil, DateTime.t()) :: map()
  def attribute(hints, runtime_id, %DateTime{} = now) do
    rung =
      explicit_arg(hints) ||
        execution_space(hints) ||
        sole_acked_stage(runtime_id, now) ||
        sole_lease(runtime_id, now)

    case rung do
      {:sole_lease, %ExecutionLease{} = lease} ->
        %{
          attribution: "sole_lease",
          task_id: lease.task_id,
          stage_id: lease.stage_id,
          lease_id: lease.id
        }

      {name, task_id, stage_id} ->
        %{
          attribution: Atom.to_string(name),
          task_id: task_id,
          stage_id: stage_id,
          lease_id: matching_lease_id(runtime_id, task_id, stage_id, now)
        }

      nil ->
        %{attribution: "unattributed", task_id: nil, stage_id: nil, lease_id: nil}
    end
  end

  # ── rung 1 ─────────────────────────────────────────────────────────────

  defp explicit_arg(%{"task_id" => task_id} = hints),
    do: {:explicit_arg, task_id, Map.get(hints, "stage_id")}

  defp explicit_arg(%{"stage_id" => stage_id}) do
    case Repo.one(
           from(s in Stage,
             join: p in Plan,
             on: p.id == s.plan_id,
             where: s.id == ^stage_id,
             select: p.task_id
           )
         ) do
      nil -> nil
      task_id -> {:explicit_arg, task_id, stage_id}
    end
  end

  defp explicit_arg(%{"plan_id" => plan_id}) do
    case Repo.one(from(p in Plan, where: p.id == ^plan_id, select: p.task_id)) do
      nil -> nil
      task_id -> {:explicit_arg, task_id, nil}
    end
  end

  defp explicit_arg(_hints), do: nil

  # ── rung 2 ─────────────────────────────────────────────────────────────

  defp execution_space(%{"space_id" => space_id}) do
    task_id =
      Repo.one(
        from(s in Space,
          where: s.id == ^space_id and s.kind == "execution",
          select: fragment("?->>'task_id'", s.metadata)
        )
      )

    if is_binary(task_id) and Platform.UUID.valid?(task_id),
      do: {:execution_space, task_id, nil},
      else: nil
  end

  defp execution_space(_hints), do: nil

  # ── rung 3 ─────────────────────────────────────────────────────────────

  defp sole_acked_stage(runtime_id, now) when is_binary(runtime_id) do
    since = DateTime.add(now, -ack_window_days() * 86_400, :second)

    acked_stage_ids =
      from(e in RuntimeEvent,
        where:
          e.runtime_id == ^runtime_id and e.event_type == "execution.acked" and
            e.occurred_at >= ^since,
        select: fragment("?->>'stage_id'", e.payload),
        distinct: true
      )
      |> Repo.all()
      |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1)))

    running =
      if acked_stage_ids == [] do
        []
      else
        Repo.all(
          from(s in Stage,
            join: p in Plan,
            on: p.id == s.plan_id,
            where: s.id in ^acked_stage_ids and s.status == "running",
            select: {p.task_id, s.id}
          )
        )
      end

    case running do
      [{task_id, stage_id}] -> {:sole_acked_stage, task_id, stage_id}
      _ -> nil
    end
  end

  defp sole_acked_stage(_runtime_id, _now), do: nil

  # ── rung 4 ─────────────────────────────────────────────────────────────

  defp sole_lease(runtime_id, now) when is_binary(runtime_id) do
    case runtime_id |> live_leases(now) |> Repo.all() do
      [%ExecutionLease{} = lease] -> {:sole_lease, lease}
      _ -> nil
    end
  end

  defp sole_lease(_runtime_id, _now), do: nil

  defp matching_lease_id(runtime_id, task_id, stage_id, now)
       when is_binary(runtime_id) and is_binary(task_id) do
    query = from(l in live_leases(runtime_id, now), where: l.task_id == ^task_id)

    query =
      if is_binary(stage_id),
        do: from(l in query, where: l.stage_id == ^stage_id),
        else: query

    case Repo.all(from(l in query, select: l.id)) do
      [lease_id] -> lease_id
      _ -> nil
    end
  end

  defp matching_lease_id(_runtime_id, _task_id, _stage_id, _now), do: nil

  defp live_leases(runtime_id, now) do
    from(l in ExecutionLease,
      where:
        l.runtime_id == ^runtime_id and l.status in ^@live_lease_statuses and
          l.expires_at > ^now
    )
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # `ToolCall.invoke/4` names the row (it is `suite_run`'s `run_id`); an
  # entry without one gets an autogenerated id.
  defp put_id(attrs, nil), do: attrs
  defp put_id(attrs, id), do: Map.put(attrs, :id, id)

  defp ack_window_days,
    do: Application.get_env(:platform, :tool_call_ledger_ack_window_days, 7)

  defp valid_uuid_or_nil(value) when is_binary(value),
    do: if(Platform.UUID.valid?(value), do: value, else: nil)

  defp valid_uuid_or_nil(_value), do: nil

  # Name, runtime and the failure's module or kind. Never the exception
  # message: a DB error can quote a parameter.
  defp log_failure(entry, failure) do
    reason =
      case failure do
        %{__struct__: module} -> inspect(module)
        other -> inspect(other)
      end

    Logger.warning(
      "[ToolCallLedger] dropped ledger row: tool=#{Map.get(entry, :tool)} " <>
        "runtime=#{Map.get(entry, :runtime_id)} reason=#{reason}"
    )
  rescue
    _ -> :ok
  end
end
