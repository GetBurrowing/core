# Manual-approval gate baseline — READ-ONLY measurement.
#
# Task 01a00b91 stage 1. Answers: are manual_approval gates actually catching
# anything, or are they waved through? Every query below is a SELECT via
# `Repo.all` / `Repo.one`. There is no INSERT/UPDATE/DELETE and no DDL here,
# deliberately: this script exists so anyone who distrusts the numbers can
# re-derive them without taking a writer's word for it.
#
#   cd apps/platform && mix run priv/repo/queries/manual_gate_baseline.exs
#
# Connection details come from config/env only — never literals. Point it at
# whichever database you mean to measure; the script prints the database name
# it read so the output can never be mistaken for a different one.
#
# Definitions used (stated so a reader can disagree with them explicitly):
#
#   * COHORT — the most recent `@cohort_size` tasks that reached an approved
#     plan, ranked by the newest `plans.approved_at` on the task.
#   * WAVE-THROUGH — a `resolved` review_request whose items are all
#     `approved`. REJECTION — a `resolved` request with >= 1 item at
#     `needs_revision`.
#   * `superseded` requests are NOT verdicts: no human dispositioned them.
#     They are excluded from BOTH sides of the rejection rate, mirroring the
#     unresolved-row treatment in
#     `lib/platform/experiments/metrics/failure_rate.ex`, which excludes
#     pending/running rather than scoring them as successes. `pending`
#     requests are excluded for the same reason.
#   * PLAN AUTHOR — `tasks.phase_assignees["planning"]["assignee_id"]`.
#     `plans` carries no author column, so the planning-phase assignee is the
#     closest durable proxy; `plans.approved_by` is the APPROVER, a different
#     actor, and is not used for attribution.
#   * UI-TOUCHING PLAN — any stage in the approved plan whose name or
#     description matches @ui_pattern. A text heuristic, not a fact.

import Ecto.Query
alias Platform.Repo
alias Platform.Tasks.{Plan, ReviewItem, ReviewRequest, Stage, Task, Validation}

cohort_size = 30

ui_pattern =
  ~r/\b(ui|ux|liveview|live_view|heex|screenshot|css|tailwind|render|layout|component|mobile|viewport|button|modal|page|nav|icon|visual)\b/i

defmodule ManualGateBaseline do
  def pct(_num, 0), do: "n/a"
  def pct(num, den), do: "#{Float.round(num * 100 / den, 1)}%"

  def line, do: String.duplicate("-", 72)

  def header(text) do
    IO.puts("\n" <> text)
    IO.puts(line())
  end
end

IO.puts(ManualGateBaseline.line())
IO.puts("manual_approval gate baseline")
IO.puts("database: #{Repo.config()[:database]}")
IO.puts("generated_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}")
IO.puts(ManualGateBaseline.line())

# ---------------------------------------------------------------------------
# Cohort: most recent N tasks that reached an approved plan.
# ---------------------------------------------------------------------------

cohort =
  from(p in Plan,
    where: not is_nil(p.approved_at),
    group_by: p.task_id,
    select: %{task_id: p.task_id, approved_at: max(p.approved_at)},
    order_by: [desc: max(p.approved_at)],
    limit: ^cohort_size
  )
  |> Repo.all()

cohort_ids = Enum.map(cohort, & &1.task_id)

total_approved_tasks =
  from(p in Plan, where: not is_nil(p.approved_at), select: count(p.task_id, :distinct))
  |> Repo.one()

IO.puts("\ntasks with an approved plan, all time: #{total_approved_tasks}")
IO.puts("cohort size (most recent): #{length(cohort_ids)}")

if cohort != [] do
  IO.puts("cohort window: #{List.last(cohort).approved_at} .. #{List.first(cohort).approved_at}")
end

# Task-level facts for the cohort: title-free (core is public), author proxy,
# and whether any approved-plan stage looks UI-touching.
task_rows =
  from(t in Task,
    where: t.id in ^cohort_ids,
    select: %{id: t.id, phase_assignees: t.phase_assignees}
  )
  |> Repo.all()

author_by_task =
  Map.new(task_rows, fn r ->
    author =
      case r.phase_assignees do
        %{"planning" => %{"assignee_id" => id}} when is_binary(id) -> id
        _ -> "(unassigned)"
      end

    {r.id, author}
  end)

stage_rows =
  from(s in Stage,
    join: p in Plan,
    on: p.id == s.plan_id,
    where: p.task_id in ^cohort_ids and not is_nil(p.approved_at),
    select: %{task_id: p.task_id, name: s.name, description: s.description}
  )
  |> Repo.all()

ui_task_ids =
  stage_rows
  |> Enum.filter(fn s ->
    text = "#{s.name} #{s.description}"
    Regex.match?(ui_pattern, text)
  end)
  |> Enum.map(& &1.task_id)
  |> MapSet.new()

# ---------------------------------------------------------------------------
# (a) manual_approval validations in the cohort.
# ---------------------------------------------------------------------------

