defmodule Platform.Repo.Migrations.AddDescriptionAndSoftDeleteToMeetings do
  @moduledoc """
  Task 01a1b281 stage 2 (edit a scheduled meeting in place, and delete it).

    * `description` — the meeting's notes, edited through
      `Platform.Meetings.Meeting.edit_changeset/2`. Nullable: every
      existing meeting has none.
    * `deleted_at` — a soft delete. A deleted meeting drops out of every
      listing and the per-meeting calendar feed, while its transcript
      (`meeting_transcripts.meeting_id`), recordings and chat space stay
      exactly where they are.
    * `deleted_by_user_id` — who deleted it. NILIFY on delete: the deletion
      is the durable fact, the attribution is the nice-to-have.

  Raw `alter` only; nothing here reads rows through the live schema.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add(:description, :text)
      add(:deleted_at, :utc_datetime_usec)
      add(:deleted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:meetings, [:deleted_by_user_id]))
  end
end
