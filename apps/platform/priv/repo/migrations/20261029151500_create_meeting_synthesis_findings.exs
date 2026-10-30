defmodule Platform.Repo.Migrations.CreateMeetingSynthesisFindings do
  @moduledoc """
  Task `01a16974-e3db-7000-97e9-8ec9611189bc`, stage 1:
  `meeting_synthesis_findings`, the shared row behind a cross-meeting
  alignment item.

  One finding can sit in SEVERAL `meeting_briefings` rows (every meeting in
  `meeting_ids`) and must resolve once for every recipient of all of them,
  so its receipt lives here, not in any one briefing's `receipts` map.

    * `dedupe_key` is unique per `org_id`: two synthesis runs, one from each
      side of the same conflict, collapse into ONE row.
    * `meeting_ids` is GIN-indexed: "the findings for meeting X" is an array
      containment probe (`meeting_ids @> ARRAY[X]`).

  Not `memory_insights`: insight rows are hard-deleted at `expires_at`,
  carry one addressee, and are surfaced by the Disseminator outside the
  meeting-briefing visibility rule.

  No `Platform.Audit.record/1`, no PubSub: migrations run before the
  supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:meeting_synthesis_findings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:origin_meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:meeting_ids, {:array, :binary_id}, null: false, default: [])
      add(:kind, :string, null: false)
      add(:confidence, :string, null: false)
      add(:body, :text, null: false)
      add(:citations, {:array, :map}, null: false, default: [])
      add(:recipient_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:receipt, :map)
      add(:dedupe_key, :string, null: false)
      add(:run_id, :binary_id)
      add(:snapshot_hash, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_synthesis_findings, [:org_id, :dedupe_key]))
    create(index(:meeting_synthesis_findings, [:meeting_ids], using: :gin))
    create(index(:meeting_synthesis_findings, [:origin_meeting_id]))
  end
end