validations =
  from(v in Validation,
    join: s in Stage,
    on: s.id == v.stage_id,
    join: p in Plan,
    on: p.id == s.plan_id,
    where: v.kind == "manual_approval" and p.task_id in ^cohort_ids and not is_nil(p.approved_at),
    select: %{id: v.id, task_id: p.task_id, status: v.status}
  )
  |> Repo.all()

all_validations =
  from(v in Validation,
    join: s in Stage,
    on: s.id == v.stage_id,
    join: p in Plan,
    on: p.id == s.plan_id,
    where: p.task_id in ^cohort_ids and not is_nil(p.approved_at),
    select: v.kind
  )
  |> Repo.all()

ManualGateBaseline.header("(a) manual_approval validations")
IO.puts("manual_approval validations: #{length(validations)}")
IO.puts("all validations in cohort:   #{length(all_validations)}")

IO.puts(
  "share of all validations:    #{ManualGateBaseline.pct(length(validations), length(all_validations))}"
)

IO.puts(
  "tasks carrying >= 1 manual_approval: #{validations |> Enum.map(& &1.task_id) |> Enum.uniq() |> length()}"
)

IO.puts("\nby validation status:")

validations
|> Enum.frequencies_by(& &1.status)
|> Enum.sort()
|> Enum.each(fn {k, n} -> IO.puts("  #{String.pad_trailing(k, 12)} #{n}") end)

validation_ids = Enum.map(validations, & &1.id)
# ---------------------------------------------------------------------------
# (b) review_requests bound to those validations: rejection vs wave-through.
# ---------------------------------------------------------------------------

requests =
  from(r in ReviewRequest,
    where: r.validation_id in ^validation_ids,
    select: %{id: r.id, validation_id: r.validation_id, task_id: r.task_id, status: r.status}
  )
  |> Repo.all()

request_ids = Enum.map(requests, & &1.id)

items =
  from(i in ReviewItem,
    where: i.review_request_id in ^request_ids,
    select: %{
      id: i.id,
      review_request_id: i.review_request_id,
      status: i.status,
      canvas_id: i.canvas_id,
      content: i.content
    }
  )
  |> Repo.all()

items_by_request = Enum.group_by(items, & &1.review_request_id)

resolved = Enum.filter(requests, &(&1.status == "resolved"))

{rejections, wave_throughs} =
  Enum.split_with(resolved, fn r ->
    items_by_request
    |> Map.get(r.id, [])
    |> Enum.any?(&(&1.status == "needs_revision"))
  end)

ManualGateBaseline.header("(b) verdicts on those gates")
IO.puts("review_requests bound to manual_approval validations: #{length(requests)}")

requests
|> Enum.frequencies_by(& &1.status)
|> Enum.sort()
|> Enum.each(fn {k, n} -> IO.puts("  #{String.pad_trailing(k, 12)} #{n}") end)

IO.puts("\nverdicts (resolved only; pending and superseded excluded from both sides):")
IO.puts("  resolved:      #{length(resolved)}")
IO.puts("  REJECTION:     #{length(rejections)}  (>= 1 item needs_revision)")
IO.puts("  WAVE-THROUGH:  #{length(wave_throughs)}  (all items approved)")

IO.puts(
  "  rejection rate: #{ManualGateBaseline.pct(length(rejections), length(resolved))} of resolved gates"
)

gates_with_verdict_by_task = Enum.group_by(resolved, & &1.task_id)

tasks_with_a_rejection =
  rejections |> Enum.map(& &1.task_id) |> Enum.uniq() |> length()

IO.puts("\nper-task view:")
IO.puts("  tasks with >= 1 resolved manual gate: #{map_size(gates_with_verdict_by_task)}")
IO.puts("  ... of which >= 1 produced a rejection: #{tasks_with_a_rejection}")

IO.puts(
  "  => #{ManualGateBaseline.pct(tasks_with_a_rejection, map_size(gates_with_verdict_by_task))} of gated tasks caught something"
)

# ---------------------------------------------------------------------------
# (c) evidence shape: screenshot (canvas_id) vs text-only padding.
# ---------------------------------------------------------------------------

with_canvas = Enum.count(items, &(not is_nil(&1.canvas_id) and &1.canvas_id != ""))

text_only =
  Enum.count(items, fn i ->
    (is_nil(i.canvas_id) or i.canvas_id == "") and not is_nil(i.content) and i.content != ""
  end)

empty = length(items) - with_canvas - text_only

ManualGateBaseline.header("(c) evidence shape of review_items")
IO.puts("review_items: #{length(items)}")

IO.puts(
  "  with canvas_id (screenshot): #{with_canvas}  #{ManualGateBaseline.pct(with_canvas, length(items))}"
)

IO.puts(
  "  content only (text padding): #{text_only}  #{ManualGateBaseline.pct(text_only, length(items))}"
)

