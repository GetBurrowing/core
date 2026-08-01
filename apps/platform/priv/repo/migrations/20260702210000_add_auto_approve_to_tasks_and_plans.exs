defmodule Platform.Repo.Migrations.AddAutoApproveToTasksAndPlans do
  use Ecto.Migration

  @moduledoc """
  Auto-approve plan (task 019f25f2) — stage 1 of 5. Schema foundation only;
  state-machine wiring, MCP surface, UI, and serializer expansion land in
  later stages.

    * `tasks.auto_approve_plan` (bool, default false) — opt-in flag on the
      parent task. When set, the planner's `submit_plan_for_review/1` should
      short-circuit to `approve_plan` instead of pausing at pending_review.
      Non-null default false keeps existing rows explicit and preserves the
      current manual-review behaviour.

    * `plans.auto_approved_at` (utc_datetime_usec, null) — timestamp
      recorded when the auto-approval fires, distinct from `approved_at`
      which will still be set by the shared approval codepath. Nullable
      because most plans reach approval through manual review and won't
      carry this marker.
  """

  def up do
    alter table(:tasks) do
      add(:auto_approve_plan, :boolean, null: false, default: false)
    end

    alter table(:plans) do
      add(:auto_approved_at, :utc_datetime_usec, null: true)
    end
  end

  def down do
    alter table(:plans) do
      remove(:auto_approved_at)
    end

    alter table(:tasks) do
      remove(:auto_approve_plan)
    end
  end
end
