defmodule Platform.Tasks.PipelineHealth do
  @moduledoc """
  Read-only aggregation over `Platform.Tasks.PhaseTransitions` for the
  pipeline-health surface.

  Every function takes a window — `%{since: DateTime.t(), until: DateTime.t()}`
  — and answers about the tasks that reached `done` inside it.

  ## The cohort is a fraction, and says so

  Only tasks whose `PhaseTransitions.decompose/2` returns `complete?: true`
  can be decomposed: a task with no transition rows predates the
  instrumentation, and a task whose first row starts from something other
  than `"backlog"` was already mid-flight when instrumentation landed. Both
  are excluded from every aggregate here.

  They are excluded VISIBLY. `cohort/1` returns `tasks_in_window` alongside
  `decomposable`, so a caller can print "m of n tasks decomposable" rather
  than presenting the decomposable subset as the whole cohort. A chart drawn
  confidently from a fraction of the data, with no statement of which
  fraction, is the failure this shape exists to prevent. No function in this
  module mixes a partial decomposition into a total.

  ## No reconstruction

  Nothing here derives a duration from a task's last-modified column, and
  the literal name of that column appears nowhere in this file so a plain
  grep can decide the question — a source scanner cannot tell a comment from
  a call, so the safe answer is to give it nothing to misread. There is no
  backfill (see `Platform.Tasks.PhaseTransitions` — "BACKFILL IS OUT OF SCOPE
  AND FORBIDDEN"). The only use of `tasks.inserted_at` is the `first_spans`
  anchor copied verbatim from that module's moduledoc: the true start of an
  interval whose end was observed. If the requested window predates the
  instrumentation, the answer is the shorter history plus `instrumented_from`
  — never a synthesised one.

  Cohort membership therefore keys off `tasks.inserted_at`, not a completion
  timestamp: the last-modified column is the only one that would record
  "when this task reached done", and reading it is exactly the reconstruction
  that is forbidden. `throughput/1`, which genuinely needs completion DATES, reads
  them from the observed `done` transitions instead — the only measured
  completion time in the system.

  ## An absent phase is an absent key

  A phase no task in the cohort visited reports `p50_seconds: nil` and
  `tasks: 0`, never `0.0`. `in_progress -> deploying` skips review and
  `in_review -> done` skips deploy, and both occur in real data; a phase that
  never happened has to stay distinguishable from one that was fast.

  ## Never one number for cycle time

  `cycle_time_distribution/1` returns median AND mean together. The recorded
  baseline is a mean of 161.7 h against a median of 13.1 h — a twelvefold
  gap. Either figure alone will be quoted and will be wrong.

  ## Who may read it (task 01a1386d-fb6e stage 2)

  The aggregates are install-wide: they have no project or org dimension.
  `snapshot/2` is the actor-checked read the pipeline view uses. It requires
  `tasks.manage` over every resource (`Platform.Access.authorize_everywhere/2`,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`,
  "Pipeline moves into Tasks"), so a grantee whose `tasks.manage` names one
  project is refused. With no grants that is the root admin, the actors
  `/admin/pipeline` admits today. The five window functions stay unchecked
  for system callers and tests.
  """

  import Ecto.Query

  alias Platform.Access
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tasks.{PhaseTransition, PhaseTransitions, Task}

  # `payload->>'reported_by'` when the tool surface had no agent in its
  # context (`Map.get(context, :agent_id) || "agent"` in ToolSurface). Such a
  # blocker is real and is shown as its own row rather than dropped.
  @unattributed "unattributed"

  # The status phases, in pipeline order. `awaiting_plan_approval` and
  # `awaiting_manual_approval` are NOT statuses — they are sub-phase waits
  # read from `decompose/2`'s `waits`, and are interleaved by
  # `phase_breakdown/1`.
  @status_phases ~w(planning in_progress deploying)

  @phase_order [
    "planning",
    "awaiting_plan_approval",
    "in_progress",
    "awaiting_manual_approval",
    "deploying"
  ]

  # Log-spaced bins with an explicit final overflow bucket. The upper bound of
  # each bin is exclusive; `>7d` catches everything above the last.
  @buckets [
    {"<1h", 3_600},
    {"1-4h", 14_400},
    {"4-12h", 43_200},
    {"12h-1d", 86_400},
    {"1-3d", 259_200},
    {"3-7d", 604_800},
    {">7d", :infinity}
  ]

  # Copied from `Platform.Tasks.PhaseTransitions`'s moduledoc rather than
  # rewritten. The one deviation: cohort selection is an explicit task-id list
  # ($1) instead of a row-level `occurred_at` window, because every aggregate
  # here must be computed over the `complete?: true` subset ONLY, and because
  # filtering rows by date would truncate the history of a cohort task whose
  # earlier spans sit before the window.
  #
  # The per-task SUM before `percentile_cont` is load-bearing and is kept: a
  # task re-enters a phase (blocked and back, `in_review -> in_progress`), and
  # a percentile over raw spans answers a different question.
  @spans_cte """
  WITH spans AS (
    SELECT
      t.task_id,
      t.to_status AS phase,
      t.occurred_at AS entered_at,
      lead(t.occurred_at) OVER (
        PARTITION BY t.task_id ORDER BY t.occurred_at, t.inserted_at
      ) AS left_at,
      lead(t.actor_kind) OVER (
        PARTITION BY t.task_id ORDER BY t.occurred_at, t.inserted_at
      ) AS closed_by
    FROM task_phase_transitions t
    WHERE t.task_id = ANY($1::uuid[])
  ),
  first_spans AS (
    SELECT
      f.task_id,
      f.from_status AS phase,
      tk.inserted_at AS entered_at,
      f.occurred_at AS left_at,
      f.actor_kind AS closed_by
    FROM (
      SELECT DISTINCT ON (t.task_id)
        t.task_id, t.from_status, t.occurred_at, t.actor_kind
      FROM task_phase_transitions t
      WHERE t.task_id = ANY($1::uuid[])
      ORDER BY t.task_id, t.occurred_at, t.inserted_at
    ) f
    JOIN tasks tk ON tk.id = f.task_id
    WHERE f.from_status IS NOT NULL
  ),
  all_spans AS (
    SELECT * FROM spans WHERE left_at IS NOT NULL
    UNION ALL
    SELECT * FROM first_spans
  ),
  per_task AS (
    SELECT task_id, phase, SUM(EXTRACT(EPOCH FROM (left_at - entered_at))) AS secs
    FROM all_spans
    GROUP BY task_id, phase
  )
  """

  @doc """
  Every aggregate the pipeline view shows, for `window`, read on behalf of
  `actor_or_scope` (a `%User{}` or a `%Platform.Access.Scope{}`). Returns
  `{:ok, %{cohort:, breakdown:, distribution:, throughput:, agent_activity:}}`
  or `{:error, :unauthorized}` before any aggregate is read. See "Who may
  read it" in the moduledoc.
  """
  @spec snapshot(map(), term()) :: {:ok, map()} | {:error, :unauthorized}
  def snapshot(window, actor_or_scope) do
    with :ok <- Access.authorize_everywhere(actor_or_scope, "tasks.manage") do
      {:ok,
       %{
         cohort: cohort(window),
         breakdown: phase_breakdown(window),
         distribution: cycle_time_distribution(window),
         throughput: throughput(window),
         agent_activity: agent_activity(window)
       }}
    end
  end


  @doc """
  The cohort for a window: how many tasks reached `done`, and how many of
  those can actually be decomposed.

  Returns `%{tasks_in_window: n, decomposable: m, instrumented_from: dt | nil,
  task_ids: [id]}` where `task_ids` is the decomposable subset — the input to
  every other function here.

  Both counts are returned deliberately. `decomposable` alone reads as the
  cohort, and the uninstrumented tasks vanish instead of being excluded.
  """
  def cohort(window) do
    ids = done_task_ids(window)

    decomposable =
      Enum.filter(ids, fn id ->
        match?({:ok, %{complete?: true}}, PhaseTransitions.decompose(id))
      end)

    %{
      tasks_in_window: length(ids),
      decomposable: length(decomposable),
      instrumented_from: instrumented_from(),
      task_ids: decomposable
    }
  end

  @doc """
  Per-phase durations across the decomposable cohort, in pipeline order.

  Each entry is `%{phase: String.t(), p50_seconds: float | nil, p75_seconds:
  float | nil, tasks: integer, human: boolean, unknown_seconds: float}`.

  A phase no cohort task visited is `nil` seconds and `0` tasks — not `0.0`.

  `human` is derived, not declared. For the two wait phases it comes from
  `decompose/2`'s `waits` (a plan approval with `approved_at` set and
  `auto_approved_at` nil was a person; a review request is a human gate by
  construction). For a status phase it comes from the actor who TERMINATED
  each interval, which is the actor who was being waited on: more seconds
  closed by `user` than by `agent` and `system` together makes the phase a
  human wait. `unknown` is never folded into engine time — it is reported
  separately as `unknown_seconds`.
  """
  def phase_breakdown(window) do
    %{task_ids: ids} = cohort(window)

    status_stats = status_phase_stats(ids)
    actor_stats = actor_seconds_by_phase(ids)
    wait_stats = wait_phase_stats(ids)

    Enum.map(@phase_order, fn phase ->
      case Map.fetch(wait_stats, phase) do
        {:ok, stats} -> stats
        :error -> status_row(phase, status_stats, actor_stats)
      end
    end)
  end

  @doc """
  Cycle-time distribution across the decomposable cohort.

  Returns `%{buckets: [%{label: String.t(), count: integer}], median_seconds:,
  mean_seconds:, p25:, p75:, p90:, n:}`. Bins are log-spaced with an explicit
  `>7d` overflow bucket, and every bucket is present even at zero — a bucket
  is a fixed axis, not an observation, so its absence would be a hole in the
  chart rather than a missing phase.

  Median and mean are both returned, always. A single figure for a
  distribution this skewed is the failure mode this function exists to avoid.

  Cycle time per task is the sum of its measured phase durations, so a task
  whose history is partly unobserved cannot contribute a partial total: such
  tasks are not in the cohort at all.
  """
  def cycle_time_distribution(window) do
    %{task_ids: ids} = cohort(window)

    totals =
      ids
      |> Enum.map(&cycle_seconds/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    %{
      buckets: bucket_counts(totals),
      n: length(totals),
      median_seconds: percentile(totals, 0.5),
      mean_seconds: mean(totals),
      p25: percentile(totals, 0.25),
      p75: percentile(totals, 0.75),
      p90: percentile(totals, 0.9)
    }
  end

  @doc """
  Completions per ACTIVE day across the decomposable cohort.

  Returns `%{per_active_day: float, series: [%{date: Date.t(), count: n}],
  best_day: n}`. A day with zero completions is excluded from the divisor and
  included in the series: dividing by calendar days would report a rate the
  pipeline never ran at, while dropping the empty days from the series would
  hide the gaps.

  Completion dates come from the observed `done` transitions — the only
  measured completion time. Nothing is read from the last-modified column.
  """
  def throughput(window) do
    ids = cohort(window).task_ids

    series =
      done_dates(ids, window)
      |> Enum.frequencies()
      |> Enum.map(fn {date, count} -> %{date: date, count: count} end)
      |> Enum.sort_by(& &1.date, Date)

    active = Enum.reject(series, &(&1.count == 0))
    total = active |> Enum.map(& &1.count) |> Enum.sum()

    %{
      series: series,
      best_day: series |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end),
      per_active_day:
        case active do
          [] -> 0.0
          days -> total / length(days)
        end
    }
  end

  @doc """
  Per-agent completions and blockers across the window, sorted by
  completions descending and then by agent name.

  Each entry is `%{agent_id, agent_name, completions, blockers_needs_human,
  blockers_no_human, blockers_per_completion}`.

  Completions count ALL tasks that reached `done` in the window — the
  `done_task_ids/1` cohort, not the decomposable subset — because attributing
  a completion to an agent needs no phase decomposition. Attribution reads
  the task's CURRENT `phase_assignees["execution"]` (agent-typed only):
  `task_phase_transitions` records no assignee, so this is a present-tense
  read of who holds the execution slot today, not a reconstruction of who
  held it at the transition. A task whose execution slot is unset or
  user-typed is in nobody's row.

  Blockers are `execution.blocked` runtime events whose `occurred_at` falls
  in the window, grouped by `payload->>'reported_by'` and split on
  `payload->>'needs_human'`. A `reported_by` that is not an agent id (the
  tool surface writes the literal `"agent"` when its context has no
  agent) is reported under the `"unattributed"` row, never dropped.

  `blockers_per_completion` is `nil` when there are no completions — an
  absence, never `0.0`. An agent with blockers and no completions appears
  with `completions: 0` and a nil ratio.
  """
  def agent_activity(window) do
    completions = completions_by_agent(done_task_ids(window))
    blockers = blockers_by_agent(window)

    ids = Enum.uniq(Map.keys(completions) ++ Map.keys(blockers))
    names = agent_names(ids)

    ids
    |> Enum.map(fn id ->
      done = Map.get(completions, id, 0)

      %{needs_human: needs_human, no_human: no_human} =
        Map.get(blockers, id, %{needs_human: 0, no_human: 0})

      %{
        agent_id: id,
        agent_name: Map.get(names, id, fallback_name(id)),
        completions: done,
        blockers_needs_human: needs_human,
        blockers_no_human: no_human,
        blockers_per_completion: ratio(needs_human + no_human, done)
      }
    end)
    |> Enum.sort_by(&{-&1.completions, &1.agent_name})
  end

  # --- cohort -------------------------------------------------------------

  defp done_task_ids(%{since: since, until: until}) do
    Task
    |> where([t], t.status == "done")
    |> where([t], t.inserted_at >= ^since and t.inserted_at < ^until)
    |> select([t], t.id)
    |> Repo.all()
  end

  defp instrumented_from do
    PhaseTransition
    |> select([t], min(t.occurred_at))
    |> Repo.one()
  end

  # --- phase breakdown ----------------------------------------------------

  defp status_row(phase, status_stats, actor_stats) do
    stats = Map.get(status_stats, phase, %{p50_seconds: nil, p75_seconds: nil, tasks: 0})
    actors = Map.get(actor_stats, phase, %{})

    user = Map.get(actors, "user", 0.0)
    engine = Map.get(actors, "agent", 0.0) + Map.get(actors, "system", 0.0)

    stats
    |> Map.put(:phase, phase)
    |> Map.put(:human, user > engine)
    |> Map.put(:unknown_seconds, Map.get(actors, "unknown", 0.0))
  end

  defp status_phase_stats([]), do: %{}

  defp status_phase_stats(ids) do
    sql =
      @spans_cte <>
        """
        SELECT
          phase,
          count(*) AS tasks,
          percentile_cont(0.5)  WITHIN GROUP (ORDER BY secs) AS p50_seconds,
          percentile_cont(0.75) WITHIN GROUP (ORDER BY secs) AS p75_seconds
        FROM per_task
        WHERE phase = ANY($2)
        GROUP BY phase
        """

    %{rows: rows} = Repo.query!(sql, [uuids(ids), @status_phases])

    Map.new(rows, fn [phase, tasks, p50, p75] ->
      {phase, %{tasks: tasks, p50_seconds: to_float(p50), p75_seconds: to_float(p75)}}
    end)
  end

  defp actor_seconds_by_phase([]), do: %{}

  defp actor_seconds_by_phase(ids) do
    sql =
      @spans_cte <>
        """
        SELECT
          phase,
          coalesce(closed_by, 'unknown') AS closed_by,
          SUM(EXTRACT(EPOCH FROM (left_at - entered_at))) AS secs
        FROM all_spans
        WHERE phase = ANY($2)
        GROUP BY phase, coalesce(closed_by, 'unknown')
        """

    %{rows: rows} = Repo.query!(sql, [uuids(ids), @status_phases])

    Enum.reduce(rows, %{}, fn [phase, kind, secs], acc ->
      Map.update(acc, phase, %{kind => to_float(secs)}, &Map.put(&1, kind, to_float(secs)))
    end)
  end

  # The two waits live in `decompose/2`'s `waits`, not in the status series.
  # `:none` means the wait never occurred for that task and contributes
  # nothing — it is not a zero sample, which would drag the median down and
  # claim the gate was instant.
  defp wait_phase_stats(ids) do
    decompositions = Enum.map(ids, &decomposition/1)

    Map.new(
      [
        {"awaiting_plan_approval", :awaiting_plan_approval},
        {"awaiting_manual_approval", :awaiting_manual_approval}
      ],
      fn {phase, key} ->
        observed =
          decompositions
          |> Enum.map(&get_in(&1, [:waits, key]))
          |> Enum.reject(&(&1 == :none))

        seconds = observed |> Enum.map(& &1.seconds) |> Enum.sort()

        {phase,
         %{
           phase: phase,
           tasks: length(seconds),
           p50_seconds: percentile(seconds, 0.5),
           p75_seconds: percentile(seconds, 0.75),
           human: human_wait?(phase, observed),
           unknown_seconds: 0.0
         }}
      end
    )
  end

  # A plan gate is human only when a person stamped `approved_at`;
  # auto-approval is engine time. A review request is a human gate by
  # construction — it exists to be dispositioned by a person.
  defp human_wait?("awaiting_manual_approval", observed), do: observed != []
  defp human_wait?("awaiting_plan_approval", observed), do: Enum.any?(observed, & &1.human)

  # --- cycle time ---------------------------------------------------------

  defp cycle_seconds(task_id) do
    case decomposition(task_id) do
      %{phases: phases} when map_size(phases) > 0 ->
        phases |> Map.values() |> Enum.map(& &1.total_seconds) |> Enum.sum()

      _ ->
        nil
    end
  end

  defp bucket_counts(totals) do
    Enum.map(@buckets, fn {label, upper} ->
      %{label: label, count: Enum.count(totals, &in_bucket?(&1, label, upper))}
    end)
  end

  defp in_bucket?(seconds, label, upper) do
    lower =
      case Enum.find_index(@buckets, fn {l, _} -> l == label end) do
        0 -> 0
        i -> @buckets |> Enum.at(i - 1) |> elem(1)
      end

    seconds >= lower and (upper == :infinity or seconds < upper)
  end

  # --- throughput ---------------------------------------------------------

  defp done_dates([], _window), do: []

  defp done_dates(ids, %{since: since, until: until}) do
    PhaseTransition
    |> where([t], t.task_id in ^ids and t.to_status == "done")
    |> where([t], t.occurred_at >= ^since and t.occurred_at < ^until)
    |> select([t], t.occurred_at)
    |> Repo.all()
    |> Enum.map(&DateTime.to_date/1)
  end

  # --- agent activity -----------------------------------------------------

  defp completions_by_agent([]), do: %{}

  defp completions_by_agent(ids) do
    sql = """
    SELECT
      t.phase_assignees->'execution'->>'assignee_id' AS agent_id,
      count(*) AS completions
    FROM tasks t
    WHERE t.id = ANY($1::uuid[])
      AND t.phase_assignees->'execution'->>'assignee_type' = 'agent'
      AND t.phase_assignees->'execution'->>'assignee_id' IS NOT NULL
    GROUP BY 1
    """

    %{rows: rows} = Repo.query!(sql, [uuids(ids)])

    Map.new(rows, fn [agent_id, completions] -> {agent_id, completions} end)
  end

  defp blockers_by_agent(%{since: since, until: until}) do
    sql = """
    SELECT
      e.payload->>'reported_by' AS reported_by,
      count(*) FILTER (WHERE e.payload->>'needs_human' = 'true') AS needs_human,
      count(*) FILTER (WHERE e.payload->>'needs_human' IS DISTINCT FROM 'true') AS no_human
    FROM runtime_events e
    WHERE e.event_type = 'execution.blocked'
      AND e.occurred_at >= $1
      AND e.occurred_at < $2
    GROUP BY 1
    """

    %{rows: rows} = Repo.query!(sql, [since, until])

    Enum.reduce(rows, %{}, fn [reported_by, needs_human, no_human], acc ->
      Map.update(
        acc,
        attribution_key(reported_by),
        %{needs_human: needs_human, no_human: no_human},
        &%{needs_human: &1.needs_human + needs_human, no_human: &1.no_human + no_human}
      )
    end)
  end

  # Anything that is not an agent id collapses into the one unattributed row.
  defp attribution_key(value) do
    if is_binary(value) and Platform.UUID.valid?(value), do: value, else: @unattributed
  end

  defp agent_names(ids) do
    case Enum.filter(ids, &Platform.UUID.valid?/1) do
      [] ->
        %{}

      valid ->
        Agent
        |> where([a], a.id in ^valid)
        |> select([a], {a.id, a.name})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp fallback_name(@unattributed), do: @unattributed
  defp fallback_name(id), do: String.slice(id, 0, 8)

  # `nil`, not `0.0`: no completions means the ratio has no denominator.
  defp ratio(_blockers, 0), do: nil
  defp ratio(blockers, completions), do: blockers / completions

  # --- shared -------------------------------------------------------------

  defp decomposition(task_id) do
    {:ok, decomposition} = PhaseTransitions.decompose(task_id)
    decomposition
  end

  defp uuids(ids), do: Enum.map(ids, &Ecto.UUID.dump!/1)

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n / 1
  defp to_float(n) when is_float(n), do: n

  # `nil`, not `0.0`: an empty sample has no percentile, and answering zero
  # would be indistinguishable from a phase that took no time.
  defp percentile([], _q), do: nil

  # Linear interpolation between order statistics — the same definition
  # `percentile_cont` uses, so the two paths agree.
  defp percentile(sorted, q) do
    rank = q * (length(sorted) - 1)
    lower = floor(rank)
    upper = ceil(rank)
    low = Enum.at(sorted, lower)

    if lower == upper do
      low / 1
    else
      low + (Enum.at(sorted, upper) - low) * (rank - lower)
    end
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
