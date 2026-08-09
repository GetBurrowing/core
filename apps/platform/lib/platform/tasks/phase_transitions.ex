defmodule Platform.Tasks.PhaseTransitions do
  @moduledoc """
  Recording and query surface for `Platform.Tasks.PhaseTransition` rows.

  `record/2` and `list_for_task/2` are the write and read primitives;
  `decompose/2` turns the raw time series into a per-phase decomposition of
  a single task's cycle time. See `decompose/2` for the shape and for the
  interval-construction rules.

  ## Cross-task aggregation (copy-pasteable SQL)

  `decompose/2` answers for one task. For "median and p75 time in each phase
  over a date range" across many tasks, use the window-function form below.
  It reproduces the same interval construction — each row's interval runs
  from its own `occurred_at` to the NEXT row's `occurred_at` for the same
  task, and the phase that interval belongs to is the row's `to_status`.

      -- Median / p75 seconds spent in each phase, per task cohort.
      --
      -- CAVEAT: this only covers tasks CREATED AFTER the phase-transition
      -- instrumentation shipped. Tasks older than that have no rows here and
      -- are simply absent from the result — they are NOT zero-duration tasks,
      -- and nothing in this query may be changed to synthesise a duration for
      -- them from tasks.inserted_at / tasks.updated_at. See the backfill note
      -- below.
      WITH spans AS (
        SELECT
          t.task_id,
          t.to_status AS phase,
          t.occurred_at AS entered_at,
          lead(t.occurred_at) OVER (
            PARTITION BY t.task_id ORDER BY t.occurred_at, t.inserted_at
          ) AS left_at
        FROM task_phase_transitions t
        WHERE t.occurred_at >= $1 AND t.occurred_at < $2
      ),
      -- The FIRST interval of each task is not described by any row's
      -- to_status: it is the task's original status, which is the first
      -- row's from_status, running from tasks.inserted_at. Anchoring on
      -- tasks.inserted_at is legitimate HERE (it is the true start of a
      -- measured interval whose end was observed) and only here.
      first_spans AS (
        SELECT
          f.task_id,
          f.from_status AS phase,
          tk.inserted_at AS entered_at,
          f.occurred_at AS left_at
        FROM (
          SELECT DISTINCT ON (t.task_id)
            t.task_id, t.from_status, t.occurred_at
          FROM task_phase_transitions t
          ORDER BY t.task_id, t.occurred_at, t.inserted_at
        ) f
        JOIN tasks tk ON tk.id = f.task_id
        WHERE f.from_status IS NOT NULL
          AND f.occurred_at >= $1 AND f.occurred_at < $2
      ),
      all_spans AS (
        SELECT * FROM spans WHERE left_at IS NOT NULL
        UNION ALL
        SELECT * FROM first_spans
      ),
      -- Sum ACROSS VISITS first: a task may enter a phase many times
      -- (blocked and back, reopen, in_review -> in_progress). Taking the
      -- percentile over raw spans would answer a different question.
      per_task AS (
        SELECT task_id, phase, SUM(EXTRACT(EPOCH FROM (left_at - entered_at))) AS secs
        FROM all_spans
        GROUP BY task_id, phase
      )
      SELECT
        phase,
        count(*) AS tasks,
        percentile_cont(0.5)  WITHIN GROUP (ORDER BY secs) AS p50_seconds,
        percentile_cont(0.75) WITHIN GROUP (ORDER BY secs) AS p75_seconds
      FROM per_task
      GROUP BY phase
      ORDER BY p50_seconds DESC;

  ## BACKFILL IS OUT OF SCOPE AND FORBIDDEN

  Historical tasks have no transition data and it cannot be reconstructed.
  Never synthesise rows from `tasks.inserted_at` / `tasks.updated_at`, and
  never infer a transition that was not observed. A synthesised baseline
  that looks real is worse than an absent one: it silently poisons every
  aggregate computed over the table, and nobody downstream can tell the
  fabricated rows from the measured ones. A task that predates this
  instrumentation simply has no decomposition, and that is the correct
  answer.

  ## Repo argument

  `record/2` takes an explicit repo because the caller that matters records
  from inside `Ecto.Changeset.prepare_changes/2`, where the repo comes off
  the changeset and the write must land in the same transaction as the
  status change it describes.
  """

  import Ecto.Query

  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.{Plan, ReviewRequest, Task}

  @terminal_statuses ~w(done cancelled)
  @actor_kinds ~w(user agent system unknown)

  @doc """
  Insert one transition row.

  Returns `{:ok, transition}` or `{:error, changeset}`.
  """
  def record(attrs, repo \\ Platform.Repo) do
    %PhaseTransition{}
    |> PhaseTransition.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  All recorded transitions for a task, oldest first.

  Ordered by `occurred_at` then `inserted_at` — two transitions can share a
  microsecond, and interval construction downstream depends on a stable
  order.
  """
  def list_for_task(task_id, repo \\ Platform.Repo) do
    PhaseTransition
    |> where([t], t.task_id == ^task_id)
    |> order_by([t], asc: t.occurred_at, asc: t.inserted_at)
    |> repo.all()
  end

  @doc """
  Decompose one task's cycle time into per-phase durations.

  Returns `{:ok, decomposition}` or `{:error, :task_not_found}`.

      %{
        task_id: id,
        instrumented_from: ~U[...],           # tasks.inserted_at
        complete?: true,
        phases: %{
          "planning" => %{total_seconds: 3600.0, visits: 2, open?: false},
          "in_progress" => %{total_seconds: 120.0, visits: 1, open?: false}
        },
        waits: %{
          awaiting_plan_approval: %{seconds: 900.0, human: true},
          awaiting_manual_approval: :none
        },
        by_actor: %{"user" => 1200.0, "agent" => 300.0, "system" => 60.0, "unknown" => 0.0}
      }

  ## Interval construction

  Rows are read oldest first. The FIRST interval runs from `tasks.inserted_at`
  to the first row's `occurred_at`, and its phase is that row's `from_status` —
  the task's genuine original status, never the schema default and never
  anything derived from `tasks.updated_at`. Each subsequent interval runs from
  row N's `occurred_at` to row N+1's `occurred_at` in row N's `to_status`. If
  the task is not terminal (`done` / `cancelled`) the final interval is still
  running: it is measured to `DateTime.utc_now()` and its phase entry carries
  `open?: true`.

  ## No data is not zero data

  A task with zero transition rows predates this instrumentation. It gets
  `complete?: false`, `phases: %{}` and every wait `:none`. NOTHING is
  reconstructed from `inserted_at` / `updated_at` — backfill is out of scope
  and forbidden (see the moduledoc). A synthesised decomposition that looks
  real is worse than an absent one.

  `complete?` is also `false` for a task whose first recorded row starts from
  something other than the creation default `"backlog"`: that task was already
  mid-flight when instrumentation landed, so the anchor interval would absorb
  an unknown amount of pre-instrumentation time. The decomposition is still
  returned — it is just flagged as not trustworthy end to end.

  ## An absent phase is an absent key

  `phases` is NOT pre-seeded with every status. `in_progress -> deploying`
  skips review and `in_review -> done` skips deploy (the stack-member path),
  and both occur in real data. A phase that never happened must stay
  distinguishable from one that took no time.

  A task may enter a phase many times (`blocked` and back, reopen,
  `in_review -> in_progress`). `total_seconds` sums across every visit and
  `visits` reports how many there were.

  ## Sub-phase waits

  These come from existing tables, not from new instrumentation.

    * `awaiting_plan_approval` — from the approved plan's `inserted_at`
      (clamped to be no earlier than the task's entry into `planning`) to
      whichever of `approved_at` / `auto_approved_at` is set. `plans` has no
      `submitted_at` column; `inserted_at` is the available proxy for
      "submitted" and slightly OVERSTATES the wait by the drafting time.
      `human: true` when `approved_at` is set and `auto_approved_at` is nil —
      those two columns are what separate a human gate from an engine gate and
      must not be merged.
    * `awaiting_manual_approval` — the task's review requests, each running
      `inserted_at -> resolved_at` (or now, if unresolved), intersected with
      the task's `in_review` intervals, summed. `requests` is the count.

  No plan, or no review request, yields `:none` — not `0.0`.

  ## `by_actor`

  Each interval is attributed to the actor on the row that TERMINATED it, not
  the one that opened it. The actor who ends an interval is the one who was
  being waited on: a `planning` interval closed by a `user` actor was human
  wait, and the same interval closed by `system` or `agent` was engine time.
  That is the whole justification for `actor_kind` existing on the table — a
  boolean "was this automated" could not answer it, because the question is
  about who ended the wait, not who started it.

  The still-open final interval of a non-terminal task has no terminating row
  and is therefore attributed to nobody. Unlike `phases`, `by_actor` always
  carries all four buckets: it reports attribution of measured time, so a
  bucket at `0.0` means "no measured time was attributable to this kind",
  which is a real answer rather than a missing one.
  """
  def decompose(task_id, repo \\ Platform.Repo) do
    case repo.get(Task, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, build(task, list_for_task(task.id, repo), repo)}
    end
  end

  defp build(task, [], _repo) do
    %{
      task_id: task.id,
      instrumented_from: task.inserted_at,
      complete?: false,
      phases: %{},
      waits: %{awaiting_plan_approval: :none, awaiting_manual_approval: :none},
      by_actor: empty_actor_buckets()
    }
  end

  defp build(task, rows, repo) do
    intervals = intervals(task, rows)

    %{
      task_id: task.id,
      instrumented_from: task.inserted_at,
      complete?: hd(rows).from_status == "backlog",
      phases: phases(intervals),
      waits: %{
        awaiting_plan_approval: plan_wait(task, intervals, repo),
        awaiting_manual_approval: manual_approval_wait(task, intervals, repo)
      },
      by_actor: by_actor(intervals)
    }
  end

  # `{status, started_at, ended_at, terminating_row_or_nil}`.
  defp intervals(task, [first | _] = rows) do
    anchor =
      if first.from_status do
        [{first.from_status, task.inserted_at, first.occurred_at, first}]
      else
        # No prior status was recorded, so there is no phase to attribute the
        # pre-first-row time to. Attributing it anywhere would be a guess.
        []
      end

    chained =
      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [row, next] -> {row.to_status, row.occurred_at, next.occurred_at, next} end)

    last = List.last(rows)

    tail =
      if last.to_status in @terminal_statuses do
        []
      else
        [{last.to_status, last.occurred_at, DateTime.utc_now(), nil}]
      end

    anchor ++ chained ++ tail
  end

  defp phases(intervals) do
    intervals
    |> Enum.group_by(fn {status, _s, _e, _row} -> status end)
    |> Map.new(fn {status, group} ->
      {status,
       %{
         total_seconds: group |> Enum.map(&duration/1) |> Enum.sum(),
         visits: length(group),
         open?: Enum.any?(group, fn {_s, _st, _e, row} -> is_nil(row) end)
       }}
    end)
  end

  defp by_actor(intervals) do
    Enum.reduce(intervals, empty_actor_buckets(), fn
      {_status, _s, _e, nil}, acc ->
        acc

      {_status, _s, _e, row} = interval, acc ->
        Map.update(acc, row.actor_kind, duration(interval), &(&1 + duration(interval)))
    end)
  end

  defp empty_actor_buckets, do: Map.new(@actor_kinds, &{&1, 0.0})

  defp duration({_status, started_at, ended_at, _row}), do: seconds_between(started_at, ended_at)

  defp seconds_between(from, to) do
    to |> DateTime.diff(from, :microsecond) |> max(0) |> Kernel./(1_000_000)
  end

  defp plan_wait(task, intervals, repo) do
    plan =
      Plan
      |> where([p], p.task_id == ^task.id)
      |> where([p], not is_nil(p.approved_at) or not is_nil(p.auto_approved_at))
      |> order_by([p], desc: p.version, desc: p.inserted_at)
      |> limit(1)
      |> repo.one()

    case plan do
      nil ->
        :none

      plan ->
        resolved_at = plan.approved_at || plan.auto_approved_at
        started_at = clamp_to_planning(plan.inserted_at, intervals)

        %{
          seconds: seconds_between(started_at, resolved_at),
          # Auto-approval stamps `auto_approved_at`; a human gate leaves it
          # nil. Keep the two columns distinct — collapsing them erases the
          # only signal that says whether a person was waited on.
          human: not is_nil(plan.approved_at) and is_nil(plan.auto_approved_at)
        }
    end
  end

  defp clamp_to_planning(plan_inserted_at, intervals) do
    case Enum.filter(intervals, fn {status, _s, _e, _r} -> status == "planning" end) do
      [] ->
        plan_inserted_at

      planning ->
        planning
        |> Enum.map(fn {_s, started_at, _e, _r} -> started_at end)
        |> Enum.min(DateTime)
        |> latest(plan_inserted_at)
    end
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp manual_approval_wait(task, intervals, repo) do
    requests =
      ReviewRequest
      |> where([r], r.task_id == ^task.id)
      |> repo.all()

    case requests do
      [] ->
        :none

      requests ->
        now = DateTime.utc_now()

        review_intervals =
          Enum.filter(intervals, fn {status, _s, _e, _r} -> status == "in_review" end)

        seconds =
          for request <- requests, {_status, review_from, review_to, _r} <- review_intervals do
            overlap_seconds(
              request.inserted_at,
              request.resolved_at || now,
              review_from,
              review_to
            )
          end
          |> Enum.sum()

        %{seconds: seconds, requests: length(requests)}
    end
  end

  defp overlap_seconds(a_from, a_to, b_from, b_to) do
    seconds_between(latest(a_from, b_from), earliest(a_to, b_to))
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
