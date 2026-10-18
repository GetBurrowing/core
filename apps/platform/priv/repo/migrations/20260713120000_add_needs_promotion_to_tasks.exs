defmodule Platform.Repo.Migrations.AddNeedsPromotionToTasks do
  use Ecto.Migration

  @moduledoc """
  Meeting-triage `needs_promotion` flag (task 019f5e2b-8d29 stage 2).

  Set to true by `Platform.Meetings.Triage.file_tasks_from_canvas/2`
  while the per-project triage-backlog count is under
  `:meetings_triage_backlog_cap` (default 10). Cleared by
  `Platform.Tasks.promote/1` when the kanban badge is clicked. Above
  cap: filed with `needs_promotion: false` so the review path still
  sees them but the badge doesn't render.

  A dedicated boolean (rather than a metadata JSONB key) gives the
  kanban a partial index for the badge-count the designer may want later —
  metadata JSONB would need a functional index.
  """
  def change do
    alter table(:tasks) do
      add(:needs_promotion, :boolean, default: false, null: false)
    end

    create(
      index(:tasks, [:needs_promotion],
        where: "needs_promotion = true",
        name: :tasks_needs_promotion_partial_idx
      )
    )
  end
end
