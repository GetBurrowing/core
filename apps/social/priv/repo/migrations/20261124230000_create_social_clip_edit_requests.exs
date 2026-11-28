defmodule Platform.Repo.Migrations.CreateSocialClipEditRequests do
  @moduledoc "Work 01a20faf: retain same-clip editing assignments, notes and return receipts."
  use Ecto.Migration

  # old-code-compatible: additive table only; older code ignores it.
  def change do
    create table(:social_clip_edit_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:position, :bigserial, null: false)

      add(:clip_id, references(:social_clips, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :base_render_id,
        references(:social_clip_renders, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:requested_by_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:assigned_user_id, references(:users, type: :binary_id, on_delete: :restrict))
      add(:assigned_agent_id, references(:agents, type: :binary_id, on_delete: :restrict))
      add(:note, :text, null: false)
      add(:client_request_id, :binary_id, null: false)
      add(:request_payload_hash, :text, null: false)
      add(:notification_status, :text)
      add(:notification_attempted_at, :utc_datetime_usec)
      add(:notification_message_id, :binary_id)

      add(
        :returned_render_id,
        references(:social_clip_renders, type: :binary_id, on_delete: :restrict)
      )

      add(:returned_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:social_clip_edit_requests, [:clip_id, :client_request_id]))
    create(unique_index(:social_clip_edit_requests, [:returned_render_id]))
    create(unique_index(:social_clip_edit_requests, [:clip_id, :position]))

    create(
      constraint(:social_clip_edit_requests, :social_clip_edit_requests_assignee,
        check: "(assigned_user_id IS NULL) <> (assigned_agent_id IS NULL)"
      )
    )

    create(
      constraint(:social_clip_edit_requests, :social_clip_edit_requests_note,
        check: "length(btrim(note)) BETWEEN 1 AND 2000"
      )
    )

    create(
      constraint(:social_clip_edit_requests, :social_clip_edit_requests_notification,
        check:
          "notification_status IS NULL OR notification_status IN ('not_applicable','attempted','sent','failed','uncertain')"
      )
    )

    create(
      constraint(:social_clip_edit_requests, :social_clip_edit_requests_return,
        check: "(returned_render_id IS NULL) = (returned_at IS NULL)"
      )
    )
  end
end
