defmodule Platform.Repo.Migrations.AddSupersededByPlanIdToPlans do
  use Ecto.Migration

  @moduledoc """
  Adds `superseded_by_plan_id` to `plans`. Self-referential FK that points
  from a superseded plan to the plan that replaced it. Set when a new plan
  auto-marks the previous plan as superseded (lifecycle helper lives in a
  later stage). See task 019dfd5a.

  Stage 1 only adds the column + schema field. Lifecycle wiring (stage 2)
  and UI polish (stage 3) come later. No partial index for now — only add
  if query-by-supersession becomes hot.
  """

  def change do
    alter table(:plans) do
      add(:superseded_by_plan_id, references(:plans, type: :uuid, on_delete: :nilify_all),
        null: true
      )
    end
  end
end
