defmodule Platform.Repo.Migrations.CreateOrgMemoryFeedback do
  use Ecto.Migration

  @moduledoc """
  Append-only ledger of edit/delete/retention signals against org memory.

  Layer 1 of the memory-feedback training corpus. Rows are captured
  synchronously inside the mutation transaction of
  `Platform.Org.Context.upsert_context_file/3` and `delete_file/1`
  (stage 2 wires the capture hooks). Read surface comes online in stage 3.

  ## Column notes

    * `feedback_kind` is a string with a CHECK constraint restricting values
      to `edit`, `delete`, or `retention`. String rather than a Postgres
      ENUM so future additions don't require a `ALTER TYPE` migration.
    * `edited_content` is NULL for delete rows (there is no successor
      content) and required for edit rows (enforced at the changeset layer).
    * No `updated_at` — the table is append-only. Once written, feedback
      rows are immutable.
  """

  def change do
    create table(:org_memory_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:original_content, :text, null: false)
      add(:edited_content, :text)
      add(:original_author_id, :uuid)
      add(:editor_id, :uuid)
      add(:path, :text, null: false)
      add(:namespace, :string, null: false)
      add(:workspace_id, :uuid)
      add(:feedback_kind, :string, null: false)
      add(:reason_text, :text)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:org_memory_feedback, :feedback_kind_must_be_known,
        check: "feedback_kind IN ('edit','delete','retention')"
      )
    )

    create(index(:org_memory_feedback, [:namespace, :path, "inserted_at DESC"]))
    create(index(:org_memory_feedback, [:workspace_id, "inserted_at DESC"]))
  end
end
