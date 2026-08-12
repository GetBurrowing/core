defmodule Platform.Repo.Migrations.AddReviewRoundCountToTasks do
  @moduledoc """
  Task `019ff788` stage 3: bound the review-gate → `in_progress` loop.

  Nothing bounded it before this column existed — no counter, no `@max_*`
  constant in the router or the plan engine, and no code path that set a
  task's status back to `"planning"` on a gate failure. A task could bounce
  between the behavioural review gate and implementation forever.

  The column counts GENUINE gate-failure rounds only: a review that could
  not be RUN (dev server will not boot, un-buildable fixture, known flake)
  raises a blocker and leaves this value alone, so a broken environment
  cannot burn three rounds and re-plan a feature that was never wrong. See
  `Platform.Tasks.ReviewDisposition` for the seam that carries that
  distinction.

  Non-null with a `0` default so every existing row starts with a full
  allowance rather than a NULL the bound would have to special-case. No
  index: it is read only for a task row the router has already loaded by
  id, never as a filter.
  """
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:review_round_count, :integer, null: false, default: 0)
    end
  end
end
