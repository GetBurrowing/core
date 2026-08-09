defmodule Platform.Repo.Migrations.CreateLifecycleStepRuns do
  @moduledoc """
  Task `019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95`, stage 1 — durable per-step
  outcome rows for lifecycle hook pipelines (ADR-0046 Amendment 1).

  Storage only. Nothing in this member calls a step, awaits one, honours a
  divert or enforces a budget; the runner is a later stage. What lands here
  is the table the runner will write and the re-entry bound will read.

  ## The unit of counting is a FIRING, not a row

  One firing of an edge writes ONE row per step, all sharing a `run_seq`.
  A three-step pipeline that fires once writes three rows with
  `run_seq = 1`. The re-entry bound asks "how many times has this edge
  fired?", so it must count DISTINCT `run_seq` — counting rows would make
  a three-step pipeline look like three firings and trip a bound of 2 on
  the very first transition. Hence the `(task_id, edge)` index: every read
  is scoped to one edge of one task.

  ## Columns

    * `task_id` — FK `tasks`, NOT NULL, indexed. A run is meaningless
      without its task and dies with it.
    * `edge` — the phase boundary that fired, e.g. `"in_progress->deploying"`.
      A string rather than an FK: edges are derived from the status
      vocabulary, not rows, and there is no edges table to point at.
    * `run_seq` — 1-based, per `(task_id, edge)`. See above.
    * `step_name` — NULLABLE. A suppressed run, or a firing of an edge with
      an empty pipeline, has no step. Making this NOT NULL would force a
      sentinel string and lose the distinction.
    * `position` — NULLABLE, for the same reason.
    * `awaited` / `can_divert` — NOT NULL. These persist WHAT THE
      DECLARATION SAID at firing time, not what the config says now. ADR-0046
      Amendment 1 decision 3 turns on `can_divert` being per-step data; a
      reader six months from now asking "was this an advisory step or a
      gate?" must get the answer from the row, because the config it was read
      from may since have changed and would answer for a different pipeline.
    * `status` — extensible string enum, guarded by the changeset only (no
      DB CHECK). See `Platform.Lifecycle.StepRun` for why the vocabulary has
      six values and why none of them may be collapsed into another.
    * `reason` — free text, NULLABLE. Why a run diverted, failed, timed out
      or was suppressed.
    * `started_at` / `finished_at` — NULLABLE. A suppressed run has neither;
      a started-and-still-running row has only the first.

  ## Deliberate omissions

    * **No unique index on `(task_id, edge, run_seq, position)`.** A
      suppressed or empty firing has a NULL position, and NULLs do not
      collide in a Postgres unique index, so the constraint would be
      silently inert exactly on the rows it looked like it covered.
    * **No `project_id`.** Reachable through `tasks`; a denormalised copy is
      a column that drifts.
  """

  use Ecto.Migration

  def change do
    create table(:lifecycle_step_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:edge, :string, null: false)
      add(:run_seq, :integer, null: false)
      add(:step_name, :string)
      add(:position, :integer)
      add(:awaited, :boolean, null: false)
      add(:can_divert, :boolean, null: false)
      add(:status, :string, null: false)
      add(:reason, :text)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:lifecycle_step_runs, [:task_id]))
    create(index(:lifecycle_step_runs, [:task_id, :edge]))
  end
end
