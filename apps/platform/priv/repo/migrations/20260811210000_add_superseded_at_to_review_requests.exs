defmodule Platform.Repo.Migrations.AddSupersededAtToReviewRequests do
  @moduledoc """
  Task `019fed8d` stage 3, defect 2: a second review request filed against the
  same `manual_approval` validation used to sit alongside the first, each with
  its own Approve button, and nothing on screen said which carried the newer
  evidence. Approving the stale one silently discarded the newer verdict.

  `create_review_request/1` now marks the earlier pending sibling
  `"superseded"`, and this column records WHEN. The timestamp is not
  decoration: the panel renders "submitted … · superseded …" so a reader can
  tell an entry that was replaced from one a human dispositioned, which
  `resolved_at` alone cannot express.

  Nullable and unbacked by an index on purpose — it is read only for rows a
  task-scoped query already selected, never as a filter.
  """
  use Ecto.Migration

  def change do
    alter table(:review_requests) do
      add(:superseded_at, :utc_datetime_usec)
    end
  end
end
