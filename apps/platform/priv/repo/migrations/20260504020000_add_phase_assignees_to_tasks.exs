defmodule Platform.Repo.Migrations.AddPhaseAssigneesToTasks do
  use Ecto.Migration

  @moduledoc """
  Per-phase assignees: `tasks.phase_assignees` is a jsonb map keyed by phase
  ("planning" | "execution" | "review") with an agent UUID per phase.

  The existing `tasks.assignee_id` is preserved as the *current* phase's
  assignee — derived from `phase_assignees[Tasks.current_phase(task)]` —
  and is what the task-router and existing read paths consult.

  Backfill: copy the existing `assignee_id` (and `assignee_type`) into
  all three phase keys for every task that already has an assignee, so
  previously-assigned tasks behave as the new "Simple mode" case
  automatically.
  """

  def up do
    alter table(:tasks) do
      add(:phase_assignees, :map, default: %{})
    end

    flush()

    execute("""
    UPDATE tasks
    SET phase_assignees = jsonb_build_object(
      'planning',  jsonb_build_object('assignee_id', assignee_id::text, 'assignee_type', assignee_type),
      'execution', jsonb_build_object('assignee_id', assignee_id::text, 'assignee_type', assignee_type),
      'review',    jsonb_build_object('assignee_id', assignee_id::text, 'assignee_type', assignee_type)
    )
    WHERE assignee_id IS NOT NULL
    """)
  end

  def down do
    alter table(:tasks) do
      remove(:phase_assignees)
    end
  end
end
