defmodule Platform.Repo.Migrations.AddPlanningStepToTasks do
  use Ecto.Migration

  @moduledoc """
  ADR-0046 member 4 (task 019f9b28-ab82) stage 1 — planning sub-phase
  cursor + per-step outcome record.

  `planning_step` is the sub-phase cursor within the planning phase:
  one of `designing | planning | architecting`. It is NOT a task
  status — `tasks.status` and the `@valid_task_transitions` table in
  `Platform.Tasks` are deliberately untouched by this task.

  `planning_step_outcomes` records, per planning step, whether the
  responsibility dispatch for that step actually happened. Shape:

      %{"architecture" => %{
          "outcome" => "complete" | "not_applicable" | "failed",
          "recorded_at" => <iso8601>,
          "detail" => <string> | nil
        }}

  The three outcomes must never collapse into two. `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
  names the bug: a dispatch failure and a genuinely-unfilled responsibility
  both normalised to `:ok`, so a gate that never ran looked identical
  to a gate that ran and passed. `not_applicable` is the
  progressive-enhancement path (nobody holds the role — fine);
  `failed` is a dispatch that was expected to run and did not.

  BACKFILL — carried by the column DEFAULT, no separate UPDATE. Every
  task that has ever existed was, sub-phase-wise, in exactly the plain
  `planning` step: design and architecture have never run for any of
  them. NULL would mean "unknown", which is not true here, and would
  force every reader to carry a nil branch for a state that cannot
  occur. `null: false, default:` mirrors `auto_approve_plan` and
  `needs_promotion`, the two most recent flag adds on this table.
  On PG11+ a non-volatile default is filled in place — no table
  rewrite.

  NO INDEX — deliberate. Both readers this task adds fetch by primary
  key or iterate an already-loaded stack-member list; there is no
  "list all tasks with a failed gate" query. Contrast
  `needs_promotion`, which added a partial index because the kanban
  genuinely does a filtered list.
  """
  def change do
    alter table(:tasks) do
      add(:planning_step, :string, default: "planning", null: false)
      add(:planning_step_outcomes, :map, default: %{}, null: false)
    end
  end
end