IO.puts("  neither:                     #{empty}")

IO.puts("\nitem dispositions:")

items
|> Enum.frequencies_by(& &1.status)
|> Enum.sort()
|> Enum.each(fn {k, n} -> IO.puts("  #{String.pad_trailing(k, 15)} #{n}") end)

# ---------------------------------------------------------------------------
# (d) human touches after plan approval, per task, split by UI-touching plan.
# ---------------------------------------------------------------------------
# Counts ALL resolved review_requests on the task (not only the ones bound to
# manual_approval validations in the cohort) — a "human touch" is a human
# dispositioning a request, whatever gate filed it.

all_resolved_by_task =
  from(r in ReviewRequest,
    where: r.task_id in ^cohort_ids and r.status == "resolved",
    group_by: r.task_id,
    select: {r.task_id, count(r.id)}
  )
  |> Repo.all()
  |> Map.new()

touches =
  Enum.map(cohort_ids, fn id ->
    {id, Map.get(all_resolved_by_task, id, 0), MapSet.member?(ui_task_ids, id)}
  end)

summarise = fn rows ->
  n = length(rows)
  total = rows |> Enum.map(fn {_, c, _} -> c end) |> Enum.sum()
  mean = if n == 0, do: 0.0, else: Float.round(total / n, 2)
  zero = Enum.count(rows, fn {_, c, _} -> c == 0 end)
  {n, total, mean, zero}
end

{ui_rows, non_ui_rows} = Enum.split_with(touches, fn {_, _, ui} -> ui end)

ManualGateBaseline.header("(d) human touches after plan approval, per task")

for {label, rows} <- [
      {"UI-touching plan", ui_rows},
      {"no UI-touching stage", non_ui_rows},
      {"ALL", touches}
    ] do
  {n, total, mean, zero} = summarise.(rows)

  IO.puts(
    "  #{String.pad_trailing(label, 22)} tasks=#{n} resolved_requests=#{total} mean=#{mean} tasks_with_zero=#{zero}"
  )
end

# ---------------------------------------------------------------------------
# (e) attribution by plan author — is padding systemic or concentrated?
# ---------------------------------------------------------------------------

by_author =
  cohort_ids
  |> Enum.group_by(&Map.get(author_by_task, &1, "(unknown)"))
  |> Enum.map(fn {author, ids} ->
    id_set = MapSet.new(ids)
    v = Enum.filter(validations, &MapSet.member?(id_set, &1.task_id))
    v_ids = MapSet.new(v, & &1.id)
    reqs = Enum.filter(requests, &MapSet.member?(v_ids, &1.validation_id))
    res = Enum.filter(reqs, &(&1.status == "resolved"))

    rej =
      Enum.count(res, fn r ->
        items_by_request |> Map.get(r.id, []) |> Enum.any?(&(&1.status == "needs_revision"))
      end)

    its = Enum.flat_map(reqs, &Map.get(items_by_request, &1.id, []))
    canvas = Enum.count(its, &(not is_nil(&1.canvas_id) and &1.canvas_id != ""))

    %{
      author: author,
      tasks: length(ids),
      manual_validations: length(v),
      resolved: length(res),
      rejections: rej,
      items: length(its),
      items_with_canvas: canvas
    }
  end)
  |> Enum.sort_by(& &1.manual_validations, :desc)

ManualGateBaseline.header("(e) by plan author (planning-phase assignee)")

IO.puts(
  "  #{String.pad_trailing("author", 38)} tasks  manual_v  resolved  rejects  items  w/canvas"
)

total_manual = length(validations)

Enum.each(by_author, fn a ->
  IO.puts(
    "  #{String.pad_trailing(a.author, 38)} " <>
      "#{String.pad_leading(to_string(a.tasks), 5)}  " <>
      "#{String.pad_leading(to_string(a.manual_validations), 8)}  " <>
      "#{String.pad_leading(to_string(a.resolved), 8)}  " <>
      "#{String.pad_leading(to_string(a.rejections), 7)}  " <>
      "#{String.pad_leading(to_string(a.items), 5)}  " <>
      "#{String.pad_leading(to_string(a.items_with_canvas), 8)}"
  )
end)

top_two =
  by_author |> Enum.take(2) |> Enum.map(& &1.manual_validations) |> Enum.sum()

IO.puts(
  "\n  top-2 authors hold #{top_two}/#{total_manual} manual_approval validations " <>
    "(#{ManualGateBaseline.pct(top_two, total_manual)}) across #{length(by_author)} authors"
)

ManualGateBaseline.header("verdict inputs")

IO.puts(
  "  (i)  rejection rate over resolved gates: " <>
    "#{ManualGateBaseline.pct(length(rejections), length(resolved))} " <>
    "— threshold for 'already acceptable' is ~33%"
)

IO.puts(
  "  (ii) concentration: top-2 authors hold #{ManualGateBaseline.pct(top_two, total_manual)} of manual gates"
)

IO.puts("")
