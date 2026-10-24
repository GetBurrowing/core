defmodule Platform.Repo.Migrations.CreateMeetingBriefings do
  @moduledoc """
  Task `01a1694a-676e-7000-a653-5e1e6db65205`, stage 1: `meeting_briefings`,
  the per-meeting after-action briefing delivered to every attendee's Inbox.

  ONE row per meeting (`meeting_id` is unique), with ONE shared `receipts`
  map. That is why this is a new table and not `memory_briefings`: there a
  row belongs to one person and one day, `(user_id, digest_date)` is unique,
  and each person's receipts live on their own row, so an item one attendee
  resolved could never show as resolved to another.

    * `attendee_user_ids` — the people the briefing is for; GIN-indexed so
      "is this user an attendee of this briefing" is an index probe.
    * `items` — node key → item (`kind`, `ref`, `title`, `filed_status`).
    * `receipts` — node key → how the item was resolved, shared by everyone.
    * `summary` / `transcript_id` — copied from the meeting's completed
      transcript when one exists.

  No `Platform.Audit.record/1`, no PubSub: migrations run before the
  supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:meeting_briefings, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:attendee_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:items, :map, null: false, default: %{})
      add(:receipts, :map, null: false, default: %{})
      add(:summary, :text)
      add(:transcript_id, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_briefings, [:meeting_id]))
    create(index(:meeting_briefings, [:attendee_user_ids], using: :gin))
  end
end
