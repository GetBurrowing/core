defmodule Platform.Repo.Migrations.AddActorUserIdToFeedbackSubmissions do
  @moduledoc """
  Task 01a1a6a5 stage 2: a signed-in person can be the feedback actor
  (`Platform.Feedback.PersonForm`), so `feedback_submissions` gains
  `actor_user_id` beside `actor_agent_id`.

  Like `actor_agent_id` it carries no foreign key: the row is a rate ledger
  and idempotency key, and holds no submission text. `(actor_user_id,
  inserted_at)` backs the per-person rate window. The check constraint keeps
  at most one actor column set per row.
  """
  use Ecto.Migration

  def change do
    alter table(:feedback_submissions) do
      add(:actor_user_id, :binary_id)
    end

    create(index(:feedback_submissions, [:actor_user_id, :inserted_at]))

    create(
      constraint(:feedback_submissions, :feedback_submissions_one_actor_check,
        check: "num_nonnulls(actor_agent_id, actor_user_id) <= 1"
      )
    )
  end
end
