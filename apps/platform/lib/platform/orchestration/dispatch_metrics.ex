defmodule Platform.Orchestration.DispatchMetrics do
  @moduledoc """
  Per-dispatch measurements for the code-mode experiment (task 01a114a8
  stage 1): Suite tool calls, client-reported turns, tokens and tool calls,
  wall time and outcome. Read by the `dispatch_metrics_list` MCP tool
  (`experiments` bundle) and by stage 4's metric kind.

  ## What a "dispatch" is

  One row per dispatch. Each row says which source produced it in
  `unit_source`, in this priority order:

    1. `ack`: an `execution.acked` runtime_event, keyed by
       (task_id, stage_id, runtime_id). Consecutive acks of one stage by the
       same runtime AND subagent collapse into one dispatch; an ack by a
       different subagent (or runtime) starts a new one (a re-dispatch).
       Wall time runs from the first ack to the earliest of: the next
       dispatch of the same stage, or the stage's end.
       `re_dispatch_count` = dispatches of that (task, stage) minus 1.
       (Same-subagent re-acks are deliberately not counted as re-dispatches.)
    2. `stage_row`: a stage that started (`started_at` set, status running,
       passed, failed or skipped) with NO ack at all. One row per
       (task, stage). The agent is the task's assignee for the stage's
       phase (`review` for a synthesized stage, else `execution`), falling
       back to a validation evaluator that names a runtime. Wall time runs
       from `stages.started_at`, which is EARLIER than the ack clock (it
       includes dispatch latency and time before the runtime acked), so
       `ack` and `stage_row` wall times are not directly comparable.
       `re_dispatch_count` is nil, never 0: there is no record to count.
    3. `lease`: an execution_lease row. Leases add detail (`lease_ids`,
       `lease_started_at`) to the `ack` or `stage_row` unit for the same
       (task, stage). A lease with no such unit becomes its own row.

  **Execution lease rows do not exist for Claude Code runtimes.**
  `task_ack` records `execution.acked`, which maps to `nil` in
  `Platform.Orchestration.RuntimeSupervision`'s `@event_statuses`
  (runtime_supervision.ex:40), so no lease row is ever written. Only
  runtimes that send `execution.started` / `heartbeat` / `progress` events
  (OpenClaw) have them. Measured on prod 2026-10-07: 29 of the 30 most
  recent done tasks had zero lease rows. Nothing here requires them.

  `coverage` reports, per agent, the count and percentage of dispatch rows
  from each `unit_source`, so a runtime that acks only some stages shows up
  as a lower `ack` share instead of being hidden.

  ## What can and cannot be measured

  **Server side (exact per call): Suite MCP tool calls only.** Every call
  through `Platform.Federation.ToolCall.invoke/4` writes a
  `dispatch_tool_calls` row. A call counts toward a dispatch when it has the
  dispatch's runtime_id and task_id, its stage_id is nil or equal, and it
  happened inside the dispatch's wall-time window. Attribution is
  approximate when a runtime works several tasks at once; an `unattributed`
  call counts toward no dispatch, and `attribution_coverage` reports the
  share per agent.

  `suite_tool_calls` counts model-issued calls (`parent_run_id IS NULL`),
  `inner_tool_calls` counts calls made from inside a `suite_run` script
  (`parent_run_id NOT NULL`, stage 2), and `suite_run_calls` counts
  `suite_run` calls.

  **Client side (self-reported): local tools (Bash, Read, Grep), model
  turns and tokens never touch core.** They come only from
  `agent_usage_events` that a client sends. `client_*` fields are nil, never
  0, when no report matched. A report matches a dispatch when its `task_id`
  is the dispatch's task, its `metadata.stage_id` is the dispatch's stage
  (or absent, with the report inside the window), and its `agent_id` is the
  dispatch's agent. **These numbers are self-reported:** the
  `/api/internal/usage-events` endpoint checks only that some runtime token
  is valid and does not bind `agent_id` to that runtime, so a report cannot
  be traced to the runtime that sent it.

  `suite_reply` and typing frames are channel events, not tool calls, and
  are not counted anywhere.
  """

  import Ecto.Query

  alias Platform.Agents.AgentRuntime
  alias Platform.Analytics.UsageEvent
  alias Platform.Federation.ToolCallRecord
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Project
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task
  alias Platform.Tasks.Validation

  @default_window_days 7
  @default_limit 50
  @max_limit 500
  @started_stage_statuses ~w(running passed failed skipped)
  @terminal_stage_statuses ~w(passed failed skipped)
  @unit_sources ~w(ack stage_row lease)

  @type filters :: %{
          optional(:agent_id) => String.t(),
          optional(:task_id) => String.t(),
          optional(:from) => DateTime.t(),
          optional(:to) => DateTime.t(),
          optional(:org_id) => String.t(),
          optional(:limit) => integer(),
          optional(:offset) => integer(),
          optional(:now) => DateTime.t()
        }

  @doc "The `unit_source` values, in priority order."
  def unit_sources, do: @unit_sources

  @doc """
  List dispatches matching `filters`, newest first.

  Filters: `:agent_id`, `:task_id`, `:from` / `:to` (on the dispatch start;
  `from` defaults to #{@default_window_days} days ago unless `:task_id` is
  given), `:org_id` (restricts to tasks whose project is in that org; the
  tool sets it for tenant-pinned callers), `:limit` (default
  #{@default_limit}, max #{@max_limit}), `:offset`.

  Returns `%{dispatches, total, coverage, attribution_coverage, limit,
  offset}`.
  """
  @spec list(filters()) :: map()
  def list(filters \\ %{}) do
    now = Map.get(filters, :now) || DateTime.utc_now()
    filters = resolve_window(filters, now)
    runtimes = runtime_index()

    units =
      filters
      |> collect_units(runtimes)
      |> Enum.filter(&in_scope?(&1, filters))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    limit = clamp_limit(Map.get(filters, :limit))
    offset = max(Map.get(filters, :offset) || 0, 0)
    page = units |> Enum.drop(offset) |> Enum.take(limit)

    %{
      dispatches: enrich(page, now),
      total: length(units),
      coverage: coverage(units),
      attribution_coverage: attribution_coverage(filters, runtimes),
      limit: limit,
      offset: offset
    }
  end

  @doc """
  Every dispatch of `task_ids`, unpaged, enriched exactly as `list/1`'s
  rows are. Read by the `dispatch_usage` metric kind and
  `Platform.Experiments.Results.by_agent/1` (task 01a114a8 stage 4), whose
  population is an experiment's assigned tasks rather than a time window.

  There is no time window: every started stage, ack and lease of those tasks
  counts. Options: `:now` (default `DateTime.utc_now/0`), the clock that
  closes a still-running dispatch's window for call matching.
  """
  @spec for_tasks([String.t()], keyword()) :: [map()]
  def for_tasks(task_ids, opts \\ []) when is_list(task_ids) do
    ids = task_ids |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1))) |> Enum.uniq()

    if ids == [] do
      []
    else
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      filters = %{task_ids: ids, from: ~U[1970-01-01 00:00:00Z], to: now}

      filters
      |> collect_units(runtime_index())
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> enrich(now)
    end
  end

  @doc """
  Model-issued tool calls per agent in a window, split by attribution rung:
  `[%{agent_id, tool_calls, attributed, pct, by_rung}]`, the same rows as
  `list/1`'s `attribution_coverage`. Filters: `:from`, `:to` (both
  required), `:agent_id`.

  An unattributed call cannot be tied to any task, so coverage is per agent
  over a window, never per experiment.
  """
  @spec attribution_coverage_for(map()) :: [map()]
  def attribution_coverage_for(%{from: %DateTime{}, to: %DateTime{}} = filters),
    do: attribution_coverage(filters, runtime_index())

  @doc """
  The `dispatch_metrics_list` MCP tool. Parses and validates `args`, applies
  the caller's tenancy (a tenant-pinned agent sees only dispatches of tasks
  in its own org), and wraps `list/1` in the list envelope.
  """
  @spec run_tool(map(), map()) :: {:ok, map()} | {:error, map()}
  def run_tool(args, context) when is_map(args) do
    with {:ok, agent_id} <- uuid_arg(args, "agent_id"),
         {:ok, task_id} <- uuid_arg(args, "task_id"),
         {:ok, from} <- datetime_arg(args, "from"),
         {:ok, to} <- datetime_arg(args, "to"),
         {:ok, limit} <- integer_arg(args, "limit"),
         {:ok, offset} <- integer_arg(args, "offset") do
      filters =
        %{
          agent_id: agent_id,
          task_id: task_id,
          from: from,
          to: to,
          limit: limit,
          offset: offset,
          org_id: caller_org(context)
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      result = list(filters)

      {:ok,
       Platform.Federation.ResultBound.paged(
         :dispatches,
         result.dispatches,
         result.total,
         result.offset,
         %{
           count: length(result.dispatches),
           limit: result.limit,
           coverage: result.coverage,
           attribution_coverage: result.attribution_coverage
         }
       )}
    end
  end

  def run_tool(_args, _context),
    do: tool_error(:invalid_arguments, "arguments must be an object", "Pass a JSON object.")

  defp caller_org(context) do
    agent =
      case Map.get(context, :agent_id) do
        id when is_binary(id) ->
          if Platform.UUID.valid?(id), do: Repo.get(Platform.Agents.Agent, id)

        _ ->
          nil
      end

    case Platform.Experiments.Tools.home_org(agent) do
      {:tenant, org_id} -> org_id
      :root -> nil
    end
  end

  defp uuid_arg(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Platform.UUID.valid?(value),
          do: {:ok, value},
          else: tool_error(:"invalid_#{key}", "`#{key}` must be a UUID", "Pass a UUID.")

      _ ->
        tool_error(:"invalid_#{key}", "`#{key}` must be a UUID", "Pass a UUID.")
    end
  end

  defp datetime_arg(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} ->
            {:ok, dt}

          _ ->
            tool_error(
              :"invalid_#{key}",
              "`#{key}` must be an ISO 8601 timestamp",
              "Pass e.g. 2026-10-07T00:00:00Z."
            )
        end

      _ ->
        tool_error(:"invalid_#{key}", "`#{key}` must be an ISO 8601 timestamp", "Pass a string.")
    end
  end

  defp integer_arg(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        tool_error(
          :"invalid_#{key}",
          "`#{key}` must be a non-negative integer",
          "Pass an integer."
        )
    end
  end

  defp tool_error(code, message, suggestion) do
    {:error,
     %{
       error: "dispatch_metrics_list: #{message}",
       code: code,
       recoverable: true,
       suggestion: suggestion
     }}
  end

  # ── units ─────────────────────────────────────────────────────────────

  defp collect_units(filters, runtimes) do
    stages = started_stages(filters)
    ack_units = ack_units(filters, runtimes)
    acked = MapSet.new(ack_units, &{&1.task_id, &1.stage_id})

    stage_units =
      stages
      |> Enum.reject(fn {stage, task} -> MapSet.member?(acked, {task.id, stage.id}) end)
      |> Enum.map(fn {stage, task} -> stage_unit(stage, task, runtimes) end)

    attach_leases(ack_units ++ stage_units, filters, runtimes)
  end

  defp ack_units(filters, runtimes) do
    task_ids =
      from(e in RuntimeEvent,
        where: e.event_type == "execution.acked",
        where: e.occurred_at >= ^filters.from and e.occurred_at <= ^filters.to,
        select: e.task_id,
        distinct: true
      )
      |> scope_task_field(filters)
      |> Repo.all()

    if task_ids == [] do
      []
    else
      # Every ack of those tasks, not only the windowed ones, so a
      # re-dispatch boundary outside the window is still seen.
      acks =
        Repo.all(
          from(e in RuntimeEvent,
            where: e.event_type == "execution.acked" and e.task_id in ^task_ids,
            order_by: [asc: e.occurred_at, asc: e.id],
            select: %{
              id: e.id,
              task_id: e.task_id,
              runtime_id: e.runtime_id,
              occurred_at: e.occurred_at,
              stage_id: fragment("?->>'stage_id'", e.payload),
              subagent_id: fragment("?->>'subagent_id'", e.payload)
            }
          )
        )
        |> Enum.filter(&(is_binary(&1.stage_id) and Platform.UUID.valid?(&1.stage_id)))

      stages = stages_by_id(Enum.map(acks, & &1.stage_id))

      acks
      |> Enum.group_by(&{&1.task_id, &1.stage_id})
      |> Enum.flat_map(fn {_key, stage_acks} ->
        ack_segments(stage_acks, Map.get(stages, hd(stage_acks).stage_id), runtimes)
      end)
      |> Enum.filter(&within?(&1.started_at, filters))
    end
  end

  # Collapse consecutive acks by the same runtime+subagent into one dispatch.
  defp ack_segments(stage_acks, stage, runtimes) do
    segments =
      stage_acks
      |> Enum.chunk_by(&{&1.runtime_id, &1.subagent_id})
      |> Enum.map(&hd/1)

    re_dispatch_count = length(segments) - 1
    stage_end = stage_end(stage)

    segments
    |> Enum.with_index()
    |> Enum.map(fn {ack, index} ->
      next_start =
        case Enum.at(segments, index + 1) do
          nil -> nil
          next -> next.occurred_at
        end

      ended_at = earliest(next_start, stage_end)

      %{
        dispatch_id: ack.id,
        unit_source: "ack",
        task_id: ack.task_id,
        stage_id: ack.stage_id,
        runtime_id: ack.runtime_id,
        agent_id: Map.get(runtimes.agent_by_runtime, ack.runtime_id),
        subagent_id: ack.subagent_id,
        started_at: ack.occurred_at,
        ended_at: ended_at,
        re_dispatch_count: re_dispatch_count,
        stage: stage
      }
    end)
  end

  defp started_stages(filters) do
    from(s in Stage,
      join: p in Plan,
      on: p.id == s.plan_id,
      join: t in Task,
      on: t.id == p.task_id,
      where: s.status in ^@started_stage_statuses and not is_nil(s.started_at),
      where: s.started_at >= ^filters.from and s.started_at <= ^filters.to,
      select: {s, t}
    )
    |> scope_task_binding(filters)
    |> Repo.all()
  end

  defp stage_unit(stage, task, runtimes) do
    {agent_id, runtime_id} = stage_owner(stage, task, runtimes)

    %{
      dispatch_id: "stage:" <> stage.id,
      unit_source: "stage_row",
      task_id: task.id,
      stage_id: stage.id,
      runtime_id: runtime_id,
      agent_id: agent_id,
      subagent_id: nil,
      started_at: stage.started_at,
      ended_at: stage_end(stage),
      re_dispatch_count: nil,
      stage: stage
    }
  end

  defp stage_owner(stage, task, runtimes) do
    phase = if stage.origin == "synthesized", do: "review", else: "execution"

    case Platform.Tasks.assignee_for_phase(task, phase) do
      {agent_id, "agent"} when is_binary(agent_id) ->
        {agent_id, Map.get(runtimes.runtime_by_agent, agent_id)}

      _ ->
        evaluator_owner(stage.id, runtimes)
    end
  end

  defp evaluator_owner(stage_id, runtimes) do
    from(v in Validation,
      where: v.stage_id == ^stage_id and not is_nil(v.evaluated_by),
      select: v.evaluated_by
    )
    |> Repo.all()
    |> Enum.find_value({nil, nil}, fn evaluated_by ->
      case Map.fetch(runtimes.agent_by_runtime, evaluated_by) do
        {:ok, agent_id} -> {agent_id, evaluated_by}
        :error -> nil
      end
    end)
  end

  defp attach_leases(units, filters, runtimes) do
    leases =
      from(l in ExecutionLease,
        where: l.started_at >= ^filters.from and l.started_at <= ^filters.to,
        order_by: [asc: l.started_at]
      )
      |> scope_task_field(filters)
      |> Repo.all()

    by_stage = Enum.group_by(leases, &{&1.task_id, &1.stage_id})
    unit_keys = MapSet.new(units, &{&1.task_id, &1.stage_id})

    enriched =
      Enum.map(units, fn unit ->
        matching =
          by_stage
          |> Map.get({unit.task_id, unit.stage_id}, [])
          |> Enum.filter(&(unit.unit_source != "ack" or &1.runtime_id == unit.runtime_id))

        lease_detail(unit, matching, runtimes)
      end)

    lease_only =
      leases
      |> Enum.reject(&MapSet.member?(unit_keys, {&1.task_id, &1.stage_id}))
      |> Enum.map(fn lease ->
        %{
          dispatch_id: lease.id,
          unit_source: "lease",
          task_id: lease.task_id,
          stage_id: lease.stage_id,
          runtime_id: lease.runtime_id,
          agent_id: Map.get(runtimes.agent_by_runtime, lease.runtime_id),
          subagent_id: nil,
          started_at: lease.started_at,
          ended_at: lease_end(lease),
          re_dispatch_count: nil,
          stage: nil,
          lease_ids: [lease.id],
          lease_started_at: lease.started_at
        }
      end)

    enriched ++ lease_only
  end

  defp lease_detail(unit, [], _runtimes),
    do: Map.merge(unit, %{lease_ids: [], lease_started_at: nil})

  defp lease_detail(unit, [first | _] = leases, runtimes) do
    unit =
      Map.merge(unit, %{lease_ids: Enum.map(leases, & &1.id), lease_started_at: first.started_at})

    # A stage_row's owner is a guess from the assignee; the lease names the
    # runtime that actually held the stage.
    if unit.unit_source == "stage_row" do
      %{
        unit
        | runtime_id: first.runtime_id,
          agent_id: Map.get(runtimes.agent_by_runtime, first.runtime_id, unit.agent_id)
      }
    else
      unit
    end
  end

  # ── enrichment (page only) ────────────────────────────────────────────

  defp enrich([], _now), do: []

  defp enrich(units, now) do
    task_ids = units |> Enum.map(& &1.task_id) |> Enum.uniq()
    runtime_ids = units |> Enum.map(& &1.runtime_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    stage_ids = units |> Enum.map(& &1.stage_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    calls = tool_calls(task_ids, runtime_ids)
    usage = usage_events(task_ids)
    validations = validation_counts(stage_ids)
    stages = stages_by_id(stage_ids)

    Enum.map(units, fn unit ->
      stage = unit.stage || Map.get(stages, unit.stage_id)
      unit_calls = Enum.filter(calls, &call_in_unit?(&1, unit, now))
      reports = Enum.filter(usage, &report_in_unit?(&1, unit, now))

      %{
        dispatch_id: unit.dispatch_id,
        unit_source: unit.unit_source,
        task_id: unit.task_id,
        stage_id: unit.stage_id,
        runtime_id: unit.runtime_id,
        agent_id: unit.agent_id,
        subagent_id: unit.subagent_id,
        started_at: unit.started_at,
        ended_at: unit.ended_at,
        wall_ms: wall_ms(unit.started_at, unit.ended_at),
        lease_ids: unit.lease_ids,
        lease_started_at: unit.lease_started_at,
        suite_tool_calls: Enum.count(unit_calls, &is_nil(&1.parent_run_id)),
        inner_tool_calls: Enum.count(unit_calls, &(not is_nil(&1.parent_run_id))),
        suite_run_calls:
          Enum.count(unit_calls, &(is_nil(&1.parent_run_id) and &1.tool == "suite_run")),
        tool_calls_denied: Enum.count(unit_calls, &(&1.status == "denied")),
        tool_calls_error: Enum.count(unit_calls, &(&1.status == "error")),
        client_reports: length(reports),
        client_turns: sum_metadata(reports, "turns"),
        client_tool_calls: sum_metadata(reports, "client_tool_calls"),
        client_wall_ms: sum_metadata(reports, "wall_ms"),
        client_tokens_in: sum_field(reports, :input_tokens),
        client_tokens_out: sum_field(reports, :output_tokens),
        client_cache_read_tokens: sum_field(reports, :cache_read_tokens),
        client_cache_write_tokens: sum_field(reports, :cache_write_tokens),
        client_harness: reports |> Enum.map(&harness/1) |> Enum.find(&is_binary/1),
        stage_status: stage && stage.status,
        validations: Map.get(validations, unit.stage_id, %{}),
        re_dispatch_count: unit.re_dispatch_count
      }
    end)
  end

  defp tool_calls([], _runtime_ids), do: []
  defp tool_calls(_task_ids, []), do: []

  defp tool_calls(task_ids, runtime_ids) do
    Repo.all(
      from(c in ToolCallRecord,
        where: c.task_id in ^task_ids and c.runtime_id in ^runtime_ids,
        select: %{
          task_id: c.task_id,
          stage_id: c.stage_id,
          runtime_id: c.runtime_id,
          tool: c.tool,
          status: c.status,
          parent_run_id: c.parent_run_id,
          inserted_at: c.inserted_at
        }
      )
    )
  end

  defp call_in_unit?(call, unit, now) do
    call.runtime_id == unit.runtime_id and call.task_id == unit.task_id and
      (is_nil(call.stage_id) or call.stage_id == unit.stage_id) and
      in_window?(call.inserted_at, unit, now)
  end

  defp usage_events(task_ids) do
    Repo.all(from(e in UsageEvent, where: e.task_id in ^task_ids))
  end

  defp report_in_unit?(event, unit, now) do
    reported_stage = Map.get(event.metadata || %{}, "stage_id")

    is_binary(unit.agent_id) and event.agent_id == unit.agent_id and
      event.task_id == unit.task_id and
      if(is_binary(reported_stage),
        do: reported_stage == unit.stage_id,
        else: in_window?(event.inserted_at, unit, now)
      )
  end

  defp validation_counts([]), do: %{}

  defp validation_counts(stage_ids) do
    from(v in Validation,
      where: v.stage_id in ^stage_ids,
      group_by: [v.stage_id, v.status],
      select: {v.stage_id, v.status, count(v.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {stage_id, status, n}, acc ->
      Map.update(acc, stage_id, %{status => n}, &Map.put(&1, status, n))
    end)
  end

  # ── coverage ──────────────────────────────────────────────────────────

  defp coverage(units) do
    units
    |> Enum.group_by(& &1.agent_id)
    |> Enum.map(fn {agent_id, rows} ->
      total = length(rows)
      counts = Enum.frequencies_by(rows, & &1.unit_source)

      %{
        agent_id: agent_id,
        dispatches: total,
        by_unit_source:
          Map.new(@unit_sources, fn source ->
            n = Map.get(counts, source, 0)
            {source, %{count: n, pct: pct(n, total)}}
          end)
      }
    end)
    |> Enum.sort_by(&to_string(&1.agent_id))
  end

  defp attribution_coverage(filters, runtimes) do
    query =
      from(c in ToolCallRecord,
        where: c.inserted_at >= ^filters.from and c.inserted_at <= ^filters.to,
        where: is_nil(c.parent_run_id),
        group_by: [c.runtime_id, c.attribution],
        select: {c.runtime_id, c.attribution, count(c.id)}
      )

    query =
      case Map.get(filters, :agent_id) do
        nil -> query
        agent_id -> from(c in query, where: c.agent_id == ^agent_id)
      end

    query
    |> Repo.all()
    |> Enum.group_by(fn {runtime_id, _, _} -> Map.get(runtimes.agent_by_runtime, runtime_id) end)
    |> Enum.map(fn {agent_id, rows} ->
      by_rung =
        Map.new(rows |> Enum.group_by(&elem(&1, 1)), fn {rung, rs} ->
          {rung, rs |> Enum.map(&elem(&1, 2)) |> Enum.sum()}
        end)

      total = by_rung |> Map.values() |> Enum.sum()
      attributed = total - Map.get(by_rung, "unattributed", 0)

      %{
        agent_id: agent_id,
        tool_calls: total,
        attributed: attributed,
        pct: pct(attributed, total),
        by_rung: by_rung
      }
    end)
    |> Enum.sort_by(&to_string(&1.agent_id))
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp resolve_window(filters, now) do
    default_from =
      if Map.get(filters, :task_id),
        do: ~U[1970-01-01 00:00:00Z],
        else: DateTime.add(now, -@default_window_days * 86_400, :second)

    filters
    |> Map.put(:from, Map.get(filters, :from) || default_from)
    |> Map.put(:to, Map.get(filters, :to) || now)
  end

  defp runtime_index do
    rows =
      Repo.all(
        from(r in AgentRuntime,
          where: not is_nil(r.agent_id),
          order_by: [asc_nulls_first: r.last_connected_at],
          select: {r.runtime_id, r.agent_id}
        )
      )

    %{
      agent_by_runtime: Map.new(rows),
      # Last write wins, and rows are ordered oldest connection first, so an
      # agent with several runtimes resolves to its most recently connected.
      runtime_by_agent: Map.new(rows, fn {runtime_id, agent_id} -> {agent_id, runtime_id} end)
    }
  end

  defp scope_task_field(query, filters) do
    query =
      case Map.get(filters, :task_id) do
        nil -> query
        task_id -> where(query, [r], r.task_id == ^task_id)
      end

    query =
      case Map.get(filters, :task_ids) do
        nil -> query
        task_ids -> where(query, [r], r.task_id in ^task_ids)
      end

    case Map.get(filters, :org_id) do
      nil ->
        query

      org_id ->
        from(r in query,
          join: t in Task,
          on: t.id == r.task_id,
          join: pr in Project,
          on: pr.id == t.project_id,
          where: pr.org_id == ^org_id
        )
    end
  end

  defp scope_task_binding(query, filters) do
    query =
      case Map.get(filters, :task_id) do
        nil -> query
        task_id -> where(query, [_s, _p, t], t.id == ^task_id)
      end

    query =
      case Map.get(filters, :task_ids) do
        nil -> query
        task_ids -> where(query, [_s, _p, t], t.id in ^task_ids)
      end

    case Map.get(filters, :org_id) do
      nil ->
        query

      org_id ->
        from([_s, _p, t] in query,
          join: pr in Project,
          on: pr.id == t.project_id,
          where: pr.org_id == ^org_id
        )
    end
  end

  defp in_scope?(unit, filters) do
    case Map.get(filters, :agent_id) do
      nil -> true
      agent_id -> unit.agent_id == agent_id
    end
  end

  defp within?(%DateTime{} = at, filters),
    do: DateTime.compare(at, filters.from) != :lt and DateTime.compare(at, filters.to) != :gt

  defp in_window?(%DateTime{} = at, unit, now) do
    finish = unit.ended_at || now
    DateTime.compare(at, unit.started_at) != :lt and DateTime.compare(at, finish) != :gt
  end

  defp stages_by_id([]), do: %{}

  defp stages_by_id(stage_ids) do
    ids = Enum.uniq(stage_ids)
    from(s in Stage, where: s.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  defp stage_end(%Stage{status: status} = stage) when status in @terminal_stage_statuses,
    do: stage.completed_at || stage.updated_at

  defp stage_end(_stage), do: nil

  defp lease_end(%ExecutionLease{status: status}) when status in ~w(active blocked), do: nil

  defp lease_end(%ExecutionLease{} = lease), do: lease.updated_at

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp wall_ms(_started, nil), do: nil
  defp wall_ms(started, ended), do: max(DateTime.diff(ended, started, :millisecond), 0)

  defp sum_metadata(reports, key) do
    values =
      reports
      |> Enum.map(fn
        %UsageEvent{metadata: %{} = metadata} -> Map.get(metadata, key)
        _ -> nil
      end)
      |> Enum.filter(&is_integer/1)

    if values == [], do: nil, else: Enum.sum(values)
  end

  defp sum_field([], _field), do: nil

  defp sum_field(reports, field),
    do: reports |> Enum.map(&(Map.get(&1, field) || 0)) |> Enum.sum()

  defp harness(%UsageEvent{metadata: %{"harness" => harness}}) when is_binary(harness),
    do: harness

  defp harness(_event), do: nil

  defp pct(_n, 0), do: nil
  defp pct(n, total), do: Float.round(n * 100 / total, 1)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
